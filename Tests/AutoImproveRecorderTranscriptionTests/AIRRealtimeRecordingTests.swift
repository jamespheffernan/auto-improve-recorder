import AVFoundation
import XCTest
@testable import AutoImproveRecorderCore

/// The `fastest` handle with a socket startup the test holds open: what it
/// does when stop or cancel arrives first, and what it does with the audio.
final class AIRRealtimeRecordingTests: XCTestCase {
    private let audioURL = URL(fileURLWithPath: "/tmp/recording.wav")
    private static let cliStatuses = [
        "Fastest unavailable; falling back to Parakeet.cpp Recommended.",
        "Transcribing with parakeet.cpp 0.6B v2 Q4_K Metal."
    ]

    private func captured(_ sequence: UInt64) throws -> CapturedAudioBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        return try XCTUnwrap(CapturedAudioBuffer.copying(sequence: sequence, buffer: buffer))
    }

    func testStopBeforeTheSocketIsReadyUsesTheCLIAndCancelsTheLateTranscriber() async throws {
        let fixture = Fixture(startIsHeld: true)
        let handle = fixture.begin()
        handle.receive(.captured(try captured(1)))
        let preparation = Task { await handle.prepare() }
        await fixture.waitFor("realtime start")

        XCTAssertNil(handle.captureWillStop())
        let result = try await handle.finish(audioURL: audioURL)

        XCTAssertEqual(result, TranscriptionResult(text: "cli text", engineName: "parakeet.cpp 0.6B v2 Q4_K Metal"))
        XCTAssertEqual(Array(fixture.statuses.prefix(2)), Self.cliStatuses)
        let statusesAfterFinish = fixture.statuses

        fixture.releaseStart()
        let preparationStatus = await preparation.value
        XCTAssertNil(preparationStatus)
        XCTAssertEqual(fixture.calls, ["realtime create", "realtime start", "cli", "realtime cancel"])
        XCTAssertEqual(fixture.startTaskWasCancelled, [true])
        XCTAssertEqual(fixture.statuses, statusesAfterFinish)
        XCTAssertEqual(fixture.diagnostics, [])
        XCTAssertEqual(fixture.consumer.sequences, [])
    }

    func testStartFailureAfterStopReportsNothing() async throws {
        let fixture = Fixture(startIsHeld: true)
        fixture.startError = FixtureError()
        let handle = fixture.begin()
        let preparation = Task { await handle.prepare() }
        await fixture.waitFor("realtime start")

        XCTAssertNil(handle.captureWillStop())
        fixture.releaseStart()
        let preparationStatus = await preparation.value

        XCTAssertNil(preparationStatus)
        XCTAssertEqual(fixture.calls, ["realtime create", "realtime start", "realtime cancel"])
        XCTAssertEqual(fixture.statuses, [])
        XCTAssertEqual(fixture.diagnostics, [])
    }

    func testCancelBeforeTheSocketIsReadyCancelsTheLateTranscriberAndFinishThrows() async throws {
        let fixture = Fixture(startIsHeld: true)
        let handle = fixture.begin()
        let preparation = Task { await handle.prepare() }
        await fixture.waitFor("realtime start")

        handle.cancel()
        handle.cancel()
        handle.receive(.captured(try captured(1)))
        do {
            _ = try await handle.finish(audioURL: audioURL)
            XCTFail("finish after cancel returned a result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        fixture.releaseStart()
        let preparationStatus = await preparation.value

        XCTAssertNil(preparationStatus)
        XCTAssertEqual(fixture.calls, ["realtime create", "realtime start", "realtime cancel"])
        XCTAssertEqual(fixture.startTaskWasCancelled, [true])
        XCTAssertEqual(fixture.statuses, [])
        XCTAssertEqual(fixture.diagnostics, [])
        XCTAssertEqual(fixture.consumer.sequences, [])
    }

    func testPrepareAfterCancelStartsNothing() async {
        let fixture = Fixture(startIsHeld: false)
        let handle = fixture.begin()

        handle.cancel()
        let preparationStatus = await handle.prepare()

        XCTAssertNil(preparationStatus)
        XCTAssertEqual(fixture.calls, [])
    }

    func testReadyBeforeStopReplaysHeldAudioInOrderThenForwardsAndFinishesOnTheSocket() async throws {
        let fixture = Fixture(startIsHeld: true)
        let handle = fixture.begin()
        handle.receive(.captured(try captured(1)))
        handle.receive(.captured(try captured(2)))
        let preparation = Task { await handle.prepare() }
        await fixture.waitFor("realtime start")
        handle.receive(.captured(try captured(3)))
        XCTAssertEqual(fixture.consumer.sequences, [])

        fixture.releaseStart()
        let preparationStatus = await preparation.value
        XCTAssertEqual(preparationStatus, "Recording with OpenAI realtime transcription.")
        XCTAssertEqual(fixture.consumer.sequences, [1, 2, 3])
        XCTAssertEqual(fixture.consumer.diagnostics.first?.first, "Realtime pending buffers replayed: 3")
        handle.receive(.captured(try captured(4)))
        XCTAssertEqual(fixture.consumer.sequences, [1, 2, 3, 4])

        XCTAssertEqual(handle.captureWillStop(), "Finalizing OpenAI streaming transcript.")
        let result = try await handle.finish(audioURL: audioURL)

        XCTAssertEqual(result, Fixture.realtimeResult)
        XCTAssertEqual(fixture.calls, ["realtime create", "realtime start", "realtime finish"])
        XCTAssertEqual(fixture.statuses.count, 1)
        XCTAssertTrue(fixture.statuses[0].hasPrefix("OpenAI transcript ready in "))
        XCTAssertEqual(fixture.diagnostics, [])
    }

    func testCancelAfterReadyCancelsTheTranscriberOnce() async throws {
        let fixture = Fixture(startIsHeld: false)
        let handle = fixture.begin()
        _ = await handle.prepare()

        handle.cancel()
        handle.cancel()
        await fixture.waitFor("realtime cancel")
        handle.receive(.captured(try captured(1)))

        XCTAssertEqual(fixture.calls, ["realtime create", "realtime start", "realtime cancel"])
        XCTAssertEqual(fixture.consumer.sequences, [])
    }

    func testCaptureFailureIsKeptByTheFastestHandleAndByAFileModeHandle() {
        let failure = AudioCaptureFailure.sharedBufferAllocationFailed(sequence: 7)
        for mode in [TranscriptionMode.fastest, .localParakeetCppRecommended] {
            let handle = Fixture(startIsHeld: false).begin(mode: mode)
            XCTAssertNil(handle.captureFailure, "\(mode)")

            handle.receive(.failure(failure))

            XCTAssertEqual(handle.captureFailure, failure, "\(mode)")
        }
    }

    func testAHandleNotAttachedToCaptureIsNeverPreparedAndUsesTheCLI() async throws {
        let fixture = Fixture(startIsHeld: false)
        let handle = fixture.begin(attachedToCapture: false)

        let preparationStatus = await handle.prepare()
        let result = try await handle.finish(audioURL: audioURL)

        XCTAssertNil(preparationStatus)
        XCTAssertEqual(result.engineName, "parakeet.cpp 0.6B v2 Q4_K Metal")
        XCTAssertEqual(fixture.calls, ["cli"])
    }
}

private struct FixtureError: LocalizedError {
    var errorDescription: String? { "start refused" }
}

/// Scripted realtime and file dependencies. With `startIsHeld`, the socket
/// start waits until `releaseStart()`.
private final class Fixture: @unchecked Sendable {
    static let realtimeResult = TranscriptionResult(text: "three whole words", engineName: "OpenAI Realtime test")

    let consumer = RecordingConsumer()
    var startError: Error?

    private let lock = NSLock()
    private var startIsHeld: Bool
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var recordedCalls: [String] = []
    private var recordedStatuses: [String] = []
    private var recordedDiagnostics: [TranscriptionDiagnostic] = []
    private var recordedStartCancellations: [Bool] = []

    var calls: [String] { lock.withLock { recordedCalls } }
    var statuses: [String] { lock.withLock { recordedStatuses } }
    var diagnostics: [TranscriptionDiagnostic] { lock.withLock { recordedDiagnostics } }
    var startTaskWasCancelled: [Bool] { lock.withLock { recordedStartCancellations } }

    init(startIsHeld: Bool) {
        self.startIsHeld = startIsHeld
    }

    func begin(mode: TranscriptionMode = .fastest, attachedToCapture: Bool = true) -> any RecordingSessionHandle {
        var dependencies = AIRTranscriberCatalog.Dependencies()
        dependencies.transcribeParakeetCpp = { variant, _, _ in
            self.record("cli")
            return TranscriptionResult(text: "cli text", engineName: variant.engineName)
        }
        dependencies.transcribeOpenAIAPI = { _, _, _ in
            self.record("api")
            return TranscriptionResult(text: "api text", engineName: "OpenAI Audio test")
        }
        dependencies.makeRealtimeTranscriber = { apiKey, dictionarySnapshot in
            self.record("realtime create")
            return OpenAIRealtimeTranscriber(apiKey: apiKey, dictionarySnapshot: dictionarySnapshot)
        }
        dependencies.startRealtime = { _ in
            self.record("realtime start")
            await self.waitForStartRelease()
            self.lock.withLock { self.recordedStartCancellations.append(Task.isCancelled) }
            if let startError = self.startError { throw startError }
        }
        dependencies.finishRealtime = { _ in
            self.record("realtime finish")
            return Fixture.realtimeResult
        }
        dependencies.realtimeDiagnostics = { _, summary in
            OpenAIRealtimeDiagnostics(summary: summary, details: "scripted details")
        }
        dependencies.cancelRealtime = { _ in self.record("realtime cancel") }
        dependencies.realtimeAudioConsumer = { _ in self.consumer }
        return LiveTranscriptionService(dependencies: dependencies).beginRecording(
            RecordingTranscriptionRequest(
                mode: mode,
                dictionarySnapshot: "Turf",
                attachedToCapture: attachedToCapture,
                apiKeyAtStart: "sk-test",
                apiKey: { "sk-test" }
            ),
            events: { event in
                self.lock.withLock {
                    switch event {
                    case .status(let status): self.recordedStatuses.append(status)
                    case .diagnostic(let diagnostic): self.recordedDiagnostics.append(diagnostic)
                    }
                }
            }
        )
    }

    func releaseStart() {
        let waiters = lock.withLock {
            startIsHeld = false
            defer { startWaiters = [] }
            return startWaiters
        }
        waiters.forEach { $0.resume() }
    }

    /// Returns once `call` has been recorded.
    func waitFor(_ call: String) async {
        while !calls.contains(call) {
            await Task.yield()
        }
    }

    private func record(_ call: String) {
        lock.withLock { recordedCalls.append(call) }
    }

    private func waitForStartRelease() async {
        await withCheckedContinuation { continuation in
            let isHeld = lock.withLock {
                if startIsHeld { startWaiters.append(continuation) }
                return startIsHeld
            }
            if !isHeld { continuation.resume() }
        }
    }
}

private final class RecordingConsumer: RealtimeAudioSinkConsumer, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedSequences: [UInt64] = []
    private var recordedDiagnostics: [[String]] = []

    var sequences: [UInt64] { lock.withLock { recordedSequences } }
    var diagnostics: [[String]] { lock.withLock { recordedDiagnostics } }

    func appendAudioBuffer(_ captured: CapturedAudioBuffer) {
        lock.withLock { recordedSequences.append(captured.sequence) }
    }

    func recordCaptureFailure(_ failure: AudioCaptureFailure) {}

    func recordCaptureDiagnostics(_ lines: [String]) {
        lock.withLock { recordedDiagnostics.append(lines) }
    }
}
