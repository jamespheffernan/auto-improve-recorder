// StreamSharedClientBench
// =======================
// Measures perceived TTFB (time-to-first-delta) for the OpenAI Responses
// streaming endpoint. Two backends:
//   - mock:   a local Network.framework SSE server with configurable TTFB jitter.
//   - openai: the real https://api.openai.com/v1/responses, gated on OPENAI_API_KEY.
//
// The bench treats five primary axes as configurable so the autoresearch loop
// (.autoresearch/air-stream-shared-client.jsonl) can sweep them:
//   * SESSION   = persistent | ephemeral
//   * PREWARM   = on | off       (issue HEAD against host before timed run)
//   * STREAM    = on | off       (server-sent events vs buffered JSON)
//   * GZIP      = on | off       (Accept-Encoding: gzip)
//   * RETRY     = on | off       (retry once on 429/503; mock can inject 429s)
//
// Output: BENCH_RESULT <json> on stdout. Fields:
//   variant, backend, iters, warmup,
//   ttfbP50, ttfbP95, ttfbP99,
//   totalP50, totalP95,
//   bytesIn, retries, failures.
//
// The bench is intentionally side-effect-clean -- no temp files, only stdout.

import Foundation

func envInt(_ key: String, _ def: Int) -> Int {
    if let s = ProcessInfo.processInfo.environment[key], let v = Int(s) { return v }
    return def
}
func envFlag(_ key: String, _ def: Bool) -> Bool {
    guard let s = ProcessInfo.processInfo.environment[key] else { return def }
    let lower = s.lowercased()
    if lower == "1" || lower == "true" || lower == "on" || lower == "yes" { return true }
    if lower == "0" || lower == "false" || lower == "off" || lower == "no" { return false }
    return def
}
func envStr(_ key: String, _ def: String) -> String {
    return ProcessInfo.processInfo.environment[key] ?? def
}

// ---------- bench config ----------
struct BenchConfig {
    let backend: String              // "mock" or "openai"
    let label: String                // human-readable variant label
    let useSharedSession: Bool
    let prewarm: Bool
    let stream: Bool
    let gzip: Bool
    let retry: Bool
    let iters: Int
    let warmup: Int
    let mockTTFBMs: Int
    let mockTTFBJitterMs: Int
    let mockChunkGapMs: Int
    let mockRateLimitEveryN: Int
    let realModel: String            // model id when backend == openai
    let realInput: String            // user input string when backend == openai
    let realInstructions: String

    static func fromEnv() -> BenchConfig {
        return BenchConfig(
            backend: envStr("BENCH_BACKEND", "mock"),
            label: envStr("BENCH_LABEL", "default"),
            useSharedSession: envFlag("BENCH_SESSION_PERSISTENT", true),
            prewarm: envFlag("BENCH_PREWARM", false),
            stream: envFlag("BENCH_STREAM", true),
            gzip: envFlag("BENCH_GZIP", true),
            retry: envFlag("BENCH_RETRY", true),
            iters: envInt("BENCH_ITERS", 10),
            warmup: envInt("BENCH_WARMUP", 2),
            mockTTFBMs: envInt("BENCH_TTFB_MS", 80),
            mockTTFBJitterMs: envInt("BENCH_TTFB_JITTER_MS", 20),
            mockChunkGapMs: envInt("BENCH_CHUNK_GAP_MS", 25),
            mockRateLimitEveryN: envInt("BENCH_RATE_LIMIT_EVERY_N", 0),
            realModel: envStr("BENCH_MODEL", "gpt-4o-mini"),
            realInput: envStr("BENCH_INPUT", "Improve this transcript: hello world this is a quick test sentence."),
            realInstructions: envStr("BENCH_INSTRUCTIONS", "You are a careful editor. Tighten and lightly polish the input. Reply in 1-2 sentences.")
        )
    }
}

// ---------- result accumulator ----------
struct TrialResult {
    var totalMs: Double = 0
    var ttfbMs: Int? = nil
    var bytesIn: Int = 0
    var retries: Int = 0
    var failed: Bool = false
}

// ---------- session factories ----------
enum BenchSessions {
    static let persistent: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        let httpThreeSelector = NSSelectorFromString("setAssumesHTTP3Capable:")
        if (cfg as NSObject).responds(to: httpThreeSelector) {
            cfg.setValue(true, forKey: "assumesHTTP3Capable")
        }
        var headers: [AnyHashable: Any] = cfg.httpAdditionalHeaders ?? [:]
        if headers["Accept-Encoding"] == nil {
            headers["Accept-Encoding"] = "gzip"
        }
        cfg.httpAdditionalHeaders = headers
        return URLSession(configuration: cfg)
    }()

    static func ephemeral() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        cfg.waitsForConnectivity = false
        let httpThreeSelector = NSSelectorFromString("setAssumesHTTP3Capable:")
        if (cfg as NSObject).responds(to: httpThreeSelector) {
            cfg.setValue(true, forKey: "assumesHTTP3Capable")
        }
        return URLSession(configuration: cfg)
    }
}

// ---------- helpers ----------
func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * p)))
    return sorted[idx]
}

// ---------- transport runs ----------
func runOnce(config: BenchConfig, baseURL: URL, apiKey: String?) async -> TrialResult {
    var result = TrialResult()
    let url: URL
    var request: URLRequest

    if config.backend == "openai" {
        url = baseURL.appendingPathComponent("v1/responses")
        request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey ?? "")", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if config.gzip { request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding") }
        if config.stream {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        var body: [String: Any] = [
            "model": config.realModel,
            "instructions": config.realInstructions,
            "input": config.realInput
        ]
        if config.stream { body["stream"] = true }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
    } else {
        url = baseURL.appendingPathComponent("v1/responses")
        request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer test-key", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if config.gzip { request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding") }
        if config.stream { request.setValue("1", forHTTPHeaderField: "X-Bench-Stream") }
        let body: [String: Any] = [
            "model": "gpt-5.4-mini",
            "instructions": "You are a careful editor.",
            "input": "Hello, this is a test."
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
    }
    request.timeoutInterval = 60

    let session = config.useSharedSession ? BenchSessions.persistent : BenchSessions.ephemeral()
    let start = Date()

    var attempts = 0
    while true {
        attempts += 1
        do {
            if config.stream {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    result.failed = true
                    return result
                }
                if (http.statusCode == 429 || http.statusCode == 503) && config.retry && attempts <= 2 {
                    for try await _ in bytes { /* drain */ }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                if !(200..<300).contains(http.statusCode) {
                    var drained = 0
                    for try await _ in bytes { drained += 1; if drained > 65536 { break } }
                    result.failed = true
                    result.totalMs = Date().timeIntervalSince(start) * 1000
                    return result
                }
                var sawFirst = false
                var byteCount = 0
                for try await line in bytes.lines {
                    byteCount += line.utf8.count + 1
                    if line.isEmpty { continue }
                    if line.hasPrefix("data:") {
                        var payload = String(line.dropFirst(5))
                        if payload.hasPrefix(" ") { payload.removeFirst() }
                        if payload.isEmpty { continue }
                        if !sawFirst {
                            // Real OpenAI emits a `response.created` event before deltas;
                            // skip non-delta payloads when locating first-token TTFB.
                            if config.backend == "openai" {
                                if let data = payload.data(using: .utf8),
                                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   let type = obj["type"] as? String,
                                   !type.contains("output_text.delta") {
                                    continue
                                }
                            }
                            sawFirst = true
                            result.ttfbMs = Int(Date().timeIntervalSince(start) * 1000)
                        }
                        if payload == "[DONE]" { break }
                        if let data = payload.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let type = obj["type"] as? String,
                           type == "response.completed" || type == "response.failed" || type == "response.error" {
                            break
                        }
                    }
                }
                result.bytesIn = byteCount
                result.retries = attempts - 1
                result.totalMs = Date().timeIntervalSince(start) * 1000
                return result
            } else {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    result.failed = true
                    return result
                }
                if (http.statusCode == 429 || http.statusCode == 503) && config.retry && attempts <= 2 {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                if !(200..<300).contains(http.statusCode) {
                    result.failed = true
                    result.totalMs = Date().timeIntervalSince(start) * 1000
                    return result
                }
                let firstByteMs = Int(Date().timeIntervalSince(start) * 1000)
                result.ttfbMs = firstByteMs
                result.bytesIn = data.count
                result.retries = attempts - 1
                result.totalMs = Date().timeIntervalSince(start) * 1000
                return result
            }
        } catch {
            result.failed = true
            result.totalMs = Date().timeIntervalSince(start) * 1000
            return result
        }
    }
}

// Top-level driver (file is named main.swift, so SwiftPM runs the script-level statements).
@discardableResult
func runBench() async throws -> Int32 {
        let config = BenchConfig.fromEnv()
        let stderr = FileHandle.standardError

        // ---------- resolve baseURL ----------
        let baseURL: URL
        let apiKey: String?
        var mockServer: MockSSEServer? = nil
        switch config.backend {
        case "openai":
            guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !key.isEmpty else {
                stderr.write("ERROR: BENCH_BACKEND=openai but OPENAI_API_KEY not set\n")
                exit(2)
            }
            baseURL = URL(string: "https://api.openai.com/")!
            apiKey = key
        default:
            let server = try MockSSEServer.start(config: config)
            baseURL = URL(string: "http://127.0.0.1:\(server.port)/")!
            apiKey = nil
            mockServer = server
        }
        defer { mockServer?.stop() }

        stderr.write("backend=\(config.backend) variant=\(config.label) iters=\(config.iters) warmup=\(config.warmup) "
            + "session=\(config.useSharedSession ? "persistent" : "ephemeral") prewarm=\(config.prewarm) "
            + "stream=\(config.stream) gzip=\(config.gzip) retry=\(config.retry)\n")

        // ---------- prewarm hook ----------
        if config.prewarm {
            // Issue a single HEAD to the host to seed DNS / TCP / TLS / HTTP/2 connection pool.
            var head = URLRequest(url: baseURL)
            head.httpMethod = "HEAD"
            head.timeoutInterval = 5
            _ = try? await BenchSessions.persistent.data(for: head)
        }

        // ---------- warmup ----------
        for _ in 0..<config.warmup {
            _ = await runOnce(config: config, baseURL: baseURL, apiKey: apiKey)
        }

        // ---------- timed iters ----------
        var totals: [Double] = []
        var ttfbs: [Double] = []
        var bytesIns: [Int] = []
        var retries: [Int] = []
        var failures = 0
        for _ in 0..<config.iters {
            let r = await runOnce(config: config, baseURL: baseURL, apiKey: apiKey)
            if r.failed { failures += 1; continue }
            totals.append(r.totalMs)
            if let t = r.ttfbMs { ttfbs.append(Double(t)) }
            bytesIns.append(r.bytesIn)
            retries.append(r.retries)
        }

        guard !totals.isEmpty else {
            stderr.write("ERROR: no successful iterations\n")
            return 2
        }

        let totalsSorted = totals.sorted()
        let ttfbSorted = ttfbs.sorted()
        let totalP50 = percentile(totalsSorted, 0.50)
        let totalP95 = percentile(totalsSorted, 0.95)
        let totalP99 = percentile(totalsSorted, 0.99)
        let ttfbP50 = percentile(ttfbSorted, 0.50)
        let ttfbP95 = percentile(ttfbSorted, 0.95)
        let ttfbP99 = percentile(ttfbSorted, 0.99)
        let avgBytesIn = bytesIns.isEmpty ? 0 : Int(bytesIns.reduce(0, +) / max(1, bytesIns.count))
        let totalRetries = retries.reduce(0, +)

        let json: [String: Any] = [
            "label": config.label,
            "backend": config.backend,
            "session": config.useSharedSession ? "persistent" : "ephemeral",
            "prewarm": config.prewarm,
            "stream": config.stream,
            "gzip": config.gzip,
            "retry": config.retry,
            "iters": config.iters,
            "warmup": config.warmup,
            "ttfbP50": ttfbP50,
            "ttfbP95": ttfbP95,
            "ttfbP99": ttfbP99,
            "totalP50": totalP50,
            "totalP95": totalP95,
            "totalP99": totalP99,
            "avgBytesIn": avgBytesIn,
            "retries": totalRetries,
            "failures": failures,
            "rateLimitEveryN": config.mockRateLimitEveryN,
            "ttfbMs": config.mockTTFBMs
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let s = String(data: data, encoding: .utf8) ?? "{}"
        print("BENCH_RESULT \(s)")
        return 0
}

// stderr writer extension (avoid retroactive Foundation conformance warning).
extension FileHandle {
    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        self.write(data)
    }
}

// Run.
let rc = try await runBench()
exit(rc)
