import AppKit
import Combine
import Foundation

/// Carries the workflow's snapshots to the state object, which does not exist yet when the
/// workflow's environment is built.
@MainActor
private final class AutoSendRunRelay {
    weak var state: AutoSendState?

    func publish(_ snapshot: AutoSendRunSnapshot) {
        state?.receive(snapshot)
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

    let replacementRules: SharedReplacementRules
    private let transcription: AutoSendParakeetService
    private let workflow: AutoSendWorkflow
    private let runRelay: AutoSendRunRelay
    /// The newest snapshot received from the workflow, which owns the run's state.
    private var snapshot = AutoSendRunSnapshot()
    private var appRememberedForSettings: FocusedApp?
    private var stopTask: Task<Void, Never>?
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
        let transcription = AutoSendParakeetService(model: settings.transcriptionModel)
        settings.transcriptionModelDidChange = { [weak transcription] model in
            transcription?.selectModel(model)
            Task { await transcription?.warmUp() }
        }
        let runRelay = AutoSendRunRelay()
        self.settings = settings
        availableMicrophones = microphones
        self.transcription = transcription
        self.runRelay = runRelay
        let recording = AutoSendRecordingService(
            transcription: transcription,
            preferredMicrophoneID: settings.preferredMicrophoneID
        )
        settings.microphoneDidChange = { [weak recording] id in
            recording?.updatePreferredMicrophoneID(id)
        }
        let delivery = AutoSendDeliveryAdapter(settings: settings)
        // AIR's manual rules (read only) and the lexicon's rules, re-read for every recording.
        let replacementRules = SharedReplacementRules()
        self.replacementRules = replacementRules
        workflow = AutoSendWorkflow(environment: AutoSendWorkflowEnvironment(
            capture: recording,
            transcription: transcription,
            delivery: delivery,
            processTranscript: { [replacementRules] in
                let outcome = replacementRules.process($0)
                return AutoSendProcessedTranscript(afterRules: outcome.afterRules, final: outcome.final)
            },
            archive: { AutoSendTranscriptArchive.save($0) },
            discardRecording: { try? FileManager.default.removeItem(at: $0) },
            runDidChange: { [weak runRelay] snapshot in
                Task { @MainActor in
                    runRelay?.publish(snapshot)
                }
            }
        ))
        runRelay.state = self
        recording.setMicrophoneWarningHandler { [weak workflow] operationID, warning in
            Task { await workflow?.reportMicrophoneWarning(warning, operationID: operationID) }
        }
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
        guard phase.acceptsStart else { return }
        activeRecordingSource = source
        if source == .macHotKey && settings.triggerMode == .walkieTalkie {
            _ = registerSpaceLatch?()
        }
        anticipate(.starting)
        Task { [workflow] in
            await workflow.start(source: source)
        }
    }

    func stopRecording() {
        guard phase.acceptsStop else { return }
        unregisterSpaceLatch?()
        anticipate(.transcribing)
        stopTask?.cancel()
        // Kept so that `cancel` can interrupt a stop that is still transcribing.
        stopTask = Task { [workflow] in
            await workflow.stop()
        }
    }

    func cancel() {
        guard phase.isBusy else { return }
        unregisterSpaceLatch?()
        stopTask?.cancel()
        stopTask = nil
        Task { [workflow] in
            await workflow.cancel()
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

    static let microphoneWarningSoundName = NSSound.Name("Funk")

    /// Shows a snapshot from the workflow. Snapshots can arrive out of order, so only one newer
    /// than the last counts.
    fileprivate func receive(_ newSnapshot: AutoSendRunSnapshot) {
        guard newSnapshot.sequence > snapshot.sequence else { return }
        // One sound when a run's microphone warning first appears, for when the HUD is not in view.
        if newSnapshot.microphoneWarning != nil, snapshot.microphoneWarning == nil {
            NSSound(named: AutoSendState.microphoneWarningSoundName)?.play()
        }
        snapshot = newSnapshot
        phase = newSnapshot.phase
        lastText = newSnapshot.lastText
        present(newSnapshot)
        processRecordingPhaseChange()
        // The trigger controller may have latched, which changes the recording message. If it
        // issued a stop instead, the next phase is already showing.
        if phase == .recording {
            present(newSnapshot)
        }
        notifyChange()
    }

    /// Shows a phase before the workflow publishes it, so the HUD responds at once and a second
    /// trigger sees the run as busy. The workflow's next snapshot replaces it.
    private func anticipate(_ anticipated: AutoSendPhase) {
        var shown = snapshot
        shown.phase = anticipated
        phase = anticipated
        present(shown)
        notifyChange()
    }

    private func present(_ shown: AutoSendRunSnapshot) {
        let presentation = shown.presentation(
            triggerMode: settings.triggerMode,
            shortcutName: settings.recordingShortcut.displayName,
            isLatched: recordingTriggerController.isLatched
        )
        experienceState = presentation.experienceState
        statusMessage = presentation.statusMessage
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

    private func notifyChange() {
        didChange?()
    }

    private var readyStatusMessage: String {
        AutoSendRunPresentation.readyMessage(
            triggerMode: settings.triggerMode,
            shortcutName: settings.recordingShortcut.displayName
        )
    }
}

/// Writes one archive record per ASR recording under Auto Send Recorder/TranscriptTruth.
enum AutoSendTranscriptArchive {
    static func save(_ evidence: AutoSendTranscriptEvidence) {
        TranscriptArchiveStore.saveAutoSend(
            audioURL: evidence.audioURL,
            outcome: TranscriptRuleOutcome(
                recognizer: evidence.recognizerText,
                afterRules: evidence.afterRulesText,
                final: evidence.finalText
            ),
            deliveredText: evidence.deliveredText,
            deliveredVia: evidence.disposition?.archiveLabel,
            message: evidence.failure,
            transcriptionEngine: evidence.transcriptionEngine
        )
    }
}
