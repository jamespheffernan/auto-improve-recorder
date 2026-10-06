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

    /// A run can begin only when no run is in progress.
    var acceptsStart: Bool { !isBusy }

    /// Only a run that is recording can be stopped and sent.
    var acceptsStop: Bool { self == .recording }
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

/// One run as the workflow sees it. The workflow publishes a new snapshot on every change, so a
/// reader never combines values read at different moments.
struct AutoSendRunSnapshot: Equatable, Sendable {
    /// Increases with every change; a reader keeps the highest it has seen.
    var sequence: UInt64 = 0
    var phase: AutoSendPhase = .idle
    /// The current run's text once transcribed; empty from the start of a run until then.
    var lastText = ""
    var deliveryDisposition: AutoSendDeliveryDisposition?
    var failureKind: AutoSendFailureKind?
    /// True when the run ended because the user cancelled it.
    var wasCancelled = false
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

/// What shared delivery reported, reduced to the facts ASR's disposition depends on.
struct AutoSendDeliveryReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case submitted
        case pasted
        case copied
        /// Nothing was pasted or copied; the text is still undelivered.
        case ready
    }

    var outcome: Outcome
    /// False when the app's rule turned sending off.
    var sendWasRequested: Bool
    var statusMessage: String
    var errorSummary: String?
    var accessibilityTrusted: Bool
}

extension AutoSendDeliveryDisposition {
    /// Turns shared delivery's report into ASR's disposition. `copyToClipboard` runs only when
    /// delivery left the text undelivered, and returns whether the write succeeded.
    static func resolving(
        _ report: AutoSendDeliveryReport,
        copyToClipboard: () -> Bool
    ) -> AutoSendDeliveryDisposition {
        switch report.outcome {
        case .submitted:
            return .sent
        case .pasted:
            return report.sendWasRequested
                ? .sendSuppressed(report.statusMessage)
                : .pastedWithoutSending
        case .copied:
            if let error = report.errorSummary {
                return report.accessibilityTrusted
                    ? .pasteFailed(error)
                    : .permissionRequired(report.statusMessage)
            }
            return .copied(report.statusMessage)
        case .ready:
            let clipboardWriteSucceeded = copyToClipboard()
            if let error = report.errorSummary {
                guard clipboardWriteSucceeded else {
                    return .pasteFailed("Could not paste or copy the transcript. \(error)")
                }
                return report.accessibilityTrusted
                    ? .pasteFailed("Copied to clipboard. \(error)")
                    : .permissionRequired("Copied to clipboard. \(report.statusMessage)")
            }
            return AutoSendClipboardFallback.disposition(
                accessibilityTrusted: report.accessibilityTrusted,
                clipboardWriteSucceeded: clipboardWriteSucceeded,
                statusMessage: report.statusMessage
            )
        }
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

/// The recogniser's text after replacement rules, and after rules plus spoken-number normalisation.
struct AutoSendProcessedTranscript: Equatable, Sendable {
    var afterRules: String
    var final: String
}

struct AutoSendWorkflowEnvironment: @unchecked Sendable {
    let capture: any AutoSendCaptureService
    let transcription: any AutoSendTranscriptService
    let delivery: any AutoSendDeliveryService
    /// Replacement rules and spoken-number normalisation, applied to the recogniser's output.
    let processTranscript: @Sendable (String) -> AutoSendProcessedTranscript
    let archive: @Sendable (AutoSendTranscriptEvidence) -> Void
    let runDidChange: @Sendable (AutoSendRunSnapshot) -> Void

    init(
        capture: any AutoSendCaptureService,
        transcription: any AutoSendTranscriptService,
        delivery: any AutoSendDeliveryService,
        processTranscript: @escaping @Sendable (String) -> AutoSendProcessedTranscript = {
            AutoSendProcessedTranscript(afterRules: $0, final: $0)
        },
        archive: @escaping @Sendable (AutoSendTranscriptEvidence) -> Void = { _ in },
        runDidChange: @escaping @Sendable (AutoSendRunSnapshot) -> Void = { _ in }
    ) {
        self.capture = capture
        self.transcription = transcription
        self.delivery = delivery
        self.processTranscript = processTranscript
        self.archive = archive
        self.runDidChange = runDidChange
    }
}

actor AutoSendWorkflow {
    private let environment: AutoSendWorkflowEnvironment
    /// The only copy of the run's state. Every change to it goes out through `publish`.
    private(set) var snapshot = AutoSendRunSnapshot()
    private(set) var lastAudioURL: URL?
    private var nextOperationValue: UInt64 = 0
    private var activeOperationID: AutoSendOperationID?
    private var deliveryTask: (
        operationID: AutoSendOperationID,
        task: Task<AutoSendDeliveryDisposition, Error>
    )?

    var phase: AutoSendPhase { snapshot.phase }
    var lastText: String { snapshot.lastText }
    var lastDeliveryDisposition: AutoSendDeliveryDisposition? { snapshot.deliveryDisposition }
    var lastFailureKind: AutoSendFailureKind? { snapshot.failureKind }

    init(environment: AutoSendWorkflowEnvironment) {
        self.environment = environment
    }

    func start(source: AutoSendRecordingSource = .macHotKey) async {
        guard phase.acceptsStart else { return }
        let operationID = makeOperationID()
        activeOperationID = operationID
        snapshot.lastText = ""
        snapshot.deliveryDisposition = nil
        snapshot.failureKind = nil
        snapshot.wasCancelled = false
        publish(.starting)

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
            snapshot.failureKind = error is AutoSendRecorderProductError
                ? .microphonePermission
                : .recording
            publish(.failed(error.localizedDescription))
        }
    }

    @discardableResult
    func stop() async -> Bool {
        guard phase.acceptsStop, let operationID = activeOperationID else { return false }
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

            let processed = environment.processTranscript(transcript)
            let normalized = processed.final.trimmingCharacters(in: .whitespacesAndNewlines)
            evidence = AutoSendTranscriptEvidence(
                audioURL: audioURL,
                recognizerText: transcript,
                afterRulesText: processed.afterRules,
                finalText: normalized
            )
            guard !normalized.isEmpty else {
                throw AutoSendWorkflowError.emptyTranscript
            }
            snapshot.lastText = normalized
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
            snapshot.deliveryDisposition = disposition
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
            snapshot.failureKind = failedDuringDelivery ? .delivery : .transcription
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
        snapshot.wasCancelled = true
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
        snapshot.phase = newPhase
        snapshot.sequence &+= 1
        environment.runDidChange(snapshot)
    }
}

enum AutoSendWorkflowError: LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "No speech was detected. The recording was kept."
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

// MARK: - What the user sees

enum AutoSendExperienceState: Equatable, Sendable, Identifiable {
    case idle
    case starting
    case recording
    case finalizing
    case delivering
    case sent
    case cancelled
    case pastedWithoutSend
    case suppressed
    case noTarget(String)
    case failed(String)
    case hotKeyConflict
    case permissionNeeded(String)

    var id: String {
        switch self {
        case .idle: return "idle"
        case .starting: return "starting"
        case .recording: return "recording"
        case .finalizing: return "finalizing"
        case .delivering: return "delivering"
        case .sent: return "sent"
        case .cancelled: return "cancelled"
        case .pastedWithoutSend: return "pasted-without-send"
        case .suppressed: return "suppressed"
        case .noTarget: return "no-target"
        case .failed: return "failed"
        case .hotKeyConflict: return "hotkey-conflict"
        case .permissionNeeded: return "permission-needed"
        }
    }

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .starting: return "Listening"
        case .recording: return "Recording"
        case .finalizing: return "Finishing"
        case .delivering: return "Sending"
        case .sent: return "Sent"
        case .cancelled: return "Cancelled"
        case .pastedWithoutSend: return "Pasted only"
        case .suppressed: return "Send suppressed"
        case .noTarget: return "No text field"
        case .failed: return "Failed"
        case .hotKeyConflict: return "Hotkey conflict"
        case .permissionNeeded: return "Permission needed"
        }
    }

    var detail: String? {
        switch self {
        case .idle:
            return "Use the recording shortcut"
        case .starting:
            return "Microphone is opening · use the cancel shortcut to stop"
        case .recording:
            return "Use the recording shortcut to send · use the cancel shortcut to stop"
        case .finalizing:
            return "Preparing transcript · use the cancel shortcut to stop"
        case .delivering:
            return "Pasting into the focused field · use the cancel shortcut to stop"
        case .sent:
            return "Pasted and sent"
        case .cancelled:
            return "The recording was not sent"
        case .pastedWithoutSend:
            return "Your app rule disabled sending"
        case .suppressed:
            return "The destination was not safe to send to"
        case .noTarget(let message), .failed(let message), .permissionNeeded(let message):
            return message
        case .hotKeyConflict:
            return "Another app uses the recording shortcut"
        }
    }

    var symbolName: String {
        switch self {
        case .idle: return "paperplane"
        case .starting: return "mic"
        case .recording: return "waveform"
        case .finalizing: return "paperplane"
        case .delivering: return "paperplane.fill"
        case .sent: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle.fill"
        case .pastedWithoutSend: return "doc.on.clipboard.fill"
        case .suppressed: return "hand.raised.fill"
        case .noTarget: return "text.cursor"
        case .failed: return "exclamationmark.triangle.fill"
        case .hotKeyConflict: return "keyboard"
        case .permissionNeeded: return "lock.trianglebadge.exclamationmark"
        }
    }

    var tone: AutoSendExperienceTone {
        switch self {
        case .idle, .starting, .finalizing, .delivering:
            return .neutral
        case .recording:
            return .recording
        case .sent:
            return .success
        case .cancelled, .pastedWithoutSend:
            return .informational
        case .suppressed, .noTarget, .hotKeyConflict, .permissionNeeded:
            return .warning
        case .failed:
            return .failure
        }
    }

    var shouldShowHUD: Bool {
        self != .idle
    }

    var hudLifetime: Duration? {
        switch self {
        case .sent:
            return .milliseconds(850)
        case .cancelled:
            return .milliseconds(1200)
        case .pastedWithoutSend, .suppressed, .noTarget:
            return .seconds(2)
        case .failed, .hotKeyConflict, .permissionNeeded:
            return .seconds(4)
        case .idle, .starting, .recording, .finalizing, .delivering:
            return nil
        }
    }

#if DEBUG
    static let playgroundStates: [AutoSendExperienceState] = [
        .idle,
        .starting,
        .recording,
        .finalizing,
        .delivering,
        .sent,
        .cancelled,
        .pastedWithoutSend,
        .suppressed,
        .noTarget("Focus an editable text field, then try again."),
        .failed("The transcript could not be delivered. The recording was kept."),
        .hotKeyConflict,
        .permissionNeeded("Allow microphone and Accessibility access in System Settings.")
    ]
#endif
}

enum AutoSendExperienceTone: Sendable {
    case neutral
    case recording
    case success
    case informational
    case warning
    case failure
}

/// What the HUD, the menu and the settings window show for a run.
struct AutoSendRunPresentation: Equatable, Sendable {
    var experienceState: AutoSendExperienceState
    var statusMessage: String

    static func readyMessage(triggerMode: AutoSendTriggerMode, shortcutName: String) -> String {
        switch triggerMode {
        case .walkieTalkie:
            return "Ready. Hold \(shortcutName) to record and release to send, or press Space to lock it."
        case .toggle:
            return "Ready. Press \(shortcutName) to start, then press again to send."
        }
    }

    static func recordingMessage(
        triggerMode: AutoSendTriggerMode,
        shortcutName: String,
        isLatched: Bool
    ) -> String {
        switch triggerMode {
        case .walkieTalkie:
            if isLatched {
                return "Recording locked. Press \(shortcutName) to send."
            }
            return "Recording. Release \(shortcutName) to send, or press Space to lock it."
        case .toggle:
            return "Recording. Press \(shortcutName) again to send."
        }
    }
}

extension AutoSendRunSnapshot {
    /// The one mapping from a run's state to what the user sees.
    func presentation(
        triggerMode: AutoSendTriggerMode,
        shortcutName: String,
        isLatched: Bool
    ) -> AutoSendRunPresentation {
        switch phase {
        case .idle:
            if wasCancelled {
                return AutoSendRunPresentation(
                    experienceState: .cancelled,
                    statusMessage: "Cancelled. Saved recordings were not deleted."
                )
            }
            return AutoSendRunPresentation(
                experienceState: .idle,
                statusMessage: AutoSendRunPresentation.readyMessage(
                    triggerMode: triggerMode,
                    shortcutName: shortcutName
                )
            )
        case .starting:
            return AutoSendRunPresentation(experienceState: .starting, statusMessage: "Listening...")
        case .recording:
            return AutoSendRunPresentation(
                experienceState: .recording,
                statusMessage: AutoSendRunPresentation.recordingMessage(
                    triggerMode: triggerMode,
                    shortcutName: shortcutName,
                    isLatched: isLatched
                )
            )
        case .transcribing:
            return AutoSendRunPresentation(
                experienceState: .finalizing,
                statusMessage: "Finishing and sending..."
            )
        case .delivering:
            return AutoSendRunPresentation(
                experienceState: .delivering,
                statusMessage: "Pasting transcript..."
            )
        case .ready:
            switch deliveryDisposition {
            case .sent:
                return AutoSendRunPresentation(experienceState: .sent, statusMessage: "Pasted and sent.")
            case .pastedWithoutSending:
                return AutoSendRunPresentation(
                    experienceState: .pastedWithoutSend,
                    statusMessage: "Pasted. Sending is off for this app."
                )
            case .sendSuppressed(let message):
                return AutoSendRunPresentation(experienceState: .suppressed, statusMessage: message)
            case .noPasteTarget(let message):
                return AutoSendRunPresentation(experienceState: .noTarget(message), statusMessage: message)
            case .copied(let message):
                return AutoSendRunPresentation(experienceState: .pastedWithoutSend, statusMessage: message)
            case .permissionRequired(let message):
                return AutoSendRunPresentation(
                    experienceState: .permissionNeeded(message),
                    statusMessage: message
                )
            case .pasteFailed(let message):
                return AutoSendRunPresentation(experienceState: .failed(message), statusMessage: message)
            case .none:
                return AutoSendRunPresentation(
                    experienceState: .pastedWithoutSend,
                    statusMessage: "Transcript ready."
                )
            }
        case .failed(let message):
            return AutoSendRunPresentation(
                experienceState: failureKind == .microphonePermission
                    ? .permissionNeeded(message)
                    : .failed(message),
                statusMessage: message
            )
        }
    }
}
