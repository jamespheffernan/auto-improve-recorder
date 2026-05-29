// Benchmark runner for autoresearch loop. Activated via launch arg -AIRBenchmarkMode 1.
// Measures tap-record -> first audio buffer arrival latency over N cycles.
// Writes JSON to Documents/air_bench.json and exits.

import AVFoundation
import Foundation
import UIKit

@MainActor
enum AIRBenchmarkRunner {
    struct CycleResult: Codable {
        let index: Int
        let armDuration: Double           // start() call wall time
        let firstBufferLatency: Double    // tap -> first buffer
        let totalLatency: Double          // tap -> first buffer (includes arm)
        let success: Bool
        let error: String?
    }

    struct BenchResult: Codable {
        let label: String
        let cycles: [CycleResult]
        let p50FirstBuffer: Double
        let p95FirstBuffer: Double
        let p50Total: Double
        let p95Total: Double
        let meanFirstBuffer: Double
        let failures: Int
        let warmedAtLaunch: Bool
        let keepEngineWarm: Bool
        // Device-tier reporting added in loop #6 (physical-device validation).
        // These fields make it possible to (a) confirm setPreferredIOBufferDuration(0.005)
        // is being honored by hardware, and (b) tag results with device class so
        // simulator/device numbers don't collide in the JSONL log.
        let deviceModel: String?
        let systemVersion: String?
        let isSimulator: Bool
        let reportedIOBufferMs: Double?      // session.ioBufferDuration after first cycle, ms
        let reportedSampleRate: Double?      // session.sampleRate after first cycle, Hz
    }

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-AIRBenchmarkMode")
    }

    static func arg(_ name: String, default def: String) -> String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: name), i + 1 < args.count {
            return args[i + 1]
        }
        return def
    }

    static func run() {
        let cycles = Int(arg("-AIRBenchCycles", default: "20")) ?? 20
        let label = arg("-AIRBenchLabel", default: "unknown")
        let warmAtLaunch = arg("-AIRBenchWarmAtLaunch", default: "0") == "1"
        let keepWarm = arg("-AIRBenchKeepWarm", default: "0") == "1"

        // Fast permission grant in simulator: we set TCC pre-authorized.
        // If still .notDetermined, request. Mic delivers silence in sim but tap fires.
        Task { @MainActor in
            await runAsync(cycles: cycles, label: label, warmAtLaunch: warmAtLaunch, keepWarm: keepWarm)
        }
    }

    static func runAsync(cycles: Int, label: String, warmAtLaunch: Bool, keepWarm: Bool) async {
        do { try await AudioRecorder.requestMicrophonePermission() } catch {
            writeFailureAndExit(label: label, message: "permission denied: \(error.localizedDescription)")
            return
        }

        // Optional: simulate "prewarm at launch" by triggering prepareForFastStartIfAuthorized once.
        let recorder = AudioRecorder()
        if warmAtLaunch {
            recorder.prepareForFastStartIfAuthorized()
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        var results: [CycleResult] = []
        var capturedSessionInfo: (Double, Double)? = nil
        for i in 0..<cycles {
            let res = await singleCycle(index: i, recorder: recorder, keepWarm: keepWarm)
            results.append(res)
            // Capture audio session info once we know the engine has armed at least once.
            if capturedSessionInfo == nil, res.success {
                let session = AVAudioSession.sharedInstance()
                capturedSessionInfo = (session.ioBufferDuration, session.sampleRate)
            }
            // Settle gap between cycles to mimic user behavior.
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        let firstBufferLatencies = results.compactMap { $0.success ? $0.firstBufferLatency : nil }
            .sorted()
        let totalLatencies = results.compactMap { $0.success ? $0.totalLatency : nil }
            .sorted()

        func percentile(_ values: [Double], _ p: Double) -> Double {
            guard !values.isEmpty else { return -1 }
            let idx = min(values.count - 1, Int((p / 100.0 * Double(values.count - 1)).rounded()))
            return values[idx]
        }

        // Device profile (physical vs simulator + model + iOS).
        let device = UIDevice.current
        #if targetEnvironment(simulator)
        let isSim = true
        #else
        let isSim = false
        #endif

        let summary = BenchResult(
            label: label,
            cycles: results,
            p50FirstBuffer: percentile(firstBufferLatencies, 50),
            p95FirstBuffer: percentile(firstBufferLatencies, 95),
            p50Total: percentile(totalLatencies, 50),
            p95Total: percentile(totalLatencies, 95),
            meanFirstBuffer: firstBufferLatencies.isEmpty ? -1 : firstBufferLatencies.reduce(0, +) / Double(firstBufferLatencies.count),
            failures: results.filter { !$0.success }.count,
            warmedAtLaunch: warmAtLaunch,
            keepEngineWarm: keepWarm,
            deviceModel: device.model,
            systemVersion: device.systemVersion,
            isSimulator: isSim,
            reportedIOBufferMs: capturedSessionInfo.map { $0.0 * 1000.0 },
            reportedSampleRate: capturedSessionInfo.map { $0.1 }
        )

        writeResult(summary)
        // Exit cleanly so simctl/host can read the file.
        exit(0)
    }

    static func singleCycle(index: Int, recorder: AudioRecorder, keepWarm: Bool) async -> CycleResult {
        let url = AudioRecorder.makeRecordingURL()
        let tap = Date()
        // Use a CheckedContinuation that resumes on first buffer or after timeout.
        let firstBuffer = await withCheckedContinuation { (cont: CheckedContinuation<Date?, Never>) in
            // Timeout watchdog
            let deadline = DispatchTime.now() + .milliseconds(2500)
            var resumed = false
            let lock = NSLock()
            func resumeOnce(_ value: Date?) {
                lock.lock()
                defer { lock.unlock() }
                if !resumed {
                    resumed = true
                    cont.resume(returning: value)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                resumeOnce(nil)
            }
            do {
                _ = try recorder.start(at: url, onFirstBuffer: {
                    resumeOnce(Date())
                })
            } catch {
                resumeOnce(nil)
            }
        }
        let armEnd = Date()
        let success = firstBuffer != nil
        let firstBufferLatency = success ? firstBuffer!.timeIntervalSince(tap) : -1
        let armDuration = armEnd.timeIntervalSince(tap)

        // Stop after this cycle.
        if !keepWarm {
            _ = recorder.stop()
            recorder.releaseWarmResources()
        } else {
            // Stop file but leave engine alive
            _ = recorder.stop()
        }

        return CycleResult(
            index: index,
            armDuration: armDuration,
            firstBufferLatency: firstBufferLatency,
            totalLatency: firstBufferLatency,
            success: success,
            error: success ? nil : "first buffer timeout"
        )
    }

    static func writeResult(_ result: BenchResult) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("air_bench.json")
        do {
            let data = try JSONEncoder().encode(result)
            try data.write(to: url)
            NSLog("AIRBench: wrote results to \(url.path)")
            // Also emit JSON inline so the harness can capture it from the console stream
            // even if the sandbox is later wiped by another process.
            if let json = String(data: data, encoding: .utf8) {
                NSLog("AIRBenchJSON %@", json)
            }
        } catch {
            NSLog("AIRBench: write error \(error.localizedDescription)")
        }
    }

    static func writeFailureAndExit(label: String, message: String) {
        #if targetEnvironment(simulator)
        let isSim = true
        #else
        let isSim = false
        #endif
        let result = BenchResult(
            label: label,
            cycles: [],
            p50FirstBuffer: -1,
            p95FirstBuffer: -1,
            p50Total: -1,
            p95Total: -1,
            meanFirstBuffer: -1,
            failures: 999,
            warmedAtLaunch: false,
            keepEngineWarm: false,
            deviceModel: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            isSimulator: isSim,
            reportedIOBufferMs: nil,
            reportedSampleRate: nil
        )
        writeResult(result)
        exit(1)
    }
}
