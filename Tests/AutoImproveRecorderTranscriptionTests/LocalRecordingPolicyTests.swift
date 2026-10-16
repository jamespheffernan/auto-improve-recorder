import AVFoundation
import XCTest
@testable import AutoImproveRecorderCore

/// The rules Auto Send Recorder relies on, exercised through the shared
/// policy with scripted engines. No model, process or microphone is used.
final class LocalRecordingPolicyTests: XCTestCase {
    private let audioURL = URL(fileURLWithPath: "/tmp/recording.wav")

    // MARK: Phonon-2

    func testPhononUsesOnlyPhononForBothSources() async throws {
        for source in [LocalTranscriberPolicy.Source.hotKey, .wirelessButton] {
            let script = Script()
            let handle = script.policy().begin(model: .phonon, source: source)
            let result = try await handle.finish(audioURL: audioURL)

            XCTAssertEqual(result, TranscriptionResult(text: "phonon text", engineName: "Phonon-2"))
            XCTAssertEqual(script.log.entries, ["phonon transcribe \(audioURL.path)"])
        }
    }

    func testPhononFailureIsTheResultAndParakeetIsNotTried() async {
        let script = Script()
        script.phonon = .failure(ScriptError.phonon)
        let handle = script.policy().begin(model: .phonon, source: .hotKey)

        await assertThrows(ScriptError.phonon) { try await handle.finish(audioURL: self.audioURL) }
        XCTAssertEqual(script.log.entries, ["phonon transcribe \(audioURL.path)"])
    }

    // MARK: Live Parakeet from the hot key

    func testHotKeyParakeetKeepsTheLiveTranscript() async throws {
        let script = Script()
        script.live = .success("  live transcript \n")
        let handle = script.policy().begin(model: .parakeet, source: .hotKey)
        let result = try await handle.finish(audioURL: audioURL)

        XCTAssertEqual(result, TranscriptionResult(text: "live transcript", engineName: "scripted live"))
        XCTAssertEqual(script.log.entries, ["gate memory", "live begin", "live finalize"])
    }

    func testLiveErrorIsSwallowedAndTheOneShotReadsTheSavedFile() async throws {
        let script = Script()
        script.live = .failure(ScriptError.live)
        let handle = script.policy().begin(model: .parakeet, source: .hotKey)
        let result = try await handle.finish(audioURL: audioURL)

        XCTAssertEqual(result, TranscriptionResult(text: "one-shot text", engineName: "scripted one-shot"))
        XCTAssertEqual(script.log.entries, [
            "gate memory", "live begin", "live finalize", "one-shot run \(audioURL.path)"
        ])
    }

    func testLiveTextOfOnlyWhitespaceFallsBackToTheOneShot() async throws {
        let script = Script()
        script.live = .success(" \n\t")
        let handle = script.policy().begin(model: .parakeet, source: .hotKey)
        let result = try await handle.finish(audioURL: audioURL)

        XCTAssertEqual(result.text, "one-shot text")
        XCTAssertEqual(script.log.entries.last, "one-shot run \(audioURL.path)")
    }

    func testWhenLiveAndOneShotBothFailTheOneShotErrorIsReported() async {
        let script = Script()
        script.live = .failure(ScriptError.live)
        script.oneShot = .failure(ParakeetRunnerError.timedOut)
        let handle = script.policy().begin(model: .parakeet, source: .hotKey)

        do {
            _ = try await handle.finish(audioURL: audioURL)
            XCTFail("finish should throw")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Parakeet transcription timed out. The recording was kept."
            )
        }
    }

    // MARK: The live gate

    func testLiveBeginsAtSixteenGibibytesAndNotOneByteBelow() async throws {
        let sixteenGibibytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
        XCTAssertEqual(ParakeetLiveGate.minimumPhysicalMemory, sixteenGibibytes)

        let enough = Script()
        enough.memory = sixteenGibibytes
        _ = enough.policy().begin(model: .parakeet, source: .hotKey)
        XCTAssertTrue(enough.log.entries.contains("live begin"))

        let short = Script()
        short.memory = sixteenGibibytes - 1
        let handle = short.policy().begin(model: .parakeet, source: .hotKey)
        let result = try await handle.finish(audioURL: audioURL)
        XCTAssertEqual(result.text, "one-shot text")
        XCTAssertEqual(short.log.entries, ["gate memory", "one-shot run \(audioURL.path)"])
    }

    func testLiveDoesNotBeginWithoutTheOneShotRuntimeOrTheLiveModel() async throws {
        let noRuntime = Script()
        noRuntime.oneShotRuntimeIsInstalled = false
        let noLive = Script()
        noLive.liveIsAvailable = false

        for script in [noRuntime, noLive] {
            let handle = script.policy().begin(model: .parakeet, source: .hotKey)
            let result = try await handle.finish(audioURL: audioURL)
            XCTAssertEqual(result.text, "one-shot text")
            XCTAssertFalse(script.log.entries.contains("live begin"))
        }
    }

    // MARK: Resident model from the wireless button

    func testWirelessButtonUsesTheResidentModelAndNeverBeginsLive() async throws {
        let script = Script()
        let handle = script.policy().begin(model: .parakeet, source: .wirelessButton)
        handle.receive(.captured(Self.buffer(sequence: 1)))
        handle.receive(.failure(.sharedBufferAllocationFailed(sequence: 2)))
        let result = try await handle.finish(audioURL: audioURL)

        XCTAssertEqual(result, TranscriptionResult(text: "resident text", engineName: "scripted resident"))
        // The gate is read at begin and says live is safe; live still does not begin.
        XCTAssertEqual(script.log.entries, ["gate memory", "resident transcribe \(audioURL.path)"])
    }

    func testResidentErrorFallsBackToTheOneShot() async throws {
        let script = Script()
        script.resident = .failure(ScriptError.resident)
        let handle = script.policy().begin(model: .parakeet, source: .wirelessButton)
        let result = try await handle.finish(audioURL: audioURL)

        XCTAssertEqual(result.text, "one-shot text")
        XCTAssertEqual(script.log.entries, [
            "gate memory", "resident transcribe \(audioURL.path)", "one-shot run \(audioURL.path)"
        ])
    }

    func testResidentTextOfOnlyWhitespaceFallsBackToTheOneShot() async throws {
        let script = Script()
        script.resident = .success("  ")
        let handle = script.policy().begin(model: .parakeet, source: .wirelessButton)
        let result = try await handle.finish(audioURL: audioURL)

        XCTAssertEqual(result.text, "one-shot text")
    }

    func testResidentAndOneShotFailureReportsTheOneShotError() async {
        let script = Script()
        script.resident = .failure(ScriptError.resident)
        script.oneShot = .failure(ScriptError.oneShot)
        let handle = script.policy().begin(model: .parakeet, source: .wirelessButton)

        await assertThrows(ScriptError.oneShot) { try await handle.finish(audioURL: self.audioURL) }
    }

    // MARK: A finish without a handle from begin

    func testBeginWithoutCaptureReadsTheSavedFileOnly() async throws {
        let parakeet = Script()
        let parakeetResult = try await parakeet.policy()
            .beginWithoutCapture(model: .parakeet)
            .finish(audioURL: audioURL)
        XCTAssertEqual(parakeetResult.text, "one-shot text")
        XCTAssertEqual(parakeet.log.entries, ["one-shot run \(audioURL.path)"])

        let phonon = Script()
        let phononResult = try await phonon.policy()
            .beginWithoutCapture(model: .phonon)
            .finish(audioURL: audioURL)
        XCTAssertEqual(phononResult.text, "phonon text")
        XCTAssertEqual(phonon.log.entries, ["phonon transcribe \(audioURL.path)"])
    }

    func testAHandleKeepsTheModelItBeganWithWhenALaterRecordingUsesAnother() async throws {
        let script = Script()
        let policy = script.policy()
        let phononHandle = policy.begin(model: .phonon, source: .hotKey)
        let parakeetHandle = policy.begin(model: .parakeet, source: .wirelessButton)

        let phononResult = try await phononHandle.finish(audioURL: audioURL)
        let parakeetResult = try await parakeetHandle.finish(audioURL: audioURL)

        XCTAssertEqual(phononResult.text, "phonon text")
        XCTAssertEqual(parakeetResult.text, "resident text")
        XCTAssertEqual(script.log.entries, [
            "gate memory", "phonon transcribe \(audioURL.path)", "resident transcribe \(audioURL.path)"
        ])
    }

    // MARK: Warm-up

    func testParakeetWarmsTheResidentModelThenReadsTheGateThenWarmsLive() async {
        let script = Script()
        await script.policy().warmUp(model: .parakeet)
        XCTAssertEqual(script.log.entries, ["resident warm", "gate memory", "live warm"])
    }

    func testParakeetWarmsOnlyTheResidentModelWhenLiveIsNotSafe() async {
        let script = Script()
        script.memory = 8 * 1_024 * 1_024 * 1_024
        await script.policy().warmUp(model: .parakeet)
        XCTAssertEqual(script.log.entries, ["resident warm", "gate memory"])
    }

    func testPhononWarmsOnlyPhonon() async {
        let script = Script()
        await script.policy().warmUp(model: .phonon)
        XCTAssertEqual(script.log.entries, ["phonon warm"])
    }

    // MARK: First buffer and capture failures

    func testBeginAndTheFirstBuffersDoNotWaitForWarmUp() async throws {
        let script = Script()
        let warmStarted = AsyncGate()
        let warmMayFinish = AsyncGate()
        script.residentWarm = {
            warmStarted.open()
            await warmMayFinish.wait()
        }
        let policy = script.policy()
        let warming = Task { await policy.warmUp(model: .parakeet) }
        await warmStarted.wait()

        let handle = policy.begin(model: .parakeet, source: .hotKey)
        handle.receive(.captured(Self.buffer(sequence: 1)))
        handle.receive(.captured(Self.buffer(sequence: 2)))
        handle.receive(.failure(.sharedBufferAllocationFailed(sequence: 3)))
        handle.receive(.captured(Self.buffer(sequence: 4)))

        XCTAssertEqual(script.log.entries, [
            "resident warm", "gate memory", "live begin",
            "live append 1", "live append 2", "live failure 3", "live append 4"
        ])
        warmMayFinish.open()
        await warming.value
    }

    func testCaptureFailureReachesTheLiveSessionAndItsErrorFallsBackToTheOneShot() async throws {
        let script = Script()
        script.liveFailsAfterCaptureFailure = true
        let handle = script.policy().begin(model: .parakeet, source: .hotKey)
        handle.receive(.captured(Self.buffer(sequence: 1)))
        handle.receive(.failure(.sharedBufferAllocationFailed(sequence: 2)))
        let result = try await handle.finish(audioURL: audioURL)

        XCTAssertEqual(result.text, "one-shot text")
        XCTAssertEqual(script.log.entries, [
            "gate memory", "live begin", "live append 1", "live failure 2",
            "live finalize", "one-shot run \(audioURL.path)"
        ])
    }

    // MARK: Cancel

    func testCancelStopsTheLiveSessionOnceAndLaterEventsDoNothing() async {
        let script = Script()
        let handle = script.policy().begin(model: .parakeet, source: .hotKey)
        handle.receive(.captured(Self.buffer(sequence: 1)))
        handle.cancel()
        handle.cancel()
        handle.receive(.captured(Self.buffer(sequence: 2)))
        handle.receive(.failure(.sharedBufferAllocationFailed(sequence: 3)))

        XCTAssertEqual(script.log.entries, ["gate memory", "live begin", "live append 1", "live cancel"])
    }

    func testFinishAfterCancelThrowsCancellationAndStartsNoEngine() async {
        for (model, source) in [
            (LocalTranscriberPolicy.Model.parakeet, LocalTranscriberPolicy.Source.hotKey),
            (.parakeet, .wirelessButton),
            (.phonon, .hotKey)
        ] {
            let script = Script()
            let handle = script.policy().begin(model: model, source: source)
            handle.cancel()
            do {
                _ = try await handle.finish(audioURL: audioURL)
                XCTFail("finish should throw")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let engineCalls = script.log.entries.filter {
                $0.contains("transcribe") || $0.contains("run") || $0.contains("finalize")
            }
            XCTAssertEqual(engineCalls, [])
        }
    }

    // MARK: Helpers

    private func assertThrows(
        _ expected: ScriptError,
        _ body: () async throws -> TranscriptionResult,
        line: UInt = #line
    ) async {
        do {
            _ = try await body()
            XCTFail("finish should throw", line: line)
        } catch {
            XCTAssertEqual(error as? ScriptError, expected, line: line)
        }
    }

    private static func buffer(sequence: UInt64) -> CapturedAudioBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        buffer.frameLength = 16
        return CapturedAudioBuffer(sequence: sequence, buffer: buffer)
    }
}

private enum ScriptError: Error, Equatable {
    case phonon
    case live
    case resident
    case oneShot
    case captureFailure
}

/// Scripted engines for one policy. Every engine call is written to `log`.
private final class Script: @unchecked Sendable {
    let log = CallLog()
    var memory: UInt64 = 32 * 1_024 * 1_024 * 1_024
    var oneShotRuntimeIsInstalled = true
    var liveIsAvailable = true
    var phonon: Result<String, Error> = .success("phonon text")
    var live: Result<String, Error> = .success("live text")
    var liveFailsAfterCaptureFailure = false
    var resident: Result<String, Error> = .success("resident text")
    var oneShot: Result<String, Error> = .success("one-shot text")
    var residentWarm: @Sendable () async -> Void = {}

    /// Reads the scripted values once; later changes do not reach the policy.
    func policy() -> LocalTranscriberPolicy {
        let log = self.log
        let memory = self.memory
        let oneShotRuntimeIsInstalled = self.oneShotRuntimeIsInstalled
        let liveIsAvailable = self.liveIsAvailable
        let phonon = self.phonon
        let live = self.live
        let resident = self.resident
        let oneShot = self.oneShot
        let liveFailsAfterCaptureFailure = self.liveFailsAfterCaptureFailure
        let residentWarm = self.residentWarm
        return LocalTranscriberPolicy(
            phonon: PhononRecordingAdapter(
                warm: { log.add("phonon warm") },
                transcribe: { url in
                    log.add("phonon transcribe \(url.path)")
                    return try phonon.get()
                }
            ),
            parakeetLive: ParakeetLiveRecordingAdapter(
                warm: { log.add("live warm") },
                beginSession: {
                    log.add("live begin")
                    return ScriptedLiveSession(
                        log: log,
                        result: live,
                        failsAfterCaptureFailure: liveFailsAfterCaptureFailure
                    )
                }
            ),
            parakeetResident: ParakeetResidentRecordingAdapter(
                engineName: "scripted resident",
                warm: {
                    log.add("resident warm")
                    await residentWarm()
                },
                transcribe: { url in
                    log.add("resident transcribe \(url.path)")
                    return try resident.get()
                }
            ),
            parakeetOneShot: ParakeetOneShotRecordingAdapter(
                engineName: "scripted one-shot",
                run: { url in
                    log.add("one-shot run \(url.path)")
                    return try oneShot.get()
                }
            ),
            liveGate: ParakeetLiveGate(
                physicalMemory: {
                    log.add("gate memory")
                    return memory
                },
                oneShotRuntimeIsInstalled: { oneShotRuntimeIsInstalled },
                liveIsAvailable: { liveIsAvailable }
            )
        )
    }
}

private final class ScriptedLiveSession: LocalLiveTranscriptionSession, @unchecked Sendable {
    let engineName = "scripted live"
    private let log: CallLog
    private let result: Result<String, Error>
    private let failsAfterCaptureFailure: Bool
    private let lock = NSLock()
    private var sawCaptureFailure = false

    init(log: CallLog, result: Result<String, Error>, failsAfterCaptureFailure: Bool) {
        self.log = log
        self.result = result
        self.failsAfterCaptureFailure = failsAfterCaptureFailure
    }

    func append(_ captured: CapturedAudioBuffer) {
        log.add("live append \(captured.sequence)")
    }

    func recordCaptureFailure(_ failure: AudioCaptureFailure) {
        lock.withLock { sawCaptureFailure = true }
        if case .sharedBufferAllocationFailed(let sequence) = failure {
            log.add("live failure \(sequence)")
        }
    }

    func finalize() async throws -> String {
        log.add("live finalize")
        if failsAfterCaptureFailure, lock.withLock({ sawCaptureFailure }) {
            throw ScriptError.captureFailure
        }
        return try result.get()
    }

    func cancel() {
        log.add("live cancel")
    }
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var entries: [String] { lock.withLock { stored } }

    func add(_ entry: String) {
        lock.withLock { stored.append(entry) }
    }
}

/// Lets a test hold an async closure until the test opens the gate.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

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
        let waiting = waiters
        waiters = []
        lock.unlock()
        waiting.forEach { $0.resume() }
    }
}
