import XCTest
@testable import AutoImproveRecorderCore

/// Characterization tests: they record what `AppState` does today with every dependency faked.
@MainActor
final class AppStateRecordingFlowTests: XCTestCase {
    private var harness: AppStateHarness!

    override func tearDown() async throws {
        harness?.cleanUp()
        harness = nil
    }

    private func makeHarness(
        devices: [AudioInputDevice] = [.systemDefault],
        settings: (inout AppSettingsSnapshot) -> Void = { _ in }
    ) throws -> AppStateHarness {
        let harness = try AppStateHarness(devices: devices, settings: settings)
        self.harness = harness
        return harness
    }

    private func device(id: String, name: String, isSystemDefault: Bool = false) -> AudioInputDevice {
        AudioInputDevice(
            id: id,
            name: name,
            coreAudioDeviceID: nil,
            transportType: nil,
            isConnected: true,
            isInputCapable: true,
            isSystemDefault: isSystemDefault
        )
    }

    // MARK: Start, stop, transcript, delivery

    func testStartStopTranscribesDeliversAndArchives() async throws {
        let harness = try makeHarness()
        let appState = harness.appState

        appState.startRecording()
        XCTAssertEqual(appState.phase, .starting)
        XCTAssertEqual(appState.statusMessage, "Opening microphone.")
        XCTAssertEqual(harness.microphoneUseLock.reasons.values, ["starting"])

        await harness.waitUntil("recording to begin") { appState.isRecording }
        let draft = try XCTUnwrap(harness.archive.preparedDrafts.first)
        XCTAssertEqual(appState.phase, .recording(draft.audioURL))
        XCTAssertNil(appState.statusMessage)
        XCTAssertNotNil(appState.recordingStartedAt)
        XCTAssertEqual(harness.microphoneUseLock.reasons.values, ["starting", "recording"])
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs.count, 1)
        XCTAssertEqual(harness.enginePrewarm.requests.map(\.transcriptionMode), [.localPhonon2])
        XCTAssertEqual(harness.cancelHotKeyRegisterCount, 2)

        harness.markBeforeEnding()
        appState.stopRecording()
        XCTAssertEqual(appState.phase, .transcribing)
        XCTAssertEqual(appState.statusMessage, "Transcribing with Phonon-2.")
        await harness.waitForDelivery()

        XCTAssertEqual(
            harness.phases,
            [.idle, .starting, .recording(draft.audioURL), .transcribing, .ready, .delivering, .ready]
        )
        XCTAssertEqual(harness.transcription.requests.values.map(\.audioURL), [draft.audioURL])
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["hello world"])
        XCTAssertTrue(harness.improvement.rawTranscripts.values.isEmpty)
        XCTAssertEqual(appState.session.rawTranscript, "hello world")
        XCTAssertEqual(appState.session.deliveredText, "hello world")
        XCTAssertEqual(appState.session.deliveredVia, "auto-paste")
        XCTAssertTrue(appState.showRawTranscript)
        XCTAssertEqual(appState.statusMessage, "Fake delivery finished.")
        XCTAssertEqual(appState.processingVisualState, .pasted)

        // One save after transcription, one after delivery. Both name the engine.
        let records = harness.archive.savedRecords
        XCTAssertEqual(records.map(\.id), [draft.id, draft.id])
        XCTAssertEqual(records.map(\.transcriptionEngine), ["Fake Engine", "Fake Engine"])
        let record = try XCTUnwrap(records.last)
        XCTAssertEqual(record.audioPath, draft.audioURL.path)
        XCTAssertEqual(record.rawTranscript, "hello world")
        XCTAssertEqual(record.cleanedTranscript, "")
        XCTAssertEqual(record.finalTranscript, "hello world")
        XCTAssertEqual(record.recognizerTranscript, "hello world")
        XCTAssertEqual(record.deliveredText, "hello world")
        XCTAssertEqual(record.deliveredVia, "auto-paste")
        XCTAssertFalse(record.improveFailed)
        XCTAssertEqual(record.transcriptionMode, TranscriptionMode.localPhonon2.rawValue)
        XCTAssertEqual(record.autoImproveMode, AutoImproveMode.automatic.rawValue)
        XCTAssertEqual(record.thresholdWords, 35)
        XCTAssertFalse(record.microphoneUsedFallback)

        harness.assertTornDown(recorderStops: 1)
        // The next recording's draft and recorder are prepared once the run ends.
        XCTAssertEqual(harness.archive.preparedDrafts.count, 2)
        XCTAssertEqual(harness.recorder.prepareCount, 1)
    }

    // MARK: Improvement and the word threshold

    func testTranscriptAtWordThresholdIsImprovedAndDelivered() async throws {
        let harness = try makeHarness { $0.thresholdWords = 3 }
        let appState = harness.appState
        harness.transcription.result = .success(TranscriptionResult(text: "alpha beta gamma", engineName: "Fake Engine"))
        harness.improvement.result = .success("Alpha, beta, gamma.")

        await harness.startAndWaitForRecording()
        harness.markBeforeEnding()
        appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertEqual(harness.improvement.rawTranscripts.values, ["alpha beta gamma"])
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["Alpha, beta, gamma."])
        XCTAssertEqual(Array(harness.phases.suffix(5)), [.transcribing, .improving, .ready, .delivering, .ready])
        XCTAssertEqual(appState.session.improvedText, "Alpha, beta, gamma.")
        XCTAssertFalse(appState.session.improveFailed)
        XCTAssertFalse(appState.showRawTranscript)
        let record = try XCTUnwrap(harness.archive.savedRecords.last)
        XCTAssertEqual(record.rawTranscript, "alpha beta gamma")
        XCTAssertEqual(record.cleanedTranscript, "Alpha, beta, gamma.")
        XCTAssertEqual(record.finalTranscript, "Alpha, beta, gamma.")
        XCTAssertEqual(record.deliveredText, "Alpha, beta, gamma.")
        XCTAssertEqual(harness.archive.savedRecords.count, 3)
        harness.assertTornDown(recorderStops: 1)
    }

    func testTranscriptBelowWordThresholdIsDeliveredWithoutImprovement() async throws {
        let harness = try makeHarness { $0.thresholdWords = 3 }
        harness.transcription.result = .success(TranscriptionResult(text: "alpha beta", engineName: "Fake Engine"))

        await harness.startAndWaitForRecording()
        harness.markBeforeEnding()
        harness.appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertTrue(harness.improvement.rawTranscripts.values.isEmpty)
        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["alpha beta"])
        XCTAssertFalse(harness.phases.contains(.improving))
    }

    func testImprovementFailureDeliversRawTranscript() async throws {
        let harness = try makeHarness { $0.thresholdWords = 3 }
        let appState = harness.appState
        harness.transcription.result = .success(TranscriptionResult(text: "alpha beta gamma", engineName: "Fake Engine"))
        harness.improvement.result = .failure(FakeError(message: "Fake improve failed."))

        await harness.startAndWaitForRecording()
        harness.markBeforeEnding()
        appState.stopRecording()
        await harness.waitForDelivery()

        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["alpha beta gamma"])
        XCTAssertTrue(appState.session.improveFailed)
        XCTAssertEqual(appState.session.improvedText, "")
        XCTAssertEqual(appState.session.message, "Improve failed; showing raw transcript. Fake improve failed.")
        XCTAssertTrue(appState.showRawTranscript)
        let record = try XCTUnwrap(harness.archive.savedRecords.last)
        XCTAssertTrue(record.improveFailed)
        XCTAssertEqual(record.finalTranscript, "alpha beta gamma")
        XCTAssertEqual(record.deliveredText, "alpha beta gamma")
        XCTAssertEqual(record.transcriptionEngine, "Fake Engine")
        harness.assertTornDown(recorderStops: 1)
    }

    // MARK: The engine name in the archive record

    func testLastArchiveRecordOfADeliveredRecordingNamesTheEngine() async throws {
        let harness = try makeHarness()
        harness.transcription.result = .success(TranscriptionResult(text: "hello world", engineName: "Engine A"))

        await harness.startAndWaitForRecording()
        harness.appState.stopRecording()
        await harness.waitForDelivery()

        let record = try XCTUnwrap(harness.archive.savedRecords.last)
        XCTAssertEqual(record.deliveredText, "hello world")
        XCTAssertEqual(record.transcriptionEngine, "Engine A")
    }

    func testLastArchiveRecordOfAnImprovedAndDeliveredRecordingNamesTheEngine() async throws {
        let harness = try makeHarness { $0.thresholdWords = 3 }
        harness.transcription.result = .success(TranscriptionResult(text: "alpha beta gamma", engineName: "Engine A"))
        harness.improvement.result = .success("Alpha, beta, gamma.")

        await harness.startAndWaitForRecording()
        harness.appState.stopRecording()
        await harness.waitForDelivery()

        // One save after transcription, one after improvement, one after delivery.
        let records = harness.archive.savedRecords
        XCTAssertEqual(records.map(\.transcriptionEngine), ["Engine A", "Engine A", "Engine A"])
        XCTAssertEqual(records.last?.cleanedTranscript, "Alpha, beta, gamma.")
        XCTAssertEqual(records.last?.deliveredText, "Alpha, beta, gamma.")
    }

    func testArchiveSaveAfterEditingTheTextNamesTheEngine() async throws {
        let harness = try makeHarness()
        harness.transcription.result = .success(TranscriptionResult(text: "hello world", engineName: "Engine A"))

        await harness.startAndWaitForRecording()
        harness.appState.stopRecording()
        await harness.waitForDelivery()
        harness.appState.updateDisplayText("hello there")

        let record = try XCTUnwrap(harness.archive.savedRecords.last)
        XCTAssertEqual(record.rawTranscript, "hello there")
        XCTAssertEqual(record.transcriptionEngine, "Engine A")
    }

    func testFailedRecordingDoesNotNameTheEngineOfTheRecordingBeforeIt() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        harness.transcription.result = .success(TranscriptionResult(text: "hello world", engineName: "Engine A"))
        await harness.startAndWaitForRecording()
        appState.stopRecording()
        await harness.waitForDelivery()
        XCTAssertEqual(harness.archive.savedRecords.last?.transcriptionEngine, "Engine A")

        harness.transcription.result = .failure(FakeError(message: "Fake transcription failed."))
        await harness.startAndWaitForRecording()
        appState.stopRecording()
        await harness.waitUntil("the failure") { appState.phase == .failed }

        let record = try XCTUnwrap(harness.archive.savedRecords.last)
        XCTAssertEqual(record.message, "Fake transcription failed.")
        XCTAssertNil(record.transcriptionEngine)
    }

    // MARK: Cancel and discard

    func testCancelWhileStartingReturnsToIdle() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        harness.permissions.microphone = .notDetermined
        harness.permissions.requestGate = Gate(open: false)

        appState.startRecording()
        await harness.waitUntil("the permission request") { harness.permissions.requestCount.count == 1 }
        XCTAssertEqual(appState.phase, .starting)

        harness.markBeforeEnding()
        appState.cancelRecording()
        XCTAssertEqual(appState.phase, .idle)
        XCTAssertEqual(appState.statusMessage, "Recording cancelled.")
        harness.assertTornDown(recorderStops: 1)

        // The suspended start resumes and stops at its guard without starting the recorder.
        harness.permissions.requestGate.open()
        await harness.waitUntil("the cancelled start to resume") { harness.permissions.rememberCount == 1 }
        XCTAssertEqual(harness.phases, [.idle, .starting, .idle])
        XCTAssertTrue(harness.recorder.startedMicrophoneIDs.isEmpty)
        XCTAssertTrue(harness.archive.savedRecords.isEmpty)
        XCTAssertTrue(harness.delivery.requests.values.isEmpty)
    }

    func testCancelWhileRecordingDiscardsRecording() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        await harness.startAndWaitForRecording()
        let draft = try XCTUnwrap(harness.archive.preparedDrafts.first)

        harness.markBeforeEnding()
        appState.cancelRecording()

        XCTAssertEqual(appState.phase, .idle)
        XCTAssertEqual(appState.processingVisualState, .idle)
        XCTAssertEqual(appState.statusMessage, "Recording cancelled.")
        XCTAssertEqual(appState.session, .empty)
        XCTAssertEqual(harness.archive.deletedDraftIDs, [draft.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.audioURL.path))
        XCTAssertTrue(harness.transcription.requests.values.isEmpty)
        XCTAssertTrue(harness.archive.savedRecords.isEmpty)
        harness.assertTornDown(recorderStops: 1)
    }

    func testStopWithoutTranscribingDiscardsRecording() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        await harness.startAndWaitForRecording()
        let draft = try XCTUnwrap(harness.archive.preparedDrafts.first)

        harness.markBeforeEnding()
        appState.stopRecording(shouldTranscribe: false)

        XCTAssertEqual(appState.phase, .idle)
        XCTAssertEqual(appState.statusMessage, "Recording discarded.")
        XCTAssertEqual(appState.session, .empty)
        XCTAssertEqual(harness.archive.deletedDraftIDs, [draft.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.audioURL.path))
        XCTAssertTrue(harness.transcription.requests.values.isEmpty)
        XCTAssertTrue(harness.archive.savedRecords.isEmpty)
        harness.assertTornDown(recorderStops: 1)
    }

    // MARK: Failures

    func testStopWithNoAudioFileFails() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        await harness.startAndWaitForRecording()
        harness.recorder.stopReturnsFile = false

        harness.markBeforeEnding()
        appState.stopRecording()

        XCTAssertEqual(appState.phase, .failed)
        XCTAssertEqual(appState.statusMessage, "Recording stopped before an audio file was created.")
        XCTAssertEqual(appState.session.message, "Recording stopped before an audio file was created.")
        XCTAssertEqual(harness.previewShownCount, 1)
        XCTAssertTrue(harness.transcription.requests.values.isEmpty)
        XCTAssertTrue(harness.archive.savedRecords.isEmpty)
        harness.assertTornDown(recorderStops: 1)
    }

    func testStopWithNoAudioFileDiscardsTheArchiveDraft() async throws {
        let harness = try makeHarness()
        await harness.startAndWaitForRecording()
        let draft = try XCTUnwrap(harness.archive.preparedDrafts.first)
        harness.recorder.stopReturnsFile = false

        harness.appState.stopRecording()

        XCTAssertEqual(harness.appState.phase, .failed)
        // The draft is deleted and not saved, as on the cancel and discard paths.
        XCTAssertEqual(harness.archive.deletedDraftIDs, [draft.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: draft.directoryURL.path))
        XCTAssertTrue(harness.archive.savedRecords.isEmpty)
    }

    func testTranscriptionFailureFailsAndArchivesMessage() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        harness.transcription.result = .failure(FakeError(message: "Fake transcription failed."))

        await harness.startAndWaitForRecording()
        harness.markBeforeEnding()
        appState.stopRecording()
        await harness.waitUntil("the failure") { appState.phase == .failed }

        XCTAssertEqual(Array(harness.phases.suffix(2)), [.transcribing, .failed])
        XCTAssertEqual(appState.statusMessage, "Fake transcription failed.")
        XCTAssertEqual(appState.session.message, "Fake transcription failed.")
        XCTAssertEqual(appState.processingVisualState, .failed)
        XCTAssertTrue(harness.delivery.requests.values.isEmpty)
        XCTAssertEqual(harness.archive.savedRecords.map(\.message), ["Fake transcription failed."])
        XCTAssertEqual(harness.archive.savedRecords.map(\.rawTranscript), [""])
        harness.assertTornDown(recorderStops: 1)
    }

    func testTranscriptionFailureOpensThePreviewOnce() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        harness.transcription.result = .failure(FakeError(message: "Fake transcription failed."))

        await harness.startAndWaitForRecording()
        appState.stopRecording()
        XCTAssertEqual(harness.previewShownCount, 0)
        await harness.waitUntil("the failure") { appState.phase == .failed }
        await harness.waitUntil("the next draft to be prepared") { harness.archive.preparedDrafts.count == 2 }

        XCTAssertEqual(harness.previewShownCount, 1)
        // The failure is still saved once, with its message.
        XCTAssertEqual(harness.archive.savedRecords.map(\.message), ["Fake transcription failed."])
        XCTAssertEqual(appState.session.message, "Fake transcription failed.")

        // The failed run leaves the next recording able to start.
        harness.transcription.result = .success(TranscriptionResult(text: "hello world", engineName: "Fake Engine"))
        await harness.startAndWaitForRecording()
        appState.stopRecording()
        await harness.waitForDelivery()
        XCTAssertEqual(harness.previewShownCount, 1)
    }

    func testRecorderStartFailureFailsWithoutStoppingRecorder() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        harness.recorder.failsEveryStart = true

        appState.startRecording()
        await harness.waitUntil("the failure") { appState.phase == .failed }

        XCTAssertEqual(harness.phases, [.idle, .starting, .failed])
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs.count, 1)
        XCTAssertEqual(harness.diagnostics.events.map(\.summary), ["Recording start failed"])
        XCTAssertEqual(appState.statusMessage, harness.diagnostics.events.first?.details)
        XCTAssertEqual(harness.archive.deletedDraftIDs, harness.archive.preparedDrafts.map(\.id))
        XCTAssertEqual(harness.previewShownCount, 1)
        // The recorder never started, and this path does not ask it to stop.
        harness.assertTornDown(recorderStops: 0)
    }

    // MARK: Realtime startup task

    func testCancelWhileRecordingCancelsRealtimeStartup() async throws {
        let harness = try makeHarness { $0.transcriptionMode = .fastest }
        let appState = harness.appState
        harness.transcription.realtimeGate = Gate(open: false)

        await harness.startAndWaitForRecording()
        XCTAssertEqual(appState.statusMessage, "Recording for Parakeet fallback.")
        await harness.waitUntil("realtime preparation to begin") { harness.transcription.realtimePreparations.count == 1 }

        harness.markBeforeEnding()
        appState.cancelRecording()
        harness.transcription.realtimeGate.open()
        await harness.waitUntil("realtime preparation to return") {
            harness.transcription.realtimePreparationWasCancelled.count == 1
        }

        XCTAssertEqual(harness.transcription.realtimePreparationWasCancelled.values, [true])
        XCTAssertEqual(appState.phase, .idle)
        harness.assertTornDown(recorderStops: 1)
    }

    func testStopCancelsRealtimeStartupAndTranscribesRecordedFile() async throws {
        let harness = try makeHarness { $0.transcriptionMode = .fastest }
        let appState = harness.appState
        harness.transcription.realtimeGate = Gate(open: false)

        await harness.startAndWaitForRecording()
        await harness.waitUntil("realtime preparation to begin") { harness.transcription.realtimePreparations.count == 1 }

        harness.markBeforeEnding()
        appState.stopRecording()
        XCTAssertEqual(appState.statusMessage, "Transcribing with Parakeet.cpp Recommended.")
        harness.transcription.realtimeGate.open()
        await harness.waitForDelivery()
        await harness.waitUntil("realtime preparation to return") {
            harness.transcription.realtimePreparationWasCancelled.count == 1
        }

        XCTAssertEqual(harness.transcription.realtimePreparationWasCancelled.values, [true])
        let request = try XCTUnwrap(harness.transcription.requests.values.first)
        XCTAssertEqual(request.mode, .fastest)
        let handle = try XCTUnwrap(harness.transcription.handles.values.first)
        XCTAssertEqual(handle.captureWillStops.count, 1)
        XCTAssertEqual(handle.cancels.count, 0)
        harness.assertTornDown(recorderStops: 1)
    }

    func testRealtimeStartupThatReturnsNoTranscriberLeavesRecordingRunning() async throws {
        let harness = try makeHarness { $0.transcriptionMode = .fastest }

        await harness.startAndWaitForRecording()
        await harness.waitUntil("realtime preparation to return") {
            harness.transcription.realtimePreparationWasCancelled.count == 1
        }

        XCTAssertEqual(harness.transcription.realtimePreparationWasCancelled.values, [false])
        XCTAssertTrue(harness.appState.isRecording)
        XCTAssertTrue(harness.recorder.isRecording)
    }

    // MARK: Microphone fallback

    func testPreferredMicrophoneStartFailureQuarantinesItAndRecordsOnFallback() async throws {
        let harness = try makeHarness(
            devices: [
                device(id: "mic-preferred", name: "Preferred Mic"),
                device(id: "mic-builtin", name: "Built-in Mic", isSystemDefault: true)
            ],
            settings: { $0.preferredMicrophoneID = "mic-preferred" }
        )
        let appState = harness.appState
        XCTAssertEqual(appState.resolvedMicrophoneSummary, "Using Preferred Mic.")
        harness.recorder.failingMicrophoneIDs = ["mic-preferred"]

        await harness.startAndWaitForRecording()

        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-preferred", "mic-builtin"])
        XCTAssertEqual(appState.resolvedMicrophoneSummary, "Preferred microphone unavailable; using Built-in Mic.")
        XCTAssertTrue(harness.diagnostics.events.isEmpty)

        harness.markBeforeEnding()
        appState.stopRecording()
        await harness.waitForDelivery()
        let record = try XCTUnwrap(harness.archive.savedRecords.first)
        XCTAssertEqual(record.microphonePreferenceID, "mic-preferred")
        XCTAssertEqual(record.microphoneResolvedID, "mic-builtin")
        XCTAssertTrue(record.microphoneUsedFallback)
        XCTAssertNotNil(record.microphoneFallbackReason)

        // The quarantine outlives the recording: the next start goes straight to the fallback.
        appState.startRecording()
        await harness.waitUntil("the second recording") { appState.isRecording }
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-preferred", "mic-builtin", "mic-builtin"])
    }

    // MARK: Superseded start

    func testSupersededStartLeavesNoStaleEffects() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        harness.permissions.microphone = .notDetermined
        harness.permissions.requestGate = Gate(open: false)

        appState.startRecording()
        await harness.waitUntil("the first permission request") { harness.permissions.requestCount.count == 1 }
        harness.markBeforeEnding()
        appState.cancelRecording()
        appState.startRecording()
        await harness.waitUntil("the second permission request") { harness.permissions.requestCount.count == 2 }

        harness.permissions.requestGate.open()
        await harness.waitUntil("both starts to resume") {
            harness.permissions.rememberCount == 2 && appState.isRecording
        }

        // Only the second start reaches the recorder.
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs.count, 1)
        XCTAssertEqual(harness.phases.count, 5)
        XCTAssertEqual(Array(harness.phases.prefix(4)), [.idle, .starting, .idle, .starting])
        XCTAssertEqual(harness.microphoneUseLock.reasons.values, ["starting", "starting", "recording"])

        harness.markBeforeEnding()
        appState.stopRecording()
        await harness.waitForDelivery()
        XCTAssertEqual(harness.transcription.requests.count, 1)
        XCTAssertEqual(Set(harness.archive.savedRecords.map(\.id)).count, 1)
        harness.assertTornDown(recorderStops: 2)
    }

    // MARK: Hot keys

    func testHoldToTalkHotKeyStartsOnPressAndStopsOnRelease() async throws {
        let harness = try makeHarness { $0.recordingTriggerMode = .walkieTalkie }
        let appState = harness.appState

        appState.handleHotKeyEvent(.recordingPressed(receivedAt: Date(), eventID: 1, isRepeat: false))
        XCTAssertEqual(appState.phase, .starting)
        await harness.waitUntil("recording to begin") { appState.isRecording }

        harness.markBeforeEnding()
        appState.handleHotKeyEvent(.recordingReleased(receivedAt: Date().addingTimeInterval(2), eventID: 2))
        await harness.waitForDelivery()

        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["hello world"])
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs.count, 1)
        harness.assertTornDown(recorderStops: 1)
    }

    func testToggleHotKeyStartsOnFirstPressAndStopsOnSecondPress() async throws {
        let harness = try makeHarness { $0.recordingTriggerMode = .toggle }
        let appState = harness.appState

        appState.handleHotKeyEvent(.recordingPressed(receivedAt: Date(), eventID: 1, isRepeat: false))
        await harness.waitUntil("recording to begin") { appState.isRecording }

        appState.handleHotKeyEvent(.recordingReleased(receivedAt: Date().addingTimeInterval(1), eventID: 2))
        XCTAssertTrue(appState.isRecording)

        harness.markBeforeEnding()
        appState.handleHotKeyEvent(
            .recordingPressed(receivedAt: Date().addingTimeInterval(2), eventID: 3, isRepeat: false)
        )
        await harness.waitForDelivery()

        XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["hello world"])
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs.count, 1)
        harness.assertTornDown(recorderStops: 1)
    }

    func testCancelHotKeyWhileRecordingCancels() async throws {
        let harness = try makeHarness()
        let appState = harness.appState
        appState.handleHotKeyEvent(.recordingPressed(receivedAt: Date(), eventID: 1, isRepeat: false))
        await harness.waitUntil("recording to begin") { appState.isRecording }

        harness.markBeforeEnding()
        appState.handleHotKeyEvent(.cancelPressed(receivedAt: Date().addingTimeInterval(1)))

        XCTAssertEqual(appState.phase, .idle)
        XCTAssertEqual(appState.statusMessage, "Recording cancelled.")
        XCTAssertTrue(harness.transcription.requests.values.isEmpty)
        harness.assertTornDown(recorderStops: 1)
    }
}
