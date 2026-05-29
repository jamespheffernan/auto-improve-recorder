// Cold-start instrumentation for autoresearch loop.
// Activated via launch arg -AIRColdStartMode 1 (with optional -AIRColdStartLabel <label>).
// Captures:
//   t_proc_start  - kernel reported process start time (via sysctl KERN_PROC).
//   t_app_init    - moment App.init() body runs (set from AutoImproveRecorderIOSApp.init).
//   t_state_init_done - moment IOSAppState() finishes (heavy startup work).
//   t_first_appear - first onAppear of root IOSRecorderView.
//   t_first_runloop_idle - first time the main run loop is idle after first appear (proxy for first interactive frame).
// Writes JSON to Documents/air_cold_start.json on first interactive frame, then exits if benchmark mode.
//
// The instrumentation overhead is a few microseconds (mach_absolute_time + atomic compare-exchange) so
// it's safe to leave compiled in even outside benchmark mode; it only writes the JSON file when active.

import Foundation
import os.log
import os.signpost

@MainActor
enum AIRColdStartTracker {
    private static let log = OSLog(subsystem: "com.fieldtheory.autoimproverecorder.ios", category: "ColdStart")
    private static let signposter = OSSignposter(subsystem: "com.fieldtheory.autoimproverecorder.ios", category: "ColdStart")

    private(set) static var procStart: TimeInterval = procStartFromSysctl()
    private(set) static var appInitAt: TimeInterval = -1
    private(set) static var stateInitStartAt: TimeInterval = -1
    private(set) static var stateInitDoneAt: TimeInterval = -1
    private(set) static var firstAppearAt: TimeInterval = -1
    private(set) static var firstFrameRenderedAt: TimeInterval = -1
    private static var hasWritten = false

    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-AIRColdStartMode")
    }

    static var label: String {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-AIRColdStartLabel"), i + 1 < args.count {
            return args[i + 1]
        }
        return "unknown"
    }

    /// Should the process exit after writing metrics? (default true so harness can iterate quickly.)
    static var shouldExitAfterWrite: Bool {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-AIRColdStartExit"), i + 1 < args.count {
            return args[i + 1] != "0"
        }
        return true
    }

    static func markAppInit() {
        if appInitAt < 0 { appInitAt = now() }
    }

    static func markStateInitStart() {
        if stateInitStartAt < 0 { stateInitStartAt = now() }
    }

    static func markStateInitDone() {
        if stateInitDoneAt < 0 { stateInitDoneAt = now() }
    }

    static func markFirstAppear() {
        if firstAppearAt < 0 {
            firstAppearAt = now()
        }
    }

    /// Mark first interactive frame; schedules a write to disk (and optional exit).
    static func markFirstInteractive() {
        guard firstFrameRenderedAt < 0 else { return }
        firstFrameRenderedAt = now()
        let label = AIRColdStartTracker.label
        Task { @MainActor in
            await flushAndMaybeExit(label: label)
        }
    }

    private static func now() -> TimeInterval {
        // wall-clock seconds since reference time
        return CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970
    }

    private static func procStartFromSysctl() -> TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        let result = name.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, UInt32(buf.count), &info, &size, nil, 0)
        }
        if result != 0 {
            return -1
        }
        let tv = info.kp_proc.p_un.__p_starttime
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000.0
    }

    struct Snapshot: Codable {
        let label: String
        let bundleVersion: String
        let unixProcStart: TimeInterval
        let unixAppInit: TimeInterval
        let unixStateInitStart: TimeInterval
        let unixStateInitDone: TimeInterval
        let unixFirstAppear: TimeInterval
        let unixFirstInteractive: TimeInterval
        // Useful deltas in milliseconds:
        let dyldToAppInitMs: Double      // proc_start -> App.init body (dyld + Swift runtime)
        let appInitToStateInitDoneMs: Double   // app init body -> after IOSAppState()
        let stateInitDurationMs: Double   // IOSAppState init self time
        let stateInitDoneToFirstAppearMs: Double // state ready -> first body rendered
        let firstAppearToInteractiveMs: Double   // first appear -> first interactive frame
        let totalColdStartMs: Double      // proc_start -> first interactive (PRIMARY METRIC)
    }

    private static func snapshot() -> Snapshot {
        let bundleVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        func ms(_ a: TimeInterval, _ b: TimeInterval) -> Double {
            guard a > 0 && b > 0 else { return -1 }
            return (b - a) * 1000.0
        }
        return Snapshot(
            label: label,
            bundleVersion: bundleVersion,
            unixProcStart: procStart,
            unixAppInit: appInitAt,
            unixStateInitStart: stateInitStartAt,
            unixStateInitDone: stateInitDoneAt,
            unixFirstAppear: firstAppearAt,
            unixFirstInteractive: firstFrameRenderedAt,
            dyldToAppInitMs: ms(procStart, appInitAt),
            appInitToStateInitDoneMs: ms(appInitAt, stateInitDoneAt),
            stateInitDurationMs: ms(stateInitStartAt, stateInitDoneAt),
            stateInitDoneToFirstAppearMs: ms(stateInitDoneAt, firstAppearAt),
            firstAppearToInteractiveMs: ms(firstAppearAt, firstFrameRenderedAt),
            totalColdStartMs: ms(procStart, firstFrameRenderedAt)
        )
    }

    private static func flushAndMaybeExit(label: String) async {
        guard !hasWritten else { return }
        hasWritten = true

        // Wait one run loop turn so the first frame is actually presented.
        await Task.yield()
        // Small sleep to let the SwiftUI render pipeline finish presenting the first frame.
        try? await Task.sleep(nanoseconds: 30_000_000) // 30ms
        // Now refresh firstFrameRenderedAt to capture the post-present time.
        let presentedAt = now()

        var snap = snapshot()
        // Recompute firstAppearToInteractiveMs and totalColdStartMs using presented time as a more accurate "interactive" mark.
        snap = Snapshot(
            label: snap.label,
            bundleVersion: snap.bundleVersion,
            unixProcStart: snap.unixProcStart,
            unixAppInit: snap.unixAppInit,
            unixStateInitStart: snap.unixStateInitStart,
            unixStateInitDone: snap.unixStateInitDone,
            unixFirstAppear: snap.unixFirstAppear,
            unixFirstInteractive: presentedAt,
            dyldToAppInitMs: snap.dyldToAppInitMs,
            appInitToStateInitDoneMs: snap.appInitToStateInitDoneMs,
            stateInitDurationMs: snap.stateInitDurationMs,
            stateInitDoneToFirstAppearMs: snap.stateInitDoneToFirstAppearMs,
            firstAppearToInteractiveMs: (presentedAt - snap.unixFirstAppear) * 1000.0,
            totalColdStartMs: (presentedAt - snap.unixProcStart) * 1000.0
        )

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let url = docs.appendingPathComponent("air_cold_start.json")
        do {
            let data = try JSONEncoder().encode(snap)
            try data.write(to: url)
            os_log("AIRColdStart label=%{public}@ totalMs=%{public}.2f stateInitMs=%{public}.2f firstAppearMs=%{public}.2f",
                   log: log,
                   type: .info,
                   snap.label,
                   snap.totalColdStartMs,
                   snap.stateInitDurationMs,
                   snap.firstAppearToInteractiveMs)
            NSLog("AIRColdStart: wrote %@ totalMs=%.2f", url.path, snap.totalColdStartMs)
        } catch {
            NSLog("AIRColdStart: write error %@", String(describing: error))
        }

        if isActive && shouldExitAfterWrite {
            // Give logs a moment to flush.
            try? await Task.sleep(nanoseconds: 100_000_000)
            exit(0)
        }
    }
}
