// Local HTTP/1.1 mock server simulating OpenAI/Gemini/Anthropic latency profiles.
// Uses Network.framework so we get loopback TCP without third-party deps.
//
// Latency profile defaults (configurable via env):
//   - TTFB jitter: 80ms +/- 30ms (mobile-LTE-ish first-byte)
//   - body chunks: streamed in 4 chunks with 30ms gaps to mimic generation
//   - audio upload throughput: 600 KB/s (mock server reads multipart at this rate)
//
// The server returns OpenAI-shaped JSON for /v1/audio/transcriptions and
// /v1/responses. We don't simulate auth.

import Foundation
import Network

final class MockServer {
    struct Config {
        var ttfbMillis: Int = 80
        var ttfbJitterMillis: Int = 30
        var bodyChunkCount: Int = 4
        var bodyChunkGapMillis: Int = 30
        // Bytes per second drained from inbound multipart upload (simulates upstream throughput).
        var inboundThroughputBytesPerSecond: Int = 600_000
        // If non-zero, return 429 every Nth request to exercise retry path.
        var rateLimitEveryN: Int = 0
        // Streaming output for /v1/responses (server-sent events).
        var supportsResponseStream: Bool = true
        // Honor Accept-Encoding: gzip on responses; honors Content-Encoding: gzip for body decode.
        var honorGzip: Bool = true
    }

    private let queue = DispatchQueue(label: "MockServer.queue")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0
    let config: Config
    private(set) var totalRequests: Int = 0
    private var requestCounter: Int = 0
    private let counterLock = NSLock()

    init(config: Config = Config()) {
        self.config = config
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.handle(connection: connection)
        }
        let started = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    self?.port = port
                }
                started.signal()
            case .failed(let err):
                NSLog("MockServer: listener failed: \(err)")
                started.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        _ = started.wait(timeout: .now() + 5)
    }

    func stop() {
        listener?.cancel()
        listener = nil
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
                if let request = ParsedRequest.tryParse(combined) {
                    self.serve(request: request, on: connection)
                } else if isComplete {
                    self.send400(connection: connection)
                } else {
                    self.readRequest(connection: connection, buffer: combined)
                }
            } else if let error {
                NSLog("MockServer: receive error: \(error)")
                connection.cancel()
            } else if isComplete {
                connection.cancel()
            }
        }
    }

    private func serve(request: ParsedRequest, on connection: NWConnection) {
        counterLock.lock()
        requestCounter += 1
        totalRequests += 1
        let n = requestCounter
        counterLock.unlock()

        // Optional rate-limit injection.
        if config.rateLimitEveryN > 0, n % config.rateLimitEveryN == 0 {
            send429(connection: connection)
            return
        }

        // Inbound throughput: pretend the body took (size / throughput) seconds to upload.
        if request.body.count > 1024, config.inboundThroughputBytesPerSecond > 0 {
            let seconds = Double(request.body.count) / Double(config.inboundThroughputBytesPerSecond)
            let micros = UInt32(seconds * 1_000_000.0)
            usleep(min(micros, 5_000_000))
        }

        // Decide route.
        let path = request.path
        let isStream = request.queryAndHeadersIncludeStream

        // TTFB delay.
        let ttfb = config.ttfbMillis + Int.random(in: -config.ttfbJitterMillis...config.ttfbJitterMillis)
        usleep(UInt32(max(ttfb, 0) * 1000))

        if path.contains("/v1/audio/transcriptions") {
            sendJSON(connection: connection, request: request, body: transcribeJSON())
            return
        }

        if path.contains("/v1/responses") {
            if isStream && config.supportsResponseStream {
                sendOpenAIStream(connection: connection, request: request)
            } else {
                sendJSON(connection: connection, request: request, body: improveJSON())
            }
            return
        }

        if path.contains("/v1/messages") {
            // Anthropic messages-shaped response.
            sendJSON(connection: connection, request: request, body: anthropicJSON())
            return
        }

        if path.contains("generateContent") {
            sendJSON(connection: connection, request: request, body: geminiJSON())
            return
        }

        sendJSON(connection: connection, request: request, body: "{\"ok\":true}")
    }

    // ---------- response helpers ----------
    private func sendJSON(connection: NWConnection, request: ParsedRequest, body: String) {
        let bodyData = Data(body.utf8)
        let useGzip = config.honorGzip && request.acceptsGzip && bodyData.count > 256
        let encoded: Data
        if useGzip {
            if let gz = bodyData.gzipped() {
                encoded = gz
            } else {
                encoded = bodyData
            }
        } else {
            encoded = bodyData
        }

        var headers = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json",
            "Content-Length: \(encoded.count)",
            "Connection: keep-alive",
            "Keep-Alive: timeout=15"
        ]
        if useGzip {
            headers.append("Content-Encoding: gzip")
        }
        let header = headers.joined(separator: "\r\n") + "\r\n\r\n"

        // Chunked body simulating server-side generation.
        let chunks = chunked(encoded, count: config.bodyChunkCount)
        var packet = Data(header.utf8)
        if chunks.count <= 1 {
            packet.append(encoded)
            connection.send(content: packet, completion: .contentProcessed { _ in
                self.maybeKeepAlive(connection: connection, request: request)
            })
            return
        }
        // Send headers + first chunk together, then space remaining.
        packet.append(chunks[0])
        connection.send(content: packet, completion: .contentProcessed { _ in })
        for i in 1..<chunks.count {
            usleep(UInt32(self.config.bodyChunkGapMillis * 1000))
            connection.send(content: chunks[i], completion: .contentProcessed { _ in
                if i == chunks.count - 1 {
                    self.maybeKeepAlive(connection: connection, request: request)
                }
            })
        }
    }

    private func sendOpenAIStream(connection: NWConnection, request: ParsedRequest) {
        // Streaming SSE for /v1/responses with text deltas.
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
            var sentBytes = 0
            for phrase in phrases {
                let event = """
                event: response.output_text.delta
                data: {"type":"response.output_text.delta","delta":"\(phrase)"}\n\n
                """
                sentBytes += event.count
                let chunk = Self.encodeChunk(event)
                connection.send(content: chunk, completion: .contentProcessed { _ in })
                usleep(UInt32(self.config.bodyChunkGapMillis * 1000))
            }
            let done = """
            event: response.completed
            data: {"type":"response.completed"}\n\n
            """
            let chunk = Self.encodeChunk(done)
            connection.send(content: chunk, completion: .contentProcessed { _ in })
            // Final chunked terminator.
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
            // Loop back to read the next request on this connection.
            self.readRequest(connection: connection, buffer: Data())
        } else {
            connection.cancel()
        }
    }

    private func chunked(_ data: Data, count: Int) -> [Data] {
        guard count > 1, data.count > 64 else { return [data] }
        let size = max(1, data.count / count)
        var out: [Data] = []
        var i = 0
        while i < data.count {
            let end = min(i + size, data.count)
            out.append(data.subdata(in: i..<end))
            i = end
        }
        return out
    }

    private static func encodeChunk(_ s: String) -> Data {
        let payload = Data(s.utf8)
        let header = String(payload.count, radix: 16, uppercase: false) + "\r\n"
        var out = Data(header.utf8)
        out.append(payload)
        out.append(Data("\r\n".utf8))
        return out
    }

    // ---------- canned bodies ----------
    private func transcribeJSON() -> String {
        return "{\"text\":\"Hello, this is a transcribed sentence with several words to mimic a real session.\"}"
    }

    private func improveJSON() -> String {
        // ~1.5 KB output_text shape mimicking OpenAI Responses API.
        let text = String(repeating: "Improved version of the transcript. ", count: 12)
        return "{\"id\":\"resp_xx\",\"output_text\":\"\(text)\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"\(text)\"}]}]}"
    }

    private func anthropicJSON() -> String {
        let text = String(repeating: "Improved version of the transcript. ", count: 12)
        return "{\"id\":\"msg_xx\",\"content\":[{\"type\":\"text\",\"text\":\"\(text)\"}]}"
    }

    private func geminiJSON() -> String {
        let text = String(repeating: "Improved version of the transcript. ", count: 12)
        return "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"\(text)\"}]}}]}"
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

    var queryAndHeadersIncludeStream: Bool {
        // Bench protocol: clients indicate streaming via X-Bench-Stream header for /v1/responses.
        if let v = headers["x-bench-stream"]?.lowercased(), v == "1" || v == "true" { return true }
        // Or query string ?stream=true
        return path.contains("stream=true")
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
            return nil // need more bytes
        }
        let body = contentLength > 0
            ? data.subdata(in: bodyStart..<min(bodyStart + contentLength, data.count))
            : Data()
        return ParsedRequest(method: method, path: path, httpVersion: version, headers: headers, body: body)
    }
}

// ---------- gzip helpers ----------
import Compression

extension Data {
    /// Gzip-compress the receiver. Uses zlib RAW + manual gzip envelope so we don't depend on libz spec mismatch.
    func gzipped() -> Data? {
        // Header: 1f 8b 08 00 00 00 00 00 00 ff
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff])
        let raw = self.compressed(using: COMPRESSION_ZLIB) // raw deflate
        guard let raw else { return nil }
        out.append(raw)
        // Append CRC32 + ISIZE (little-endian).
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
