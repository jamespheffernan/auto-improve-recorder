import AVFoundation
import XCTest
@testable import AutoImproveRecorderCore

/// The backup microphone and the silence watch in `AppState`, on fakes. No audio is recorded.
@MainActor
final class AppStateBackupMicrophoneTests: XCTestCase {
    private var harness: AppStateHarness!
    private var nextSequence: UInt64 = 0

    private let mainFile = "audio.wav"
    private let backupFile = "audio-backup.wav"
    private let backupNote = "Used the backup microphone (Built-in Mic)."

    override func tearDown() async throws {
        harness?.cleanUp()
        harness = nil
    }

    private func microphone(id: String, name: String, transport: String) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            name: name,
            coreAudioDeviceID: nil,
            transportType: transport,
            isConnected: true,
            isInputCapable: true,
            isSystemDefault: false
        )
    }

    private var usbMicrophone: AudioInputDevice { microphone(id: "mic-usb", name: "USB Mic", transport: "usb") }
    private var builtInMicrophone: AudioInputDevice {
        microphone(id: "mic-builtin", name: "Built-in Mic", transport: "built-in")
    }

    /// A harness whose preferred microphone is the external USB one, with a built-in microphone beside it.
    private func makeHarness(
        devices: [AudioInputDevice]? = nil,
        preferredMicrophoneID: String = "mic-usb",
        backupMicrophoneEnabled: Bool = true
    ) throws -> AppStateHarness {
        let harness = try AppStateHarness(
            devices: devices ?? [usbMicrophone, builtInMicrophone],
            backupMicrophoneEnabled: backupMicrophoneEnabled,
            settings: { $0.preferredMicrophoneID = preferredMicrophoneID }
        )
        self.harness = harness
        return harness
    }

    private func buffer(seconds: Double, level: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frames = AVAudioFrameCount(seconds * 48_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) {
            samples[index] = level
        }
        return buffer
    }

    /// Delivers buffers to the main recorder's stream handler, as the audio thread would.
    private func feedMain(_ harness: AppStateHarness, seconds: Double, level: Float, count: Int = 1) throws {
        let handler = try XCTUnwrap(harness.recorder.streamHandler)
        for _ in 0..<count {
            nextSequence += 1
            let captured = try XCTUnwrap(
                CapturedAudioBuffer.copying(sequence: nextSequence, buffer: buffer(seconds: seconds, level: level))
            )
            handler(.captured(captured))
        }
    }

    /// Feeds silence on the main microphone, and sound on the backup when it runs, until the warning shows.
    private func feedSilenceUntilWarning(_ harness: AppStateHarness, sounds: Int = 1) async throws {
        let silent = try buffer(seconds: 0.25, level: 0)
        let loud = try buffer(seconds: 0.25, level: 0.5)
        await harness.waitUntil("the silent microphone warning") {
            guard harness.warningSounds.count < sounds else { return true }
            if let handler = harness.recorder.streamHandler,
               let captured = CapturedAudioBuffer.copying(sequence: 0, buffer: silent) {
                handler(.captured(captured))
            }
            harness.backupRecorder.onBuffer?(loud)
            return false
        }
    }

    private func setTranscripts(_ harness: AppStateHarness, main: String?, backup: String?) {
        func result(_ text: String?) -> Result<TranscriptionResult, FakeError> {
            text.map { .success(TranscriptionResult(text: $0, engineName: "Fake Engine")) }
                ?? .failure(FakeError(message: "Fake transcription failed."))
        }
        harness.transcription.resultsByAudioFileName = [mainFile: result(main), backupFile: result(backup)]
    }

    private func requestedFiles(_ harness: AppStateHarness) -> [String] {
        harness.transcription.requests.values.map(\.audioURL.lastPathComponent)
    }

    private func assertNoBackupRunning(_ harness: AppStateHarness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(harness.backupRecorder.isRunning, "backup still running", file: file, line: line)
        XCTAssertEqual(
            harness.backupRecorder.stops.count, harness.backupRecorder.startedURLs.count,
            "every started backup is stopped once", file: file, line: line
        )
    }

    // MARK: Starting the backup

    func testExternalMicrophoneStartsBackupAfterMainRecorder() async throws {
        let harness = try makeHarness()
        var mainWasRecordingAtBackupStart: Bool?
        harness.backupRecorder.onStart = { mainWasRecordingAtBackupStart = harness.recorder.isRecording }

        await harness.startAndWaitForRecording()

        let draft = try XCTUnwrap(harness.archive.preparedDrafts.first)
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-usb"])
        XCTAssertEqual(harness.backupRecorder.startedMicrophoneNames, ["Built-in Mic"])
        XCTAssertEqual(
            harness.backupRecorder.startedURLs.map(\.path),
            [draft.directoryURL.appendingPathComponent(backupFile).path]
        )
        XCTAssertEqual(mainWasRecordingAtBackupStart, true)
        XCTAssertNil(harness.appState.statusMessage)
    }

    func testBackupPrefersAnkerWebcamMicrophone() async throws {
        let anker = microphone(id: "mic-anker", name: "Anker PowerConf C200", transport: "usb")
        let harness = try makeHarness(devices: [usbMicrophone, builtInMicrophone, anker])

        await harness.startAndWaitForRecording()

        XCTAssertEqual(harness.backupRecorder.startedMicrophoneNames, ["Anker PowerConf C200"])
    }

    func testBuiltInMicrophoneStartsNoBackup() async throws {
        let harness = try makeHarness(preferredMicrophoneID: "mic-builtin")

        await harness.startAndWaitForRecording()

        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-builtin"])
        XCTAssertTrue(harness.backupRecorder.startedURLs.isEmpty)
    }

    func testSwitchOffStartsNoBackupAndNoSilenceWatch() async throws {
        let harness = try makeHarness(backupMicrophoneEnabled: false)

        await harness.startAndWaitForRecording()
        XCTAssertTrue(harness.backupRecorder.startedURLs.isEmpty)

        // Sound first, so the startup recovery stays out of it. Four seconds of exact silence is
        // then past every threshold of the silence watch.
        try feedMain(harness, seconds: 0.1, level: 0.5)
        try feedMain(harness, seconds: 0.5, level: 0, count: 8)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(harness.appState.statusMessage)
        XCTAssertEqual(harness.warningSounds.count, 0)
        XCTAssertTrue(harness.appState.isRecording)

        harness.appState.stopRecording()
        await harness.waitForDelivery()
        XCTAssertEqual(requestedFiles(harness), [mainFile])
        XCTAssertTrue(harness.backupRecorder.stops.isEmpty)
    }

    func testBackupMicrophoneSwitchIsOnUnlessSetToFalse() throws {
        let suiteName = "air-backup-switch-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(BackupMicrophoneSwitch.key, "backupMicrophoneRecordingEnabled")
        XCTAssertTrue(BackupMicrophoneSwitch.isOn(in: defaults))
        defaults.set(false, forKey: BackupMicrophoneSwitch.key)
        XCTAssertFalse(BackupMicrophoneSwitch.isOn(in: defaults))
        defaults.set(true, forKey: BackupMicrophoneSwitch.key)
        XCTAssertTrue(BackupMicrophoneSwitch.isOn(in: defaults))
    }

    // MARK: Silent microphone warning

    func testSilentMicrophoneWarningNamesBackupPlaysSoundOnceAndKeepsRecording() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        await harness.startAndWaitForRecording()

        try await feedSilenceUntilWarning(harness)

        XCTAssertEqual(appState.statusMessage, "No sound from USB Mic. Recording from Built-in Mic.")
        XCTAssertEqual(harness.warningSounds.count, 1)
        XCTAssertTrue(appState.isRecording)
        XCTAssertEqual(harness.recorder.stopCount, 0)
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-usb"])

        // Sound ends the silent span. A second silent span in the same recording warns no more.
        try feedMain(harness, seconds: 0.25, level: 0.5)
        appState.statusMessage = nil
        for _ in 0..<8 {
            try feedMain(harness, seconds: 0.25, level: 0)
            harness.backupRecorder.onBuffer?(try buffer(seconds: 0.25, level: 0.5))
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(appState.statusMessage)
        XCTAssertEqual(harness.warningSounds.count, 1)
        XCTAssertTrue(appState.isRecording)
        XCTAssertTrue(harness.backupRecorder.isRunning)
    }

    func testSilentMicrophoneWarningWithoutBackupNamesOnlyMainMicrophone() async throws {
        let harness = try makeHarness(preferredMicrophoneID: "mic-builtin")
        await harness.startAndWaitForRecording()

        // Sound first, so the startup recovery stays out of it.
        try feedMain(harness, seconds: 0.1, level: 0.5)
        try await feedSilenceUntilWarning(harness)

        XCTAssertEqual(harness.appState.statusMessage, "No sound from Built-in Mic.")
        XCTAssertEqual(harness.warningSounds.count, 1)
        XCTAssertTrue(harness.appState.isRecording)
        XCTAssertEqual(harness.recorder.stopCount, 0)
    }

    // MARK: Startup recovery

    func testBackupKeepsSilentPreferredMicrophoneRecording() async throws {
        let harness = try makeHarness()
        await harness.startAndWaitForRecording()

        // One second of exact silence is past the startup recovery's 0.75 seconds.
        try feedMain(harness, seconds: 0.1, level: 0, count: 10)
        try await feedSilenceUntilWarning(harness)

        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-usb"])
        XCTAssertEqual(harness.recorder.stopCount, 0)
        XCTAssertTrue(harness.appState.isRecording)
        XCTAssertEqual(harness.appState.resolvedMicrophoneSummary, "Using USB Mic.")
    }

    func testSilentPreferredMicrophoneRestartsOnFallbackWhenBackupFailsToOpen() async throws {
        let harness = try makeHarness()
        harness.backupRecorder.startSucceeds = false
        await harness.startAndWaitForRecording()
        XCTAssertEqual(harness.backupRecorder.startedMicrophoneNames, ["Built-in Mic"])

        try feedMain(harness, seconds: 0.1, level: 0, count: 10)
        await harness.waitUntil("the restart on the fallback") { harness.recorder.startedMicrophoneIDs.count == 2 }

        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-usb", "mic-builtin"])
        XCTAssertEqual(harness.appState.statusMessage, "Could not hear USB Mic; using Built-in Mic.")
        XCTAssertTrue(harness.appState.isRecording)
        XCTAssertEqual(harness.warningSounds.count, 0)
    }

    func testSilentPreferredMicrophoneRestartsOnFallbackWithSwitchOff() async throws {
        let harness = try makeHarness(backupMicrophoneEnabled: false)
        await harness.startAndWaitForRecording()

        try feedMain(harness, seconds: 0.1, level: 0, count: 10)
        await harness.waitUntil("the restart on the fallback") { harness.recorder.startedMicrophoneIDs.count == 2 }

        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-usb", "mic-builtin"])
        XCTAssertTrue(harness.backupRecorder.startedURLs.isEmpty)
    }

    // MARK: Choosing the text

    func testEmptyMainTranscriptUsesBackupText() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: "", backup: "words from the backup")
        await harness.startAndWaitForRecording()

        harness.markBeforeEnding()
        harness.appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertEqual(requestedFiles(harness), [mainFile, backupFile])
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["words from the backup"])
        XCTAssertEqual(harness.appState.session.rawTranscript, "words from the backup")
        XCTAssertEqual(harness.backupRecorder.stops.map(\.waitCount), [1])
        harness.assertTornDown(recorderStops: 1)
        assertNoBackupRunning(harness)
    }

    func testBackupTextUsedArchivesBackupAndSaysSoInStatus() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: "", backup: "words from the backup")
        await harness.startAndWaitForRecording()
        let draft = try XCTUnwrap(harness.archive.preparedDrafts.first)
        let backupURL = draft.directoryURL.appendingPathComponent(backupFile)

        harness.appState.stopRecording()
        await harness.waitForDelivery()
        await harness.waitUntil("the backup note") { harness.appState.statusMessage?.hasSuffix(self.backupNote) == true }

        XCTAssertEqual(harness.appState.statusMessage, "Fake delivery finished. \(backupNote)")
        XCTAssertEqual(harness.appState.session.audioURL?.path, backupURL.path)
        XCTAssertFalse(harness.archive.savedRecords.isEmpty)
        for record in harness.archive.savedRecords {
            XCTAssertEqual(record.audioPath, backupURL.path)
            XCTAssertEqual(record.microphonePreferenceID, "mic-usb")
            XCTAssertEqual(record.microphoneResolvedID, "mic-builtin")
            XCTAssertEqual(record.microphoneResolvedName, "Built-in Mic")
            XCTAssertTrue(record.microphoneUsedFallback)
            XCTAssertEqual(record.microphoneFallbackReason, "backupMicrophone")
            XCTAssertEqual(record.rawTranscript, "words from the backup")
        }
        // The backup file is kept and the unused main file is deleted.
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.audioURL.path))
    }

    func testBackupTextUsedArchivesTheBackupsEngineNameInEverySave() async throws {
        let harness = try makeHarness()
        harness.transcription.resultsByAudioFileName = [
            mainFile: .success(TranscriptionResult(text: "", engineName: "Main Engine")),
            backupFile: .success(TranscriptionResult(text: "words from the backup", engineName: "Backup Engine"))
        ]
        await harness.startAndWaitForRecording()

        harness.appState.stopRecording()
        await harness.waitForDelivery()

        // One save after transcription, one after delivery.
        XCTAssertEqual(harness.archive.savedRecords.map(\.transcriptionEngine), ["Backup Engine", "Backup Engine"])
        XCTAssertEqual(harness.archive.savedRecords.last?.deliveredText, "words from the backup")
    }

    func testMainTranscriptionFailureUsesBackupText() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: nil, backup: "words from the backup")
        await harness.startAndWaitForRecording()

        harness.appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertEqual(requestedFiles(harness), [mainFile, backupFile])
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["words from the backup"])
        XCTAssertNil(harness.appState.session.message)
        assertNoBackupRunning(harness)
    }

    func testSilentWarningUsesBackupWhenItHasMoreWords() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: "short text", backup: "the backup heard many more words")
        await harness.startAndWaitForRecording()
        try await feedSilenceUntilWarning(harness)

        harness.appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertEqual(requestedFiles(harness), [mainFile, backupFile])
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["the backup heard many more words"])
        XCTAssertEqual(harness.archive.savedRecords.last?.microphoneResolvedName, "Built-in Mic")
        assertNoBackupRunning(harness)
    }

    func testSilentWarningKeepsMainWhenItHasMoreWords() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: "the main microphone heard more words", backup: "a few words")
        await harness.startAndWaitForRecording()
        let draft = try XCTUnwrap(harness.archive.preparedDrafts.first)
        try await feedSilenceUntilWarning(harness)

        harness.appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertEqual(requestedFiles(harness), [mainFile, backupFile])
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["the main microphone heard more words"])
        XCTAssertEqual(harness.appState.statusMessage, "Fake delivery finished.")
        let record = try XCTUnwrap(harness.archive.savedRecords.last)
        XCTAssertEqual(record.audioPath, draft.audioURL.path)
        XCTAssertEqual(record.microphoneResolvedName, "USB Mic")
        XCTAssertFalse(record.microphoneUsedFallback)
        // The unused backup file is deleted.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: draft.directoryURL.appendingPathComponent(backupFile).path)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.audioURL.path))
    }

    func testBothTranscriptionsFailingReportsMainFailureAndKeepsBothFiles() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: nil, backup: nil)
        await harness.startAndWaitForRecording()
        let draft = try XCTUnwrap(harness.archive.preparedDrafts.first)

        harness.markBeforeEnding()
        harness.appState.stopRecording()
        await harness.waitUntil("the failure") { harness.appState.phase == .failed }

        XCTAssertEqual(harness.appState.statusMessage, "Fake transcription failed.")
        XCTAssertEqual(harness.archive.savedRecords.map(\.message), ["Fake transcription failed."])
        XCTAssertEqual(harness.archive.savedRecords.map(\.audioPath), [draft.audioURL.path])
        XCTAssertTrue(harness.delivery.requests.values.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draft.audioURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: draft.directoryURL.appendingPathComponent(backupFile).path)
        )
        harness.assertTornDown(recorderStops: 1)
        assertNoBackupRunning(harness)
    }

    func testBothTranscriptsEmptyEndsAsBeforeAndDeletesBackupFile() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: "", backup: "")
        await harness.startAndWaitForRecording()
        let draft = try XCTUnwrap(harness.archive.preparedDrafts.first)

        harness.appState.stopRecording()
        await harness.waitUntil("the run to end") { harness.appState.phase == .ready }

        XCTAssertEqual(harness.appState.statusMessage, "Transcript ready.")
        XCTAssertTrue(harness.delivery.requests.values.isEmpty)
        XCTAssertEqual(harness.archive.savedRecords.last?.audioPath, draft.audioURL.path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: draft.directoryURL.appendingPathComponent(backupFile).path)
        )
    }

    // MARK: Main recording fails at stop

    func testStopWithNoAudioFileContinuesWithBackupText() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: "never read", backup: "words from the backup")
        await harness.startAndWaitForRecording()
        harness.recorder.stopReturnsFile = false

        harness.markBeforeEnding()
        harness.appState.stopRecording()
        XCTAssertEqual(harness.appState.phase, .transcribing)
        await harness.waitForDelivery()
        await harness.waitUntil("the backup note") { harness.appState.statusMessage?.hasSuffix(self.backupNote) == true }

        XCTAssertEqual(requestedFiles(harness), [backupFile])
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["words from the backup"])
        XCTAssertEqual(harness.archive.savedRecords.last?.microphoneResolvedName, "Built-in Mic")
        XCTAssertEqual(harness.previewShownCount, 0)
        harness.assertTornDown(recorderStops: 1)
        assertNoBackupRunning(harness)
    }

    func testStopWithNoAudioFileAndEmptyBackupReportsOriginalFailure() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: "never read", backup: "")
        await harness.startAndWaitForRecording()
        harness.recorder.stopReturnsFile = false

        harness.markBeforeEnding()
        harness.appState.stopRecording()
        await harness.waitUntil("the failure") { harness.appState.phase == .failed }

        XCTAssertEqual(harness.appState.statusMessage, "Recording stopped before an audio file was created.")
        XCTAssertEqual(harness.appState.session.message, "Recording stopped before an audio file was created.")
        XCTAssertEqual(harness.previewShownCount, 1)
        XCTAssertEqual(requestedFiles(harness), [backupFile])
        XCTAssertTrue(harness.delivery.requests.values.isEmpty)
        XCTAssertTrue(harness.archive.savedRecords.isEmpty)
        harness.assertTornDown(recorderStops: 1)
        assertNoBackupRunning(harness)
    }

    func testFastestCaptureFailureAtStopReadsTheBackupWithAHandleThatIsNotAttachedToCapture() async throws {
        let harness = try makeHarness()
        harness.appState.transcriptionMode = .fastest
        setTranscripts(harness, main: "never read", backup: "words from the backup")
        await harness.startAndWaitForRecording()
        try XCTUnwrap(harness.recorder.streamHandler)(.failure(.sharedBufferAllocationFailed(sequence: 1)))

        harness.appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertEqual(requestedFiles(harness), [backupFile])
        XCTAssertEqual(harness.transcription.requests.values.map(\.mode), [.fastest])
        XCTAssertEqual(harness.transcription.requests.values.map(\.attachedToCapture), [false])
        XCTAssertEqual(harness.transcription.handles.values.map(\.prepares.count), [1, 0])
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["words from the backup"])
        assertNoBackupRunning(harness)
    }

    func testCaptureFailureAtStopContinuesWithBackupText() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: "never read", backup: "words from the backup")
        await harness.startAndWaitForRecording()
        try XCTUnwrap(harness.recorder.streamHandler)(.failure(.sharedBufferAllocationFailed(sequence: 1)))

        harness.appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertEqual(requestedFiles(harness), [backupFile])
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["words from the backup"])
        assertNoBackupRunning(harness)
    }

    // MARK: Endings

    func testNormalRunDiscardsBackupWithoutWaiting() async throws {
        let harness = try makeHarness()
        await harness.startAndWaitForRecording()
        XCTAssertTrue(harness.backupRecorder.isRunning)

        harness.markBeforeEnding()
        harness.appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertEqual(requestedFiles(harness), [mainFile])
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["hello world"])
        XCTAssertEqual(harness.backupRecorder.stops.map(\.waitCount), [0])
        XCTAssertEqual(harness.backupRecorder.stops.map(\.discardCount), [1])
        XCTAssertEqual(harness.appState.statusMessage, "Fake delivery finished.")
        XCTAssertEqual(harness.archive.savedRecords.last?.microphoneResolvedName, "USB Mic")
        harness.assertTornDown(recorderStops: 1)
        assertNoBackupRunning(harness)
    }

    func testCancelDiscardsBackup() async throws {
        let harness = try makeHarness()
        await harness.startAndWaitForRecording()

        harness.markBeforeEnding()
        harness.appState.cancelRecording()

        XCTAssertEqual(harness.appState.statusMessage, "Recording cancelled.")
        XCTAssertEqual(harness.backupRecorder.stops.map(\.discardCount), [1])
        XCTAssertTrue(harness.transcription.requests.values.isEmpty)
        harness.assertTornDown(recorderStops: 1)
        assertNoBackupRunning(harness)
    }

    func testStopWithoutTranscribingAndTerminationDiscardBackup() async throws {
        let harness = try makeHarness()
        await harness.startAndWaitForRecording()
        harness.appState.stopRecording(shouldTranscribe: false)
        XCTAssertEqual(harness.backupRecorder.stops.map(\.discardCount), [1])
        assertNoBackupRunning(harness)

        await harness.startAndWaitForRecording()
        XCTAssertTrue(harness.backupRecorder.isRunning)
        harness.appState.prepareForApplicationTermination()
        XCTAssertEqual(harness.backupRecorder.stops.map(\.discardCount), [1, 1])
        assertNoBackupRunning(harness)
    }
}

extension AppStateBackupMicrophoneTests {
    func testBackupSecondTranscriptionKeepsTheRecordingModeWhenTheSettingChanges() async throws {
        let harness = try makeHarness()
        setTranscripts(harness, main: "", backup: "words from the backup")
        await harness.startAndWaitForRecording()
        harness.appState.transcriptionMode = .openAIAPI

        harness.markBeforeEnding()
        harness.appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertEqual(requestedFiles(harness), [mainFile, backupFile])
        XCTAssertEqual(harness.transcription.requests.values.map(\.mode), [.localPhonon2, .localPhonon2])
        // The backup's handle is begun at stop and is never attached to capture.
        XCTAssertEqual(harness.transcription.requests.values.map(\.attachedToCapture), [true, false])
        let handles = harness.transcription.handles.values
        XCTAssertEqual(handles.count, 2)
        XCTAssertTrue(handles[1].events.values.isEmpty)
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["words from the backup"])
    }
}
