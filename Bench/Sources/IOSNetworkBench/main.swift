// IOSNetworkBench: measure transcribe + improve latency against a local mock server.
//
// Env vars:
//   BENCH_VARIANT=<baseline|keepAlive|gzipImprove|http2Hints|speculative|streaming|combined|combinedNoStream>
//   BENCH_ITERS=<N>                  default 30
//   BENCH_WARMUP=<N>                 default 3
//   BENCH_AUDIO_KB=<KB>              default 320  (synthetic WAV-ish payload)
//   BENCH_TTFB_MS=<ms>               default 80
//   BENCH_TTFB_JITTER_MS=<ms>        default 30
//   BENCH_BODY_CHUNKS=<N>            default 4
//   BENCH_BODY_GAP_MS=<ms>           default 30
//   BENCH_RATE_LIMIT_EVERY_N=<N>     default 0
//   BENCH_INBOUND_KBPS=<KB/s>        default 600
//
// Output: a final line `BENCH_RESULT <json>` with metrics.

import Foundation

func envInt(_ key: String, _ def: Int) -> Int {
    if let s = ProcessInfo.processInfo.environment[key], let v = Int(s) { return v }
    return def
}

struct BenchMain {
    static func main() async throws {
        let iterations = envInt("BENCH_ITERS", 30)
        let warmup     = envInt("BENCH_WARMUP", 3)
        let audioKB    = envInt("BENCH_AUDIO_KB", 320)

        var cfg = MockServer.Config()
        cfg.ttfbMillis = envInt("BENCH_TTFB_MS", 80)
        cfg.ttfbJitterMillis = envInt("BENCH_TTFB_JITTER_MS", 30)
        cfg.bodyChunkCount = envInt("BENCH_BODY_CHUNKS", 4)
        cfg.bodyChunkGapMillis = envInt("BENCH_BODY_GAP_MS", 30)
        cfg.rateLimitEveryN = envInt("BENCH_RATE_LIMIT_EVERY_N", 0)
        cfg.inboundThroughputBytesPerSecond = envInt("BENCH_INBOUND_KBPS", 600) * 1024

        let server = MockServer(config: cfg)
        try server.start()
        defer { server.stop() }
        let baseURL = URL(string: "http://127.0.0.1:\(server.port)/")!

        let resolved = resolveEngines()
        FileHandle.standardError.write(Data("variant=\(resolved.label) iters=\(iterations) warmup=\(warmup) audioKB=\(audioKB) port=\(server.port)\n".utf8))

        // Synthetic audio payload (mock server treats it opaquely).
        let audio = Data(count: audioKB * 1024)

        // Long-ish transcript so improve() body is realistic (~2 KB).
        let transcript = String(repeating: "This is a sentence in the transcript. ", count: 32)

        // Warmup: open one keep-alive connection and prime any caches.
        for _ in 0..<warmup {
            _ = try? await runOnce(audio: audio, transcript: transcript, baseURL: baseURL, resolved: resolved)
        }

        var totalMs: [Double] = []
        var transcribeMs: [Double] = []
        var improveMs: [Double] = []
        var firstTokenMs: [Int] = []
        var bytesIn: [Int] = []
        var bytesOut: [Int] = []
        var retries: [Int] = []
        var failures = 0

        for _ in 0..<iterations {
            do {
                let r = try await runOnce(audio: audio, transcript: transcript, baseURL: baseURL, resolved: resolved)
                totalMs.append(r.totalMs)
                transcribeMs.append(r.transcribeMs)
                improveMs.append(r.improveMs)
                if let f = r.firstTokenMs { firstTokenMs.append(f) }
                bytesIn.append(r.bytesIn)
                bytesOut.append(r.bytesOut)
                retries.append(r.retries)
            } catch {
                failures += 1
            }
        }

        guard !totalMs.isEmpty else {
            FileHandle.standardError.write(Data("ERROR: no successful iterations\n".utf8))
            exit(2)
        }

        let p50 = percentile(totalMs.sorted(), 0.50)
        let p95 = percentile(totalMs.sorted(), 0.95)
        let p99 = percentile(totalMs.sorted(), 0.99)
        let trP95 = percentile(transcribeMs.sorted(), 0.95)
        let imP95 = percentile(improveMs.sorted(), 0.95)
        let ftP50 = firstTokenMs.isEmpty ? 0 : Int(percentile(firstTokenMs.map(Double.init).sorted(), 0.50))
        let ftP95 = firstTokenMs.isEmpty ? 0 : Int(percentile(firstTokenMs.map(Double.init).sorted(), 0.95))
        let avgBytesIn = Double(bytesIn.reduce(0, +)) / Double(bytesIn.count)
        let avgBytesOut = Double(bytesOut.reduce(0, +)) / Double(bytesOut.count)
        let totalRetries = retries.reduce(0, +)

        let json: [String: Any] = [
            "variant": Variant.current().rawValue,
            "label": resolved.label,
            "iters": iterations,
            "warmup": warmup,
            "audioKB": audioKB,
            "ttfbMs": cfg.ttfbMillis,
            "totalP50": p50,
            "totalP95": p95,
            "totalP99": p99,
            "transcribeP95": trP95,
            "improveP95": imP95,
            "firstTokenP50": ftP50,
            "firstTokenP95": ftP95,
            "avgBytesIn": Int(avgBytesIn),
            "avgBytesOut": Int(avgBytesOut),
            "retries": totalRetries,
            "failures": failures,
            "rateLimitEveryN": cfg.rateLimitEveryN
        ]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let s = String(data: data, encoding: .utf8) ?? "{}"
        print("BENCH_RESULT \(s)")
    }

    static func runOnce(audio: Data, transcript: String, baseURL: URL, resolved: ResolvedEngines) async throws -> Result {
        let totalStart = Date()
        let speculativeWarm: Task<Void, Never>?
        if resolved.speculativeKickoff {
            // Warm the connection by issuing a tiny HEAD/GET against root that the mock server happily serves.
            speculativeWarm = Task {
                let warmURL = baseURL.appendingPathComponent("warm")
                var req = URLRequest(url: warmURL)
                req.httpMethod = "GET"
                req.timeoutInterval = 5
                _ = try? await Sessions.shared.data(for: req)
            }
        } else {
            speculativeWarm = nil
        }

        let trStart = Date()
        let tr = try await resolved.transcriber.transcribe(audioBytes: audio, baseURL: baseURL)
        let trMs = Date().timeIntervalSince(trStart) * 1000

        speculativeWarm?.cancel()

        let imStart = Date()
        let im = try await resolved.improver.improve(rawTranscript: tr.text + transcript, baseURL: baseURL)
        let imMs = Date().timeIntervalSince(imStart) * 1000

        let totalMs = Date().timeIntervalSince(totalStart) * 1000
        return Result(
            totalMs: totalMs,
            transcribeMs: trMs,
            improveMs: imMs,
            firstTokenMs: im.metrics.streamFirstTokenMs,
            bytesIn: tr.metrics.bytesIn + im.metrics.bytesIn,
            bytesOut: tr.metrics.bytesOut + im.metrics.bytesOut,
            retries: tr.metrics.retries + im.metrics.retries
        )
    }

    struct Result {
        let totalMs: Double
        let transcribeMs: Double
        let improveMs: Double
        let firstTokenMs: Int?
        let bytesIn: Int
        let bytesOut: Int
        let retries: Int
    }

    static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let pos = Double(sorted.count - 1) * q
        let lo = Int(floor(pos))
        let hi = Int(ceil(pos))
        let frac = pos - Double(lo)
        return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
    }
}

// Synchronous top-level entry that pumps the async main.
let semaphore = DispatchSemaphore(value: 0)
Task {
    do {
        try await BenchMain.main()
    } catch {
        FileHandle.standardError.write(Data("FATAL: \(error)\n".utf8))
        exit(3)
    }
    semaphore.signal()
}
semaphore.wait()
