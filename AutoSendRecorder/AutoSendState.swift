import AppKit
import Combine
import Foundation

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

@MainActor
private final class AutoSendPhaseRelay {
    weak var state: AutoSendState?
    private var lastSequence: UInt64 = 0

    func publish(_ update: AutoSendPhaseUpdate) {
        guard update.sequence > lastSequence else { return }
        lastSequence = update.sequence
        state?.receivePublishedPhase(update.phase)
    }
}

@MainActor
final class AutoSendState: ObservableObject {
    static let shared = AutoSendState()

    @Published private(set) var phase: AutoSendPhase = .idle
    @Published private(set) var experienceState: AutoSendExperienceState = .idle
    @Published private(set) var statusMessage = "Ready. Press Control-Option-Shift-Command-R to record."
    @Published private(set) var lastText = ""
    @Published private(set) var availableMicrophones: [MicrophoneDevice] = [.systemDefault]

    let settings: AutoSendSettingsStore
    var didChange: (() -> Void)?
    var registerSpaceLatch: (() -> Bool)?
    var unregisterSpaceLatch: (() -> Void)?

    private let transcription: AutoSendParakeetService
    private let workflow: AutoSendWorkflow
    private let phaseRelay: AutoSendPhaseRelay
    private var appRememberedForSettings: FocusedApp?
    private var stopTask: Task<Void, Never>?
    private var stopTaskGeneration: UInt64 = 0
    private var recordingTriggerController = AutoSendRecordingTriggerController()
    private var esp32TriggerController = AutoSendRecordingTriggerController()
    private var activeRecordingSource: AutoSendRecordingSource?

    private init() {
        let settings = AutoSendSettingsStore()
        let microphones = AudioInputDeviceDiscovery.inputDevices()
        if !settings.hasSavedMicrophonePreference {
            let boyaDevices = microphones.filter {
                !$0.isSystemDefaultPlaceholder &&
                    $0.name.compare(
                        AutoSendMicrophoneSelection.boyaMicrophoneName,
                        options: .caseInsensitive
                    ) == .orderedSame
            }
            if boyaDevices.count == 1 {
                settings.preferredMicrophoneID = boyaDevices[0].id
            }
        }
        let transcription = AutoSendParakeetService()
        let phaseRelay = AutoSendPhaseRelay()
        self.settings = settings
        availableMicrophones = microphones
        self.transcription = transcription
        self.phaseRelay = phaseRelay
        let recording = AutoSendRecordingService(
            transcription: transcription,
            preferredMicrophoneID: settings.preferredMicrophoneID
        )
        settings.microphoneDidChange = { [weak recording] id in
            recording?.updatePreferredMicrophoneID(id)
        }
        let delivery = AutoSendDeliveryAdapter(settings: settings)
        workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: recording,
            transcription: transcription,
            delivery: delivery,
            normalize: { TranscriptTextNormalizer.normalizeSpokenNumbers(in: $0) },
            phaseDidChange: { [weak phaseRelay] update in
                Task { @MainActor in
                    phaseRelay?.publish(update)
                }
            }
        ))
        phaseRelay.state = self
    }

    func refreshMicrophones() {
        availableMicrophones = AudioInputDeviceDiscovery.inputDevices()
    }

    func toggleRecording() {
        switch phase {
        case .recording:
            stopRecording()
        case .idle, .ready, .failed:
            startRecording(source: .macHotKey)
        case .starting, .transcribing, .delivering:
            break
        }
    }

    func recordingHotKeyPressed() {
        guard canProcessTrigger(from: .macHotKey) else { return }
        processRecordingTrigger(
            recordingTriggerController.handle(
                .pressed,
                mode: settings.triggerMode,
                phase: phase
            ),
            source: .macHotKey
        )
    }

    func recordingHotKeyReleased() {
        guard canProcessTrigger(from: .macHotKey) else { return }
        processRecordingTrigger(
            recordingTriggerController.handle(
                .released,
                mode: settings.triggerMode,
                phase: phase
            ),
            source: .macHotKey
        )
    }

    func recordingSpaceLatchPressed() {
        guard settings.triggerMode == .walkieTalkie,
              activeRecordingSource == .macHotKey else { return }
        processRecordingTrigger(
            recordingTriggerController.handle(
                .latchPressed,
                mode: .walkieTalkie,
                phase: phase
            ),
            source: .macHotKey
        )
        if phase == .recording {
            statusMessage = "Recording locked. Press the shortcut again to send."
            notifyChange()
        }
    }

    func esp32RecordingButtonPressed() {
        guard canProcessTrigger(from: .esp32Button) else { return }
        processRecordingTrigger(
            esp32TriggerController.handle(
                .pressed,
                mode: .walkieTalkie,
                phase: phase
            ),
            source: .esp32Button
        )
    }

    func esp32RecordingButtonReleased() {
        guard canProcessTrigger(from: .esp32Button) else { return }
        processRecordingTrigger(
            esp32TriggerController.handle(
                .released,
                mode: .walkieTalkie,
                phase: phase
            ),
            source: .esp32Button
        )
    }

    func startRecording(source: AutoSendRecordingSource = .macHotKey) {
        guard !phase.isBusy else { return }
        activeRecordingSource = source
        if source == .macHotKey && settings.triggerMode == .walkieTalkie {
            _ = registerSpaceLatch?()
        }
        phase = .starting
        experienceState = .starting
        statusMessage = "Listening..."
        notifyChange()
        Task {
            await workflow.start(source: source)
            await refreshFromWorkflow()
        }
    }

    func stopRecording() {
        guard phase == .recording else { return }
        unregisterSpaceLatch?()
        phase = .transcribing
        experienceState = .finalizing
        statusMessage = "Finishing and sending..."
        notifyChange()
        stopTaskGeneration &+= 1
        let generation = stopTaskGeneration
        stopTask?.cancel()
        stopTask = Task { [weak self] in
            guard let self else { return }
            let completed = await workflow.stop()
            guard completed,
                  !Task.isCancelled,
                  stopTaskGeneration == generation else {
                return
            }
            await refreshFromWorkflow()
            if stopTaskGeneration == generation {
                stopTask = nil
            }
        }
    }

    func cancel() {
        guard phase.isBusy else { return }
        unregisterSpaceLatch?()
        stopTaskGeneration &+= 1
        stopTask?.cancel()
        stopTask = nil
        Task {
            await workflow.cancel()
            await refreshFromWorkflow()
            experienceState = .cancelled
            statusMessage = "Cancelled. Saved recordings were not deleted."
            notifyChange()
        }
    }

    func prewarm() {
        Task.detached(priority: .utility) { [transcription] in
            await transcription.warmUp()
        }
    }

    func reportHotKeyRegistration(_ result: AutoSendHotKeyRegistration) {
        switch result {
        case .registered:
            experienceState = .idle
            statusMessage = readyStatusMessage
        case .deviceConflict:
            experienceState = .hotKeyConflict
            statusMessage = "The Mac shortcut is ready. Another app uses the ESP32 touch shortcut."
        case .deviceFailed(let code):
            let message = "The Mac shortcut is ready, but the ESP32 touch shortcut failed (error \(code))."
            experienceState = .failed(message)
            statusMessage = message
        case .conflict:
            experienceState = .hotKeyConflict
            statusMessage = "Shortcut unavailable. Choose another in Settings or quit the app using \(settings.recordingShortcut.displayName)."
        case .failed(let code):
            experienceState = .failed("The recording shortcut could not be registered (error \(code)).")
            statusMessage = "Could not register the recording shortcut (error \(code))."
        }
        notifyChange()
    }

    func addFrontmostAppRule() {
        let currentApp = AccessibilityPasteController.currentFocusedApp()
        let app = currentApp?.bundleIdentifier == AutoSendSettingsStore.defaultsSuiteName
            ? appRememberedForSettings
            : currentApp
        guard let app else {
            statusMessage = "Could not identify the current app."
            notifyChange()
            return
        }
        settings.upsert(
            appName: app.displayName,
            bundleIdentifier: app.bundleIdentifier,
            action: settings.action(for: app.bundleIdentifier)
        )
        statusMessage = "Added \(app.displayName) to send settings."
        notifyChange()
    }

    func rememberCurrentAppForSettings() {
        guard let app = AccessibilityPasteController.currentFocusedApp(),
              app.bundleIdentifier != AutoSendSettingsStore.defaultsSuiteName else {
            return
        }
        appRememberedForSettings = app
    }

    private func refreshFromWorkflow() async {
        phase = await workflow.phase
        lastText = await workflow.lastText
        switch phase {
        case .recording:
            experienceState = .recording
            statusMessage = recordingStatusMessage
        case .ready:
            switch await workflow.lastDeliveryDisposition {
            case .sent:
                experienceState = .sent
                statusMessage = "Pasted and sent."
            case .pastedWithoutSending:
                experienceState = .pastedWithoutSend
                statusMessage = "Pasted. Sending is off for this app."
            case .sendSuppressed(let message):
                experienceState = .suppressed
                statusMessage = message
            case .noPasteTarget(let message):
                experienceState = .noTarget(message)
                statusMessage = message
            case .copied(let message):
                experienceState = .pastedWithoutSend
                statusMessage = message
            case .permissionRequired(let message):
                experienceState = .permissionNeeded(message)
                statusMessage = message
            case .pasteFailed(let message):
                experienceState = .failed(message)
                statusMessage = message
            case .none:
                experienceState = .pastedWithoutSend
                statusMessage = "Transcript ready."
            }
        case .failed(let message):
            let failureKind = await workflow.lastFailureKind
            experienceState = Self.experienceState(forFailure: message, kind: failureKind)
            statusMessage = message
        case .idle:
            experienceState = .idle
            statusMessage = readyStatusMessage
        case .starting:
            experienceState = .starting
            statusMessage = "Listening..."
        case .transcribing:
            experienceState = .finalizing
            statusMessage = "Finishing and sending..."
        case .delivering:
            experienceState = .delivering
            statusMessage = "Pasting transcript..."
        }
        processRecordingPhaseChange()
        if phase == .recording {
            statusMessage = recordingStatusMessage
        }
        notifyChange()
    }

    fileprivate func receivePublishedPhase(_ newPhase: AutoSendPhase) {
        phase = newPhase
        switch newPhase {
        case .starting:
            experienceState = .starting
            statusMessage = "Listening..."
        case .recording:
            experienceState = .recording
            statusMessage = recordingStatusMessage
        case .transcribing:
            experienceState = .finalizing
            statusMessage = "Finishing and sending..."
        case .delivering:
            experienceState = .delivering
            statusMessage = "Pasting transcript..."
        case .idle, .ready, .failed:
            break
        }
        processRecordingPhaseChange()
        if phase == .recording {
            statusMessage = recordingStatusMessage
        }
        notifyChange()
    }

    private func processRecordingPhaseChange() {
        guard let activeRecordingSource else { return }
        switch activeRecordingSource {
        case .macHotKey:
            processRecordingTrigger(
                recordingTriggerController.handle(
                    .phaseChanged(phase),
                    mode: settings.triggerMode,
                    phase: phase
                ),
                source: .macHotKey
            )
        case .esp32Button:
            processRecordingTrigger(
                esp32TriggerController.handle(
                    .phaseChanged(phase),
                    mode: .walkieTalkie,
                    phase: phase
                ),
                source: .esp32Button
            )
        }
        if !phase.isBusy {
            unregisterSpaceLatch?()
            self.activeRecordingSource = nil
        }
    }

    private func processRecordingTrigger(
        _ command: AutoSendRecordingTriggerCommand,
        source: AutoSendRecordingSource
    ) {
        switch command {
        case .none:
            break
        case .start:
            startRecording(source: source)
        case .stop:
            if activeRecordingSource == source {
                stopRecording()
            }
        }
    }

    private func canProcessTrigger(from source: AutoSendRecordingSource) -> Bool {
        AutoSendRecordingSourceGate.canProcess(
            source: source,
            activeSource: activeRecordingSource
        )
    }

    private static func experienceState(
        forFailure message: String,
        kind: AutoSendFailureKind?
    ) -> AutoSendExperienceState {
        if kind == .microphonePermission {
            return .permissionNeeded(message)
        }
        return .failed(message)
    }

    private func notifyChange() {
        didChange?()
    }

    private var readyStatusMessage: String {
        switch settings.triggerMode {
        case .walkieTalkie:
            return "Ready. Hold \(settings.recordingShortcut.displayName) to record and release to send, or press Space to lock it."
        case .toggle:
            return "Ready. Press \(settings.recordingShortcut.displayName) to start, then press again to send."
        }
    }

    private var recordingStatusMessage: String {
        switch settings.triggerMode {
        case .walkieTalkie:
            if recordingTriggerController.isLatched {
                return "Recording locked. Press \(settings.recordingShortcut.displayName) to send."
            }
            return "Recording. Release \(settings.recordingShortcut.displayName) to send, or press Space to lock it."
        case .toggle:
            return "Recording. Press \(settings.recordingShortcut.displayName) again to send."
        }
    }
}
