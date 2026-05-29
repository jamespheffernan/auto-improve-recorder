import Foundation
import Network

// Minimal HTTP/1.1 loopback server that mimics the OpenAI transcriptions endpoint.
// Drains the multipart body and returns either {"text":"..."} JSON or plain text.
// EDIT BOUNDARY: NOT MUTABLE BY TRIALS — keep behaviour identical so timing is comparable.

actor FakeServer {
    private let port: NWEndpoint.Port
    private let listener: NWListener
    private(set) var url: URL
    /// Text returned for every request, regardless of audio content.
    let returnText: String
    /// Synthetic delay added to mimic the inference half of the API.
    let serverDelay: TimeInterval
    /// Token-bucket shaper for INBOUND request body (uplink).
    /// 0 = unshaped (loopback speed). Otherwise kbps (kilobits/sec).
    let uplinkKbps: Int

    init(
        port: UInt16 = 0,
        returnText: String = "the quick brown fox jumps over the lazy dog",
        serverDelay: TimeInterval = 0.0,
        uplinkKbps: Int = 0
    ) throws {
        let parameters = NWParameters.tcp
        parameters.allowFastOpen = true
        let portValue: NWEndpoint.Port
        if port == 0 {
            portValue = .any
        } else {
            portValue = NWEndpoint.Port(rawValue: port)!
        }
        let listener = try NWListener(using: parameters, on: portValue)
        self.listener = listener
        self.port = portValue
        self.returnText = returnText
        self.serverDelay = serverDelay
        self.uplinkKbps = uplinkKbps
        // Will be replaced once the kernel assigns an ephemeral port.
        self.url = URL(string: "http://127.0.0.1:1/v1/audio/transcriptions")!
    }

    func start() async throws {
        let started = AsyncStream<UInt16> { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let raw = self.listener.port?.rawValue {
                        continuation.yield(raw)
                        continuation.finish()
                    }
                case .failed:
                    continuation.finish()
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.handle(connection: connection) }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        for await rawPort in started {
            self.url = URL(string: "http://127.0.0.1:\(rawPort)/v1/audio/transcriptions")!
            return
        }
        throw NSError(domain: "FakeServer", code: 1)
    }

    func stop() {
        listener.cancel()
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var collected = Data()
        var headerEnd: Range<Data.Index>? = nil
        var contentLength: Int? = nil
        var bodyStart: Int = 0
        let uplinkKbpsCaptured = self.uplinkKbps
        let serverDelayCaptured = self.serverDelay
        let returnTextCaptured = self.returnText

        // Token-bucket pacer for the uplink. We pace by sleeping before re-arming
        // the receive callback. The rate is in bytes/sec = uplinkKbps * 1000 / 8.
        // Sleep = chunkBytes / bytesPerSec. This emulates a lossless link with a
        // fixed serialisation rate. Loopback is so fast that each receive fires
        // immediately, so the chunk-by-chunk sleep dominates.
        let bytesPerSec: Double = uplinkKbpsCaptured > 0
            ? Double(uplinkKbpsCaptured) * 1000.0 / 8.0
            : 0.0

        func receiveLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                let chunkBytes = data?.count ?? 0
                if let data, !data.isEmpty {
                    collected.append(data)
                    if headerEnd == nil {
                        if let r = collected.range(of: Data("\r\n\r\n".utf8)) {
                            headerEnd = r
                            bodyStart = r.upperBound
                            let headerString = String(decoding: collected[..<r.lowerBound], as: UTF8.self)
                            for line in headerString.split(separator: "\r\n") {
                                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                                if parts.count == 2, parts[0].lowercased() == "content-length" {
                                    contentLength = Int(parts[1])
                                }
                            }
                        }
                    }
                }
                let haveAllBody: Bool = {
                    guard let cl = contentLength else { return false }
                    return collected.count - bodyStart >= cl
                }()
                if haveAllBody || error != nil || isComplete {
                    Task {
                        // Per-chunk pacing in the receive loop already serialises the
                        // upload at the configured rate, so we only add the inference
                        // tail (serverDelay) here.
                        if serverDelayCaptured > 0 {
                            try? await Task.sleep(nanoseconds: UInt64(serverDelayCaptured * 1_000_000_000))
                        }
                        let respText = returnTextCaptured
                        let plain = "{\"text\":\"\(respText)\"}"
                        let bodyData = Data(plain.utf8)
                        let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
                        var out = Data(resp.utf8)
                        out.append(bodyData)
                        connection.send(content: out, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                    }
                } else {
                    // Pace the inbound receive by chunk size before re-arming.
                    // This stretches the upload across the wire-time of the data.
                    if bytesPerSec > 0 && chunkBytes > 0 {
                        let chunkSec = Double(chunkBytes) / bytesPerSec
                        let deadline = DispatchTime.now() + .milliseconds(Int(chunkSec * 1000.0))
                        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: deadline) {
                            receiveLoop()
                        }
                    } else {
                        receiveLoop()
                    }
                }
            }
        }
        receiveLoop()
    }
}
