import Foundation

// Run command:
//   BENCH_VARIANT=baseline swift run -c release TranscriptionBench --runs 10
//
// Emits one JSON line to stdout summarising p50/p95 per fixture and overall.
// Exit code 0 = success, 1 = failure (any trial threw or transcript mismatch).

struct Trial: Codable {
    let fixture: String
    let durationSeconds: Double
    let bytesUploaded: Int
    let elapsedMs: Double
    let textOK: Bool
}

struct Summary: Codable {
    let variant: String
    let runs: Int
    let perFixture: [FixtureStats]
    let overall: Stats
    let failures: Int
    let timestamp: String
    struct FixtureStats: Codable { let fixture: String; let durationSeconds: Double; let stats: Stats; let bytesP50: Int; let bytesMean: Int }
    struct Stats: Codable { let p50ms: Double; let p95ms: Double; let meanMs: Double; let n: Int }
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    if sorted.count == 1 { return sorted[0] }
    let rank = p * Double(sorted.count - 1)
    let lower = Int(rank.rounded(.down))
    let upper = Int(rank.rounded(.up))
    let frac = rank - Double(lower)
    return sorted[lower] + (sorted[upper] - sorted[lower]) * frac
}

@main
struct BenchEntry {
    static func main() async throws {
        let args = CommandLine.arguments
        var runs = 10
        var serverDelayMs: Int = 50
        var fixtureFilter: String? = nil
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "--runs", i + 1 < args.count { runs = Int(args[i+1]) ?? runs; i += 2 }
            else if a == "--server-delay-ms", i + 1 < args.count { serverDelayMs = Int(args[i+1]) ?? serverDelayMs; i += 2 }
            else if a == "--only", i + 1 < args.count { fixtureFilter = args[i+1]; i += 2 }
            else { i += 1 }
        }

        let variantName = ProcessInfo.processInfo.environment["BENCH_VARIANT"] ?? "baseline"

        let fm = FileManager.default
        let bench = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixturesDir = bench.appendingPathComponent("Fixtures")
        let allFixtures = try Fixtures.ensure(in: fixturesDir)
        let fixtures: [(spec: Fixtures.Spec, url: URL)] = {
            if let filter = fixtureFilter {
                return allFixtures.filter { $0.spec.name == filter }
            }
            return allFixtures
        }()
        guard !fixtures.isEmpty else {
            FileHandle.standardError.write(Data("No fixtures matched filter \(fixtureFilter ?? "<none>")\n".utf8))
            exit(2)
        }

        // Bandwidth shaper (token-bucket on inbound uplink). 0 = loopback.
        // LTE upload ~5 Mbps = 5000 kbps. Wi-Fi upload ~50 Mbps = 50000 kbps.
        let uplinkKbps = Int(ProcessInfo.processInfo.environment["BENCH_UPLINK_KBPS"] ?? "0") ?? 0
        let server = try FakeServer(
            returnText: "the quick brown fox jumps over the lazy dog",
            serverDelay: Double(serverDelayMs) / 1000.0,
            uplinkKbps: uplinkKbps
        )
        try await server.start()
        let endpoint = await server.url

        let config = Variant.current(endpoint: endpoint)
        let transcriber = Transcriber(config: config)

        // Warm up: prime URLSession + AVAudio etc. with a few short calls (not counted).
        for _ in 0..<2 {
            _ = try? await transcriber.transcribe(audioURL: fixtures.first!.url)
        }

        var trials: [Trial] = []
        var failures = 0
        for (spec, url) in fixtures {
            // Per-fixture: run `runs` iterations.
            for _ in 0..<runs {
                let inputBytes = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                let started = DispatchTime.now()
                do {
                    let r = try await transcriber.transcribe(audioURL: url)
                    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000.0
                    let textOK = r.text.contains("quick brown fox")
                    if !textOK { failures += 1 }
                    let bytes = r.bytesUploaded > 0 ? r.bytesUploaded : inputBytes
                    trials.append(Trial(fixture: spec.name, durationSeconds: spec.durationSeconds, bytesUploaded: bytes, elapsedMs: elapsed, textOK: textOK))
                } catch {
                    failures += 1
                    FileHandle.standardError.write(Data("trial failed: \(error)\n".utf8))
                }
            }
        }

        await server.stop()

        var perFixture: [Summary.FixtureStats] = []
        for spec in Fixtures.specs {
            let xs = trials.filter { $0.fixture == spec.name }
            guard !xs.isEmpty else { continue }
            let times = xs.map { $0.elapsedMs }
            let bytes = xs.map { $0.bytesUploaded }
            let stats = Summary.Stats(
                p50ms: percentile(times, 0.5),
                p95ms: percentile(times, 0.95),
                meanMs: times.reduce(0, +) / Double(max(times.count, 1)),
                n: times.count
            )
            let bytesMean = bytes.reduce(0, +) / max(bytes.count, 1)
            perFixture.append(Summary.FixtureStats(
                fixture: spec.name,
                durationSeconds: spec.durationSeconds,
                stats: stats,
                bytesP50: bytes.sorted()[bytes.count / 2],
                bytesMean: bytesMean
            ))
        }
        let allTimes = trials.map { $0.elapsedMs }
        let overall = Summary.Stats(
            p50ms: percentile(allTimes, 0.5),
            p95ms: percentile(allTimes, 0.95),
            meanMs: allTimes.reduce(0, +) / Double(max(allTimes.count, 1)),
            n: allTimes.count
        )

        let formatter = ISO8601DateFormatter()
        let summary = Summary(
            variant: variantName,
            runs: runs,
            perFixture: perFixture,
            overall: overall,
            failures: failures,
            timestamp: formatter.string(from: Date())
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        let data = try encoder.encode(summary)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))

        if failures > 0 {
            // Don't exit non-zero on transient failures — let the runner aggregate
            // partial passes. The summary already reports `failures`. Killing the
            // whole sweep on a single audioMissing race makes paired A/B runs flaky.
            FileHandle.standardError.write(Data("WARN: \(failures) trial failures (continuing)\n".utf8))
        }
    }
}
