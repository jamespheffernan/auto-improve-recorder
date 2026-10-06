import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog

private let recordingStartupLogger = Logger(
    subsystem: "com.fieldtheory.autoimproverecorder",
    category: "RecordingStartup"
)

private let microphoneDeviceLogger = Logger(
    subsystem: "com.fieldtheory.autoimproverecorder",
    category: "MicrophoneDevice"
)

private let recordingTriggerLogger = Logger(
    subsystem: "com.fieldtheory.autoimproverecorder",
    category: "RecordingTrigger"
)

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState(environment: .live)

    @Published var phase: RecorderPhase = .idle {
        didSet { menuNeedsUpdate?() }
    }
    @Published var session: TranscriptSession = .empty
    @Published var showRawTranscript = false
    @Published var statusMessage: String?
    @Published var processingVisualState: ProcessingVisualState = .idle
    @Published var recordingStartedAt: Date?
    @Published private(set) var walkieTalkieIsLatchedForDisplay = false
    @Published var lastOpenAIRealtimeDiagnostics: OpenAIRealtimeDiagnostics?
    @Published private(set) var permissionStatus = PermissionStatus(
        microphone: .notDetermined,
        accessibility: .denied
    )
    @Published private(set) var diagnosticEvents: [DiagnosticEvent] = []
    @Published private(set) var localModelStatuses: [LocalModelID: LocalModelStatus] = [:]

    @Published var apiKey: String = "" {
        didSet { saveCredentials(debounced: true) }
    }
    @Published var geminiAPIKey: String = "" {
        didSet { saveCredentials(debounced: true) }
    }
    @Published var anthropicAPIKey: String = "" {
        didSet { saveCredentials(debounced: true) }
    }
    @Published var autoImproveMode: AutoImproveMode = .automatic {
        didSet { saveSettings(reason: .general) }
    }
    @Published var recordingTriggerMode: RecordingTriggerMode = .walkieTalkie {
        didSet {
            saveSettings(reason: .recordingTrigger)
            if recordingTriggerMode != .walkieTalkie {
                unregisterWalkieTalkieLatchHotKey?()
            }
        }
    }
    @Published var recordingHotKey: RecordingHotKey = .defaultValue {
        didSet {
            saveSettings(reason: .recordingHotKey)
            applyRecordingHotKey(previous: oldValue)
        }
    }
    @Published var transcriptionMode: TranscriptionMode = .localPhonon2 {
        didSet { saveSettings(reason: .general) }
    }
    @Published var improvementMode: ImprovementMode = .ollamaLocal {
        didSet { saveSettings(reason: .general) }
    }
    @Published var thresholdWords: Int = 35 {
        didSet { saveSettings(reason: .general) }
    }
    @Published var modificationStrength: Int = 2 {
        didSet { saveSettings(reason: .general) }
    }
    @Published var outputMode: OutputMode = .lightCleanup {
        didSet { saveSettings(reason: .general) }
    }
    @Published var ollamaBaseURL: String = "http://127.0.0.1:11434" {
        didSet { saveSettings(reason: .textField, debounced: true) }
    }
    @Published var ollamaModel: String = "qwen3.5:0.8b-mlx" {
        didSet { saveSettings(reason: .textField, debounced: true) }
    }
    @Published var preferredMicrophoneID: String = "" {
        didSet {
            saveSettings(reason: .general)
            availableMicrophones = microphonesIncludingSavedPreference(availableMicrophones)
            updateResolvedMicrophoneSummary()
            enforcePreferredMicrophoneDefaultInput(reason: "preference changed")
        }
    }
    @Published var copyFinishedTextToClipboard: Bool = true {
        didSet { saveSettings(reason: .general) }
    }
    @Published var autoSubmitDetectedTextFields: Bool = false {
        didSet { saveSettings(reason: .general) }
    }
    @Published var appDeliveryRules: [AppDeliveryRule] = [] {
        didSet { saveSettings(reason: .appDeliveryRules) }
    }
    @Published private(set) var deliveryRuleCandidateApps: [FocusedApp] = []
    @Published var availableMicrophones: [AudioInputDevice] = [.systemDefault]
    @Published private(set) var resolvedMicrophoneSummary = "Using system default."
    let dictionaryStore: UserDictionaryStore

    var showPreview: (() -> Void)?
    var showSettings: (() -> Void)?
    var menuNeedsUpdate: (() -> Void)?
    var registerRecordingHotKey: ((RecordingHotKey) -> Bool)?
    var unregisterRecordingHotKey: (() -> Void)?
    var registerCancelHotKey: (() -> Void)?
    var unregisterCancelHotKey: (() -> Void)?
    var registerWalkieTalkieLatchHotKey: ((RecordingHotKey) -> WalkieTalkieLatchHotKeyRegistration)?
    var unregisterWalkieTalkieLatchHotKey: (() -> Void)?
    var showProcessingSignal: ((ProcessingVisualState) -> Void)?
    var flashReadySignal: ((ProcessingVisualState) -> Void)?
    var hideProcessingSignal: (() -> Void)?

    private let environment: AppEnvironment
    private let defaults: UserDefaults
    private lazy var recordingTriggerController = RecordingTriggerController { [weak self] in
        self?.recordingTriggerBehavior ?? .holdToTalk
    }
    private var activeSpaceLatchRegistrationFailed = false
    private let realtimeAudioSink = OpenAIRealtimeAudioSink()
    private var activeStreamingTranscriber: OpenAIRealtimeTranscriber?
    private var activeRecordingHandle: (any RecordingSessionHandle)?
    /// The transcription mode read when the session's recording started. Stop, transcription,
    /// the archive record and a microphone restart use it; the setting is not read again.
    private var sessionTranscriptionMode: TranscriptionMode?
    private var activeRealtimeStartupTask: Task<Void, Never>?
    private var activeRecordingID: UUID?
    private var activeProcessingRecordingID: UUID?
    private var activeArchiveDraftState = ActiveTranscriptArchiveDraftState()
    private var activeArchiveDraft: TranscriptArchiveDraft? {
        get { activeArchiveDraftState.draft }
        set { activeArchiveDraftState.replace(with: newValue) }
    }
    private var preparedArchiveDraft: TranscriptArchiveDraft?
    private var microphonePermissionKnownAuthorized = false
    private var isStartingRecording = false
    private var activeStartID: UUID?
    private var activeStartIsTriggerManaged = false
    private var isRevertingRecordingHotKey = false
    private var visualResetToken = UUID()
    private var microphoneUseLockHeartbeatTask: Task<Void, Never>?
    private var microphoneDeviceObservation: AnyObject?
    private var microphoneRecovery = MicrophoneRecovery(retryCooldown: 10)
    /// The silence watch of the recording in flight, or nil when the backup microphone switch is off.
    private var activeSilenceWatch: MicrophoneSilenceWatch?
    /// True once the silence watch has reported for the recording in flight.
    private var silentMicrophoneWarningShown = false
    private var activeBackupMicrophone: ActiveBackupMicrophone?
    /// The backup recording whose text the current session uses, or nil when it uses the main recording.
    private var usedBackupRecording: (microphone: AudioInputDevice, audioURL: URL)?
    private var triggerTimerTasks: [RecordingTriggerTimerKind: Task<Void, Never>] = [:]
    private var localModelStatusTask: Task<Void, Never>?
    private var recordingHotKeyCaptureIsActive = false

    /// The backup microphone of the recording in flight. It stays here from the request to open
    /// it until the recording ends or the open fails.
    private struct ActiveBackupMicrophone {
        let id: UUID
        let microphone: AudioInputDevice
        /// True once the backup has opened.
        var isRunning = false
    }

    /// The backup of a recording that has stopped.
    private struct StoppedBackupMicrophone {
        let microphone: AudioInputDevice
        let stop: any BackupRecordingStop
        /// True when the silence watch reported for the recording.
        let primaryWasSilent: Bool
    }

    private enum Keys {
        static let autoImproveMode = "autoImproveMode"
        static let recordingTriggerMode = "recordingTriggerMode"
        static let recordingHotKey = "recordingHotKey"
        static let transcriptionMode = "transcriptionMode"
        static let improvementMode = "improvementMode"
        static let thresholdWords = "thresholdWords"
        static let modificationStrength = "modificationStrength"
        static let outputMode = "outputMode"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let ollamaModel = "ollamaModel"
        static let preferredMicrophoneID = "preferredMicrophoneID"
        static let copyFinishedTextToClipboard = "copyFinishedTextToClipboard"
        static let autoSubmitDetectedTextFields = "autoSubmitDetectedTextFields"
        static let appDeliveryRules = "appDeliveryRules.v1"
        static let lastOpenAIRealtimeErrorSummary = "lastOpenAIRealtimeErrorSummary"
        static let lastOpenAIRealtimeErrorDetails = "lastOpenAIRealtimeErrorDetails"
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        dictionaryStore = environment.dictionaryStore
        defaults = environment.legacyDefaults
        let credentials = environment.secrets.loadCredentials()
        apiKey = credentials.openAIAPIKey
        geminiAPIKey = credentials.geminiAPIKey
        anthropicAPIKey = credentials.anthropicAPIKey
        let settings = environment.settings.load()
        autoImproveMode = settings.autoImproveMode
        recordingTriggerMode = settings.recordingTriggerMode
        recordingHotKey = settings.recordingHotKey
        transcriptionMode = settings.transcriptionMode
        improvementMode = settings.improvementMode
        thresholdWords = settings.thresholdWords
        modificationStrength = settings.modificationStrength
        outputMode = settings.outputMode
        preferredMicrophoneID = settings.preferredMicrophoneID
        copyFinishedTextToClipboard = settings.completion.copyFinishedTextToClipboard
        autoSubmitDetectedTextFields = settings.completion.autoSubmitDetectedTextFields
        appDeliveryRules = settings.appDeliveryRules
        microphonePermissionKnownAuthorized = environment.permissions.cachedMicrophonePermissionWasGranted
        diagnosticEvents = environment.diagnostics.latestEvents(limit: 5)
        lastOpenAIRealtimeDiagnostics = latestOpenAIRealtimeDiagnostics() ?? legacyOpenAIRealtimeDiagnostics()

        ollamaBaseURL = settings.ollama.baseURL
        ollamaModel = settings.ollama.model
        refreshMicrophones()
        enforcePreferredMicrophoneDefaultInput(reason: "app launch")
        microphoneDeviceObservation = environment.microphoneDevices.observeDeviceChanges { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleMicrophoneDevicesChanged()
            }
        }
        refreshDeliveryRuleCandidateApps()
    }

    var isRecording: Bool {
        if case .recording = phase {
            return true
        }
        return false
    }

    private var recordingTriggerBehavior: RecordingTriggerBehavior {
        switch recordingTriggerMode {
        case .walkieTalkie:
            return .holdToTalk
        case .toggle:
            return .toggle
        }
    }

    var displayText: String {
        showRawTranscript ? session.rawTranscript : session.preferredText
    }

    var canRerunImprove: Bool {
        !session.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !phase.isBusy
    }

    var canCopyOrPaste: Bool {
        !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var accessibilityPasteAvailable: Bool {
        environment.permissions.accessibilityState(prompt: false) == .authorized
    }

    func refreshMicrophones() {
        availableMicrophones = microphonesIncludingSavedPreference(
            environment.microphoneDevices.inputDevices()
        )
        updateResolvedMicrophoneSummary()
    }

    private func handleMicrophoneDevicesChanged() {
        refreshMicrophones()
        enforcePreferredMicrophoneDefaultInput(reason: "device route changed")
    }

    private func microphonesIncludingSavedPreference(_ discovered: [AudioInputDevice]) -> [AudioInputDevice] {
        let preferredID = preferredMicrophoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferredID.isEmpty,
              !discovered.contains(where: { $0.id == preferredID }) else {
            return discovered
        }

        var devices = discovered
        devices.append(
            AudioInputDevice(
                id: preferredID,
                name: "Previously selected microphone (unavailable)",
                coreAudioDeviceID: nil,
                transportType: nil,
                isConnected: false,
                isInputCapable: false,
                isSystemDefault: false
            )
        )
        return devices
    }

    private func updateResolvedMicrophoneSummary() {
        do {
            let resolution = try microphoneRecovery.resolve(
                preferences: .fromPreferredMicrophoneID(preferredMicrophoneID),
                devices: availableMicrophones,
                now: Date()
            )
            resolvedMicrophoneSummary = microphoneSummary(for: resolution)
        } catch {
            resolvedMicrophoneSummary = error.localizedDescription
        }
    }

    private func microphoneSummary(for resolution: MicrophoneResolution) -> String {
        if preferredMicrophoneID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Using system default: \(resolution.device.name)."
        }

        if resolution.usedFallback {
            return "Preferred microphone unavailable; using \(resolution.device.name)."
        }

        return "Using \(resolution.device.name)."
    }

    private func enforcePreferredMicrophoneDefaultInput(reason: String) {
        #if os(macOS)
        let preferences = MicrophonePreferences.fromPreferredMicrophoneID(preferredMicrophoneID)
        guard let target = MicrophoneDefaultInputPinningPolicy.targetDeviceToPin(
            preferences: preferences,
            devices: availableMicrophones,
            quarantinedUntil: microphoneRecovery.quarantinedUntil,
            now: Date()
        ),
              let coreAudioDeviceID = target.coreAudioDeviceID else {
            return
        }

        do {
            try environment.microphoneDevices.setDefaultInputDeviceID(coreAudioDeviceID)
            microphoneDeviceLogger.info(
                "Pinned macOS default input to preferred microphone id=\(target.id, privacy: .public) name=\(target.name, privacy: .public) coreAudioDeviceID=\(coreAudioDeviceID, privacy: .public) reason=\(reason, privacy: .public)"
            )
            availableMicrophones = availableMicrophones.map { device in
                var updated = device
                updated.isSystemDefault = device.isSystemDefaultPlaceholder || device.id == target.id
                return updated
            }
            updateResolvedMicrophoneSummary()
        } catch {
            microphoneDeviceLogger.error(
                "Failed to pin macOS default input to preferred microphone id=\(target.id, privacy: .public) name=\(target.name, privacy: .public) coreAudioDeviceID=\(coreAudioDeviceID, privacy: .public) reason=\(reason, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
    }

    func refreshDeliveryRuleCandidateApps() {
        let existingBundleIdentifiers = Set(appDeliveryRules.map(\.bundleIdentifier))
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        var seenBundleIdentifiers = Set<String>()

        deliveryRuleCandidateApps = environment.runningApps().filter { app in
            app.bundleIdentifier != ownBundleIdentifier &&
                !existingBundleIdentifiers.contains(app.bundleIdentifier) &&
                seenBundleIdentifiers.insert(app.bundleIdentifier).inserted
        }
        .sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func localModelStatus(for id: LocalModelID) -> LocalModelStatus? {
        localModelStatuses[id]
    }

    func refreshLocalModelStatuses() {
        let input = localModelInventoryInput()
        localModelStatusTask?.cancel()
        localModelStatusTask = Task { [weak self] in
            let inventory = LocalModelInventory()
            let statuses = await inventory.statuses(input: input)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.localModelStatuses = Dictionary(uniqueKeysWithValues: statuses.map { ($0.id, $0) })
            }
        }
    }

    func refreshReadiness(promptForAccessibility: Bool = false) async {
        permissionStatus = await environment.permissions.snapshot(promptForAccessibility: promptForAccessibility)
        refreshDiagnostics()
    }

    func promptForAccessibilityPermission() {
        Task { await refreshReadiness(promptForAccessibility: true) }
    }

    func refreshDiagnostics() {
        diagnosticEvents = environment.diagnostics.latestEvents(limit: 5)
    }

    func useRecommendedLocalTranscription() {
        applyLocalModelPreset(.recommended)
    }

    func useResidentLocalTranscription() {
        applyLocalModelPreset(.resident)
    }

    func useFastLocalTranscription() {
        applyLocalModelPreset(.fast)
    }

    func useAllLocalPreset() {
        applyLocalModelPreset(.allLocal)
    }

    func useAppleSpeechPreset() {
        applyLocalModelPreset(.appleSpeech)
    }

    func useCloudRealtimePreset() {
        applyLocalModelPreset(.cloudRealtime)
    }

    private func applyLocalModelPreset(_ preset: LocalModelPreset) {
        if let requestedMode = TranscriptionMode(rawValue: preset.transcriptionModeRawValue) {
            let wantsLiveRecommendation = preset == .recommended || preset == .allLocal
            let canUseLiveRecommendation = ParakeetLiveSafetyPolicy.shouldSelectByDefault(
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                liveRuntimeInstalled: RecommendedLiveTranscription.isAvailable,
                offlineFallbackInstalled: ParakeetCppTranscriber.isInstalled(variant: .recommended06B)
            )
            self.transcriptionMode = wantsLiveRecommendation && !canUseLiveRecommendation
                ? .localParakeetCppRecommended
                : requestedMode
        }

        if let improvementModeRawValue = preset.improvementModeRawValue,
           let improvementMode = ImprovementMode(rawValue: improvementModeRawValue) {
            self.improvementMode = improvementMode
        }

        if let ollamaModel = preset.ollamaModel {
            self.ollamaModel = ollamaModel
        }

        switch preset {
        case .recommended:
            statusMessage = transcriptionMode == .localParakeetStreaming
                ? "Using recommended live Parakeet transcription."
                : "Live Parakeet does not meet this Mac's runtime gates; using one-shot Parakeet.cpp Recommended."
        case .resident:
            statusMessage = "Using resident Parakeet.cpp for local transcription."
        case .fast:
            statusMessage = "Using Parakeet.cpp Fast for local transcription."
        case .allLocal:
            statusMessage = transcriptionMode == .localParakeetStreaming
                ? "Using recommended live Parakeet with Ollama qwen3.5 local cleanup."
                : "Using one-shot Parakeet.cpp Recommended with Ollama qwen3.5 local cleanup."
        case .appleSpeech:
            statusMessage = "Using Apple Speech for local transcription when available."
        case .cloudRealtime:
            statusMessage = "Using Cloud Realtime transcription."
        }

        refreshLocalModelStatuses()
    }

    private func localModelInventoryInput() -> LocalModelInventoryInput {
        LocalModelInventoryInput(
            parakeetCppBasePath: LocalModelInventory.defaultParakeetCppBasePath,
            ollamaBaseURL: ollamaBaseURL,
            ollamaModel: ollamaModel,
            hasOpenAIAPIKey: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    func addAppDeliveryRule(for app: FocusedApp) {
        if let index = appDeliveryRules.firstIndex(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
            appDeliveryRules[index].appName = app.displayName
            appDeliveryRules[index].isEnabled = true
            statusMessage = "Enabled app rule for \(app.displayName)."
        } else {
            appDeliveryRules.append(.defaultRule(for: app))
            statusMessage = "Added app rule for \(app.displayName)."
        }
        refreshDeliveryRuleCandidateApps()
    }

    func removeAppDeliveryRule(id: AppDeliveryRule.ID) {
        guard let rule = appDeliveryRules.first(where: { $0.id == id }) else { return }
        appDeliveryRules.removeAll { $0.id == id }
        statusMessage = "Removed app rule for \(rule.appName)."
        refreshDeliveryRuleCandidateApps()
    }

    func resetAppDeliveryRulesToDefaults() {
        appDeliveryRules = AppDeliveryRuleStore.defaultRules
        statusMessage = "Restored default app rules."
        refreshDeliveryRuleCandidateApps()
    }

    func addDictionaryEntry(_ text: String) {
        do {
            if try dictionaryStore.addEntry(text) == nil {
                statusMessage = "That dictionary entry already exists."
            } else {
                statusMessage = "Added dictionary entry."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteDictionaryEntry(id: UserDictionaryEntry.ID) {
        do {
            try dictionaryStore.deleteEntry(id: id)
            statusMessage = "Deleted dictionary entry."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func addReplacementRule(phrase: String, replacement: String) {
        do {
            if try dictionaryStore.addReplacementRule(phrase: phrase, replacement: replacement) == nil {
                statusMessage = "That replacement rule already exists."
            } else {
                statusMessage = "Added replacement rule."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteReplacementRule(id: DictionaryReplacementRule.ID) {
        do {
            try dictionaryStore.deleteReplacementRule(id: id)
            statusMessage = "Deleted replacement rule."
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func importSuperwhisperDictionary() {
        do {
            statusMessage = try dictionaryStore.importSuperwhisper().message
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func refreshRecordingHotKeyRegistration() {
        applyRecordingHotKey(previous: nil)
    }

    func beginRecordingHotKeyCapture() {
        guard !recordingHotKeyCaptureIsActive else { return }
        recordingHotKeyCaptureIsActive = true
        unregisterRecordingHotKey?()
    }

    func endRecordingHotKeyCapture() {
        guard recordingHotKeyCaptureIsActive else { return }
        recordingHotKeyCaptureIsActive = false
        refreshRecordingHotKeyRegistration()
    }

    func discardPreparedRecordingDraft() {
        environment.archive.deleteDraft(preparedArchiveDraft)
        preparedArchiveDraft = nil
    }

    private func discardActiveArchiveDraftIfNeeded() {
        environment.archive.deleteDraft(activeArchiveDraftState.takeDraftToDelete())
    }

    func prepareForApplicationTermination() {
        saveSettings(reason: .general)
        saveCredentials()
        cancelAllRecordingTriggerTimers()
        cancelRealtimeStartupTask()
        clearActiveRecordingIdentity()
        discardActiveArchiveDraftIfNeeded()
        discardPreparedRecordingDraft()
        _ = environment.recording.stopRecording()
        discardBackupMicrophone()
        endMicrophoneUseLock()
    }

    func prewarmLocalModels() {
        prewarmRecordingStartResources()
        prewarmEnginesForActiveModes()
    }

    /// Warm the engines the current modes will need, off the hot path. Called
    /// at launch and again when each recording starts, so the post-stop work
    /// never pays a cold start: parakeet.cpp weight/Metal caches stay hot,
    /// Ollama reloads the model if its keep-alive evicted it, and cloud TLS
    /// handshakes are paid while the user is still speaking.
    /// ParakeetCppWarmKeeper throttles repeat warms internally.
    private func prewarmEnginesForActiveModes() {
        environment.enginePrewarm.prewarm(
            EnginePrewarmRequest(
                transcriptionMode: transcriptionMode,
                improvementMode: improvementMode,
                ollamaBaseURL: ollamaBaseURL,
                ollamaModel: ollamaModel,
                hasOpenAIKey: !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        )
    }

    private func prewarmRecordingStartResources() {
        #if os(iOS)
        if environment.permissions.hasMicrophonePermission {
            microphonePermissionKnownAuthorized = true
            environment.permissions.rememberMicrophonePermissionGranted()
        }
        #endif
        environment.recording.prepareForFastStartIfAuthorized()
        prepareNextArchiveDraftIfNeeded()
    }

    private func prepareNextArchiveDraftIfNeeded() {
        guard preparedArchiveDraft == nil else { return }
        do {
            preparedArchiveDraft = try environment.archive.prepareRecording(createdAt: Date())
        } catch {
            NSLog("Transcript archive prewarm failed: \(error.localizedDescription)")
        }
    }

    private func consumePreparedArchiveDraft(createdAt: Date) throws -> TranscriptArchiveDraft {
        if let draft = preparedArchiveDraft {
            preparedArchiveDraft = nil
            return TranscriptArchiveDraft(
                id: draft.id,
                createdAt: createdAt,
                directoryURL: draft.directoryURL,
                audioURL: draft.audioURL
            )
        }

        return try environment.archive.prepareRecording(createdAt: createdAt)
    }

    func toggleRecording(requestedAt: Date = Date()) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(requestedAt: requestedAt)
        }
    }

    private func applyRecordingHotKey(previous: RecordingHotKey?) {
        guard !recordingHotKeyCaptureIsActive else { return }
        guard !isRevertingRecordingHotKey, let registerRecordingHotKey else { return }
        guard registerRecordingHotKey(recordingHotKey) else {
            statusMessage = "Could not register \(recordingHotKey.label)."
            if let previous, previous != recordingHotKey {
                isRevertingRecordingHotKey = true
                recordingHotKey = previous
                isRevertingRecordingHotKey = false
                _ = registerRecordingHotKey(previous)
            }
            return
        }
        if previous != nil {
            statusMessage = "Recording hotkey set to \(recordingHotKey.label)."
        }
    }

    func handleHotKeyEvent(_ event: HotKeyCenter.Event) {
        guard !recordingHotKeyCaptureIsActive else { return }

        switch event {
        case .recordingPressed(let receivedAt, let eventID, let isRepeat):
            handleRecordingTriggerEvent(.recordHotKeyDown(receivedAt: receivedAt, eventID: eventID, isRepeat: isRepeat))
        case .recordingReleased(let receivedAt, let eventID):
            handleRecordingTriggerEvent(.recordHotKeyUp(receivedAt: receivedAt, eventID: eventID))
        case .cancelPressed(let receivedAt):
            handleCancelHotKeyPressed(receivedAt: receivedAt)
        case .latchPressed(let receivedAt):
            handleRecordingTriggerEvent(.latchHotKeyDown(receivedAt: receivedAt))
        }
    }

    func recordingHotKeyPressed(requestedAt: Date = Date()) {
        handleRecordingTriggerEvent(.recordHotKeyDown(receivedAt: requestedAt, eventID: 0, isRepeat: false))
    }

    func recordingHotKeyReleased() {
        handleRecordingTriggerEvent(.recordHotKeyUp(receivedAt: Date(), eventID: 0))
    }

    func latchCurrentWalkieTalkieRecording() {
        handleRecordingTriggerEvent(.latchHotKeyDown(receivedAt: Date()))
    }

    private func handleRecordingTriggerEvent(_ event: RecordingTriggerEvent) {
        let commands = recordingTriggerController.handle(event)
        processRecordingTriggerCommands(commands)
    }

    private func handleCancelHotKeyPressed(receivedAt: Date) {
        let shouldFallbackToAppCancel = phase.canCancelActiveRecording
        let commands = recordingTriggerController.handle(.cancelHotKeyDown(receivedAt: receivedAt))
        let triggerRequestedCancel = commands.requestsCancel
        processRecordingTriggerCommands(commands)

        if shouldFallbackToAppCancel && !triggerRequestedCancel {
            cancelRecording()
        }
    }

    private func processRecordingTriggerCommands(_ commands: [RecordingTriggerCommand]) {
        for command in commands {
            switch command {
            case .requestStart(let startID, _, let requestedAt):
                startRecording(startID: startID, requestedAt: requestedAt, triggerManaged: true)
            case .requestStop(_, _, _, let shouldTranscribe):
                stopRecording(shouldTranscribe: shouldTranscribe)
            case .requestCancel(let reason):
                if reason != .startFailed {
                    cancelRecording()
                }
            case .enterLatch:
                walkieTalkieIsLatchedForDisplay = recordingTriggerBehavior == .holdToTalk
                unregisterWalkieTalkieLatchHotKey?()
            case .exitLatch:
                walkieTalkieIsLatchedForDisplay = false
                unregisterWalkieTalkieLatchHotKey?()
            case .scheduleTimer(let kind, let token, let firesAt):
                scheduleRecordingTriggerTimer(kind: kind, token: token, firesAt: firesAt)
            case .cancelTimer(let kind, let token):
                cancelRecordingTriggerTimer(kind: kind, token: token)
            case .showStatus(let message):
                statusMessage = message
            case .ignore:
                break
            case .log(let event):
                logRecordingTrigger(event)
            }
        }
    }

    private func scheduleRecordingTriggerTimer(kind: RecordingTriggerTimerKind, token: UUID, firesAt: Date) {
        cancelRecordingTriggerTimer(kind: kind, token: nil)
        triggerTimerTasks[kind] = Task { @MainActor [weak self] in
            let delay = max(0, firesAt.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.handleRecordingTriggerEvent(.timerElapsed(kind: kind, token: token, at: Date()))
        }
    }

    private func cancelRecordingTriggerTimer(kind: RecordingTriggerTimerKind, token: UUID?) {
        guard let task = triggerTimerTasks[kind] else { return }
        task.cancel()
        triggerTimerTasks[kind] = nil
    }

    private func cancelAllRecordingTriggerTimers() {
        for task in triggerTimerTasks.values {
            task.cancel()
        }
        triggerTimerTasks.removeAll()
    }

    private func resetRecordingTriggerState(reason: String) {
        cancelAllRecordingTriggerTimers()
        handleRecordingTriggerEvent(.reset(reason: reason, at: Date()))
    }

    private func logRecordingTrigger(_ event: RecordingTriggerDiagnosticEvent) {
        recordingTriggerLogger.info(
            "\(event.event, privacy: .public): \(event.previousState, privacy: .public) -> \(event.nextState, privacy: .public); commands=\(event.commands.joined(separator: ","), privacy: .public) \(event.detail, privacy: .public)"
        )
    }

    func startRecording(
        startID: UUID = UUID(),
        requestedAt: Date = Date(),
        triggerManaged: Bool = false
    ) {
        guard !phase.isBusy, !isStartingRecording else { return }
        cancelScheduledVisualReset()
        activeStartID = startID
        activeStartIsTriggerManaged = triggerManaged
        beginMicrophoneUseLock(reason: "starting")
        registerCancelHotKey?()
        if recordingTriggerBehavior == .holdToTalk {
            let registration = registerWalkieTalkieLatchHotKey?(recordingHotKey) ?? .unavailable
            activeSpaceLatchRegistrationFailed = triggerManaged
                ? !registration.spaceWhileHoldingTriggerRegistered
                : !registration.unmodifiedSpaceRegistered
        } else {
            activeSpaceLatchRegistrationFailed = false
        }
        isStartingRecording = true
        recordingStartedAt = nil
        phase = .starting
        processingVisualState = .starting
        statusMessage = activeSpaceLatchRegistrationFailed
            ? "Opening microphone. Space latch unavailable; hold to talk for this recording."
            : "Opening microphone."
        showProcessingSignal?(.starting)
        logRecordingStartup("start requested", requestedAt: requestedAt)
        Task { await startRecordingFlow(startID: startID, requestedAt: requestedAt) }
    }

    func stopRecording(shouldTranscribe: Bool = true) {
        guard case .recording = phase else { return }
        unregisterActiveRecordingHotKeys()
        cancelRealtimeStartupTask()
        let stoppedRecordingID = activeRecordingID
        let streamingTranscriber = activeStreamingTranscriber
        activeStreamingTranscriber = nil
        let recordingHandle = activeRecordingHandle
        activeRecordingHandle = nil
        guard let audioURL = environment.recording.stopRecording() else {
            let backup = endBackupMicrophone()
            activeRecordingID = nil
            microphoneRecovery.recordingEnded()
            endMicrophoneUseLock()
            realtimeAudioSink.clear()
            cancelLiveTranscription(streamingTranscriber: streamingTranscriber, recordingHandle: recordingHandle)
            let message = "Recording stopped before an audio file was created."
            guard shouldTranscribe, let backup else {
                backup?.stop.discard()
                failWithMessage(message)
                return
            }
            processBackupAfterFailedStop(
                backup,
                stoppedRecordingID: stoppedRecordingID,
                unusedAudioURL: nil,
                reportFailure: { [weak self] in self?.failWithMessage(message) }
            )
            return
        }
        let backup = endBackupMicrophone()
        endMicrophoneUseLock()
        let captureFailure = realtimeAudioSink.captureFailureSnapshot()
        realtimeAudioSink.clear()
        activeRecordingID = nil

        guard shouldTranscribe else {
            backup?.stop.discard()
            cancelLiveTranscription(streamingTranscriber: streamingTranscriber, recordingHandle: recordingHandle)
            try? FileManager.default.removeItem(at: audioURL)
            discardActiveArchiveDraftIfNeeded()
            microphoneRecovery.recordingEnded()
            session = .empty
            showRawTranscript = false
            recordingStartedAt = nil
            walkieTalkieIsLatchedForDisplay = false
            phase = .idle
            processingVisualState = .idle
            statusMessage = "Recording discarded."
            hideProcessingSignal?()
            prewarmRecordingStartResources()
            return
        }

        if let captureFailure {
            cancelLiveTranscription(streamingTranscriber: streamingTranscriber, recordingHandle: recordingHandle)
            let message = captureFailure.localizedDescription
            let reportFailure: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                self.activeProcessingRecordingID = nil
                self.recordingStartedAt = nil
                self.failWithMessage(message)
                self.persistTranscriptArchive(transcriptionEngineName: nil)
                self.microphoneRecovery.recordingEnded()
            }
            guard let backup else {
                reportFailure()
                return
            }
            processBackupAfterFailedStop(
                backup,
                stoppedRecordingID: stoppedRecordingID,
                unusedAudioURL: audioURL,
                reportFailure: reportFailure
            )
            return
        }

        recordingStartedAt = nil
        activeProcessingRecordingID = stoppedRecordingID
        phase = .transcribing
        processingVisualState = .transcribing
        statusMessage = transcriptionStatusMessage(streamingTranscriber: streamingTranscriber)
        showProcessingSignal?(.transcribing)
        handleRecordingTriggerEvent(.processingBegan(recordingID: stoppedRecordingID, at: Date()))
        Task {
            await processRecording(
                audioURL: audioURL,
                streamingTranscriber: streamingTranscriber,
                recordingHandle: recordingHandle,
                backup: backup
            )
        }
    }

    /// The main recording failed at stop and a backup exists. Shows the transcribing state, then
    /// continues the run on the backup's text when it has any. Otherwise it runs `reportFailure`,
    /// which reports the main recording's failure.
    private func processBackupAfterFailedStop(
        _ backup: StoppedBackupMicrophone,
        stoppedRecordingID: UUID?,
        unusedAudioURL: URL?,
        reportFailure: @escaping @MainActor () -> Void
    ) {
        recordingStartedAt = nil
        activeProcessingRecordingID = stoppedRecordingID
        phase = .transcribing
        processingVisualState = .transcribing
        statusMessage = "Transcribing the backup microphone recording."
        showProcessingSignal?(.transcribing)
        handleRecordingTriggerEvent(.processingBegan(recordingID: stoppedRecordingID, at: Date()))
        Task {
            let dictionarySnapshot = session.dictionarySnapshot
            guard let backupURL = await backup.stop.finishedFile() else {
                activeProcessingRecordingID = nil
                reportFailure()
                return
            }
            let result: TranscriptionResult
            do {
                result = try await transcribe(
                    audioURL: backupURL,
                    streamingTranscriber: nil,
                    recordingHandle: nil,
                    dictionarySnapshot: session.transcriptionVocabulary
                )
            } catch {
                // The backup file stays when it could not be read, so no audio is lost.
                NSLog("Backup microphone recording could not be transcribed: %@", error.localizedDescription)
                activeProcessingRecordingID = nil
                reportFailure()
                return
            }
            guard BackupTranscriptChoice.wordCount(finalTranscript(of: result)) > 0 else {
                try? FileManager.default.removeItem(at: backupURL)
                activeProcessingRecordingID = nil
                reportFailure()
                return
            }
            useBackupRecording(backupURL, microphone: backup.microphone, replacing: unusedAudioURL)
            await continueRun(with: result, dictionarySnapshot: dictionarySnapshot)
        }
    }

    func cancelRecording() {
        guard case .starting = phase else {
            cancelActiveRecording()
            return
        }

        unregisterActiveRecordingHotKeys()
        cancelRealtimeStartupTask()
        clearActiveRecordingIdentity()
        isStartingRecording = false
        let audioURL = stopRecorderAndReleaseMicrophone()
        cancelRecordingHandle()
        finishCancelledRecording(removing: audioURL)
    }

    private func cancelActiveRecording() {
        guard case .recording = phase else { return }
        unregisterActiveRecordingHotKeys()
        cancelRealtimeStartupTask()
        clearActiveRecordingIdentity()
        let streamingTranscriber = activeStreamingTranscriber
        activeStreamingTranscriber = nil
        cancelRecordingHandle()
        let audioURL = stopRecorderAndReleaseMicrophone()
        if let streamingTranscriber {
            Task { await streamingTranscriber.cancel() }
        }
        finishCancelledRecording(removing: audioURL)
    }

    /// The end of both cancel paths: delete the audio and draft, then show the idle state.
    private func finishCancelledRecording(removing audioURL: URL?) {
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        discardActiveArchiveDraftIfNeeded()
        session = .empty
        showRawTranscript = false
        phase = .idle
        processingVisualState = .idle
        recordingStartedAt = nil
        walkieTalkieIsLatchedForDisplay = false
        statusMessage = "Recording cancelled."
        hideProcessingSignal?()
        prewarmRecordingStartResources()
    }

    private func unregisterActiveRecordingHotKeys() {
        unregisterCancelHotKey?()
        unregisterWalkieTalkieLatchHotKey?()
    }

    private func cancelRealtimeStartupTask() {
        activeRealtimeStartupTask?.cancel()
        activeRealtimeStartupTask = nil
    }

    /// Forgets the start and the recording in flight.
    private func clearActiveRecordingIdentity() {
        activeStartID = nil
        activeStartIsTriggerManaged = false
        activeRecordingID = nil
        activeProcessingRecordingID = nil
        microphoneRecovery.recordingEnded()
    }

    private func stopRecorderAndReleaseMicrophone() -> URL? {
        let audioURL = environment.recording.stopRecording()
        discardBackupMicrophone()
        endMicrophoneUseLock()
        realtimeAudioSink.clear()
        return audioURL
    }

    /// Ends the silence watch and the backup microphone of the recording in flight. Returns the
    /// stopping backup, or nil when the recording had none.
    private func endBackupMicrophone() -> StoppedBackupMicrophone? {
        let primaryWasSilent = silentMicrophoneWarningShown
        activeSilenceWatch = nil
        silentMicrophoneWarningShown = false
        guard let backup = activeBackupMicrophone else { return nil }
        activeBackupMicrophone = nil
        return StoppedBackupMicrophone(
            microphone: backup.microphone,
            stop: environment.backupRecording.stop(),
            primaryWasSilent: primaryWasSilent
        )
    }

    /// Ends the silence watch and the backup microphone of the recording in flight and deletes
    /// the backup file.
    private func discardBackupMicrophone() {
        endBackupMicrophone()?.stop.discard()
    }

    private func cancelRecordingHandle() {
        activeRecordingHandle?.cancel()
        activeRecordingHandle = nil
    }

    private func cancelLiveTranscription(
        streamingTranscriber: OpenAIRealtimeTranscriber?,
        recordingHandle: (any RecordingSessionHandle)?
    ) {
        if let streamingTranscriber {
            Task { await streamingTranscriber.cancel() }
        }
        recordingHandle?.cancel()
    }

    func copyDisplayText() {
        let text = displayText
        copyToPasteboard(text)
        statusMessage = "Copied."
        recordDelivery(text, via: "manual-copy")
    }

    func pasteDisplayText() {
        let text = displayText
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await environment.delivery.pasteManually(text)
                statusMessage = "Pasted."
                recordDelivery(text, via: "manual-paste")
            } catch {
                copyToPasteboard(text)
                statusMessage = "Copied. Enable Accessibility for Auto Improve Recorder in System Settings to paste automatically."
                recordDelivery(text, via: "manual-copy")
            }
        }
    }

    func rerunImprove() {
        guard canRerunImprove else { return }
        Task { await improveCurrentTranscript(force: true) }
    }

    func updateDisplayText(_ text: String) {
        if showRawTranscript {
            session.rawTranscript = text
        } else {
            session.improvedText = text
        }
        persistTranscriptArchive(transcriptionEngineName: nil)
    }

    func openSettings() {
        showSettings?()
    }

    func copyOpenAIRealtimeDiagnostics() {
        guard let diagnostics = lastOpenAIRealtimeDiagnostics else { return }
        copyToPasteboard(diagnostics.details.isEmpty ? diagnostics.summary : diagnostics.details)
        statusMessage = "Copied OpenAI diagnostics."
    }

    func copyLatestDiagnostics() {
        refreshDiagnostics()
        guard let event = diagnosticEvents.first else { return }
        let details = event.details.trimmingCharacters(in: .whitespacesAndNewlines)
        copyToPasteboard(details.isEmpty ? event.summary : details)
        statusMessage = "Copied diagnostics."
    }

    private func startRecordingFlow(startID: UUID, requestedAt: Date) async {
        defer {
            if activeStartID == startID {
                activeStartID = nil
                activeStartIsTriggerManaged = false
            }
            isStartingRecording = false
        }
        activeArchiveDraft = nil

        do {
            if environment.permissions.microphoneState() == .authorized {
                let hadCachedPermission = microphonePermissionKnownAuthorized
                microphonePermissionKnownAuthorized = true
                environment.permissions.rememberMicrophonePermissionGranted()
                let source = hadCachedPermission ? "verified" : "ready"
                logRecordingStartup("microphone permission \(source)", requestedAt: requestedAt)
            } else {
                microphonePermissionKnownAuthorized = false
                try await environment.permissions.requestMicrophone()
                microphonePermissionKnownAuthorized = true
                environment.permissions.rememberMicrophonePermissionGranted()
                logRecordingStartup("microphone permission ready", requestedAt: requestedAt)
            }

            guard activeStartID == startID, case .starting = phase else { return }

            let recordingID = UUID()
            let archiveDraft = try consumePreparedArchiveDraft(createdAt: requestedAt)
            dictionaryStore.reloadLexicon()
            let dictionarySnapshot = dictionaryStore.currentSnapshotString
            let transcriptionVocabulary = dictionaryStore.transcriptionVocabularyString
            activeArchiveDraft = archiveDraft
            let recordingMode = transcriptionMode
            let shouldPrepareRealtime = recordingMode == .fastest
            let shouldBufferRealtimeAudio = shouldPrepareRealtime &&
                !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            realtimeAudioSink.reset(bufferPendingAudio: shouldBufferRealtimeAudio)
            let recordingHandle = beginRecordingHandle(
                mode: recordingMode,
                dictionarySnapshot: transcriptionVocabulary,
                attachedToCapture: true
            )
            activeRecordingHandle = recordingHandle
            // With the switch off there is no silence watch and no backup.
            activeSilenceWatch = environment.backupMicrophoneRecordingEnabled() ? MicrophoneSilenceWatch() : nil
            silentMicrophoneWarningShown = false
            usedBackupRecording = nil
            let audioURL: URL
            let audioSink = realtimeAudioSink
            do {
                let microphoneResolution = try resolveMicrophoneForRecording()
                audioURL = try startAudioRecorder(
                    at: archiveDraft.audioURL,
                    initialResolution: microphoneResolution,
                    audioSink: audioSink,
                    recordingHandle: recordingHandle,
                    requestedAt: requestedAt
                )
            } catch {
                realtimeAudioSink.clear()
                recordingHandle.cancel()
                activeRecordingHandle = nil
                throw error
            }
            guard activeStartID == startID, case .starting = phase else { return }
            activeStartID = nil
            activeRecordingID = recordingID
            session = TranscriptSession(
                audioURL: audioURL,
                rawTranscript: "",
                improvedText: "",
                message: nil,
                improveFailed: false,
                dictionarySnapshot: dictionarySnapshot,
                transcriptionVocabulary: transcriptionVocabulary
            )
            sessionTranscriptionMode = recordingMode
            showRawTranscript = false
            if shouldPrepareRealtime {
                statusMessage = shouldBufferRealtimeAudio
                    ? "Recording. Preparing OpenAI realtime transcription."
                    : "Recording for Parakeet fallback."
            } else {
                statusMessage = nil
            }
            phase = .recording(audioURL)
            processingVisualState = .recording
            let beganAt = Date()
            recordingStartedAt = beganAt
            beginMicrophoneUseLock(reason: "recording")
            registerCancelHotKey?()
            let triggerManaged = activeStartIsTriggerManaged
            activeStartIsTriggerManaged = false
            if triggerManaged {
                handleRecordingTriggerEvent(.recordingBegan(startID: startID, recordingID: recordingID, beganAt: beganAt))
            } else {
                handleRecordingTriggerEvent(.externalRecordingBegan(recordingID: recordingID, beganAt: beganAt))
            }
            guard case .recording = phase else { return }
            if activeSpaceLatchRegistrationFailed &&
                recordingTriggerBehavior == .holdToTalk &&
                !walkieTalkieIsLatchedForDisplay {
                statusMessage = "Space latch unavailable; keep holding to record."
            }
            showProcessingSignal?(.recording)
            logRecordingStartup("audio engine started and recording UI shown", requestedAt: requestedAt)
            startBackupMicrophoneIfEligible(mainRecordingURL: audioURL)
            prewarmEnginesForActiveModes()

            if shouldPrepareRealtime {
                activeRealtimeStartupTask = Task { [weak self] in
                    await self?.prepareRealtimeTranscriberForActiveRecording(
                        recordingID: recordingID,
                        mode: recordingMode,
                        dictionarySnapshot: transcriptionVocabulary,
                        requestedAt: requestedAt
                    )
                }
            }
        } catch {
            recordDiagnosticEvent(
                subsystem: .microphone,
                severity: .error,
                summary: "Recording start failed",
                details: error.localizedDescription,
                relatedProvider: nil
            )
            discardActiveArchiveDraftIfNeeded()
            activeRecordingID = nil
            microphoneRecovery.recordingEnded()
            activeRealtimeStartupTask = nil
            realtimeAudioSink.clear()
            cancelRecordingHandle()
            handleRecordingTriggerEvent(.startFailed(startID: startID, error: error.localizedDescription, at: Date()))
            failWithMessage(error.localizedDescription)
        }
    }

    private func resolveMicrophoneForRecording() throws -> MicrophoneResolution {
        refreshMicrophones()
        let resolution = try microphoneRecovery.resolve(
            preferences: .fromPreferredMicrophoneID(preferredMicrophoneID),
            devices: availableMicrophones,
            now: Date()
        )
        microphoneDeviceLogger.info(
            "Resolved microphone requested=\(resolution.requestedID ?? "", privacy: .public) id=\(resolution.device.id, privacy: .public) name=\(resolution.device.name, privacy: .public) fallback=\(resolution.usedFallback, privacy: .public) reason=\(resolution.reason.rawValue, privacy: .public)"
        )
        if resolution.usedFallback {
            statusMessage = "Preferred microphone unavailable; using \(resolution.device.name)."
        }
        return resolution
    }

    private func startAudioRecorder(
        at audioURL: URL,
        initialResolution: MicrophoneResolution,
        audioSink: OpenAIRealtimeAudioSink,
        recordingHandle: any RecordingSessionHandle,
        requestedAt: Date
    ) throws -> URL {
        do {
            microphoneRecovery.recordingStarted(on: initialResolution)
            return try startAudioRecorderOnce(
                at: audioURL,
                resolution: initialResolution,
                audioSink: audioSink,
                recordingHandle: recordingHandle,
                requestedAt: requestedAt
            )
        } catch {
            guard shouldRetryWithFallback(after: error, resolution: initialResolution) else {
                throw error
            }

            quarantineMicrophone(initialResolution.device.id, reason: error.localizedDescription)
            let fallbackResolution = try resolveMicrophoneForRecording()
            guard case .restart = MicrophoneRecovery.restartCommand(
                replacing: initialResolution,
                with: fallbackResolution
            ) else {
                throw error
            }

            statusMessage = "Could not use \(initialResolution.device.name); using \(fallbackResolution.device.name)."
            microphoneRecovery.recordingStarted(on: fallbackResolution)
            return try startAudioRecorderOnce(
                at: audioURL,
                resolution: fallbackResolution,
                audioSink: audioSink,
                recordingHandle: recordingHandle,
                requestedAt: requestedAt
            )
        }
    }

    private func startAudioRecorderOnce(
        at audioURL: URL,
        resolution: MicrophoneResolution,
        audioSink: OpenAIRealtimeAudioSink,
        recordingHandle: any RecordingSessionHandle,
        requestedAt: Date
    ) throws -> URL {
        let healthMonitor = shouldMonitorForPreferredMicrophoneHealth(resolution)
            ? MicrophoneHealthMonitor(configuration: .startupFallback)
            : nil
        let silenceWatch = activeSilenceWatch
        let microphoneName = BackupMicrophoneChooser.resolvedPrimary(
            resolution.device,
            devices: availableMicrophones
        )?.name ?? resolution.device.name
        return try environment.recording.startRecording(
            at: audioURL,
            microphone: resolution.device,
            bufferSize: environment.recording.fastStartBufferSize,
            streamHandler: { [weak self] captureEvent in
                switch captureEvent {
                case .captured(let captured):
                    if let silenceWatch, silenceWatch.observePrimary(captured.buffer) != nil {
                        Task { @MainActor [weak self] in
                            self?.handleSilentMicrophoneReport(from: silenceWatch, microphoneName: microphoneName)
                        }
                    }
                    if let event = healthMonitor?.observe(captured.buffer) {
                        Task { @MainActor [weak self] in
                            self?.handleMicrophoneHealthEvent(
                                event,
                                resolution: resolution,
                                audioURL: audioURL,
                                audioSink: audioSink,
                                requestedAt: requestedAt
                            )
                        }
                    }
                    audioSink.appendAudioBuffer(captured)
                    recordingHandle.receive(captureEvent)
                case .failure(let failure):
                    audioSink.recordCaptureFailure(failure)
                    recordingHandle.receive(captureEvent)
                    Task { @MainActor [weak self] in
                        guard let self, case .recording = self.phase else { return }
                        self.statusMessage = "Recording degraded. Stop and try again. \(failure.localizedDescription)"
                    }
                }
            },
            onFirstBuffer: {
                NSLog(
                    "Recording startup: first audio buffer after %.3fs.",
                    Date().timeIntervalSince(requestedAt)
                )
            }
        )
    }

    /// Opens the backup microphone beside an external main microphone. The main recorder is
    /// already running; the backup opens on its own queue and this returns at once.
    private func startBackupMicrophoneIfEligible(mainRecordingURL: URL) {
        guard let silenceWatch = activeSilenceWatch,
              let resolution = microphoneRecovery.activeResolution,
              let microphone = BackupMicrophoneChooser.chooseBackup(
                  primary: resolution.device,
                  devices: availableMicrophones,
                  isEnabled: true
              ) else {
            return
        }
        let id = UUID()
        activeBackupMicrophone = ActiveBackupMicrophone(id: id, microphone: microphone)
        environment.backupRecording.start(
            at: BackupMicrophoneRecorder.backupURL(forMainRecording: mainRecordingURL),
            microphone: microphone,
            onBuffer: { silenceWatch.observeBackup($0) },
            onResult: { [weak self] started in
                Task { @MainActor [weak self] in
                    self?.backupMicrophoneStartFinished(id: id, started: started, silenceWatch: silenceWatch)
                }
            }
        )
    }

    /// A backup that failed to open is forgotten; the recording continues without one.
    private func backupMicrophoneStartFinished(id: UUID, started: Bool, silenceWatch: MicrophoneSilenceWatch) {
        guard activeBackupMicrophone?.id == id else { return }
        if started {
            activeBackupMicrophone?.isRunning = true
            silenceWatch.backupStarted()
        } else {
            activeBackupMicrophone = nil
        }
    }

    /// Shows the silent microphone warning once per recording. The recording keeps running.
    private func handleSilentMicrophoneReport(from silenceWatch: MicrophoneSilenceWatch, microphoneName: String) {
        guard silenceWatch === activeSilenceWatch,
              !silentMicrophoneWarningShown,
              case .recording = phase else {
            return
        }
        silentMicrophoneWarningShown = true
        let backupName = activeBackupMicrophone?.isRunning == true ? activeBackupMicrophone?.microphone.name : nil
        microphoneDeviceLogger.info(
            "Exact digital silence from microphone name=\(microphoneName, privacy: .public) backup=\(backupName ?? "none", privacy: .public)"
        )
        if let backupName {
            statusMessage = "No sound from \(microphoneName). Recording from \(backupName)."
        } else {
            statusMessage = "No sound from \(microphoneName)."
        }
        environment.playMicrophoneWarningSound()
    }

    /// The mode of the session's recording, or the setting when no recording has started yet.
    private var recordingMode: TranscriptionMode {
        sessionTranscriptionMode ?? transcriptionMode
    }

    /// Starts the transcription work for one recording. The API key is read when the handle
    /// finishes, as it was before handles.
    private func beginRecordingHandle(
        mode: TranscriptionMode,
        dictionarySnapshot: String,
        attachedToCapture: Bool
    ) -> any RecordingSessionHandle {
        environment.transcription.beginRecording(
            RecordingTranscriptionRequest(
                mode: mode,
                dictionarySnapshot: dictionarySnapshot,
                attachedToCapture: attachedToCapture,
                apiKey: { [weak self] in
                    await MainActor.run { self?.apiKey ?? "" }
                }
            ),
            status: { [weak self] message in
                await MainActor.run {
                    self?.statusMessage = message
                }
            },
            recordDiagnostics: { [weak self] diagnostics in
                await MainActor.run {
                    self?.recordOpenAIRealtimeDiagnostics(diagnostics)
                }
            }
        )
    }

    private func shouldMonitorForPreferredMicrophoneHealth(_ resolution: MicrophoneResolution) -> Bool {
        MicrophoneRecovery.shouldMonitor(
            resolution,
            preferredMicrophoneID: preferredMicrophoneID.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func handleMicrophoneHealthEvent(
        _ event: MicrophoneHealthEvent,
        resolution: MicrophoneResolution,
        audioURL: URL,
        audioSink: OpenAIRealtimeAudioSink,
        requestedAt: Date
    ) {
        // A recording with a backup keeps its main microphone; the backup holds the audio.
        guard activeBackupMicrophone == nil else { return }
        guard case .recording = phase,
              case .recover(let quarantinedUntil) = microphoneRecovery.silentMicrophoneReported(
                  event,
                  on: resolution,
                  recheckingPreferredMicrophoneID: preferredMicrophoneID
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  now: Date()
              ) else {
            return
        }

        recoverFromSilentPreferredMicrophone(
            resolution,
            event: event,
            quarantinedUntil: quarantinedUntil,
            audioURL: audioURL,
            audioSink: audioSink,
            requestedAt: requestedAt
        )
    }

    private func recoverFromSilentPreferredMicrophone(
        _ resolution: MicrophoneResolution,
        event: MicrophoneHealthEvent,
        quarantinedUntil: Date,
        audioURL: URL,
        audioSink: OpenAIRealtimeAudioSink,
        requestedAt: Date
    ) {
        defer { microphoneRecovery.recoveryFinished() }

        let observedMS = Int(event.observedDuration * 1000)
        let reason = "Exact digital silence for \(observedMS)ms across \(event.silentBufferCount) startup buffers."
        noteMicrophoneQuarantined(resolution.device.id, until: quarantinedUntil, reason: reason)

        do {
            let fallbackResolution = try resolveMicrophoneForRecording()
            guard case .restart = MicrophoneRecovery.restartCommand(
                replacing: resolution,
                with: fallbackResolution
            ) else {
                return
            }

            cancelRealtimeStartupTask()
            if let streamingTranscriber = activeStreamingTranscriber {
                activeStreamingTranscriber = nil
                Task { await streamingTranscriber.cancel() }
            }

            _ = environment.recording.stopRecording()
            realtimeAudioSink.clear()

            let recordingMode = self.recordingMode
            let shouldPrepareRealtime = recordingMode == .fastest
            let shouldBufferRealtimeAudio = shouldPrepareRealtime &&
                !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            audioSink.reset(bufferPendingAudio: shouldBufferRealtimeAudio)

            // The old handle only heard digital silence; start a new one in
            // the same mode alongside the fallback microphone.
            activeRecordingHandle?.cancel()
            let recordingHandle = beginRecordingHandle(
                mode: recordingMode,
                dictionarySnapshot: session.transcriptionVocabulary,
                attachedToCapture: true
            )
            activeRecordingHandle = recordingHandle

            statusMessage = "Could not hear \(resolution.device.name); using \(fallbackResolution.device.name)."
            microphoneRecovery.recordingStarted(on: fallbackResolution)
            _ = try startAudioRecorderOnce(
                at: audioURL,
                resolution: fallbackResolution,
                audioSink: audioSink,
                recordingHandle: recordingHandle,
                requestedAt: requestedAt
            )
            microphoneDeviceLogger.info(
                "Recovered from exact-silent microphone id=\(resolution.device.id, privacy: .public) fallbackID=\(fallbackResolution.device.id, privacy: .public) fallbackName=\(fallbackResolution.device.name, privacy: .public)"
            )

            if shouldPrepareRealtime, let recordingID = activeRecordingID {
                let dictionarySnapshot = session.transcriptionVocabulary
                activeRealtimeStartupTask = Task { [weak self] in
                    await self?.prepareRealtimeTranscriberForActiveRecording(
                        recordingID: recordingID,
                        mode: recordingMode,
                        dictionarySnapshot: dictionarySnapshot,
                        requestedAt: requestedAt
                    )
                }
            }
        } catch {
            failWithMessage(error.localizedDescription)
        }
    }

    private func shouldRetryWithFallback(after error: Error, resolution: MicrophoneResolution) -> Bool {
        guard !resolution.usedFallback,
              !resolution.device.id.isEmpty,
              preferredMicrophoneID.trimmingCharacters(in: .whitespacesAndNewlines) == resolution.device.id else {
            return false
        }

        return true
    }

    private func quarantineMicrophone(_ id: String, reason: String) {
        guard let expiresAt = microphoneRecovery.quarantine(id, now: Date()) else { return }
        noteMicrophoneQuarantined(id, until: expiresAt, reason: reason)
    }

    private func noteMicrophoneQuarantined(_ id: String, until expiresAt: Date, reason: String) {
        updateResolvedMicrophoneSummary()
        microphoneDeviceLogger.info(
            "Quarantined microphone id=\(id, privacy: .public) until=\(expiresAt.ISO8601Format(), privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func prepareRealtimeTranscriberForActiveRecording(
        recordingID: UUID,
        mode selectedMode: TranscriptionMode,
        dictionarySnapshot: String,
        requestedAt: Date
    ) async {
        let selectedAPIKey = apiKey
        let streamingTranscriber = await environment.transcription.prepareRealtimeIfNeeded(
            mode: selectedMode,
            apiKey: selectedAPIKey,
            dictionarySnapshot: dictionarySnapshot,
            status: { [weak self] message in
                await MainActor.run {
                    self?.statusMessage = message
                }
            },
            recordDiagnostics: { [weak self] diagnostics in
                await MainActor.run {
                    self?.recordOpenAIRealtimeDiagnostics(diagnostics)
                }
            }
        )

        guard !Task.isCancelled,
              activeRecordingID == recordingID,
              case .recording = phase else {
            if let streamingTranscriber {
                await streamingTranscriber.cancel()
            }
            return
        }

        activeRealtimeStartupTask = nil
        guard let streamingTranscriber else {
            realtimeAudioSink.discardPendingAudio()
            return
        }

        activeStreamingTranscriber = streamingTranscriber
        let replayedBufferCount = realtimeAudioSink.setTranscriber(streamingTranscriber)
        if let captureFailure = realtimeAudioSink.captureFailureSnapshot() {
            statusMessage = "Recording degraded. Stop and try again. \(captureFailure.localizedDescription)"
        } else {
            statusMessage = "Recording with OpenAI realtime transcription."
        }
        NSLog(
            "Recording startup: OpenAI realtime ready after %.3fs; replayed %d buffered audio buffers.",
            Date().timeIntervalSince(requestedAt),
            replayedBufferCount
        )
    }

    private func processRecording(
        audioURL: URL,
        streamingTranscriber: OpenAIRealtimeTranscriber?,
        recordingHandle: (any RecordingSessionHandle)? = nil,
        backup: StoppedBackupMicrophone? = nil
    ) async {
        do {
            let dictionarySnapshot = session.dictionarySnapshot
            let result = try await transcribeChoosingBackup(
                audioURL: audioURL,
                streamingTranscriber: streamingTranscriber,
                recordingHandle: recordingHandle,
                backup: backup
            )
            await continueRun(with: result, dictionarySnapshot: dictionarySnapshot)
        } catch {
            session = TranscriptSession(
                audioURL: audioURL,
                rawTranscript: "",
                improvedText: "",
                message: error.localizedDescription,
                improveFailed: false,
                dictionarySnapshot: session.dictionarySnapshot
            )
            persistTranscriptArchive(transcriptionEngineName: nil)
            phase = .failed
            processingVisualState = .failed
            statusMessage = error.localizedDescription
            await finishProcessing()
        }
    }

    /// The run after transcription: replacement rules, the archive save, then improvement or delivery.
    private func continueRun(with result: TranscriptionResult, dictionarySnapshot: String) async {
        let outcome = TranscriptPostProcessor.process(
            result.text,
            rules: dictionaryStore.effectiveReplacementRules
        )
        let transcript = outcome.final
        session.rawTranscript = transcript
        session.recognizerTranscript = outcome.recognizer
        session.postRulesTranscript = outcome.afterRules
        session.improvedText = ""
        session.message = nil
        session.improveFailed = false
        session.dictionarySnapshot = dictionarySnapshot
        persistTranscriptArchive(transcriptionEngineName: result.engineName)

        switch autoImproveMode {
        case .off:
            phase = .ready
            showRawTranscript = true
            statusMessage = "Showing raw transcript."
            await finishProcessing()
        case .manual:
            phase = .ready
            showRawTranscript = true
            statusMessage = "Transcript ready."
            await finishProcessing()
        case .automatic:
            if wordCount(transcript) >= thresholdWords {
                await improveCurrentTranscript(force: false)
            } else {
                phase = .ready
                showRawTranscript = true
                statusMessage = "Transcript ready."
                await finishProcessing()
            }
        }
    }

    /// Transcribes the main recording. When that fails, gives no words, or the silence watch
    /// reported, it transcribes the backup too and returns the backup's result when it has more
    /// words. A backup that is not needed is deleted without waiting for its file.
    private func transcribeChoosingBackup(
        audioURL: URL,
        streamingTranscriber: OpenAIRealtimeTranscriber?,
        recordingHandle: (any RecordingSessionHandle)?,
        backup: StoppedBackupMicrophone?
    ) async throws -> TranscriptionResult {
        let vocabulary = session.transcriptionVocabulary
        let main: Result<TranscriptionResult, Error>
        do {
            main = .success(try await transcribe(
                audioURL: audioURL,
                streamingTranscriber: streamingTranscriber,
                recordingHandle: recordingHandle,
                dictionarySnapshot: vocabulary
            ))
        } catch {
            main = .failure(error)
        }
        guard let backup else { return try main.get() }

        let mainText = (try? main.get()).map(finalTranscript(of:)) ?? ""
        guard BackupTranscriptChoice.wordCount(mainText) == 0 || backup.primaryWasSilent else {
            backup.stop.discard()
            return try main.get()
        }
        guard let backupURL = await backup.stop.finishedFile() else { return try main.get() }
        do {
            // No streaming transcriber and no live session: the backup is read from its file.
            let backupResult = try await transcribe(
                audioURL: backupURL,
                streamingTranscriber: nil,
                recordingHandle: nil,
                dictionarySnapshot: vocabulary
            )
            if BackupTranscriptChoice.prefersBackup(
                mainText: mainText,
                backupText: finalTranscript(of: backupResult)
            ) {
                useBackupRecording(backupURL, microphone: backup.microphone, replacing: audioURL)
                return backupResult
            }
            try? FileManager.default.removeItem(at: backupURL)
        } catch {
            // The backup file stays when it could not be read, so no audio is lost.
            NSLog("Backup microphone recording could not be transcribed: %@", error.localizedDescription)
        }
        return try main.get()
    }

    /// The text the run would use for `result`: the recognizer's text after the replacement rules.
    private func finalTranscript(of result: TranscriptionResult) -> String {
        TranscriptPostProcessor.process(result.text, rules: dictionaryStore.effectiveReplacementRules).final
    }

    /// Makes the backup recording the session's audio and deletes the main recording's file.
    private func useBackupRecording(_ backupURL: URL, microphone: AudioInputDevice, replacing mainAudioURL: URL?) {
        usedBackupRecording = (microphone, backupURL)
        session.audioURL = backupURL
        if let mainAudioURL {
            try? FileManager.default.removeItem(at: mainAudioURL)
        }
        microphoneDeviceLogger.info(
            "Using the backup microphone recording name=\(microphone.name, privacy: .public)"
        )
    }

    /// Adds the backup microphone note to the status when the session's text came from the backup.
    private func appendBackupMicrophoneNoteToStatus() {
        guard let microphone = usedBackupRecording?.microphone else { return }
        let note = "Used the backup microphone (\(microphone.name))."
        let current = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !current.hasSuffix(note) else { return }
        statusMessage = current.isEmpty ? note : "\(current) \(note)"
    }

    private func transcribe(
        audioURL: URL,
        streamingTranscriber: OpenAIRealtimeTranscriber?,
        recordingHandle: (any RecordingSessionHandle)?,
        dictionarySnapshot: String
    ) async throws -> TranscriptionResult {
        // Without a handle this is a second transcription of a saved file. It gets a handle in
        // the recording's mode that was never attached to capture.
        let handle = recordingHandle ?? beginRecordingHandle(
            mode: recordingMode,
            dictionarySnapshot: dictionarySnapshot,
            attachedToCapture: false
        )
        if let streamingTranscriber {
            (handle as? RealtimeBridgeRecordingHandle)?.useRealtimeTranscriber(streamingTranscriber)
        }
        return try await handle.finish(audioURL: audioURL)
    }

    private func improveCurrentTranscript(force: Bool) async {
        let raw = session.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        if autoImproveMode == .off && !force {
            return
        }

        phase = .improving
        processingVisualState = .improving
        statusMessage = "Improving with \(improvementMode.detailLabel)."
        showProcessingSignal?(.improving)

        do {
            // Progressive update path: invoke streaming improve. The engine
            // calls back with the cumulative improved text; we hop to main
            // and update session.improvedText so the preview surface can
            // paint the partial result immediately.
            //
            // Paste / clipboard side-effects ONLY happen in finishProcessing()
            // after this call returns -- that guarantees no double-paste even
            // though we update session.improvedText many times during stream.
            let improved = try await environment.improvement.improve(
                ImprovementServiceRequest(
                    rawTranscript: raw,
                    mode: improvementMode,
                    outputMode: outputMode,
                    modificationStrength: cleanupStrength,
                    dictionarySnapshot: session.dictionarySnapshot,
                    credentials: ProviderCredentials(
                        openAIAPIKey: apiKey,
                        geminiAPIKey: geminiAPIKey,
                        anthropicAPIKey: anthropicAPIKey
                    ),
                    ollama: OllamaSettings(
                        baseURL: ollamaBaseURL,
                        model: ollamaModel
                    ),
                    onDelta: { [weak self] partial in
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            // Show the partial improved text in the preview surface.
                            // Suppressing showRawTranscript flips the menu/pill onto
                            // the (still-incomplete) improved buffer.
                            self.session.improvedText = partial
                            self.showRawTranscript = false
                        }
                    }
                )
            )
            session.improvedText = improved
            session.message = nil
            session.improveFailed = false
            showRawTranscript = false
            phase = .ready
            statusMessage = "Improved text ready."
            persistTranscriptArchive(transcriptionEngineName: nil)
        } catch {
            session.improvedText = ""
            session.message = "Improve failed; showing raw transcript. \(error.localizedDescription)"
            session.improveFailed = true
            showRawTranscript = true
            phase = .ready
            statusMessage = session.message
            persistTranscriptArchive(transcriptionEngineName: nil)
        }

        await finishProcessing()
    }

    private var cleanupStrength: Int {
        switch outputMode {
        case .verbatim:
            return 1
        case .lightCleanup:
            return 2
        case .promptCleanup:
            return 3
        case .structuredTask:
            return 4
        }
    }

    private func persistTranscriptArchive(transcriptionEngineName: String?) {
        guard var archiveDraft = activeArchiveDraft ?? archiveDraftFromSession() else { return }
        let microphoneResolution = microphoneRecovery.activeResolution
        // When the text came from the backup, the record names the backup's file and microphone.
        let backup = usedBackupRecording
        if let backup {
            archiveDraft = TranscriptArchiveDraft(
                id: archiveDraft.id,
                createdAt: archiveDraft.createdAt,
                directoryURL: archiveDraft.directoryURL,
                audioURL: backup.audioURL
            )
        }
        let content = TranscriptArchiveContent(
            rawTranscript: session.rawTranscript,
            cleanedTranscript: session.improvedText,
            finalTranscript: session.preferredText,
            improveFailed: session.improveFailed,
            message: session.message ?? statusMessage,
            dictionarySnapshot: session.dictionarySnapshot,
            recognizerTranscript: session.recognizerTranscript.isEmpty ? nil : session.recognizerTranscript,
            postRulesTranscript: session.postRulesTranscript.isEmpty ? nil : session.postRulesTranscript,
            deliveredText: session.deliveredText.isEmpty ? nil : session.deliveredText,
            deliveredVia: session.deliveredVia.isEmpty ? nil : session.deliveredVia
        )
        let metadata = TranscriptArchiveMetadata(
            updatedAt: Date(),
            transcriptionMode: recordingMode.rawValue,
            transcriptionEngine: transcriptionEngineName,
            improvementMode: improvementMode.rawValue,
            cleanupMode: outputMode.rawValue,
            autoImproveMode: autoImproveMode.rawValue,
            thresholdWords: thresholdWords,
            microphonePreferenceID: preferredMicrophoneID,
            microphoneResolvedID: backup?.microphone.id ?? microphoneResolution?.device.id,
            microphoneResolvedName: backup?.microphone.name ?? microphoneResolution?.device.name,
            microphoneUsedFallback: backup != nil || (microphoneResolution?.usedFallback ?? false),
            microphoneFallbackReason: backup != nil
                ? "backupMicrophone"
                : microphoneResolution?.usedFallback == true
                    ? microphoneResolution?.reason.rawValue
                    : nil
        )
        let record = environment.archive.record(
            draft: archiveDraft,
            content: content,
            metadata: metadata
        )
        if environment.archive.save(record) {
            activeArchiveDraftState.markCommittedIfCurrent(id: archiveDraft.id)
        }
    }

    private func archiveDraftFromSession() -> TranscriptArchiveDraft? {
        guard let audioURL = session.audioURL else { return nil }
        let directoryURL = audioURL.deletingLastPathComponent()
        let id = directoryURL.lastPathComponent
        guard !id.isEmpty else { return nil }
        return TranscriptArchiveDraft(
            id: id,
            createdAt: Date(),
            directoryURL: directoryURL,
            audioURL: audioURL
        )
    }

    private func transcriptionStatusMessage(streamingTranscriber: OpenAIRealtimeTranscriber?) -> String {
        if streamingTranscriber != nil {
            return "Finalizing OpenAI streaming transcript."
        }

        return AIRTranscriberCatalog.stopStatus(for: recordingMode)
    }

    private func finishProcessing() async {
        unregisterCancelHotKey?()
        defer {
            let processingRecordingID = activeProcessingRecordingID
            activeProcessingRecordingID = nil
            handleRecordingTriggerEvent(.processingFinished(recordingID: processingRecordingID, at: Date()))
            prewarmRecordingStartResources()
        }
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            phase = .delivering
            processingVisualState = .delivering
            statusMessage = "Delivering text."
            showProcessingSignal?(.delivering)

            let deliveryState = await completeWithText(text)
            processingVisualState = deliveryState
            phase = .ready
            flashReadySignal?(deliveryState)
            scheduleVisualReset(after: 1.25)
        } else {
            processingVisualState = phase == .failed ? .failed : .ready
            hideProcessingSignal?()
            scheduleVisualReset(after: 0.8)
        }
        appendBackupMicrophoneNoteToStatus()
    }

    @discardableResult
    private func completeWithText(_ text: String) async -> ProcessingVisualState {
        let result = await environment.delivery.deliver(
            DeliveryRequest(
                text: text,
                globalSettings: GlobalCompletionSettings(
                    copyFinishedTextToClipboard: copyFinishedTextToClipboard,
                    autoSubmitDetectedTextFields: autoSubmitDetectedTextFields
                ),
                rules: appDeliveryRules
            )
        )
        statusMessage = result.statusMessage
        if let via = Self.deliveredVia(for: result.outcome) {
            recordDelivery(text, via: via)
        }
        return processingVisualState(for: result.outcome)
    }

    private static func deliveredVia(for outcome: DeliveryOutcome) -> String? {
        switch outcome {
        case .pasted:
            return "auto-paste"
        case .submitted:
            return "auto-submit"
        case .copied:
            return "auto-copy"
        case .ready:
            return nil
        }
    }

    /// Records what reached the destination so the archive can compare it with the recogniser's output.
    private func recordDelivery(_ text: String, via: String) {
        session.deliveredText = text
        session.deliveredVia = via
        persistTranscriptArchive(transcriptionEngineName: nil)
    }

    private func processingVisualState(for outcome: DeliveryOutcome) -> ProcessingVisualState {
        switch outcome {
        case .pasted:
            return .pasted
        case .submitted:
            return .submitted
        case .copied:
            return .copied
        case .ready:
            return .ready
        }
    }

    private func scheduleVisualReset(after delay: TimeInterval) {
        let token = UUID()
        visualResetToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.visualResetToken == token, !self.phase.isBusy else { return }
            if self.phase == .ready {
                self.processingVisualState = .idle
            }
        }
    }

    private func cancelScheduledVisualReset() {
        visualResetToken = UUID()
    }

    private func completionNotificationBody() -> String {
        let raw = session.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let improved = session.improvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasImproved = !session.improveFailed && !raw.isEmpty && !improved.isEmpty && improved != raw

        let textFieldDestination = autoSubmitDetectedTextFields
            ? "pasted into and submitted from a focused text field"
            : "pasted into a focused text field"
        let destination = copyFinishedTextToClipboard
            ? "\(textFieldDestination) or copied to the clipboard"
            : "\(textFieldDestination) when available"

        if session.improveFailed {
            return "Improve failed, so the raw transcript is \(destination)."
        }

        if wasImproved {
            return "Improved text is \(destination)."
        }

        switch autoImproveMode {
        case .off:
            return "Raw transcript is \(destination)."
        case .manual:
            return "Transcript is \(destination). Open Preview to improve it."
        case .automatic:
            return "Transcript is \(destination)."
        }
    }

    private func failWithMessage(_ message: String) {
        unregisterActiveRecordingHotKeys()
        resetRecordingTriggerState(reason: "terminal failure: \(message)")
        discardBackupMicrophone()
        endMicrophoneUseLock()
        session.message = message
        phase = .failed
        processingVisualState = .failed
        recordingStartedAt = nil
        walkieTalkieIsLatchedForDisplay = false
        statusMessage = message
        hideProcessingSignal?()
        showPreview?()
    }

    private func recordOpenAIRealtimeDiagnostics(_ diagnostics: OpenAIRealtimeDiagnostics) {
        guard !diagnostics.isEmpty else { return }
        lastOpenAIRealtimeDiagnostics = diagnostics
        recordDiagnosticEvent(
            subsystem: .openAIRealtime,
            severity: .error,
            summary: diagnostics.summary,
            details: diagnostics.details,
            relatedProvider: "OpenAI Realtime"
        )
        menuNeedsUpdate?()
        NSLog("Last OpenAI realtime diagnostics: \(diagnostics.details)")
    }

    private func recordDiagnosticEvent(
        subsystem: DiagnosticSubsystem,
        severity: DiagnosticSeverity,
        summary: String,
        details: String,
        relatedProvider: String?
    ) {
        let event = DiagnosticEvent(
            id: UUID(),
            createdAt: Date(),
            subsystem: subsystem,
            severity: severity,
            summary: summary,
            details: details,
            relatedProvider: relatedProvider
        )
        diagnosticEvents = Array(([event] + diagnosticEvents).prefix(5))
        environment.diagnostics.record(event)
    }

    private func logRecordingStartup(_ message: String, requestedAt: Date) {
        let elapsed = String(format: "%.3f", Date().timeIntervalSince(requestedAt))
        recordingStartupLogger.info("\(message, privacy: .public) after \(elapsed, privacy: .public)s.")
    }

    private func beginMicrophoneUseLock(reason: String) {
        microphoneUseLockHeartbeatTask?.cancel()
        let microphoneUseLock = environment.microphoneUseLock
        microphoneUseLock.write(reason: reason)
        microphoneUseLockHeartbeatTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                microphoneUseLock.write(reason: reason)
            }
        }
    }

    private func endMicrophoneUseLock() {
        microphoneUseLockHeartbeatTask?.cancel()
        microphoneUseLockHeartbeatTask = nil
        environment.microphoneUseLock.clear()
    }

    private func latestOpenAIRealtimeDiagnostics() -> OpenAIRealtimeDiagnostics? {
        environment.diagnostics
            .latestEvents(limit: 20)
            .first { $0.subsystem == .openAIRealtime }
            .map { OpenAIRealtimeDiagnostics(summary: $0.summary, details: $0.details) }
    }

    private func legacyOpenAIRealtimeDiagnostics() -> OpenAIRealtimeDiagnostics? {
        let savedOpenAISummary = defaults.string(forKey: Keys.lastOpenAIRealtimeErrorSummary) ?? ""
        let savedOpenAIDetails = defaults.string(forKey: Keys.lastOpenAIRealtimeErrorDetails) ?? ""
        let diagnostics = OpenAIRealtimeDiagnostics(summary: savedOpenAISummary, details: savedOpenAIDetails)
        return diagnostics.isEmpty ? nil : diagnostics
    }

    private func saveSettings(reason: SettingsSaveReason, debounced: Bool = false) {
        let snapshot = currentSettingsSnapshot()
        if debounced {
            environment.settings.saveDebounced(snapshot, reason: reason)
        } else {
            environment.settings.save(snapshot, reason: reason)
        }
    }

    private func saveCredentials(debounced: Bool = false) {
        let credentials = ProviderCredentials(
            openAIAPIKey: apiKey,
            geminiAPIKey: geminiAPIKey,
            anthropicAPIKey: anthropicAPIKey
        )
        if debounced {
            environment.secrets.saveCredentialsDebounced(credentials)
        } else {
            environment.secrets.saveCredentials(credentials)
        }
    }

    private func currentSettingsSnapshot() -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            autoImproveMode: autoImproveMode,
            recordingTriggerMode: recordingTriggerMode,
            recordingHotKey: recordingHotKey,
            transcriptionMode: transcriptionMode,
            improvementMode: improvementMode,
            thresholdWords: thresholdWords,
            modificationStrength: modificationStrength,
            outputMode: outputMode,
            ollama: OllamaSettings(
                baseURL: ollamaBaseURL,
                model: ollamaModel
            ),
            preferredMicrophoneID: preferredMicrophoneID,
            completion: GlobalCompletionSettings(
                copyFinishedTextToClipboard: copyFinishedTextToClipboard,
                autoSubmitDetectedTextFields: autoSubmitDetectedTextFields
            ),
            appDeliveryRules: appDeliveryRules
        )
    }

    private func copyToPasteboard(_ text: String) {
        environment.delivery.copy(text)
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

private extension RecorderPhase {
    var canCancelActiveRecording: Bool {
        switch self {
        case .starting, .recording:
            return true
        case .idle, .transcribing, .improving, .delivering, .ready, .failed:
            return false
        }
    }
}
