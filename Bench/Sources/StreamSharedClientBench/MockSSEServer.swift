// MockSSEServer
// =============
// A loopback SSE server that streams OpenAI-Responses-shaped events with
// configurable TTFB and inter-chunk gaps. Mirrors the IOSNetworkBench fake
// server's `/v1/responses` streaming path but trimmed to only what this bench
// needs.
//
// Latency knobs (env-driven, see BenchConfig):
//   BENCH_TTFB_MS         baseline ms before first chunk
//   BENCH_TTFB_JITTER_MS  +/- jitter applied to TTFB
//   BENCH_CHUNK_GAP_MS    gap between successive delta chunks
//   BENCH_RATE_LIMIT_EVERY_N  inject 429 every Nth request (0 = never)
//
// Connection handling: HTTP/1.1 keep-alive, optional gzip on the buffered
// (non-stream) path, chunked transfer-encoding on the streaming path.

import Foundation
import Network
import Compression

final class MockSSEServer {
    private let queue = DispatchQueue(label: "MockSSEServer.queue")
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private let config: BenchConfig
    private var requestCounter: Int = 0
    private let counterLock = NSLock()

    private init(listener: NWListener, config: BenchConfig) {
        self.listener = listener
        self.config = config
    }

    static func start(config: BenchConfig) throws -> MockSSEServer {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        let server = MockSSEServer(listener: listener, config: config)
        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak server] state in
            switch state {
            case .ready:
                if let p = listener.port?.rawValue {
                    server?.port = p
                }
                started.signal()
            case .failed(let err):
                NSLog("MockSSEServer: listener failed: \(err)")
                started.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak server] connection in
            server?.handle(connection: connection)
        }
        listener.start(queue: server.queue)
        _ = started.wait(timeout: .now() + 5)
        guard server.port > 0 else { throw NWError.posix(.EADDRINUSE) }
        return server
    }

    func stop() {
        listener.cancel()
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection: connection, buffer: Data())
    }

    private func readRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var combined = buffer
                combined.append(data)
                if let req = ParsedRequest.tryParse(combined) {
                    self.serve(request: req, on: connection)
                } else if isComplete {
                    self.send400(connection: connection)
                } else {
                    self.readRequest(connection: connection, buffer: combined)
                }
            } else if isComplete || error != nil {
                connection.cancel()
            }
        }
    }

    private func serve(request: ParsedRequest, on connection: NWConnection) {
        counterLock.lock()
        requestCounter += 1
        let n = requestCounter
        counterLock.unlock()

        // Optional rate-limit injection.
        if config.mockRateLimitEveryN > 0, n % config.mockRateLimitEveryN == 0 {
            send429(connection: connection)
            return
        }

        // TTFB before any response bytes.
        let ttfb = config.mockTTFBMs + Int.random(in: -config.mockTTFBJitterMs...config.mockTTFBJitterMs)
        usleep(UInt32(max(ttfb, 0) * 1000))

        if request.method == "HEAD" {
            sendHEAD(connection: connection, request: request)
            return
        }

        let path = request.path
        if path.contains("/v1/responses") {
            if request.isStreaming {
                sendOpenAIStream(connection: connection, request: request)
            } else {
                sendBufferedResponse(connection: connection, request: request)
            }
            return
        }
        // Default 200 ok for other paths.
        sendBufferedResponse(connection: connection, request: request)
    }

    private func sendHEAD(connection: NWConnection, request: ParsedRequest) {
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Length: 0",
            "Connection: keep-alive",
            "Keep-Alive: timeout=15"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            self.maybeKeepAlive(connection: connection, request: request)
        })
    }

    private func sendBufferedResponse(connection: NWConnection, request: ParsedRequest) {
        // Mimic the LLM finishing generation before flushing the buffered
        // response: the buffered path pays the same total chunk-gap cost as a
        // 4-chunk stream would, but only after generation is complete. This
        // is what makes streaming win in real life -- the user sees the first
        // delta before the model finishes the rest of the output.
        let generationMs = config.mockChunkGapMs * 4 // 4 chunks worth of generation
        usleep(UInt32(generationMs * 1000))

        // Repeated body for measurable bytesIn (~1.5 KB).
        let raw = String(repeating: "Improved sentence here. ", count: 60)
        let json = "{\"id\":\"resp_xx\",\"output_text\":\"\(raw)\"}"
        var bodyData = Data(json.utf8)
        var contentEncoding: String? = nil
        if request.acceptsGzip, let gz = bodyData.gzipped() {
            bodyData = gz
            contentEncoding = "gzip"
        }
        var headerLines = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(bodyData.count)",
            "Connection: keep-alive",
            "Keep-Alive: timeout=15"
        ]
        if let ce = contentEncoding { headerLines.append("Content-Encoding: \(ce)") }
        let header = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(bodyData)
        connection.send(content: packet, completion: .contentProcessed { _ in
            self.maybeKeepAlive(connection: connection, request: request)
        })
    }

    private func sendOpenAIStream(connection: NWConnection, request: ParsedRequest) {
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/event-stream",
            "Cache-Control: no-cache",
            "Connection: keep-alive",
            "Transfer-Encoding: chunked"
        ].joined(separator: "\r\n") + "\r\n\r\n"

        let phrases = [
            "Improved transcript: ",
            "lorem ipsum dolor sit amet, ",
            "consectetur adipiscing elit. ",
            "Duis aute irure dolor in reprehenderit. "
        ]

        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in
            // First delta = paid TTFB. Send immediately, then space the rest.
            let firstEvent = """
            event: response.output_text.delta
            data: {"type":"response.output_text.delta","delta":"\(phrases[0])"}\n\n
            """
            connection.send(content: Self.encodeChunk(firstEvent), completion: .contentProcessed { _ in })
            for i in 1..<phrases.count {
                usleep(UInt32(self.config.mockChunkGapMs * 1000))
                let event = """
                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"\(phrases[i])"}\n\n
                """
                connection.send(content: Self.encodeChunk(event), completion: .contentProcessed { _ in })
            }
            usleep(UInt32(self.config.mockChunkGapMs * 1000))
            let done = """
            event: response.completed
            data: {"type":"response.completed"}\n\n
            """
            connection.send(content: Self.encodeChunk(done), completion: .contentProcessed { _ in })
            connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in
                self.maybeKeepAlive(connection: connection, request: request)
            })
        })
    }

    private func send429(connection: NWConnection) {
        let body = "{\"error\":{\"message\":\"rate limited\",\"type\":\"rate_limit\"}}"
        let bodyData = Data(body.utf8)
        let header = [
            "HTTP/1.1 429 Too Many Requests",
            "Content-Type: application/json",
            "Content-Length: \(bodyData.count)",
            "Retry-After: 1",
            "Connection: keep-alive"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(bodyData)
        connection.send(content: packet, completion: .contentProcessed { _ in })
    }

    private func send400(connection: NWConnection) {
        let body = "bad request"
        let header = "HTTP/1.1 400 Bad Request\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        let packet = Data(header.utf8) + Data(body.utf8)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func maybeKeepAlive(connection: NWConnection, request: ParsedRequest) {
        if request.wantsKeepAlive {
            self.readRequest(connection: connection, buffer: Data())
        } else {
            connection.cancel()
        }
    }

    private static func encodeChunk(_ s: String) -> Data {
        let payload = Data(s.utf8)
        let header = String(payload.count, radix: 16, uppercase: false) + "\r\n"
        var out = Data(header.utf8)
        out.append(payload)
        out.append(Data("\r\n".utf8))
        return out
    }
}

// ---------- request parsing ----------
struct ParsedRequest {
    let method: String
    let path: String
    let httpVersion: String
    let headers: [String: String]
    let body: Data

    var wantsKeepAlive: Bool {
        if let h = headers["connection"]?.lowercased() {
            return h.contains("keep-alive") || (httpVersion == "HTTP/1.1" && !h.contains("close"))
        }
        return httpVersion == "HTTP/1.1"
    }

    var acceptsGzip: Bool {
        guard let h = headers["accept-encoding"]?.lowercased() else { return false }
        return h.contains("gzip")
    }

    var isStreaming: Bool {
        if let v = headers["x-bench-stream"]?.lowercased(), v == "1" || v == "true" { return true }
        if let accept = headers["accept"]?.lowercased(), accept.contains("text/event-stream") { return true }
        if path.contains("stream=true") { return true }
        return false
    }

    static func tryParse(_ data: Data) -> ParsedRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerBlob = data.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerString = String(data: headerBlob, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ").map(String.init)
        guard parts.count == 3 else { return nil }
        let method = parts[0]
        let path = parts[1]
        let version = parts[2]
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let i = line.firstIndex(of: ":") {
                let key = String(line[..<i]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        let bodyStart = headerEnd.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyAvailable = data.count - bodyStart
        if contentLength > 0 && bodyAvailable < contentLength {
            return nil
        }
        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<min(bodyStart + contentLength, data.count))
            : Data()
        return ParsedRequest(method: method, path: path, httpVersion: version, headers: headers, body: body)
    }
}

// ---------- gzip helpers ----------
extension Data {
    func gzipped() -> Data? {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        guard let raw = self.compressed(using: COMPRESSION_ZLIB) else { return nil }
        out.append(raw)
        let crc = self.crc32()
        var crcLE = crc.littleEndian
        let isize = UInt32(self.count & 0xFFFFFFFF).littleEndian
        var isizeLE = isize
        out.append(Data(bytes: &crcLE, count: 4))
        out.append(Data(bytes: &isizeLE, count: 4))
        return out
    }

    fileprivate func compressed(using algo: compression_algorithm) -> Data? {
        let dstSize = self.count + 64 + (self.count / 16)
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstSize)
        defer { dst.deallocate() }
        let written = self.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            guard let base = src.baseAddress else { return 0 }
            return compression_encode_buffer(dst, dstSize, base.assumingMemoryBound(to: UInt8.self), self.count, nil, algo)
        }
        if written == 0 { return nil }
        return Data(bytes: dst, count: written)
    }

    fileprivate func crc32() -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in self {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                let mask = UInt32(0) &- (crc & 1)
                crc = (crc >> 1) ^ (0xEDB88320 & mask)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
