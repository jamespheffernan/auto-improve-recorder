import AVFoundation
import XCTest
@testable import AutoImproveRecorderCore

/// The recording session handle `AppState` holds for a recording: when it is begun, what reaches
/// it, how each ending finishes or cancels it, and that the recording keeps the mode it started in.
@MainActor
final class AppStateRecordingHandleTests: XCTestCase {
    private var harness: AppStateHarness?

    override func tearDown() async throws {
        harness?.cleanUp()
        harness = nil
    }

    private func makeHarness(
        devices: [AudioInputDevice] = [.systemDefault],
        settings: @escaping (inout AppSettingsSnapshot) -> Void = { _ in }
    ) throws -> AppStateHarness {
        let harness = try AppStateHarness(devices: devices, backupMicrophoneEnabled: false, settings: settings)
        self.harness = harness
        return harness
    }

    private func capturedBuffer(sequence: UInt64 = 1) throws -> CapturedAudioBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000))
        buffer.frameLength = 4_000
        return try XCTUnwrap(CapturedAudioBuffer.copying(sequence: sequence, buffer: buffer))
    }

    private func onlyHandle(_ harness: AppStateHarness, file: StaticString = #filePath, line: UInt = #line) throws -> FakeRecordingHandle {
        XCTAssertEqual(harness.transcription.handles.count, 1, file: file, line: line)
        return try XCTUnwrap(harness.transcription.handles.values.first, file: file, line: line)
    }

    func testEveryModeBeginsOneHandleBeforeCaptureFeedsItAndFinishesItAtStop() async throws {
        for mode in TranscriptionMode.allCases {
            let harness = try makeHarness(settings: { $0.transcriptionMode = mode })
            let recorderStartsAtBegin = Recorded<Int>()
            harness.transcription.onBegin = { [recorder = harness.recorder] in
                recorderStartsAtBegin.append(recorder.startedMicrophoneIDs.count)
            }

            await harness.startAndWaitForRecording()
            let handle = try onlyHandle(harness)
            XCTAssertEqual(recorderStartsAtBegin.values, [0], "\(mode)")
            XCTAssertEqual(handle.request.mode, mode)
            XCTAssertTrue(handle.request.attachedToCapture, "\(mode)")

            try XCTUnwrap(harness.recorder.streamHandler)(.captured(try capturedBuffer()))
            XCTAssertEqual(handle.events.values, ["captured"], "\(mode)")

            harness.markBeforeEnding()
            harness.appState.stopRecording()
            XCTAssertEqual(harness.appState.statusMessage, AIRTranscriberCatalog.stopStatus(for: mode))
            await harness.waitForDelivery()

            let draft = try XCTUnwrap(harness.archive.preparedDrafts.first)
            XCTAssertEqual(handle.finishedURLs.values, [draft.audioURL], "\(mode)")
            XCTAssertEqual(handle.cancels.count, 0, "\(mode)")
            XCTAssertEqual(harness.transcription.handles.count, 1, "\(mode)")
            XCTAssertEqual(harness.delivery.requests.values.map(\.text), ["hello world"], "\(mode)")
            XCTAssertEqual(harness.appState.session.rawTranscript, "hello world", "\(mode)")
            XCTAssertEqual(harness.archive.savedRecords.last?.transcriptionMode, mode.rawValue)
            XCTAssertTrue(harness.archive.savedRecords.contains { $0.transcriptionEngine == "Fake Engine" }, "\(mode)")
            harness.assertTornDown(recorderStops: 1)
            harness.cleanUp()
            self.harness = nil
        }
    }

    func testModeAndKeyChangedMidRecordingKeepTheModeAndUseTheNewKey() async throws {
        let harness = try makeHarness(settings: { $0.transcriptionMode = .localParakeetCppFast })
        let appState = harness.appState
        await harness.startAndWaitForRecording()

        appState.transcriptionMode = .openAIAPI
        appState.apiKey = "sk-changed"
        harness.markBeforeEnding()
        appState.stopRecording()
        XCTAssertEqual(appState.statusMessage, "Transcribing with Parakeet.cpp Fast.")
        await harness.waitForDelivery()

        let request = try XCTUnwrap(harness.transcription.requests.values.first)
        XCTAssertEqual(request.mode, .localParakeetCppFast)
        XCTAssertEqual(request.apiKey, "sk-changed")
        XCTAssertEqual(harness.transcription.handles.count, 1)
        XCTAssertFalse(harness.archive.savedRecords.isEmpty)
        for record in harness.archive.savedRecords {
            XCTAssertEqual(record.transcriptionMode, TranscriptionMode.localParakeetCppFast.rawValue)
        }
        XCTAssertEqual(appState.transcriptionMode, .openAIAPI)
    }

    func testMicrophoneRestartCancelsTheHandleAndBeginsANewOneInTheSameMode() async throws {
        let preferred = AudioInputDevice(
            id: "mic-preferred", name: "Preferred Mic", coreAudioDeviceID: nil, transportType: nil,
            isConnected: true, isInputCapable: true, isSystemDefault: false
        )
        let builtIn = AudioInputDevice(
            id: "mic-builtin", name: "Built-in Mic", coreAudioDeviceID: nil, transportType: nil,
            isConnected: true, isInputCapable: true, isSystemDefault: true
        )
        let harness = try makeHarness(devices: [preferred, builtIn], settings: {
            $0.preferredMicrophoneID = "mic-preferred"
            $0.transcriptionMode = .localParakeetStreaming
        })
        await harness.startAndWaitForRecording()
        harness.appState.transcriptionMode = .localWhisper

        // Exact digital silence on the preferred microphone makes AppState restart on the fallback.
        let silence = try capturedBuffer()
        await harness.waitUntil("the recorder to restart on the fallback microphone") {
            guard harness.recorder.startedMicrophoneIDs.count < 2 else { return true }
            harness.recorder.streamHandler?(.captured(silence))
            return false
        }

        let handles = harness.transcription.handles.values
        XCTAssertEqual(handles.count, 2)
        XCTAssertEqual(handles[0].cancels.count, 1)
        XCTAssertEqual(handles[1].request.mode, .localParakeetStreaming)
        XCTAssertTrue(handles[1].request.attachedToCapture)
        XCTAssertEqual(handles[1].cancels.count, 0)

        try XCTUnwrap(harness.recorder.streamHandler)(.captured(silence))
        XCTAssertEqual(handles[1].events.values, ["captured"])
        harness.appState.stopRecording()
        XCTAssertEqual(harness.appState.statusMessage, "Finalizing live Parakeet transcript.")
        await harness.waitForDelivery()
        XCTAssertEqual(handles[0].finishedURLs.count, 0)
        XCTAssertEqual(handles[1].finishedURLs.count, 1)
        XCTAssertEqual(harness.transcription.requests.values.map(\.mode), [.localParakeetStreaming])
    }

    func testLateSilenceReportFromAnEarlierRecordingDoesNotRestartTheCurrentOne() async throws {
        let preferred = AudioInputDevice(
            id: "mic-preferred", name: "Preferred Mic", coreAudioDeviceID: nil, transportType: nil,
            isConnected: true, isInputCapable: true, isSystemDefault: false
        )
        let builtIn = AudioInputDevice(
            id: "mic-builtin", name: "Built-in Mic", coreAudioDeviceID: nil, transportType: nil,
            isConnected: true, isInputCapable: true, isSystemDefault: true
        )
        let harness = try makeHarness(devices: [preferred, builtIn], settings: {
            $0.preferredMicrophoneID = "mic-preferred"
        })
        await harness.startAndWaitForRecording()
        let firstRecordingsHandler = try XCTUnwrap(harness.recorder.streamHandler)
        harness.appState.cancelRecording()

        // The second recording uses the same microphone, so its resolution equals the first's.
        await harness.startAndWaitForRecording()
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-preferred", "mic-preferred"])

        // Three silent buffers make the first recording's health monitor report startup silence
        // now, after that recording ended.
        let silence = try capturedBuffer()
        for _ in 0..<3 {
            firstRecordingsHandler(.captured(silence))
        }
        for _ in 0..<25 {
            try await Task.sleep(nanoseconds: 2_000_000)
        }

        XCTAssertTrue(harness.appState.isRecording)
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-preferred", "mic-preferred"])
        XCTAssertEqual(harness.recorder.stopCount, 1)
        XCTAssertNil(harness.appState.statusMessage)
        let handles = harness.transcription.handles.values
        XCTAssertEqual(handles.count, 2)
        XCTAssertEqual(handles[1].cancels.count, 0)

        // Silence from the current recording's own handler still restarts it on the fallback.
        await harness.waitUntil("the current recording to restart on the fallback microphone") {
            guard harness.recorder.startedMicrophoneIDs.count < 3 else { return true }
            harness.recorder.streamHandler?(.captured(silence))
            return false
        }
        XCTAssertEqual(harness.recorder.startedMicrophoneIDs, ["mic-preferred", "mic-preferred", "mic-builtin"])
        XCTAssertEqual(harness.appState.statusMessage, "Could not hear Preferred Mic; using Built-in Mic.")
    }

    func testCancelWhileRecordingCancelsTheHandleWithoutFinishingIt() async throws {
        let harness = try makeHarness()
        await harness.startAndWaitForRecording()
        harness.appState.cancelRecording()

        let handle = try onlyHandle(harness)
        XCTAssertEqual(handle.cancels.count, 1)
        XCTAssertEqual(handle.finishedURLs.count, 0)
        XCTAssertEqual(harness.appState.statusMessage, "Recording cancelled.")
    }

    func testStopWithoutTranscribingCancelsTheHandle() async throws {
        let harness = try makeHarness()
        await harness.startAndWaitForRecording()
        harness.appState.stopRecording(shouldTranscribe: false)

        let handle = try onlyHandle(harness)
        XCTAssertEqual(handle.cancels.count, 1)
        XCTAssertEqual(handle.finishedURLs.count, 0)
        XCTAssertEqual(harness.appState.statusMessage, "Recording discarded.")
    }

    func testStopWithNoAudioFileCancelsTheHandle() async throws {
        let harness = try makeHarness()
        harness.recorder.stopReturnsFile = false
        await harness.startAndWaitForRecording()
        harness.appState.stopRecording()

        let handle = try onlyHandle(harness)
        XCTAssertEqual(handle.cancels.count, 1)
        XCTAssertEqual(handle.finishedURLs.count, 0)
        XCTAssertEqual(harness.appState.phase, .failed)
    }

    func testRecorderStartFailureCancelsTheHandle() async throws {
        let harness = try makeHarness()
        harness.recorder.failsEveryStart = true
        harness.appState.startRecording()
        await harness.waitUntil("the start to fail") { harness.appState.phase == .failed }

        let handle = try onlyHandle(harness)
        XCTAssertEqual(handle.cancels.count, 1)
        XCTAssertEqual(handle.events.count, 0)
        XCTAssertEqual(handle.finishedURLs.count, 0)
    }

    func testCaptureFailureReachesTheHandleAndStopCancelsItWithoutTranscribing() async throws {
        let harness = try makeHarness()
        await harness.startAndWaitForRecording()
        let failure = AudioCaptureFailure.sharedBufferAllocationFailed(sequence: 1)
        try XCTUnwrap(harness.recorder.streamHandler)(.failure(failure))
        harness.appState.stopRecording()

        let handle = try onlyHandle(harness)
        XCTAssertEqual(handle.events.values, ["failure"])
        XCTAssertEqual(handle.cancels.count, 1)
        XCTAssertEqual(handle.finishedURLs.count, 0)
        XCTAssertTrue(harness.transcription.requests.values.isEmpty)
        XCTAssertEqual(harness.appState.phase, .failed)
        XCTAssertEqual(harness.appState.statusMessage, failure.localizedDescription)
    }

    // MARK: Fastest

    func testFastestBeginsOneHandlePreparesItAfterTheRecorderStartsAndFinishesIt() async throws {
        let harness = try makeHarness { $0.transcriptionMode = .fastest }
        let recorderWasRunningAtPrepare = Recorded<Bool>()
        harness.transcription.onPrepare = { recorderWasRunningAtPrepare.append(harness.recorder.isRecording) }
        harness.transcription.prepareStatus = "Recording with OpenAI realtime transcription."
        harness.transcription.stopStatus = "Finalizing OpenAI streaming transcript."

        await harness.startAndWaitForRecording()
        await harness.waitUntil("the prepare status to be shown") {
            harness.appState.statusMessage == "Recording with OpenAI realtime transcription."
        }
        harness.appState.stopRecording()
        XCTAssertEqual(harness.appState.statusMessage, "Finalizing OpenAI streaming transcript.")
        await harness.waitForDelivery()

        let handle = try onlyHandle(harness)
        XCTAssertEqual(recorderWasRunningAtPrepare.values, [true])
        XCTAssertEqual(handle.prepares.count, 1)
        XCTAssertEqual(handle.captureWillStops.count, 1)
        XCTAssertEqual(handle.finishedURLs.count, 1)
        XCTAssertEqual(handle.cancels.count, 0)
    }

    func testStatusesFromACancelledFastestHandleAreNotShown() async throws {
        let harness = try makeHarness { $0.transcriptionMode = .fastest }
        harness.transcription.realtimeGate = Gate(open: false)
        harness.transcription.prepareStatus = "Recording with OpenAI realtime transcription."
        await harness.startAndWaitForRecording()
        await harness.waitUntil("prepare to begin") { harness.transcription.realtimePreparations.count == 1 }

        harness.appState.cancelRecording()
        harness.transcription.realtimeGate.open()
        await harness.waitUntil("prepare to return") { harness.transcription.realtimePreparationWasCancelled.count == 1 }
        let handle = try onlyHandle(harness)
        await handle.send(.status("late status"))
        await handle.send(.diagnostic(TranscriptionDiagnostic(summary: "late summary", details: "late details")))
        await Task.yield()

        XCTAssertEqual(handle.cancels.count, 1)
        XCTAssertEqual(harness.appState.statusMessage, "Recording cancelled.")
        XCTAssertNil(harness.appState.lastOpenAIRealtimeDiagnostics)
    }

    func testDiagnosticFromTheRecordingHandleIsRecorded() async throws {
        let harness = try makeHarness { $0.transcriptionMode = .fastest }
        await harness.startAndWaitForRecording()

        await try onlyHandle(harness).send(.diagnostic(TranscriptionDiagnostic(summary: "summary", details: "details")))

        XCTAssertEqual(
            harness.appState.lastOpenAIRealtimeDiagnostics,
            OpenAIRealtimeDiagnostics(summary: "summary", details: "details")
        )
    }

    func testFastestMicrophoneRestartReplacesTheHandleAndPreparesTheNewOne() async throws {
        let preferred = AudioInputDevice(
            id: "mic-preferred", name: "Preferred Mic", coreAudioDeviceID: nil, transportType: nil,
            isConnected: true, isInputCapable: true, isSystemDefault: false
        )
        let builtIn = AudioInputDevice(
            id: "mic-builtin", name: "Built-in Mic", coreAudioDeviceID: nil, transportType: nil,
            isConnected: true, isInputCapable: true, isSystemDefault: true
        )
        let harness = try makeHarness(devices: [preferred, builtIn], settings: {
            $0.preferredMicrophoneID = "mic-preferred"
            $0.transcriptionMode = .fastest
        })
        await harness.startAndWaitForRecording()

        let silence = try capturedBuffer()
        await harness.waitUntil("the recorder to restart on the fallback microphone") {
            guard harness.recorder.startedMicrophoneIDs.count < 2 else { return true }
            harness.recorder.streamHandler?(.captured(silence))
            return false
        }
        await harness.waitUntil("both handles to be prepared") { harness.transcription.realtimePreparations.count == 2 }

        let handles = harness.transcription.handles.values
        XCTAssertEqual(handles.count, 2)
        XCTAssertEqual(handles[0].cancels.count, 1)
        XCTAssertEqual(handles[1].request.mode, .fastest)
        XCTAssertEqual(handles[1].prepares.count, 1)
        XCTAssertEqual(handles[1].cancels.count, 0)
        harness.appState.stopRecording()
        await harness.waitForDelivery()
        XCTAssertEqual(handles[0].finishedURLs.count, 0)
        XCTAssertEqual(handles[1].finishedURLs.count, 1)
    }

    func testCaptureFailureRejectsTheRecordingWithTheSameMessageInFastestAndInAFileMode() async throws {
        for mode in [TranscriptionMode.fastest, .localParakeetCppRecommended] {
            let harness = try makeHarness { $0.transcriptionMode = mode }
            await harness.startAndWaitForRecording()
            let failure = AudioCaptureFailure.sharedBufferAllocationFailed(sequence: 1)
            try XCTUnwrap(harness.recorder.streamHandler)(.failure(failure))
            harness.appState.stopRecording()

            let handle = try onlyHandle(harness)
            XCTAssertEqual(handle.cancels.count, 1, "\(mode)")
            XCTAssertEqual(handle.finishedURLs.count, 0, "\(mode)")
            XCTAssertTrue(harness.transcription.requests.values.isEmpty, "\(mode)")
            XCTAssertEqual(harness.appState.phase, .failed, "\(mode)")
            XCTAssertEqual(harness.appState.statusMessage, failure.localizedDescription, "\(mode)")
        }
    }
}
