import Foundation

enum RecordingTriggerBehavior: Equatable {
    case holdToTalk
    case toggle
}

struct RecordingTriggerTimingPolicy: Equatable, Codable {
    var accidentalTapThreshold: TimeInterval
    var doublePressLatchWindow: TimeInterval
    var startupReleaseGrace: TimeInterval
    var minimumRecordingDuration: TimeInterval
    var lostReleaseWatchdog: TimeInterval
    var repeatDebounce: TimeInterval

    static let `default` = RecordingTriggerTimingPolicy(
        accidentalTapThreshold: 0.22,
        doublePressLatchWindow: 0.32,
        startupReleaseGrace: 0.12,
        minimumRecordingDuration: 0.70,
        lostReleaseWatchdog: 45.0,
        repeatDebounce: 0.05
    )
}

enum RecordingTriggerTimerKind: String, Codable, Equatable, Hashable {
    case startupReleaseGrace
    case doublePressWindow
    case lostReleaseWatchdog
}

enum RecordingTriggerStartSource: String, Codable, Equatable {
    case holdHotKey
    case toggleHotKey
}

enum RecordingTriggerLatchSource: String, Codable, Equatable {
    case doublePress
    case latchHotKey
    case lostReleaseWatchdog
}

enum RecordingTriggerStopReason: String, Codable, Equatable {
    case holdReleased
    case togglePressed
    case latchedHotKeyPressed
    case bufferedStopCommitted
    case releasedDuringStartup
}

enum RecordingTriggerCancelReason: String, Codable, Equatable {
    case cancelHotKey
    case accidentalTap
    case belowMinimumDuration
    case startFailed
}

enum RecordingTriggerIgnoreReason: String, Codable, Equatable {
    case repeatedKeyDown
    case alreadyStarting
    case alreadyRecording
    case processingBusy
    case releaseWithoutActiveRecording
    case staleTimer
    case staleLifecycleEvent
    case unsupportedState
}

enum RecordingTriggerEvent: Equatable {
    case recordHotKeyDown(receivedAt: Date, eventID: UInt64, isRepeat: Bool)
    case recordHotKeyUp(receivedAt: Date, eventID: UInt64)
    case cancelHotKeyDown(receivedAt: Date)
    case latchHotKeyDown(receivedAt: Date)
    case recordingBegan(startID: UUID, recordingID: UUID, beganAt: Date)
    case externalRecordingBegan(recordingID: UUID, beganAt: Date)
    case startFailed(startID: UUID?, error: String, at: Date)
    case processingBegan(recordingID: UUID?, at: Date)
    case processingFinished(recordingID: UUID?, at: Date)
    case timerElapsed(kind: RecordingTriggerTimerKind, token: UUID, at: Date)
    case reset(reason: String, at: Date)
}

enum RecordingTriggerCommand: Equatable {
    case requestStart(startID: UUID, source: RecordingTriggerStartSource, requestedAt: Date)
    case requestStop(recordingID: UUID, reason: RecordingTriggerStopReason, requestedAt: Date, shouldTranscribe: Bool)
    case requestCancel(reason: RecordingTriggerCancelReason)
    case enterLatch(source: RecordingTriggerLatchSource)
    case exitLatch
    case scheduleTimer(kind: RecordingTriggerTimerKind, token: UUID, firesAt: Date)
    case cancelTimer(kind: RecordingTriggerTimerKind, token: UUID?)
    case showStatus(String)
    case ignore(reason: RecordingTriggerIgnoreReason)
    case log(RecordingTriggerDiagnosticEvent)
}

extension Array where Element == RecordingTriggerCommand {
    var requestsCancel: Bool {
        contains { command in
            if case .requestCancel = command {
                return true
            }
            return false
        }
    }
}

enum RecordingTriggerState: Equatable {
    case idle(clean: Bool)
    case starting(
        startID: UUID,
        startedFrom: RecordingTriggerStartSource,
        keyDown: Bool,
        pressedAt: Date,
        releasedDuringStartupAt: Date?,
        latchRequested: Bool,
        startupReleaseToken: UUID?
    )
    case recordingHeld(
        recordingID: UUID,
        pressedAt: Date,
        beganAt: Date,
        keyDown: Bool,
        lostReleaseToken: UUID?
    )
    case recordingLatched(
        recordingID: UUID,
        beganAt: Date,
        latchSource: RecordingTriggerLatchSource
    )
    case pendingBufferedStop(
        recordingID: UUID,
        beganAt: Date,
        releasedAt: Date,
        pendingStopToken: UUID
    )
    case stopping(recordingID: UUID, stopReason: RecordingTriggerStopReason)
    case processingBusy(recordingID: UUID?)

    var isLatched: Bool {
        if case .recordingLatched = self {
            return true
        }
        return false
    }

    var activeRecordingID: UUID? {
        switch self {
        case .recordingHeld(let recordingID, _, _, _, _),
             .recordingLatched(let recordingID, _, _),
             .pendingBufferedStop(let recordingID, _, _, _),
             .stopping(let recordingID, _):
            return recordingID
        case .idle, .starting, .processingBusy:
            return nil
        }
    }

    var activeStartID: UUID? {
        if case .starting(let startID, _, _, _, _, _, _) = self {
            return startID
        }
        return nil
    }

    var diagnosticName: String {
        switch self {
        case .idle:
            return "idle"
        case .starting:
            return "starting"
        case .recordingHeld:
            return "recordingHeld"
        case .recordingLatched:
            return "recordingLatched"
        case .pendingBufferedStop:
            return "pendingBufferedStop"
        case .stopping:
            return "stopping"
        case .processingBusy:
            return "processingBusy"
        }
    }
}

struct RecordingTriggerDiagnosticEvent: Equatable, Codable {
    var at: Date
    var event: String
    var previousState: String
    var nextState: String
    var commands: [String]
    var detail: String
}
