// Trial-editable iOS engine clones (mirror AutoImproveRecorderIOS network code paths).
//
// EDIT BOUNDARY for the autoresearch loop: only this file should change between trials.
// We mirror the iOS engines so the bench measures the same network shape (multipart upload,
// JSON Responses API, retry/backoff). When a trial wins, port the change back to the
// AutoImproveRecorder/Engines/*.swift in a follow-up commit.

import Foundation

// ---------- shared types ----------
struct EngineMetrics {
    var bytesIn: Int = 0
    var bytesOut: Int = 0
    var retries: Int = 0
    var streamFirstTokenMs: Int? = nil
}

enum BenchError: Error {
    case invalidResponse
    case serverStatus(Int)
}

protocol BenchTranscriber {
    func transcribe(audioBytes: Data, baseURL: URL) async throws -> (text: String, metrics: EngineMetrics)
}

protocol BenchImprover {
    func improve(rawTranscript: String, baseURL: URL) async throws -> (text: String, metrics: EngineMetrics)
}

// ---------- variant registry ----------
// The bench picks a variant via the BENCH_VARIANT env var. Each variant is a
// concrete (transcriber, improver) pair plus a label.
enum Variant: String {
    case baseline           // ephemeral session, no compression, no streaming, no warm-up
    case keepAlive          // shared persistent URLSession with keep-alive + warm DNS
    case gzipImprove        // shared session + Accept-Encoding gzip + Content-Encoding gzip on improve
    case http2Hints         // keepAlive + assumesHTTP3Capable + accept gzip
    case speculative        // run improve speculatively in parallel with audio upload finalization (toy: warm TCP)
    case streaming          // Responses API streaming (text/event-stream) for first-token TTFB
    case combined           // keepAlive + gzip + streaming + retry/backoff with jittered cap
    case combinedNoStream   // keepAlive + gzip + retry/backoff (control: combined without streaming)

    static func current() -> Variant {
        let raw = ProcessInfo.processInfo.environment["BENCH_VARIANT"] ?? "baseline"
        return Variant(rawValue: raw) ?? .baseline
    }
}

// ---------- session factories ----------
enum Sessions {
    // Per-call ephemeral (mirrors current iOS code).
    static func ephemeral() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 60
        return URLSession(configuration: cfg)
    }

    // Shared, persistent, keep-alive friendly.
    static let shared: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 60
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.httpShouldUsePipelining = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    // Shared session that opts into HTTP/3 hints + gzip Accept-Encoding default.
    static let h2: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 60
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.httpShouldUsePipelining = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        // assumesHTTP3Capable was added in iOS 18 / macOS 14.x; using KVC for forward-compat.
        cfg.setValue(true, forKey: "assumesHTTP3Capable")
        cfg.httpAdditionalHeaders = ["Accept-Encoding": "gzip"]
        return URLSession(configuration: cfg)
    }()
}

// ---------- transcribers ----------
struct MultipartTranscriber: BenchTranscriber {
    let useSharedSession: Bool
    let acceptGzip: Bool
    let extraHeaders: [String: String]

    func transcribe(audioBytes: Data, baseURL: URL) async throws -> (text: String, metrics: EngineMetrics) {
        let url = baseURL.appendingPathComponent("v1/audio/transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if acceptGzip { request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding") }
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

        var body = Data()
        func append(_ s: String) { body.append(Data(s.utf8)) }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\ngpt-4o-transcribe\r\n")
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"clip.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(audioBytes)
        append("\r\n--\(boundary)--\r\n")
        request.httpBody = body
        let bytesOut = body.count

        let session = useSharedSession ? Sessions.shared : Sessions.ephemeral()
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw BenchError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw BenchError.serverStatus(http.statusCode) }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["text"] as? String
        else { throw BenchError.invalidResponse }

        var metrics = EngineMetrics()
        metrics.bytesIn = data.count
        metrics.bytesOut = bytesOut
        return (text, metrics)
    }
}

// ---------- improvers ----------
struct ResponsesImprover: BenchImprover {
    let useSharedSession: Bool
    let acceptGzip: Bool
    let compressRequest: Bool
    let stream: Bool
    let extraHeaders: [String: String]
    let retryOn429: Bool

    func improve(rawTranscript: String, baseURL: URL) async throws -> (text: String, metrics: EngineMetrics) {
        let url = baseURL.appendingPathComponent("v1/responses")
        // Build instructions/input bodies of realistic size.
        let instructions = String(repeating: "You are a careful editor. ", count: 8)
        let body: [String: Any] = [
            "model": "gpt-5.4-mini",
            "instructions": instructions,
            "input": rawTranscript
        ]
        let raw = try JSONSerialization.data(withJSONObject: body, options: [])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if acceptGzip { request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding") }
        if stream { request.setValue("1", forHTTPHeaderField: "X-Bench-Stream") }
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

        var bytesOut = raw.count
        if compressRequest, let gz = raw.gzippedRequest(), gz.count < raw.count {
            request.setValue("gzip", forHTTPHeaderField: "Content-Encoding")
            request.httpBody = gz
            bytesOut = gz.count
        } else {
            request.httpBody = raw
        }

        let session = useSharedSession ? Sessions.shared : Sessions.ephemeral()
        var attempts = 0
        var totalBytesIn = 0
        var firstTokenMs: Int? = nil

        while true {
            attempts += 1
            let start = Date()
            do {
                if stream {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw BenchError.invalidResponse }
                    if http.statusCode == 429, retryOn429, attempts <= 3 {
                        await sleep(ms: backoffMs(attempts: attempts))
                        continue
                    }
                    guard (200..<300).contains(http.statusCode) else { throw BenchError.serverStatus(http.statusCode) }

                    var assembled = ""
                    var sawFirstDelta = false
                    var streamBytes = 0
                    for try await line in bytes.lines {
                        streamBytes += line.utf8.count + 1
                        if line.hasPrefix("data: ") {
                            let payload = String(line.dropFirst(6))
                            if !sawFirstDelta {
                                sawFirstDelta = true
                                firstTokenMs = Int(Date().timeIntervalSince(start) * 1000)
                            }
                            if payload == "[DONE]" { break }
                            if let data = payload.data(using: .utf8),
                               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                               let delta = obj["delta"] as? String {
                                assembled += delta
                            } else if let data = payload.data(using: .utf8),
                                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                      let type = obj["type"] as? String, type == "response.completed" {
                                break
                            }
                        }
                    }
                    var metrics = EngineMetrics()
                    metrics.bytesIn = streamBytes
                    metrics.bytesOut = bytesOut
                    metrics.retries = attempts - 1
                    metrics.streamFirstTokenMs = firstTokenMs
                    return (assembled.trimmingCharacters(in: .whitespacesAndNewlines), metrics)
                } else {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw BenchError.invalidResponse }
                    if http.statusCode == 429, retryOn429, attempts <= 3 {
                        await sleep(ms: backoffMs(attempts: attempts))
                        continue
                    }
                    guard (200..<300).contains(http.statusCode) else { throw BenchError.serverStatus(http.statusCode) }
                    totalBytesIn = data.count
                    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                    let text = (json["output_text"] as? String) ?? ""
                    var metrics = EngineMetrics()
                    metrics.bytesIn = totalBytesIn
                    metrics.bytesOut = bytesOut
                    metrics.retries = attempts - 1
                    return (text, metrics)
                }
            } catch let err as BenchError {
                if case .serverStatus(let s) = err, s == 429, retryOn429, attempts <= 3 {
                    await sleep(ms: backoffMs(attempts: attempts))
                    continue
                }
                throw err
            }
        }
    }

    private func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    private func backoffMs(attempts: Int) -> Int {
        // Exponential with jitter: 100, 200, 400 ms +/- 25%.
        let base = 100 * Int(pow(2.0, Double(attempts - 1)))
        let jitter = Int.random(in: -base/4 ... base/4)
        return max(20, base + jitter)
    }
}

// ---------- factory ----------
struct ResolvedEngines {
    let label: String
    let transcriber: BenchTranscriber
    let improver: BenchImprover
    // If true, the runner kicks off improve() speculatively in parallel with transcribe.
    let speculativeKickoff: Bool
}

func resolveEngines() -> ResolvedEngines {
    switch Variant.current() {
    case .baseline:
        return ResolvedEngines(
            label: "baseline (ephemeral, no gzip, no stream)",
            transcriber: MultipartTranscriber(useSharedSession: false, acceptGzip: false, extraHeaders: [:]),
            improver: ResponsesImprover(useSharedSession: false, acceptGzip: false, compressRequest: false, stream: false, extraHeaders: [:], retryOn429: false),
            speculativeKickoff: false
        )
    case .keepAlive:
        return ResolvedEngines(
            label: "keep-alive shared URLSession",
            transcriber: MultipartTranscriber(useSharedSession: true, acceptGzip: false, extraHeaders: [:]),
            improver: ResponsesImprover(useSharedSession: true, acceptGzip: false, compressRequest: false, stream: false, extraHeaders: [:], retryOn429: false),
            speculativeKickoff: false
        )
    case .gzipImprove:
        return ResolvedEngines(
            label: "shared + gzip improve (req+resp)",
            transcriber: MultipartTranscriber(useSharedSession: true, acceptGzip: true, extraHeaders: [:]),
            improver: ResponsesImprover(useSharedSession: true, acceptGzip: true, compressRequest: true, stream: false, extraHeaders: [:], retryOn429: false),
            speculativeKickoff: false
        )
    case .http2Hints:
        return ResolvedEngines(
            label: "shared h2/h3-hint + accept-gzip",
            transcriber: MultipartTranscriber(useSharedSession: true, acceptGzip: true, extraHeaders: [:]),
            improver: ResponsesImprover(useSharedSession: true, acceptGzip: true, compressRequest: false, stream: false, extraHeaders: [:], retryOn429: false),
            speculativeKickoff: false
        )
    case .speculative:
        return ResolvedEngines(
            label: "shared + warm-tcp speculative kickoff",
            transcriber: MultipartTranscriber(useSharedSession: true, acceptGzip: true, extraHeaders: [:]),
            improver: ResponsesImprover(useSharedSession: true, acceptGzip: true, compressRequest: true, stream: false, extraHeaders: [:], retryOn429: false),
            speculativeKickoff: true
        )
    case .streaming:
        return ResolvedEngines(
            label: "shared + streaming improve",
            transcriber: MultipartTranscriber(useSharedSession: true, acceptGzip: true, extraHeaders: [:]),
            improver: ResponsesImprover(useSharedSession: true, acceptGzip: true, compressRequest: false, stream: true, extraHeaders: [:], retryOn429: false),
            speculativeKickoff: false
        )
    case .combined:
        return ResolvedEngines(
            label: "combined: shared+gzip+stream+retry",
            transcriber: MultipartTranscriber(useSharedSession: true, acceptGzip: true, extraHeaders: [:]),
            improver: ResponsesImprover(useSharedSession: true, acceptGzip: true, compressRequest: true, stream: true, extraHeaders: [:], retryOn429: true),
            speculativeKickoff: false
        )
    case .combinedNoStream:
        return ResolvedEngines(
            label: "shared+gzip+retry (no stream)",
            transcriber: MultipartTranscriber(useSharedSession: true, acceptGzip: true, extraHeaders: [:]),
            improver: ResponsesImprover(useSharedSession: true, acceptGzip: true, compressRequest: true, stream: false, extraHeaders: [:], retryOn429: true),
            speculativeKickoff: false
        )
    }
}

// ---------- gzip on the request side ----------
extension Data {
    /// Mirror of MockServer.gzipped used for client-side request compression.
    func gzippedRequest() -> Data? {
        return self.gzipped()
    }
}
