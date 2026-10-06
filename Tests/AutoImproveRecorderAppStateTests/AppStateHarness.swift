import Combine
import XCTest
@testable import AutoImproveRecorderCore

/// An `AppState` built on fakes, plus what its callbacks and published phase recorded.
@MainActor
final class AppStateHarness {
    let delivery = FakeDeliveryService()
    let settings: InMemorySettingsStore
    let secrets = InMemorySecretsStore()
    let archive: TemporaryTranscriptArchiveClient
    let diagnostics = InMemoryDiagnosticsStore()
    let permissions = FakePermissionsClient()
    let recorder = FakeRecordingClient()
    let transcription = FakeTranscriptionService()
    let improvement = FakeImprovementService()
    let microphoneDevices = FakeMicrophoneDeviceClient()
    let microphoneUseLock = FakeMicrophoneUseLockClient()
    let enginePrewarm = FakeEnginePrewarmClient()
    let appState: AppState

    private(set) var phases: [RecorderPhase] = []
    private(set) var latchUnregisterCount = 0
    private(set) var cancelHotKeyRegisterCount = 0
    private(set) var cancelHotKeyUnregisterCount = 0
    private(set) var previewShownCount = 0
    private var latchUnregistersAtMark = 0
    private var cancelHotKeyUnregistersAtMark = 0

    private let rootURL: URL
    private let defaultsSuiteName: String
    private var cancellables = Set<AnyCancellable>()

    init(
        devices: [AudioInputDevice] = [.systemDefault],
        settings configureSettings: (inout AppSettingsSnapshot) -> Void = { _ in }
    ) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("air-appstate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defaultsSuiteName = "air-appstate-tests-\(UUID().uuidString)"

        var snapshot = AppSettingsSnapshot(
            autoImproveMode: .automatic,
            recordingTriggerMode: .walkieTalkie,
            recordingHotKey: .defaultValue,
            transcriptionMode: .localPhonon2,
            improvementMode: .ollamaLocal,
            thresholdWords: 35,
            modificationStrength: 2,
            outputMode: .lightCleanup,
            ollama: OllamaSettings(baseURL: "http://127.0.0.1:11434", model: "fake-model"),
            preferredMicrophoneID: "",
            completion: GlobalCompletionSettings(
                copyFinishedTextToClipboard: true,
                autoSubmitDetectedTextFields: false
            ),
            appDeliveryRules: []
        )
        configureSettings(&snapshot)
        settings = InMemorySettingsStore(snapshot: snapshot)
        archive = TemporaryTranscriptArchiveClient(
            rootURL: rootURL.appendingPathComponent("Archive", isDirectory: true)
        )
        microphoneDevices.devices = devices

        appState = AppState(
            environment: AppEnvironment(
                delivery: delivery,
                settings: settings,
                secrets: secrets,
                archive: archive,
                diagnostics: diagnostics,
                permissions: permissions,
                recording: recorder,
                transcription: transcription,
                improvement: improvement,
                dictionaryStore: UserDictionaryStore(
                    directoryURL: rootURL.appendingPathComponent("Dictionary", isDirectory: true)
                ),
                legacyDefaults: UserDefaults(suiteName: defaultsSuiteName)!,
                microphoneDevices: microphoneDevices,
                microphoneUseLock: microphoneUseLock,
                enginePrewarm: enginePrewarm,
                runningApps: { [] }
            )
        )

        appState.registerWalkieTalkieLatchHotKey = { _ in
            WalkieTalkieLatchHotKeyRegistration(
                unmodifiedSpaceRegistered: true,
                spaceWhileHoldingTriggerRegistered: true
            )
        }
        appState.unregisterWalkieTalkieLatchHotKey = { [weak self] in self?.latchUnregisterCount += 1 }
        appState.registerCancelHotKey = { [weak self] in self?.cancelHotKeyRegisterCount += 1 }
        appState.unregisterCancelHotKey = { [weak self] in self?.cancelHotKeyUnregisterCount += 1 }
        appState.showPreview = { [weak self] in self?.previewShownCount += 1 }
        appState.$phase
            .sink { [weak self] phase in self?.phases.append(phase) }
            .store(in: &cancellables)
    }

    func cleanUp() {
        cancellables.removeAll()
        try? FileManager.default.removeItem(at: rootURL)
        UserDefaults().removePersistentDomain(forName: defaultsSuiteName)
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes.
    func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for \(description). Phase: \(appState.phase)", file: file, line: line)
                return
            }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    func startAndWaitForRecording(file: StaticString = #filePath, line: UInt = #line) async {
        appState.startRecording()
        await waitUntil("recording to begin", file: file, line: line) { appState.isRecording }
    }

    /// Waits for the delivery that ends a run with text.
    func waitForDelivery(file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("delivery to finish", file: file, line: line) {
            delivery.requests.count == 1 && appState.phase == .ready
        }
    }

    /// Call just before the action that ends a recording, so `assertTornDown` counts only what the ending did.
    func markBeforeEnding() {
        latchUnregistersAtMark = latchUnregisterCount
        cancelHotKeyUnregistersAtMark = cancelHotKeyUnregisterCount
    }

    /// The teardown effects the fakes can see after any ending.
    func assertTornDown(recorderStops: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(recorder.stopCount, recorderStops, "recorder stop count", file: file, line: line)
        XCTAssertFalse(recorder.isRecording, "recorder still recording", file: file, line: line)
        XCTAssertGreaterThan(
            latchUnregisterCount, latchUnregistersAtMark, "latch hot key not unregistered", file: file, line: line
        )
        XCTAssertGreaterThan(
            cancelHotKeyUnregisterCount, cancelHotKeyUnregistersAtMark, "cancel hot key not unregistered",
            file: file, line: line
        )
        XCTAssertFalse(microphoneUseLock.isHeld, "microphone lock still held", file: file, line: line)
        XCTAssertNil(appState.recordingStartedAt, file: file, line: line)
    }
}
