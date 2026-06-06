import Foundation

final class RecordingTriggerController {
    private(set) var state: RecordingTriggerState
    private let behaviorProvider: () -> RecordingTriggerBehavior
    let timingPolicy: RecordingTriggerTimingPolicy

    private(set) var diagnostics: [RecordingTriggerDiagnosticEvent] = []
    private let diagnosticsLimit: Int

    init(
        initialState: RecordingTriggerState = .idle(clean: true),
        timingPolicy: RecordingTriggerTimingPolicy = .default,
        diagnosticsLimit: Int = 100,
        behaviorProvider: @escaping () -> RecordingTriggerBehavior
    ) {
        self.state = initialState
        self.timingPolicy = timingPolicy
        self.diagnosticsLimit = diagnosticsLimit
        self.behaviorProvider = behaviorProvider
    }

    var isLatchedForDisplay: Bool {
        state.isLatched
    }

    @discardableResult
    func handle(_ event: RecordingTriggerEvent) -> [RecordingTriggerCommand] {
        let previousState = state
        var commands = reduce(event)
        let diagnostic = RecordingTriggerDiagnosticEvent(
            at: event.receivedAt,
            event: event.diagnosticName,
            previousState: previousState.diagnosticName,
            nextState: state.diagnosticName,
            commands: commands.map(\.diagnosticName),
            detail: event.diagnosticDetail
        )
        appendDiagnostic(diagnostic)
        commands.append(.log(diagnostic))
        return commands
    }

    private func reduce(_ event: RecordingTriggerEvent) -> [RecordingTriggerCommand] {
        switch event {
        case .recordHotKeyDown(let receivedAt, let eventID, let isRepeat):
            return handleRecordDown(receivedAt: receivedAt, eventID: eventID, isRepeat: isRepeat)
        case .recordHotKeyUp(let receivedAt, let eventID):
            return handleRecordUp(receivedAt: receivedAt, eventID: eventID)
        case .cancelHotKeyDown:
            return handleCancel()
        case .latchHotKeyDown:
            return handleLatch()
        case .recordingBegan(let startID, let recordingID, let beganAt):
            return handleRecordingBegan(startID: startID, recordingID: recordingID, beganAt: beganAt)
        case .externalRecordingBegan(let recordingID, let beganAt):
            state = .recordingLatched(
                recordingID: recordingID,
                beganAt: beganAt,
                latchSource: .latchHotKey
            )
            return [.enterLatch(source: .latchHotKey)]
        case .startFailed(let startID, _, _):
            return handleStartFailed(startID: startID)
        case .processingBegan(let recordingID, _):
            state = .processingBusy(recordingID: recordingID)
            return [.cancelTimer(kind: .lostReleaseWatchdog, token: nil)]
        case .processingFinished:
            state = .idle(clean: true)
            return [.exitLatch]
        case .timerElapsed(let kind, let token, let at):
            return handleTimerElapsed(kind: kind, token: token, at: at)
        case .reset:
            state = .idle(clean: true)
            return [.exitLatch]
        }
    }

    private func handleRecordDown(receivedAt: Date, eventID: UInt64, isRepeat: Bool) -> [RecordingTriggerCommand] {
        if isRepeat {
            return [.ignore(reason: .repeatedKeyDown)]
        }

        switch state {
        case .idle:
            let startID = UUID()
            let source: RecordingTriggerStartSource = behaviorProvider() == .toggle ? .toggleHotKey : .holdHotKey
            state = .starting(
                startID: startID,
                startedFrom: source,
                keyDown: true,
                pressedAt: receivedAt,
                releasedDuringStartupAt: nil,
                startupReleaseToken: nil
            )
            return [.requestStart(startID: startID, source: source, requestedAt: receivedAt)]

        case .starting(let startID, let source, let keyDown, _, _, let token):
            guard !keyDown else { return [.ignore(reason: .repeatedKeyDown)] }
            state = .starting(
                startID: startID,
                startedFrom: source,
                keyDown: true,
                pressedAt: receivedAt,
                releasedDuringStartupAt: nil,
                startupReleaseToken: nil
            )
            return [.cancelTimer(kind: .startupReleaseGrace, token: token)]

        case .recordingHeld:
            return [.ignore(reason: .alreadyRecording)]

        case .recordingLatched(let recordingID, let beganAt, _):
            let shouldTranscribe = receivedAt.timeIntervalSince(beganAt) >= timingPolicy.minimumRecordingDuration
            if shouldTranscribe {
                state = .stopping(recordingID: recordingID, stopReason: .latchedHotKeyPressed)
            } else {
                state = .idle(clean: true)
            }
            return [
                .exitLatch,
                .requestStop(
                    recordingID: recordingID,
                    reason: .latchedHotKeyPressed,
                    requestedAt: receivedAt,
                    shouldTranscribe: shouldTranscribe
                )
            ] + (shouldTranscribe ? [] : [.showStatus("Recording discarded.")])

        case .pendingBufferedStop(let recordingID, let beganAt, _, let pendingStopToken):
            state = .recordingLatched(
                recordingID: recordingID,
                beganAt: beganAt,
                latchSource: .doublePress
            )
            return [
                .cancelTimer(kind: .doublePressWindow, token: pendingStopToken),
                .enterLatch(source: .doublePress),
                .showStatus("Recording latched.")
            ]

        case .stopping:
            return [.ignore(reason: .alreadyRecording)]

        case .processingBusy:
            return [
                .ignore(reason: .processingBusy),
                .showStatus("Still finishing the last recording.")
            ]
        }
    }

    private func handleRecordUp(receivedAt: Date, eventID: UInt64) -> [RecordingTriggerCommand] {
        switch state {
        case .idle:
            return [.ignore(reason: .releaseWithoutActiveRecording)]

        case .starting(let startID, let source, _, let pressedAt, _, let token):
            guard behaviorProvider() == .holdToTalk else {
                state = .starting(
                    startID: startID,
                    startedFrom: source,
                    keyDown: false,
                    pressedAt: pressedAt,
                    releasedDuringStartupAt: nil,
                    startupReleaseToken: token
                )
                return []
            }

            let releaseToken = UUID()
            state = .starting(
                startID: startID,
                startedFrom: source,
                keyDown: false,
                pressedAt: pressedAt,
                releasedDuringStartupAt: receivedAt,
                startupReleaseToken: releaseToken
            )
            return [
                .scheduleTimer(
                    kind: .startupReleaseGrace,
                    token: releaseToken,
                    firesAt: receivedAt.addingTimeInterval(timingPolicy.startupReleaseGrace)
                )
            ]

        case .recordingHeld(let recordingID, let pressedAt, let beganAt, _, let lostReleaseToken):
            guard behaviorProvider() == .holdToTalk else { return [] }
            let heldDuration = receivedAt.timeIntervalSince(pressedAt)
            let recordingDuration = receivedAt.timeIntervalSince(beganAt)

            if heldDuration < timingPolicy.accidentalTapThreshold {
                let token = UUID()
                state = .pendingBufferedStop(
                    recordingID: recordingID,
                    beganAt: beganAt,
                    releasedAt: receivedAt,
                    pendingStopToken: token
                )
                return [
                    .cancelTimer(kind: .lostReleaseWatchdog, token: lostReleaseToken),
                    .scheduleTimer(
                        kind: .doublePressWindow,
                        token: token,
                        firesAt: receivedAt.addingTimeInterval(timingPolicy.doublePressLatchWindow)
                    )
                ]
            }

            if recordingDuration < timingPolicy.minimumRecordingDuration {
                state = .idle(clean: true)
                return [
                    .cancelTimer(kind: .lostReleaseWatchdog, token: lostReleaseToken),
                    .requestStop(
                        recordingID: recordingID,
                        reason: .holdReleased,
                        requestedAt: receivedAt,
                        shouldTranscribe: false
                    ),
                    .showStatus("Recording discarded.")
                ]
            }

            state = .stopping(recordingID: recordingID, stopReason: .holdReleased)
            return [
                .cancelTimer(kind: .lostReleaseWatchdog, token: lostReleaseToken),
                .requestStop(
                    recordingID: recordingID,
                    reason: .holdReleased,
                    requestedAt: receivedAt,
                    shouldTranscribe: true
                )
            ]

        case .recordingLatched:
            return []

        case .pendingBufferedStop:
            return []

        case .stopping, .processingBusy:
            return [.ignore(reason: .releaseWithoutActiveRecording)]
        }
    }

    private func handleCancel() -> [RecordingTriggerCommand] {
        switch state {
        case .idle, .processingBusy:
            return []
        case .starting(_, _, _, _, _, let token):
            state = .idle(clean: true)
            return [
                .cancelTimer(kind: .startupReleaseGrace, token: token),
                .requestCancel(reason: .cancelHotKey),
                .exitLatch
            ]
        case .recordingHeld(_, _, _, _, let token):
            state = .idle(clean: true)
            return [
                .cancelTimer(kind: .lostReleaseWatchdog, token: token),
                .requestCancel(reason: .cancelHotKey),
                .exitLatch
            ]
        case .recordingLatched:
            state = .idle(clean: true)
            return [
                .requestCancel(reason: .cancelHotKey),
                .exitLatch
            ]
        case .pendingBufferedStop(_, _, _, let token):
            state = .idle(clean: true)
            return [
                .cancelTimer(kind: .doublePressWindow, token: token),
                .requestCancel(reason: .cancelHotKey),
                .exitLatch
            ]
        case .stopping:
            return []
        }
    }

    private func handleLatch() -> [RecordingTriggerCommand] {
        guard behaviorProvider() == .holdToTalk else { return [] }

        switch state {
        case .recordingHeld(let recordingID, _, let beganAt, _, let lostReleaseToken):
            state = .recordingLatched(
                recordingID: recordingID,
                beganAt: beganAt,
                latchSource: .latchHotKey
            )
            return [
                .cancelTimer(kind: .lostReleaseWatchdog, token: lostReleaseToken),
                .enterLatch(source: .latchHotKey),
                .showStatus("Recording latched.")
            ]
        case .pendingBufferedStop(let recordingID, let beganAt, _, let pendingStopToken):
            state = .recordingLatched(
                recordingID: recordingID,
                beganAt: beganAt,
                latchSource: .latchHotKey
            )
            return [
                .cancelTimer(kind: .doublePressWindow, token: pendingStopToken),
                .enterLatch(source: .latchHotKey),
                .showStatus("Recording latched.")
            ]
        default:
            return []
        }
    }

    private func handleRecordingBegan(startID: UUID, recordingID: UUID, beganAt: Date) -> [RecordingTriggerCommand] {
        guard case .starting(let currentStartID, _, let keyDown, let pressedAt, let releasedAt, let startupReleaseToken) = state,
              currentStartID == startID else {
            return [.ignore(reason: .staleLifecycleEvent)]
        }

        if behaviorProvider() == .toggle {
            state = .recordingLatched(recordingID: recordingID, beganAt: beganAt, latchSource: .latchHotKey)
            return [.enterLatch(source: .latchHotKey)]
        }

        if let releasedAt {
            let heldDuration = releasedAt.timeIntervalSince(pressedAt)
            let recordingDuration = max(0, releasedAt.timeIntervalSince(beganAt))

            if heldDuration < timingPolicy.accidentalTapThreshold ||
                recordingDuration < timingPolicy.minimumRecordingDuration {
                state = .idle(clean: true)
                return [
                    .cancelTimer(kind: .startupReleaseGrace, token: startupReleaseToken),
                    .requestStop(
                        recordingID: recordingID,
                        reason: .releasedDuringStartup,
                        requestedAt: releasedAt,
                        shouldTranscribe: false
                    ),
                    .showStatus("Recording discarded.")
                ]
            }

            state = .stopping(recordingID: recordingID, stopReason: .releasedDuringStartup)
            return [
                .cancelTimer(kind: .startupReleaseGrace, token: startupReleaseToken),
                .requestStop(
                    recordingID: recordingID,
                    reason: .releasedDuringStartup,
                    requestedAt: releasedAt,
                    shouldTranscribe: true
                )
            ]
        }

        let lostReleaseToken = UUID()
        state = .recordingHeld(
            recordingID: recordingID,
            pressedAt: pressedAt,
            beganAt: beganAt,
            keyDown: keyDown,
            lostReleaseToken: lostReleaseToken
        )
        return [
            .cancelTimer(kind: .startupReleaseGrace, token: startupReleaseToken),
            .scheduleTimer(
                kind: .lostReleaseWatchdog,
                token: lostReleaseToken,
                firesAt: beganAt.addingTimeInterval(timingPolicy.lostReleaseWatchdog)
            )
        ]
    }

    private func handleStartFailed(startID: UUID?) -> [RecordingTriggerCommand] {
        if let startID, state.activeStartID != startID {
            return [.ignore(reason: .staleLifecycleEvent)]
        }
        state = .idle(clean: true)
        return [
            .requestCancel(reason: .startFailed),
            .exitLatch
        ]
    }

    private func handleTimerElapsed(kind: RecordingTriggerTimerKind, token: UUID, at: Date) -> [RecordingTriggerCommand] {
        switch (kind, state) {
        case (.doublePressWindow, .pendingBufferedStop(let recordingID, let beganAt, let releasedAt, let pendingStopToken)):
            guard pendingStopToken == token else { return [.ignore(reason: .staleTimer)] }
            let recordingDuration = releasedAt.timeIntervalSince(beganAt)
            let shouldTranscribe = recordingDuration >= timingPolicy.minimumRecordingDuration
            if shouldTranscribe {
                state = .stopping(recordingID: recordingID, stopReason: .bufferedStopCommitted)
            } else {
                state = .idle(clean: true)
            }
            return [
                .requestStop(
                    recordingID: recordingID,
                    reason: .bufferedStopCommitted,
                    requestedAt: releasedAt,
                    shouldTranscribe: shouldTranscribe
                )
            ] + (shouldTranscribe ? [] : [.showStatus("Recording discarded.")])

        case (.startupReleaseGrace, .starting(_, _, _, _, _, let startupReleaseToken)):
            guard startupReleaseToken == token else { return [.ignore(reason: .staleTimer)] }
            return []

        case (.lostReleaseWatchdog, .recordingHeld(let recordingID, _, let beganAt, _, let lostReleaseToken)):
            guard lostReleaseToken == token else { return [.ignore(reason: .staleTimer)] }
            state = .recordingLatched(
                recordingID: recordingID,
                beganAt: beganAt,
                latchSource: .lostReleaseWatchdog
            )
            return [
                .enterLatch(source: .lostReleaseWatchdog),
                .showStatus("Recording latched after long hold.")
            ]

        default:
            return [.ignore(reason: .staleTimer)]
        }
    }

    private func appendDiagnostic(_ event: RecordingTriggerDiagnosticEvent) {
        diagnostics.append(event)
        if diagnostics.count > diagnosticsLimit {
            diagnostics.removeFirst(diagnostics.count - diagnosticsLimit)
        }
    }
}

private extension RecordingTriggerEvent {
    var receivedAt: Date {
        switch self {
        case .recordHotKeyDown(let receivedAt, _, _),
             .recordHotKeyUp(let receivedAt, _),
             .cancelHotKeyDown(let receivedAt),
             .latchHotKeyDown(let receivedAt),
             .recordingBegan(_, _, let receivedAt),
             .externalRecordingBegan(_, let receivedAt),
             .startFailed(_, _, let receivedAt),
             .processingBegan(_, let receivedAt),
             .processingFinished(_, let receivedAt),
             .timerElapsed(_, _, let receivedAt),
             .reset(_, let receivedAt):
            return receivedAt
        }
    }

    var diagnosticName: String {
        switch self {
        case .recordHotKeyDown:
            return "recordHotKeyDown"
        case .recordHotKeyUp:
            return "recordHotKeyUp"
        case .cancelHotKeyDown:
            return "cancelHotKeyDown"
        case .latchHotKeyDown:
            return "latchHotKeyDown"
        case .recordingBegan:
            return "recordingBegan"
        case .externalRecordingBegan:
            return "externalRecordingBegan"
        case .startFailed:
            return "startFailed"
        case .processingBegan:
            return "processingBegan"
        case .processingFinished:
            return "processingFinished"
        case .timerElapsed(let kind, _, _):
            return "timerElapsed.\(kind.rawValue)"
        case .reset:
            return "reset"
        }
    }

    var diagnosticDetail: String {
        switch self {
        case .recordHotKeyDown(_, let eventID, let isRepeat):
            return "eventID=\(eventID) isRepeat=\(isRepeat)"
        case .recordHotKeyUp(_, let eventID):
            return "eventID=\(eventID)"
        case .startFailed(_, let error, _):
            return error
        case .reset(let reason, _):
            return reason
        default:
            return ""
        }
    }
}

private extension RecordingTriggerCommand {
    var diagnosticName: String {
        switch self {
        case .requestStart:
            return "requestStart"
        case .requestStop(_, let reason, _, let shouldTranscribe):
            return "requestStop.\(reason.rawValue).transcribe=\(shouldTranscribe)"
        case .requestCancel(let reason):
            return "requestCancel.\(reason.rawValue)"
        case .enterLatch(let source):
            return "enterLatch.\(source.rawValue)"
        case .exitLatch:
            return "exitLatch"
        case .scheduleTimer(let kind, _, _):
            return "scheduleTimer.\(kind.rawValue)"
        case .cancelTimer(let kind, _):
            return "cancelTimer.\(kind.rawValue)"
        case .showStatus:
            return "showStatus"
        case .ignore(let reason):
            return "ignore.\(reason.rawValue)"
        case .log:
            return "log"
        }
    }
}
