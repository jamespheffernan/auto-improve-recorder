import XCTest
@testable import AutoImproveRecorderCore

final class RecordingTriggerControllerTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000)
    private let startID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!

    func testHoldModeStartsOnFirstPressAndIgnoresRepeat() {
        let controller = makeController()

        let commands = controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false))
        XCTAssertEqual(commands.firstRequestStart?.source, .holdHotKey)

        let repeatCommands = controller.handle(.recordHotKeyDown(receivedAt: base.addingTimeInterval(0.01), eventID: 2, isRepeat: true))
        XCTAssertTrue(repeatCommands.contains(.ignore(reason: .repeatedKeyDown)))
    }

    func testReleaseDuringStartupStopsAfterRecordingBegins() throws {
        let controller = makeController()
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))

        _ = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(1.0), eventID: 2))
        let commands = controller.handle(.recordingBegan(
            startID: start.startID,
            recordingID: recordingID,
            beganAt: base.addingTimeInterval(0.2)
        ))

        XCTAssertEqual(commands.firstRequestStop?.reason, .releasedDuringStartup)
        XCTAssertEqual(commands.firstRequestStop?.shouldTranscribe, true)
    }

    func testQuickStartupTapDiscardsWhenRecordingBegins() throws {
        let controller = makeController()
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))

        _ = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(0.08), eventID: 2))
        let commands = controller.handle(.recordingBegan(
            startID: start.startID,
            recordingID: recordingID,
            beganAt: base.addingTimeInterval(0.05)
        ))

        XCTAssertEqual(commands.firstRequestStop?.reason, .releasedDuringStartup)
        XCTAssertEqual(commands.firstRequestStop?.shouldTranscribe, false)
        XCTAssertTrue(commands.contains(.showStatus("Recording discarded.")))
    }

    func testSecondPressDuringStartupClearsQuickReleaseDiscard() throws {
        let controller = makeController()
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))

        _ = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(0.08), eventID: 2))
        let secondDownCommands = controller.handle(.recordHotKeyDown(receivedAt: base.addingTimeInterval(0.10), eventID: 3, isRepeat: false))
        XCTAssertEqual(secondDownCommands.cancelledTimerKind, .startupReleaseGrace)

        let beganCommands = controller.handle(.recordingBegan(
            startID: start.startID,
            recordingID: recordingID,
            beganAt: base.addingTimeInterval(0.12)
        ))

        XCTAssertNil(beganCommands.firstRequestStop)
        XCTAssertEqual(beganCommands.scheduledTimerKind, .lostReleaseWatchdog)
        XCTAssertEqual(
            controller.state,
            .recordingHeld(
                recordingID: recordingID,
                pressedAt: base.addingTimeInterval(0.10),
                beganAt: base.addingTimeInterval(0.12),
                keyDown: true,
                lostReleaseToken: beganCommands.scheduledTimerToken
            )
        )
    }

    func testSpaceLatchRequestedDuringStartupAppliesWhenRecordingBegins() throws {
        let controller = makeController()
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))

        let latchCommands = controller.handle(.latchHotKeyDown(receivedAt: base.addingTimeInterval(0.05)))
        XCTAssertTrue(latchCommands.contains(.showStatus("Recording will latch when ready.")))
        XCTAssertFalse(controller.isLatchedForDisplay)

        let beganCommands = controller.handle(.recordingBegan(
            startID: start.startID,
            recordingID: recordingID,
            beganAt: base.addingTimeInterval(0.12)
        ))

        XCTAssertTrue(beganCommands.contains(.enterLatch(source: .latchHotKey)))
        XCTAssertEqual(
            controller.state,
            .recordingLatched(
                recordingID: recordingID,
                beganAt: base.addingTimeInterval(0.12),
                latchSource: .latchHotKey
            )
        )
    }

    func testHeldRecordingReleaseStopsAndTranscribesAfterMinimumDuration() throws {
        let controller = makeController()
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))
        _ = controller.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base.addingTimeInterval(0.1)))

        let commands = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(1.2), eventID: 2))

        XCTAssertEqual(commands.firstRequestStop?.reason, .holdReleased)
        XCTAssertEqual(commands.firstRequestStop?.shouldTranscribe, true)
    }

    func testHeldRecordingBelowMinimumDurationDiscards() throws {
        let controller = makeController()
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))
        _ = controller.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base.addingTimeInterval(0.05)))

        let commands = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(0.4), eventID: 2))

        XCTAssertEqual(commands.firstRequestStop?.reason, .holdReleased)
        XCTAssertEqual(commands.firstRequestStop?.shouldTranscribe, false)
        XCTAssertTrue(commands.contains(.showStatus("Recording discarded.")))
    }

    func testQuickReleaseBuffersStopAndSecondPressLatches() throws {
        let controller = makeController()
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))
        _ = controller.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base.addingTimeInterval(0.02)))

        let releaseCommands = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(0.10), eventID: 2))
        XCTAssertEqual(releaseCommands.scheduledTimerKind, .doublePressWindow)

        let latchCommands = controller.handle(.recordHotKeyDown(receivedAt: base.addingTimeInterval(0.2), eventID: 3, isRepeat: false))
        XCTAssertTrue(latchCommands.contains(.enterLatch(source: .doublePress)))
        XCTAssertTrue(controller.isLatchedForDisplay)
    }

    func testBufferedStopCommitsWhenSecondPressDoesNotArrive() throws {
        let controller = makeController()
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))
        _ = controller.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base.addingTimeInterval(-1.0)))

        let releaseCommands = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(0.1), eventID: 2))
        let timer = try scheduledTimer(from: releaseCommands, kind: .doublePressWindow)
        let commands = controller.handle(.timerElapsed(kind: .doublePressWindow, token: timer.token, at: timer.firesAt))

        XCTAssertEqual(commands.firstRequestStop?.reason, .bufferedStopCommitted)
        XCTAssertEqual(commands.firstRequestStop?.shouldTranscribe, true)
    }

    func testLatchedRecordingIgnoresReleaseAndStopsOnNextPrimaryPress() throws {
        let controller = makeController()
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))
        _ = controller.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base))
        _ = controller.handle(.latchHotKeyDown(receivedAt: base.addingTimeInterval(0.5)))

        let releaseCommands = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(0.6), eventID: 2))
        XCTAssertNil(releaseCommands.firstRequestStop)

        let stopCommands = controller.handle(.recordHotKeyDown(receivedAt: base.addingTimeInterval(1.0), eventID: 3, isRepeat: false))
        XCTAssertEqual(stopCommands.firstRequestStop?.reason, .latchedHotKeyPressed)
        XCTAssertEqual(stopCommands.firstRequestStop?.shouldTranscribe, true)
    }

    func testExternalRecordingBeganSeedsPrimaryHotkeyStop() {
        let controller = makeController()

        let beginCommands = controller.handle(.externalRecordingBegan(recordingID: recordingID, beganAt: base))
        XCTAssertTrue(beginCommands.contains(.enterLatch(source: .latchHotKey)))
        XCTAssertTrue(controller.isLatchedForDisplay)

        let stopCommands = controller.handle(.recordHotKeyDown(receivedAt: base.addingTimeInterval(1.0), eventID: 1, isRepeat: false))

        XCTAssertEqual(stopCommands.firstRequestStop?.reason, .latchedHotKeyPressed)
        XCTAssertEqual(stopCommands.firstRequestStop?.shouldTranscribe, true)
        XCTAssertEqual(controller.state, .stopping(recordingID: recordingID, stopReason: .latchedHotKeyPressed))
    }

    func testCancelHotkeyCancelsStartingAndRecording() throws {
        let startingController = makeController()
        _ = startingController.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false))
        XCTAssertTrue(startingController.handle(.cancelHotKeyDown(receivedAt: base.addingTimeInterval(0.1))).contains(.requestCancel(reason: .cancelHotKey)))

        let recordingController = makeController()
        let start = try requestStart(from: recordingController.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))
        _ = recordingController.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base))
        XCTAssertTrue(recordingController.handle(.cancelHotKeyDown(receivedAt: base.addingTimeInterval(0.5))).contains(.requestCancel(reason: .cancelHotKey)))
    }

    func testCommandCollectionReportsCancelRequests() {
        XCTAssertFalse([RecordingTriggerCommand.ignore(reason: .releaseWithoutActiveRecording)].requestsCancel)
        XCTAssertTrue([RecordingTriggerCommand.requestCancel(reason: .cancelHotKey)].requestsCancel)
    }

    func testToggleModeIgnoresReleasesAndStopsOnSecondPress() throws {
        let controller = makeController(behavior: .toggle)
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))
        _ = controller.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base))

        let releaseCommands = controller.handle(.recordHotKeyUp(receivedAt: base.addingTimeInterval(0.1), eventID: 2))
        XCTAssertNil(releaseCommands.firstRequestStop)

        let stopCommands = controller.handle(.recordHotKeyDown(receivedAt: base.addingTimeInterval(1.0), eventID: 3, isRepeat: false))
        XCTAssertEqual(stopCommands.firstRequestStop?.reason, .latchedHotKeyPressed)
        XCTAssertEqual(stopCommands.firstRequestStop?.shouldTranscribe, true)
    }

    func testToggleModeDiscardsBelowMinimumDuration() throws {
        let controller = makeController(behavior: .toggle)
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))
        _ = controller.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base))

        let stopCommands = controller.handle(.recordHotKeyDown(receivedAt: base.addingTimeInterval(0.2), eventID: 2, isRepeat: false))

        XCTAssertEqual(stopCommands.firstRequestStop?.reason, .latchedHotKeyPressed)
        XCTAssertEqual(stopCommands.firstRequestStop?.shouldTranscribe, false)
        XCTAssertTrue(stopCommands.contains(.showStatus("Recording discarded.")))
        XCTAssertEqual(controller.state, .idle(clean: true))

        let restartCommands = controller.handle(.recordHotKeyDown(receivedAt: base.addingTimeInterval(0.3), eventID: 3, isRepeat: false))
        XCTAssertEqual(restartCommands.firstRequestStart?.source, .toggleHotKey)
    }

    func testProcessingBusyIgnoresHotkeyPresses() {
        let controller = makeController(initialState: .processingBusy(recordingID: recordingID))

        let commands = controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false))

        XCTAssertTrue(commands.contains(.ignore(reason: .processingBusy)))
        XCTAssertTrue(commands.contains(.showStatus("Still finishing the last recording.")))
    }

    func testLostReleaseWatchdogLatchesHeldRecording() throws {
        let controller = makeController()
        let start = try requestStart(from: controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)))
        let beginCommands = controller.handle(.recordingBegan(startID: start.startID, recordingID: recordingID, beganAt: base))
        let timer = try scheduledTimer(from: beginCommands, kind: .lostReleaseWatchdog)

        let commands = controller.handle(.timerElapsed(kind: .lostReleaseWatchdog, token: timer.token, at: timer.firesAt))

        XCTAssertTrue(commands.contains(.enterLatch(source: .lostReleaseWatchdog)))
        XCTAssertTrue(commands.contains(.showStatus("Recording latched after long hold.")))
        XCTAssertTrue(controller.isLatchedForDisplay)
    }

    func testStartFailureResetsToIdle() {
        let controller = makeController()
        let start = controller.handle(.recordHotKeyDown(receivedAt: base, eventID: 1, isRepeat: false)).firstRequestStart!

        let commands = controller.handle(.startFailed(startID: start.startID, error: "No microphone", at: base.addingTimeInterval(0.1)))

        XCTAssertTrue(commands.contains(.requestCancel(reason: .startFailed)))
        XCTAssertEqual(controller.state, .idle(clean: true))
    }

    func testResetClearsStaleTerminalFailureState() {
        let controller = makeController(
            initialState: .stopping(recordingID: recordingID, stopReason: .holdReleased)
        )

        let commands = controller.handle(.reset(reason: "recording failed", at: base.addingTimeInterval(0.1)))

        XCTAssertTrue(commands.contains(.exitLatch))
        XCTAssertEqual(controller.state, .idle(clean: true))
    }

    private func makeController(
        initialState: RecordingTriggerState = .idle(clean: true),
        behavior: RecordingTriggerBehavior = .holdToTalk
    ) -> RecordingTriggerController {
        RecordingTriggerController(
            initialState: initialState,
            timingPolicy: .default,
            behaviorProvider: { behavior }
        )
    }

    private func requestStart(from commands: [RecordingTriggerCommand]) throws -> (startID: UUID, source: RecordingTriggerStartSource) {
        guard let request = commands.firstRequestStart else { throw TestError.missingCommand }
        return request
    }

    private func scheduledTimer(
        from commands: [RecordingTriggerCommand],
        kind: RecordingTriggerTimerKind
    ) throws -> (token: UUID, firesAt: Date) {
        guard let timer = commands.compactMap({ command -> (UUID, Date)? in
            if case .scheduleTimer(kind, let token, let firesAt) = command {
                return (token, firesAt)
            }
            return nil
        }).first else {
            throw TestError.missingCommand
        }
        return timer
    }
}

private enum TestError: Error {
    case missingCommand
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

    var scheduledTimerToken: UUID? {
        for command in self {
            if case .scheduleTimer(_, let token, _) = command {
                return token
            }
        }
        return nil
    }

    var cancelledTimerKind: RecordingTriggerTimerKind? {
        for command in self {
            if case .cancelTimer(let kind, _) = command {
                return kind
            }
        }
        return nil
    }
}
