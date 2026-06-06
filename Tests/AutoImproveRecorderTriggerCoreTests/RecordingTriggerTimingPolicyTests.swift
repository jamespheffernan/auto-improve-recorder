import XCTest
@testable import AutoImproveRecorderTriggerCore

final class RecordingTriggerTimingPolicyTests: XCTestCase {
    func testDefaultThresholdsMatchPlan() {
        let policy = RecordingTriggerTimingPolicy.default

        XCTAssertEqual(policy.accidentalTapThreshold, 0.22)
        XCTAssertEqual(policy.doublePressLatchWindow, 0.32)
        XCTAssertEqual(policy.startupReleaseGrace, 0.12)
        XCTAssertEqual(policy.minimumRecordingDuration, 0.70)
        XCTAssertEqual(policy.lostReleaseWatchdog, 45.0)
        XCTAssertEqual(policy.repeatDebounce, 0.05)
    }

    func testMinimumDurationBoundaryIsInclusive() throws {
        let base = Date(timeIntervalSince1970: 2_000)
        let controller = RecordingTriggerController(
            timingPolicy: RecordingTriggerTimingPolicy(
                accidentalTapThreshold: 0.05,
                doublePressLatchWindow: 0.1,
                startupReleaseGrace: 0.01,
                minimumRecordingDuration: 0.5,
                lostReleaseWatchdog: 10,
                repeatDebounce: 0.01
            ),
            behaviorProvider: { .holdToTalk }
        )
        let start = try XCTUnwrap(controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)).firstRequestStart)
        let recordingID = UUID()
        _ = controller.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base))

        let commands = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(0.5), eventID: 2))

        XCTAssertEqual(commands.firstRequestStop?.shouldTranscribe, true)
    }

    func testInjectedAccidentalTapThresholdAffectsClassification() throws {
        let base = Date(timeIntervalSince1970: 3_000)
        let controller = RecordingTriggerController(
            timingPolicy: RecordingTriggerTimingPolicy(
                accidentalTapThreshold: 0.5,
                doublePressLatchWindow: 0.1,
                startupReleaseGrace: 0.01,
                minimumRecordingDuration: 0.05,
                lostReleaseWatchdog: 10,
                repeatDebounce: 0.01
            ),
            behaviorProvider: { .holdToTalk }
        )
        let start = try XCTUnwrap(controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)).firstRequestStart)
        let recordingID = UUID()
        _ = controller.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base))

        let commands = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(0.4), eventID: 2))

        XCTAssertEqual(commands.scheduledTimerKind, .doublePressWindow)
        XCTAssertNil(commands.firstRequestStop)
    }

    func testPolicyEncodesForDiagnosticsExport() throws {
        let policy = RecordingTriggerTimingPolicy.default

        let data = try JSONEncoder().encode(policy)
        let decoded = try JSONDecoder().decode(RecordingTriggerTimingPolicy.self, from: data)

        XCTAssertEqual(decoded, policy)
    }
}

private extension Array where Element == RecordingTriggerCommand {
    var firstRequestStart: (startID: UUID, source: RecordingTriggerStartSource)? {
        for command in self {
            if case .requestStart(let startID, let source, _) = command {
                return (startID, source)
            }
        }
        return nil
    }

    var firstRequestStop: (recordingID: UUID, reason: RecordingTriggerStopReason, shouldTranscribe: Bool)? {
        for command in self {
            if case .requestStop(let recordingID, let reason, _, let shouldTranscribe) = command {
                return (recordingID, reason, shouldTranscribe)
            }
        }
        return nil
    }

    var scheduledTimerKind: RecordingTriggerTimerKind? {
        for command in self {
            if case .scheduleTimer(let kind, _, _) = command {
                return kind
            }
        }
        return nil
    }
}
