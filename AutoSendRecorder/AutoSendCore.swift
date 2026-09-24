import Foundation

enum AutoSendPhase: Equatable, Sendable {
    case idle
    case starting
    case recording
    case transcribing
    case delivering
    case ready
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .starting, .recording, .transcribing, .delivering:
            return true
        case .idle, .ready, .failed:
            return false
        }
    }
}

enum AutoSendRecordingTriggerEvent: Equatable, Sendable {
    case pressed
    case released
    case latchPressed
    case phaseChanged(AutoSendPhase)
}

enum AutoSendRecordingTriggerCommand: Equatable, Sendable {
    case none
    case start
    case stop
}

struct AutoSendRecordingTriggerController: Sendable {
    private var keyIsDown = false
    private var stopWhenRecordingStarts = false
    private var latchRequested = false
    private(set) var isLatched = false

    mutating func handle(
        _ event: AutoSendRecordingTriggerEvent,
        mode: AutoSendTriggerMode,
        phase: AutoSendPhase
    ) -> AutoSendRecordingTriggerCommand {
        switch mode {
        case .toggle:
            stopWhenRecordingStarts = false
            switch event {
            case .pressed:
                return phase == .recording ? .stop : (phase.isBusy ? .none : .start)
            case .released, .latchPressed, .phaseChanged:
                return .none
            }

        case .walkieTalkie:
            switch event {
            case .pressed:
                guard !keyIsDown else { return .none }
                keyIsDown = true
                if isLatched {
                    isLatched = false
                    keyIsDown = false
                    return phase == .recording ? .stop : .none
                }
                stopWhenRecordingStarts = false
                return phase.isBusy ? .none : .start

            case .released:
                guard keyIsDown else { return .none }
                keyIsDown = false
                guard !isLatched else { return .none }
                if phase == .recording {
                    stopWhenRecordingStarts = false
                    return .stop
                }
                if phase == .starting {
                    stopWhenRecordingStarts = true
                }
                return .none

            case .latchPressed:
                guard phase == .starting || phase == .recording else { return .none }
                latchRequested = true
                if phase == .recording {
                    isLatched = true
                    latchRequested = false
                    keyIsDown = false
                    stopWhenRecordingStarts = false
                }
                return .none

            case .phaseChanged(let newPhase):
                if newPhase == .recording, latchRequested {
                    isLatched = true
                    latchRequested = false
                    keyIsDown = false
                    stopWhenRecordingStarts = false
                    return .none
                }
                if newPhase == .recording, stopWhenRecordingStarts, !keyIsDown {
                    stopWhenRecordingStarts = false
                    return .stop
                }
                if !newPhase.isBusy {
                    stopWhenRecordingStarts = false
                    keyIsDown = false
                    latchRequested = false
                    isLatched = false
                }
                return .none
            }
        }
    }
}

struct AutoSendPhaseUpdate: Equatable, Sendable {
    let sequence: UInt64
    let phase: AutoSendPhase
}

struct AutoSendOperationID: Equatable, Hashable, Sendable {
    let rawValue: UInt64
}

enum AutoSendRecordingSource: Equatable, Sendable {
    case macHotKey
    case esp32Button
}

enum AutoSendRecordingSourceGate {
    static func canProcess(
        source: AutoSendRecordingSource,
        activeSource: AutoSendRecordingSource?
    ) -> Bool {
        activeSource == nil || activeSource == source
    }
}

struct AutoSendWirelessButtonStateFilter: Sendable {
    private var lastPressed = false

    mutating func consume(pressed: Bool) -> Bool? {
        guard pressed != lastPressed else { return nil }
        lastPressed = pressed
        return pressed
    }

    mutating func reset() {
        lastPressed = false
    }
}

enum AutoSendDeliveryDisposition: Equatable, Sendable {
    case sent
    case pastedWithoutSending
    case sendSuppressed(String)
    case copied(String)
    case noPasteTarget(String)
    case permissionRequired(String)
    case pasteFailed(String)

    /// Whether the text reached a destination: a text field or the clipboard.
    var delivered: Bool {
        switch self {
        case .sent, .pastedWithoutSending, .sendSuppressed, .copied, .permissionRequired:
            return true
        case .noPasteTarget, .pasteFailed:
            return false
        }
    }

    /// Short label for the archive's `deliveredVia`.
    var archiveLabel: String {
        switch self {
        case .sent: return "sent"
        case .pastedWithoutSending: return "pasted"
        case .sendSuppressed: return "pasted-send-suppressed"
        case .copied: return "copied"
        case .noPasteTarget: return "no-paste-target"
        case .permissionRequired: return "copied-permission-required"
        case .pasteFailed: return "paste-failed"
        }
    }
}

enum AutoSendClipboardFallback {
    static func disposition(
        accessibilityTrusted: Bool,
        clipboardWriteSucceeded: Bool,
        statusMessage: String
    ) -> AutoSendDeliveryDisposition {
        guard clipboardWriteSucceeded else {
            return .pasteFailed("Could not write the transcript to the clipboard.")
        }
        guard accessibilityTrusted else {
            return .permissionRequired("Copied to clipboard. \(statusMessage)")
        }
        return .copied("Copied to clipboard. No editable text field was available.")
    }
}

enum AutoSendFailureKind: Equatable, Sendable {
    case microphonePermission
    case recording
    case transcription
    case delivery
}

protocol AutoSendCaptureService {
    func start(
        operationID: AutoSendOperationID,
        source: AutoSendRecordingSource
    ) async throws
    func stop(operationID: AutoSendOperationID) async throws -> URL
    func cancel(operationID: AutoSendOperationID) async
}

protocol AutoSendTranscriptService {
    func transcribe(audioURL: URL, operationID: AutoSendOperationID) async throws -> String
    func cancel(operationID: AutoSendOperationID) async
}

protocol AutoSendDeliveryService {
    func deliver(text: String) async throws -> AutoSendDeliveryDisposition
}

/// One recording's texts for the transcript archive: what the recogniser heard, what the replacement
/// rules made of it, and what was sent (nil when delivery failed).
struct AutoSendTranscriptEvidence: Equatable, Sendable {
    var audioURL: URL
    var recognizerText: String
    var afterRulesText: String
    var finalText: String
    var deliveredText: String?
    var disposition: AutoSendDeliveryDisposition?
    var failure: String?
}

struct AutoSendWorkflowEnvironment: @unchecked Sendable {
    let capture: any AutoSendCaptureService
    let transcription: any AutoSendTranscriptService
    let delivery: any AutoSendDeliveryService
    /// Replacement rules, applied to the recogniser's output before `normalize`.
    let applyRules: @Sendable (String) -> String
    let normalize: @Sendable (String) -> String
    let archive: @Sendable (AutoSendTranscriptEvidence) -> Void
    let phaseDidChange: @Sendable (AutoSendPhaseUpdate) -> Void

    init(
        capture: any AutoSendCaptureService,
        transcription: any AutoSendTranscriptService,
        delivery: any AutoSendDeliveryService,
        applyRules: @escaping @Sendable (String) -> String = { $0 },
        normalize: @escaping @Sendable (String) -> String,
        archive: @escaping @Sendable (AutoSendTranscriptEvidence) -> Void = { _ in },
        phaseDidChange: @escaping @Sendable (AutoSendPhaseUpdate) -> Void = { _ in }
    ) {
        self.capture = capture
        self.transcription = transcription
        self.delivery = delivery
        self.applyRules = applyRules
        self.normalize = normalize
        self.archive = archive
        self.phaseDidChange = phaseDidChange
    }
}

actor AutoSendWorkflow {
    private let environment: AutoSendWorkflowEnvironment
    private(set) var phase: AutoSendPhase = .idle
    private(set) var lastAudioURL: URL?
    private(set) var lastText = ""
    private(set) var lastDeliveryDisposition: AutoSendDeliveryDisposition?
    private(set) var lastFailureKind: AutoSendFailureKind?
    private var nextOperationValue: UInt64 = 0
    private var activeOperationID: AutoSendOperationID?
    private var phaseSequence: UInt64 = 0
    private var deliveryTask: (
        operationID: AutoSendOperationID,
        task: Task<AutoSendDeliveryDisposition, Error>
    )?

    init(environment: AutoSendWorkflowEnvironment) {
        self.environment = environment
    }

    func start(source: AutoSendRecordingSource = .macHotKey) async {
        guard !phase.isBusy else { return }
        let operationID = makeOperationID()
        activeOperationID = operationID
        publish(.starting)
        lastText = ""
        lastDeliveryDisposition = nil
        lastFailureKind = nil

        do {
            try await environment.capture.start(
                operationID: operationID,
                source: source
            )
            guard isActive(operationID) else {
                await cleanUpStaleOperation(operationID)
                return
            }
            publish(.recording)
        } catch {
            guard isActive(operationID) else {
                await cleanUpStaleOperation(operationID)
                return
            }
            activeOperationID = nil
            await environment.transcription.cancel(operationID: operationID)
            lastFailureKind = error is AutoSendRecorderProductError
                ? .microphonePermission
                : .recording
            publish(.failed(error.localizedDescription))
        }
    }

    @discardableResult
    func stop() async -> Bool {
        guard phase == .recording, let operationID = activeOperationID else { return false }
        publish(.transcribing)
        var evidence: AutoSendTranscriptEvidence?

        do {
            let audioURL = try await environment.capture.stop(operationID: operationID)
            guard isActive(operationID) else {
                await environment.transcription.cancel(operationID: operationID)
                return false
            }
            lastAudioURL = audioURL

            let transcript = try await environment.transcription.transcribe(
                audioURL: audioURL,
                operationID: operationID
            )
            guard isActive(operationID) else {
                await environment.transcription.cancel(operationID: operationID)
                return false
            }

            let afterRules = environment.applyRules(transcript)
            let normalized = environment.normalize(afterRules)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            evidence = AutoSendTranscriptEvidence(
                audioURL: audioURL,
                recognizerText: transcript,
                afterRulesText: afterRules,
                finalText: normalized
            )
            guard !normalized.isEmpty else {
                throw AutoSendWorkflowError.emptyTranscript
            }
            lastText = normalized
            publish(.delivering)
            let task = Task {
                try await environment.delivery.deliver(text: normalized)
            }
            deliveryTask = (operationID, task)
            let disposition = try await task.value
            clearDeliveryTask(operationID: operationID)
            if var record = evidence {
                record.deliveredText = disposition.delivered ? normalized : nil
                record.disposition = disposition
                environment.archive(record)
            }
            guard isActive(operationID) else { return false }
            lastDeliveryDisposition = disposition
            activeOperationID = nil
            publish(.ready)
            return true
        } catch {
            clearDeliveryTask(operationID: operationID)
            if var record = evidence {
                record.failure = error.localizedDescription
                environment.archive(record)
            }
            guard isActive(operationID) else {
                await environment.transcription.cancel(operationID: operationID)
                return false
            }
            let failedDuringDelivery = phase == .delivering
            activeOperationID = nil
            await environment.transcription.cancel(operationID: operationID)
            lastFailureKind = failedDuringDelivery ? .delivery : .transcription
            publish(.failed(error.localizedDescription))
            return true
        }
    }

    func cancel() async {
        guard phase.isBusy, let operationID = activeOperationID else { return }
        if deliveryTask?.operationID == operationID {
            deliveryTask?.task.cancel()
            deliveryTask = nil
        }
        activeOperationID = nil
        publish(.idle)
        await environment.capture.cancel(operationID: operationID)
        await environment.transcription.cancel(operationID: operationID)
    }

    private func makeOperationID() -> AutoSendOperationID {
        nextOperationValue &+= 1
        return AutoSendOperationID(rawValue: nextOperationValue)
    }

    private func isActive(_ operationID: AutoSendOperationID) -> Bool {
        activeOperationID == operationID
    }

    private func cleanUpStaleOperation(_ operationID: AutoSendOperationID) async {
        await environment.capture.cancel(operationID: operationID)
        await environment.transcription.cancel(operationID: operationID)
    }

    private func clearDeliveryTask(operationID: AutoSendOperationID) {
        if deliveryTask?.operationID == operationID {
            deliveryTask = nil
        }
    }

    private func publish(_ newPhase: AutoSendPhase) {
        phase = newPhase
        phaseSequence &+= 1
        environment.phaseDidChange(
            AutoSendPhaseUpdate(sequence: phaseSequence, phase: newPhase)
        )
    }
}

enum AutoSendWorkflowError: LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "Parakeet did not detect speech. The recording was kept."
        }
    }
}

enum AutoSendRecorderProductError: LocalizedError, Equatable, Sendable {
    case microphoneDenied
    case microphoneRequestTimedOut
    case microphoneRequestFailed(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "Microphone access is required. Enable it for Auto Send Recorder in System Settings."
        case .microphoneRequestTimedOut:
            return "The microphone permission request did not finish. Quit and reopen Auto Send Recorder, then try again."
        case .microphoneRequestFailed(let message):
            return "Microphone permission could not be checked: \(message)"
        }
    }
}

enum AutoSendMicrophonePermissionOutcome: Equatable, Sendable {
    case granted
    case denied
    case timedOut
    case cancelled
    case failed(String)
}

enum AutoSendMicrophonePermissionRequest {
    static let defaultTimeoutNanoseconds: UInt64 = 12_000_000_000

    static func resolve(
        timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds,
        request: @escaping @Sendable () async -> AutoSendMicrophonePermissionOutcome
    ) async -> AutoSendMicrophonePermissionOutcome {
        let resultGate = AutoSendPermissionResultGate()
        let requestTask = Task {
            resultGate.resolve(await request())
        }
        let timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                resultGate.resolve(.timedOut)
            } catch {
                // The request completed or its caller cancelled.
            }
        }
        let result = await withTaskCancellationHandler {
            await resultGate.wait()
        } onCancel: {
            resultGate.resolve(.cancelled)
        }
        requestTask.cancel()
        timeoutTask.cancel()
        return result
    }
}

private final class AutoSendPermissionResultGate: @unchecked Sendable {
    private enum State {
        case pending
        case waiting(CheckedContinuation<AutoSendMicrophonePermissionOutcome, Never>)
        case resolved(AutoSendMicrophonePermissionOutcome)
        case finished
    }

    private let lock = NSLock()
    private var state: State = .pending

    func wait() async -> AutoSendMicrophonePermissionOutcome {
        await withCheckedContinuation { continuation in
            lock.lock()
            switch state {
            case .pending:
                state = .waiting(continuation)
                lock.unlock()
            case .resolved(let result):
                state = .finished
                lock.unlock()
                continuation.resume(returning: result)
            case .waiting, .finished:
                lock.unlock()
                preconditionFailure("The permission result can only be awaited once.")
            }
        }
    }

    func resolve(_ result: AutoSendMicrophonePermissionOutcome) {
        lock.lock()
        switch state {
        case .pending:
            state = .resolved(result)
            lock.unlock()
        case .waiting(let continuation):
            state = .finished
            lock.unlock()
            continuation.resume(returning: result)
        case .resolved, .finished:
            lock.unlock()
        }
    }
}

protocol AutoSendLiveTranscriptFinalizing: Sendable {
    func finalize() async throws -> String
    func cancel()
}

protocol AutoSendOneShotTranscribing: Sendable {
    func transcribe(audioURL: URL) async throws -> String
}

struct AutoSendParakeetFallbackPipeline: Sendable {
    let oneShot: any AutoSendOneShotTranscribing

    func transcribe(
        liveSession: (any AutoSendLiveTranscriptFinalizing)?,
        audioURL: URL
    ) async throws -> String {
        if let liveSession {
            do {
                let text = try await liveSession.finalize()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return text
                }
            } catch {
                // The saved WAV is authoritative and remains available for fallback.
            }
        }

        return try await oneShot.transcribe(audioURL: audioURL)
    }
}

struct AutoSendSourceAwareTranscriptionPipeline: Sendable {
    let fastWireless: any AutoSendOneShotTranscribing
    let fallback: AutoSendParakeetFallbackPipeline

    func transcribe(
        source: AutoSendRecordingSource,
        liveSession: (any AutoSendLiveTranscriptFinalizing)?,
        audioURL: URL
    ) async throws -> String {
        if source == .esp32Button {
            do {
                let text = try await fastWireless.transcribe(audioURL: audioURL)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    liveSession?.cancel()
                    return text
                }
            } catch {
                // Keep the intact-WAV fallback below for runtime or model failures.
            }
        }

        return try await fallback.transcribe(
            liveSession: liveSession,
            audioURL: audioURL
        )
    }
}
