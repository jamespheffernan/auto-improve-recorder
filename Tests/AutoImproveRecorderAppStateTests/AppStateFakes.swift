import AVFoundation
import CoreAudio
import Foundation
@testable import AutoImproveRecorderCore

/// Suspends callers of `wait()` until `open()` is called. Starts open unless told otherwise.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = true) {
        isOpen = open
    }

    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let resumed = waiters
        waiters = []
        lock.unlock()
        resumed.forEach { $0.resume() }
    }
}

/// A list that fakes append to from any thread and tests read on the main actor.
final class Recorded<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int { values.count }

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

struct FakeError: LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }
}

final class FakeDeliveryService: DeliveryService {
    var outcome: DeliveryOutcome = .pasted
    var statusMessage = "Fake delivery finished."
    let requests = Recorded<DeliveryRequest>()
    let copiedTexts = Recorded<String>()

    private let context = DeliveryContext(focusedApp: nil, focusedTarget: nil, accessibilityTrusted: true)

    func focusedContext(promptForPermission: Bool) -> DeliveryContext {
        context
    }

    func copy(_ text: String) {
        copiedTexts.append(text)
    }

    func pasteManually(_ text: String) async throws {}

    func deliver(_ request: DeliveryRequest) async -> DeliveryResult {
        requests.append(request)
        return DeliveryResult(
            outcome: outcome,
            statusMessage: statusMessage,
            context: context,
            policy: ResolvedDeliveryPolicy(
                matchedRule: nil,
                shouldCopyToClipboard: false,
                wantsPaste: true,
                shouldPaste: true,
                sendCommand: nil,
                sendWasSuppressedByRule: false
            ),
            errorSummary: nil
        )
    }
}

final class InMemorySettingsStore: SettingsStore {
    var snapshot: AppSettingsSnapshot
    private(set) var saveCount = 0

    init(snapshot: AppSettingsSnapshot) {
        self.snapshot = snapshot
    }

    func load() -> AppSettingsSnapshot {
        snapshot
    }

    func save(_ snapshot: AppSettingsSnapshot, reason: SettingsSaveReason) {
        self.snapshot = snapshot
        saveCount += 1
    }

    func saveDebounced(_ snapshot: AppSettingsSnapshot, reason: SettingsSaveReason) {
        save(snapshot, reason: reason)
    }
}

final class InMemorySecretsStore: SecretsStore {
    var credentials = ProviderCredentials(openAIAPIKey: "", geminiAPIKey: "", anthropicAPIKey: "")

    func loadCredentials() -> ProviderCredentials {
        credentials
    }

    func saveCredentials(_ credentials: ProviderCredentials) {
        self.credentials = credentials
    }

    func saveCredentialsDebounced(_ credentials: ProviderCredentials) {
        self.credentials = credentials
    }
}

final class InMemoryDiagnosticsStore: DiagnosticsStore {
    private(set) var events: [DiagnosticEvent] = []

    func record(_ event: DiagnosticEvent) {
        events.insert(event, at: 0)
    }

    func latestEvents(limit: Int) -> [DiagnosticEvent] {
        Array(events.prefix(limit))
    }

    func clear() {
        events = []
    }
}

/// Prepares drafts under a temporary directory and keeps saved records in memory.
final class TemporaryTranscriptArchiveClient: TranscriptArchiveClient {
    let rootURL: URL
    private(set) var preparedDrafts: [TranscriptArchiveDraft] = []
    private(set) var deletedDraftIDs: [String] = []
    private(set) var savedRecords: [TranscriptArchiveRecord] = []

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func prepareRecording(createdAt: Date) throws -> TranscriptArchiveDraft {
        let id = UUID().uuidString
        let directoryURL = rootURL.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let draft = TranscriptArchiveDraft(
            id: id,
            createdAt: createdAt,
            directoryURL: directoryURL,
            audioURL: directoryURL.appendingPathComponent("audio.wav")
        )
        preparedDrafts.append(draft)
        return draft
    }

    func deleteDraft(_ draft: TranscriptArchiveDraft?) {
        guard let draft else { return }
        deletedDraftIDs.append(draft.id)
        try? FileManager.default.removeItem(at: draft.directoryURL)
    }

    func record(
        draft: TranscriptArchiveDraft,
        content: TranscriptArchiveContent,
        metadata: TranscriptArchiveMetadata
    ) -> TranscriptArchiveRecord {
        // The live client's mapping touches no files, so the tests assert on the real record fields.
        LiveTranscriptArchiveClient().record(draft: draft, content: content, metadata: metadata)
    }

    func save(_ record: TranscriptArchiveRecord) -> Bool {
        savedRecords.append(record)
        return true
    }
}

final class FakePermissionsClient: PermissionsClient, @unchecked Sendable {
    var microphone: PermissionState = .authorized
    /// `requestMicrophone()` waits here, then grants the permission.
    var requestGate = Gate()
    let requestCount = Recorded<Void>()
    private(set) var rememberCount = 0

    var hasMicrophonePermission: Bool { microphone == .authorized }
    var cachedMicrophonePermissionWasGranted: Bool { false }

    func microphoneState() -> PermissionState {
        microphone
    }

    func requestMicrophone() async throws {
        requestCount.append(())
        await requestGate.wait()
        await MainActor.run { microphone = .authorized }
    }

    func rememberMicrophonePermissionGranted() {
        rememberCount += 1
    }

    func accessibilityState(prompt: Bool) -> PermissionState {
        .authorized
    }

    func snapshot(promptForAccessibility: Bool) async -> PermissionStatus {
        PermissionStatus(microphone: .authorized, accessibility: .authorized)
    }
}

final class FakeRecordingClient: RecordingClient {
    var failingMicrophoneIDs: Set<String> = []
    var failsEveryStart = false
    var stopReturnsFile = true
    private(set) var startedMicrophoneIDs: [String?] = []
    private(set) var stopCount = 0
    private(set) var prepareCount = 0
    private(set) var streamHandler: AudioRecorder.AudioBufferHandler?
    private var activeURL: URL?

    var fastStartBufferSize: AVAudioFrameCount { 1024 }
    var isRecording: Bool { activeURL != nil }

    func prepareForFastStartIfAuthorized() {
        prepareCount += 1
    }

    func startRecording(
        at url: URL,
        microphone: AudioInputDevice?,
        bufferSize: AVAudioFrameCount,
        streamHandler: AudioRecorder.AudioBufferHandler?,
        onFirstBuffer: (() -> Void)?
    ) throws -> URL {
        startedMicrophoneIDs.append(microphone?.id)
        if failsEveryStart || failingMicrophoneIDs.contains(microphone?.id ?? "") {
            throw FakeError(message: "Fake recorder could not open \(microphone?.name ?? "the microphone").")
        }
        FileManager.default.createFile(atPath: url.path, contents: Data())
        activeURL = url
        self.streamHandler = streamHandler
        return url
    }

    func stopRecording() -> URL? {
        stopCount += 1
        let url = activeURL
        activeURL = nil
        streamHandler = nil
        return stopReturnsFile ? url : nil
    }

    func releaseWarmResources() {}
}

final class FakeTranscriptionService: TranscriptionService, @unchecked Sendable {
    var result: Result<TranscriptionResult, FakeError> = .success(
        TranscriptionResult(text: "hello world", engineName: "Fake Engine")
    )
    /// Results for requests whose audio file has this name. Other requests get `result`.
    var resultsByAudioFileName: [String: Result<TranscriptionResult, FakeError>] = [:]
    var gate = Gate()
    let requests = Recorded<TranscriptionServiceRequest>()
    let realtimePreparations = Recorded<TranscriptionMode>()
    /// `prepareRealtimeIfNeeded` waits here, then records whether its task was cancelled while it waited.
    /// It always returns nil: `OpenAIRealtimeTranscriber` is a concrete class that opens a network session.
    var realtimeGate = Gate()
    let realtimePreparationWasCancelled = Recorded<Bool>()

    func prepareRealtimeIfNeeded(
        mode: TranscriptionMode,
        apiKey: String,
        dictionarySnapshot: String,
        status: @escaping (String) async -> Void,
        recordDiagnostics: @escaping (OpenAIRealtimeDiagnostics) async -> Void
    ) async -> OpenAIRealtimeTranscriber? {
        realtimePreparations.append(mode)
        await realtimeGate.wait()
        realtimePreparationWasCancelled.append(Task.isCancelled)
        return nil
    }

    func transcribe(
        _ request: TranscriptionServiceRequest,
        status: @escaping (String) async -> Void,
        recordDiagnostics: @escaping (OpenAIRealtimeDiagnostics) async -> Void
    ) async throws -> TranscriptionResult {
        requests.append(request)
        await gate.wait()
        return try (resultsByAudioFileName[request.audioURL.lastPathComponent] ?? result).get()
    }
}

/// A backup recorder that writes an empty file and lets the test deliver buffers and the start result.
final class FakeBackupRecordingClient: BackupRecordingClient {
    var startSucceeds = true
    /// When false the start result waits until the test calls `reportStartResult`.
    var reportsStartResultAtOnce = true
    /// When false a stop gives no file, as when the backup file could not be finished.
    var stopGivesFile = true
    /// Runs at the beginning of every start.
    var onStart: (() -> Void)?
    private(set) var startedMicrophoneNames: [String] = []
    private(set) var startedURLs: [URL] = []
    private(set) var stops: [FakeBackupRecordingStop] = []
    private(set) var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private var onResult: ((Bool) -> Void)?
    private var activeURL: URL?

    var isRunning: Bool { activeURL != nil }

    func start(
        at url: URL,
        microphone: AudioInputDevice,
        onBuffer: @escaping (AVAudioPCMBuffer) -> Void,
        onResult: @escaping (Bool) -> Void
    ) {
        onStart?()
        startedMicrophoneNames.append(microphone.name)
        startedURLs.append(url)
        self.onBuffer = onBuffer
        self.onResult = onResult
        if startSucceeds {
            FileManager.default.createFile(atPath: url.path, contents: Data())
            activeURL = url
        }
        if reportsStartResultAtOnce {
            reportStartResult()
        }
    }

    func reportStartResult() {
        onResult?(startSucceeds)
        onResult = nil
    }

    func stop() -> any BackupRecordingStop {
        let stop = FakeBackupRecordingStop(url: stopGivesFile ? activeURL : nil)
        activeURL = nil
        onBuffer = nil
        stops.append(stop)
        return stop
    }
}

final class FakeBackupRecordingStop: BackupRecordingStop, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL?
    private var waits = 0
    private var discards = 0

    init(url: URL?) {
        self.url = url
    }

    var waitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waits
    }

    var discardCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return discards
    }

    func finishedFile() async -> URL? {
        lock.withLock { waits += 1 }
        return url
    }

    func discard() {
        lock.withLock { discards += 1 }
        if let url {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

final class FakeImprovementService: ImprovementService, @unchecked Sendable {
    var result: Result<String, FakeError> = .success("Improved text.")
    let rawTranscripts = Recorded<String>()

    func improve(_ request: ImprovementServiceRequest) async throws -> String {
        rawTranscripts.append(request.rawTranscript)
        return try result.get()
    }
}

final class FakeMicrophoneDeviceClient: MicrophoneDeviceClient {
    var devices: [AudioInputDevice] = [.systemDefault]
    private(set) var pinnedDeviceIDs: [AudioObjectID] = []
    private(set) var observerCount = 0

    func inputDevices() -> [AudioInputDevice] {
        devices
    }

    func setDefaultInputDeviceID(_ deviceID: AudioObjectID) throws {
        pinnedDeviceIDs.append(deviceID)
    }

    func observeDeviceChanges(_ onDevicesChanged: @escaping () -> Void) -> AnyObject? {
        observerCount += 1
        return nil
    }
}

final class FakeMicrophoneUseLockClient: MicrophoneUseLockClient, @unchecked Sendable {
    let reasons = Recorded<String>()
    private let held = NSLock()
    private var heldValue = false
    private(set) var clearCount = 0

    var isHeld: Bool {
        held.lock()
        defer { held.unlock() }
        return heldValue
    }

    func write(reason: String) {
        reasons.append(reason)
        held.lock()
        heldValue = true
        held.unlock()
    }

    func clear() {
        held.lock()
        heldValue = false
        clearCount += 1
        held.unlock()
    }
}

final class FakeEnginePrewarmClient: EnginePrewarmClient {
    private(set) var requests: [EnginePrewarmRequest] = []

    func prewarm(_ request: EnginePrewarmRequest) {
        requests.append(request)
    }
}
