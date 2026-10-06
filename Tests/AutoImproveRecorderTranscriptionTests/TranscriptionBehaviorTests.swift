import Foundation
import XCTest
@testable import AutoImproveRecorderCore

/// Records what `LiveTranscriptionService` does today for every transcription
/// mode. Every engine and realtime call is a scripted closure, so no test
/// opens a socket, loads a model or starts a process.
final class TranscriptionBehaviorTests: XCTestCase {
    private let audioURL = URL(fileURLWithPath: "/recordings/sample.wav")
    private let vocabulary = "Turf, Phonon"

    // MARK: File engines

    func testPhonon2ReportsStatusAndPhononEngineName() async throws {
        let script = Script()
        script.phonon = .success("phonon text")

        let result = try await script.transcribe(request(.localPhonon2))

        XCTAssertEqual(result, TranscriptionResult(text: "phonon text", engineName: "Phonon-2"))
        XCTAssertEqual(script.calls, ["phonon /recordings/sample.wav"])
        assertStatuses(script.statuses, ["Transcribing with Phonon-2.", "Phonon-2 transcript ready in <t>s."])
        XCTAssertEqual(script.diagnostics, [])
    }

    func testOpenAIAPIPassesKeyAndVocabulary() async throws {
        let script = Script()

        let result = try await script.transcribe(request(.openAIAPI))

        XCTAssertEqual(result, Script.apiResult)
        XCTAssertEqual(script.calls, ["api key=sk-test vocabulary=Turf, Phonon"])
        assertStatuses(script.statuses, ["Transcribing with OpenAI API.", "OpenAI API transcript ready in <t>s."])
    }

    func testLocalWhisperPassesVocabulary() async throws {
        let script = Script()

        let result = try await script.transcribe(request(.localWhisper))

        XCTAssertEqual(result, Script.whisperResult)
        XCTAssertEqual(script.calls, ["whisper vocabulary=Turf, Phonon"])
        assertStatuses(script.statuses, ["Transcribing with local Whisper.", "Local Whisper transcript ready in <t>s."])
    }

    func testAppleLocalPassesVocabulary() async throws {
        let script = Script()

        let result = try await script.transcribe(request(.appleLocal))

        XCTAssertEqual(result, Script.appleResult)
        XCTAssertEqual(script.calls, ["apple vocabulary=Turf, Phonon"])
        assertStatuses(script.statuses, ["Transcribing with Apple Speech.", "Apple Speech transcript ready in <t>s."])
    }

    func testParakeetCppFastUsesFastVariant() async throws {
        let script = Script()

        let result = try await script.transcribe(request(.localParakeetCppFast))

        XCTAssertEqual(result, TranscriptionResult(text: "cli text", engineName: "parakeet.cpp 110M Q4_K CPU"))
        XCTAssertEqual(script.calls, ["cli fast110M vocabulary=Turf, Phonon"])
        assertStatuses(script.statuses, [
            "Transcribing with parakeet.cpp 110M Q4_K CPU.",
            "parakeet.cpp 110M Q4_K CPU transcript ready in <t>s."
        ])
    }

    func testParakeetCppRecommendedUsesRecommendedVariant() async throws {
        let script = Script()

        let result = try await script.transcribe(request(.localParakeetCppRecommended))

        XCTAssertEqual(result, Script.recommendedCLIResult)
        XCTAssertEqual(script.calls, ["cli recommended06B vocabulary=Turf, Phonon"])
        assertStatuses(script.statuses, Self.recommendedCLIStatuses)
    }

    func testFileEngineErrorsPropagateWithoutFallback() async {
        let modes: [TranscriptionMode] = [
            .localPhonon2, .openAIAPI, .localWhisper, .appleLocal,
            .localParakeetCppFast, .localParakeetCppRecommended
        ]
        for mode in modes {
            let script = Script()
            script.phonon = .failure(ScriptedError("engine failed"))
            script.api = [.failure(ScriptedError("engine failed"))]
            script.whisper = .failure(ScriptedError("engine failed"))
            script.apple = .failure(ScriptedError("engine failed"))
            script.cli = .failure(ScriptedError("engine failed"))

            await assertThrows("engine failed", "\(mode)") {
                try await script.transcribe(self.request(mode))
            }
            XCTAssertEqual(script.calls.count, 1, "\(mode) must call exactly one engine")
            XCTAssertEqual(script.statuses.count, 1, "\(mode) must report only its starting status")
        }
    }

    // MARK: Resident Parakeet

    func testResidentAvailableUsesResidentEngine() async throws {
        let script = Script()

        let result = try await script.transcribe(request(.localParakeetCppResident))

        XCTAssertEqual(result, Script.residentResult)
        XCTAssertEqual(script.calls, ["resident available", "resident vocabulary=Turf, Phonon"])
        assertStatuses(script.statuses, ["Transcribing with resident Parakeet.", "Parakeet transcript ready in <t>s."])
    }

    func testResidentUnavailableFallsBackToRecommendedCLI() async throws {
        let script = Script()
        script.residentAvailable = false

        let result = try await script.transcribe(request(.localParakeetCppResident))

        XCTAssertEqual(result, Script.recommendedCLIResult)
        XCTAssertEqual(script.calls, ["resident available", "cli recommended06B vocabulary=Turf, Phonon"])
        assertStatuses(
            script.statuses,
            ["Resident Parakeet unavailable; using Parakeet.cpp Recommended."] + Self.recommendedCLIStatuses
        )
    }

    func testResidentInferenceErrorPropagatesWithoutFallback() async {
        let script = Script()
        script.resident = .failure(ScriptedError("resident failed"))

        await assertThrows("resident failed") {
            try await script.transcribe(self.request(.localParakeetCppResident))
        }
        XCTAssertEqual(script.calls, ["resident available", "resident vocabulary=Turf, Phonon"])
        XCTAssertEqual(script.statuses, ["Transcribing with resident Parakeet."])
    }

    // MARK: Live Parakeet

    func testLiveParakeetReturnsSessionTextAndEngineName() async throws {
        let script = Script()
        let session = FakeLiveSession(finalizeResult: .success("live text"))

        let result = try await script.transcribe(request(.localParakeetStreaming, liveSession: session))

        XCTAssertEqual(result, TranscriptionResult(text: "live text", engineName: "fake live engine"))
        XCTAssertEqual(session.finalizeCount, 1)
        XCTAssertEqual(session.cancelCount, 0)
        XCTAssertEqual(script.calls, [])
        assertStatuses(script.statuses, ["Live transcript ready in <t>s."])
    }

    func testLiveParakeetMissingSessionFallsBackToRecommendedCLI() async throws {
        let script = Script()

        let result = try await script.transcribe(request(.localParakeetStreaming))

        XCTAssertEqual(result, Script.recommendedCLIResult)
        XCTAssertEqual(script.calls, ["cli recommended06B vocabulary=Turf, Phonon"])
        assertStatuses(script.statuses, Self.liveFallbackStatuses)
    }

    func testLiveParakeetEmptyTranscriptFallsBackToRecommendedCLI() async throws {
        let script = Script()
        let session = FakeLiveSession(finalizeResult: .success(""))

        let result = try await script.transcribe(request(.localParakeetStreaming, liveSession: session))

        XCTAssertEqual(result, Script.recommendedCLIResult)
        XCTAssertEqual(session.finalizeCount, 1)
        XCTAssertEqual(script.calls, ["cli recommended06B vocabulary=Turf, Phonon"])
        assertStatuses(script.statuses, Self.liveFallbackStatuses)
    }

    func testLiveParakeetFinalizeFailureFallsBackToRecommendedCLI() async throws {
        let script = Script()
        let session = FakeLiveSession(finalizeResult: .failure(ScriptedError("finalize failed")))

        let result = try await script.transcribe(request(.localParakeetStreaming, liveSession: session))

        XCTAssertEqual(result, Script.recommendedCLIResult)
        XCTAssertEqual(session.finalizeCount, 1)
        XCTAssertEqual(session.cancelCount, 0)
        XCTAssertEqual(script.calls, ["cli recommended06B vocabulary=Turf, Phonon"])
        assertStatuses(script.statuses, Self.liveFallbackStatuses)
    }

    func testLiveParakeetFallbackErrorPropagates() async {
        let script = Script()
        script.cli = .failure(ScriptedError("cli failed"))

        await assertThrows("cli failed") {
            try await script.transcribe(self.request(.localParakeetStreaming))
        }
    }

    // MARK: Fastest

    func testFastestWithoutPreparedSessionUsesRecommendedCLI() async throws {
        let script = Script()

        let result = try await script.transcribe(request(.fastest))

        XCTAssertEqual(result, Script.recommendedCLIResult)
        XCTAssertEqual(script.calls, ["cli recommended06B vocabulary=Turf, Phonon"])
        assertStatuses(
            script.statuses,
            ["Fastest unavailable; falling back to Parakeet.cpp Recommended."] + Self.recommendedCLIStatuses
        )
        XCTAssertEqual(script.diagnostics, [])
    }

    func testFastestPreparedSessionReturnsRealtimeResult() async throws {
        let script = Script()
        script.realtimeFinish = .success(
            TranscriptionResult(text: "three whole words", engineName: "OpenAI Realtime test")
        )

        let result = try await script.transcribe(request(.fastest, realtime: Self.makeRealtimeHandle()))

        XCTAssertEqual(result, TranscriptionResult(text: "three whole words", engineName: "OpenAI Realtime test"))
        XCTAssertEqual(script.calls, ["realtime finish"])
        assertStatuses(script.statuses, ["OpenAI transcript ready in <t>s."])
        XCTAssertEqual(script.diagnostics, [])
    }

    func testFastestPreparedSessionFailureUsesOpenAIAPI() async throws {
        let script = Script()
        script.realtimeFinish = .failure(ScriptedError("socket closed"))

        let result = try await script.transcribe(request(.fastest, realtime: Self.makeRealtimeHandle()))

        XCTAssertEqual(result, Script.apiResult)
        XCTAssertEqual(script.calls, [
            "realtime finish",
            "realtime diagnostics",
            "api key=sk-test vocabulary=Turf, Phonon"
        ])
        XCTAssertEqual(script.diagnostics, [
            OpenAIRealtimeDiagnostics(
                summary: "OpenAI streaming failed; falling back to OpenAI API. socket closed",
                details: "scripted details"
            )
        ])
        assertStatuses(
            script.statuses,
            ["OpenAI streaming failed; using OpenAI API."] + Self.apiStatuses
        )
    }

    func testFastestTranscriptOfTwoWordsOrFewerUsesOpenAIAPI() async throws {
        for shortText in ["", "Okay.", "thank you"] {
            let script = Script()
            script.realtimeFinish = .success(
                TranscriptionResult(text: shortText, engineName: "OpenAI Realtime test")
            )

            let result = try await script.transcribe(request(.fastest, realtime: Self.makeRealtimeHandle()))

            XCTAssertEqual(result, Script.apiResult, shortText)
            XCTAssertEqual(script.calls, [
                "realtime finish",
                "realtime diagnostics",
                "api key=sk-test vocabulary=Turf, Phonon"
            ], shortText)
            XCTAssertEqual(script.diagnostics, [
                OpenAIRealtimeDiagnostics(
                    summary: "OpenAI realtime returned a suspiciously short transcript (‘\(shortText)’); using OpenAI API transcription instead.",
                    details: "scripted details"
                )
            ], shortText)
            assertStatuses(
                script.statuses,
                ["Realtime transcript looked wrong; using OpenAI API."] + Self.apiStatuses
            )
        }
    }

    func testFastestVerificationAPIFailureCallsAPIASecondTime() async throws {
        let script = Script()
        script.realtimeFinish = .success(TranscriptionResult(text: "thank you", engineName: "OpenAI Realtime test"))
        script.api = [.failure(ScriptedError("upload failed")), .success(Script.apiResult)]

        let result = try await script.transcribe(request(.fastest, realtime: Self.makeRealtimeHandle()))

        XCTAssertEqual(result, Script.apiResult)
        XCTAssertEqual(script.calls, [
            "realtime finish",
            "realtime diagnostics",
            "api key=sk-test vocabulary=Turf, Phonon",
            "realtime diagnostics",
            "api key=sk-test vocabulary=Turf, Phonon"
        ])
        XCTAssertEqual(script.diagnostics.map(\.summary), [
            "OpenAI realtime returned a suspiciously short transcript (‘thank you’); using OpenAI API transcription instead.",
            "OpenAI streaming failed; falling back to OpenAI API. upload failed"
        ])
        assertStatuses(script.statuses, [
            "Realtime transcript looked wrong; using OpenAI API.",
            "Transcribing with OpenAI API.",
            "OpenAI streaming failed; using OpenAI API."
        ] + Self.apiStatuses)
    }

    func testFastestSecondAPIFailurePropagates() async {
        let script = Script()
        script.realtimeFinish = .failure(ScriptedError("socket closed"))
        script.api = [.failure(ScriptedError("upload failed"))]

        await assertThrows("upload failed") {
            try await script.transcribe(self.request(.fastest, realtime: Self.makeRealtimeHandle()))
        }
        XCTAssertEqual(script.calls, [
            "realtime finish",
            "realtime diagnostics",
            "api key=sk-test vocabulary=Turf, Phonon"
        ])
    }

    // MARK: Realtime preparation

    func testPrepareRealtimeDoesNothingOutsideFastest() async {
        for mode in TranscriptionMode.allCases where mode != .fastest {
            let script = Script()

            let transcriber = await script.prepare(mode: mode, apiKey: "sk-test")

            XCTAssertNil(transcriber, "\(mode)")
            XCTAssertEqual(script.calls, [], "\(mode)")
            XCTAssertEqual(script.statuses, [], "\(mode)")
            XCTAssertEqual(script.diagnostics, [], "\(mode)")
        }
    }

    func testPrepareRealtimeWithoutKeyReportsFallbackAndCreatesNothing() async {
        let script = Script()

        let transcriber = await script.prepare(mode: .fastest, apiKey: "  \n")

        let reason = "Fastest mode needs an OpenAI API key. Falling back to Parakeet."
        XCTAssertNil(transcriber)
        XCTAssertEqual(script.calls, [])
        XCTAssertEqual(script.diagnostics, [OpenAIRealtimeDiagnostics(summary: reason, details: reason)])
        XCTAssertEqual(script.statuses, [reason])
    }

    func testPrepareRealtimeStartsAndReturnsTheCreatedTranscriber() async {
        let script = Script()

        let transcriber = await script.prepare(mode: .fastest, apiKey: "sk-test")

        XCTAssertNotNil(transcriber)
        XCTAssertTrue(transcriber === script.createdRealtime)
        XCTAssertEqual(script.calls, ["realtime create key=sk-test vocabulary=Turf, Phonon", "realtime start"])
        XCTAssertEqual(script.statuses, [])
        XCTAssertEqual(script.diagnostics, [])
    }

    func testPrepareRealtimeStartFailureReportsFallbackAndCancels() async {
        let script = Script()
        script.realtimeStart = .failure(ScriptedError("handshake refused"))

        let transcriber = await script.prepare(mode: .fastest, apiKey: "sk-test")

        XCTAssertNil(transcriber)
        XCTAssertEqual(script.calls, [
            "realtime create key=sk-test vocabulary=Turf, Phonon",
            "realtime start",
            "realtime diagnostics",
            "realtime cancel"
        ])
        XCTAssertEqual(script.diagnostics, [
            OpenAIRealtimeDiagnostics(
                summary: "OpenAI streaming unavailable; falling back to Parakeet. handshake refused",
                details: "scripted details"
            )
        ])
        XCTAssertEqual(script.statuses, ["OpenAI streaming unavailable; falling back to Parakeet."])
    }

    // MARK: Helpers

    private static let recommendedCLIStatuses = [
        "Transcribing with parakeet.cpp 0.6B v2 Q4_K Metal.",
        "parakeet.cpp 0.6B v2 Q4_K Metal transcript ready in <t>s."
    ]
    private static let liveFallbackStatuses =
        ["Live streaming unavailable; using Parakeet.cpp Recommended."] + recommendedCLIStatuses
    private static let apiStatuses = ["Transcribing with OpenAI API.", "OpenAI API transcript ready in <t>s."]

    /// A real transcriber object that is never started. The service only
    /// passes it to the scripted realtime closures.
    private static func makeRealtimeHandle() -> OpenAIRealtimeTranscriber {
        OpenAIRealtimeTranscriber(apiKey: "unused")
    }

    private func request(
        _ mode: TranscriptionMode,
        realtime: OpenAIRealtimeTranscriber? = nil,
        liveSession: (any LocalLiveTranscriptionSession)? = nil
    ) -> TranscriptionServiceRequest {
        TranscriptionServiceRequest(
            audioURL: audioURL,
            mode: mode,
            apiKey: "sk-test",
            dictionarySnapshot: vocabulary,
            streamingTranscriber: realtime,
            parakeetStreamSession: liveSession
        )
    }

    /// `<t>` in an expected status stands for the elapsed seconds, which vary.
    private func assertStatuses(
        _ actual: [String],
        _ expected: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "statuses: \(actual)", file: file, line: line)
        for (actualStatus, expectedStatus) in zip(actual, expected) {
            let pattern = "^" + NSRegularExpression.escapedPattern(for: expectedStatus)
                .replacingOccurrences(of: "<t>", with: "[0-9]+\\.[0-9]") + "$"
            XCTAssertNotNil(
                actualStatus.range(of: pattern, options: .regularExpression),
                "‘\(actualStatus)’ does not match ‘\(expectedStatus)’",
                file: file,
                line: line
            )
        }
    }

    private func assertThrows(
        _ expectedDescription: String,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> TranscriptionResult
    ) async {
        do {
            _ = try await body()
            XCTFail("expected an error. \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, expectedDescription, message, file: file, line: line)
        }
    }
}

private struct ScriptedError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private final class FakeLiveSession: LocalLiveTranscriptionSession, @unchecked Sendable {
    let engineName = "fake live engine"
    private let finalizeResult: Result<String, Error>
    private let lock = NSLock()
    private var finalizes = 0
    private var cancels = 0

    init(finalizeResult: Result<String, Error>) {
        self.finalizeResult = finalizeResult
    }

    var finalizeCount: Int { lock.withLock { finalizes } }
    var cancelCount: Int { lock.withLock { cancels } }

    func append(_ captured: CapturedAudioBuffer) {}
    func recordCaptureFailure(_ failure: AudioCaptureFailure) {}

    func finalize() async throws -> String {
        lock.withLock { finalizes += 1 }
        return try finalizeResult.get()
    }

    func cancel() {
        lock.withLock { cancels += 1 }
    }
}

/// One recording for `Script.transcribe`: the mode, what the recording was started with, and the
/// live session and realtime transcriber it has at stop.
private struct TranscriptionServiceRequest: @unchecked Sendable {
    var audioURL: URL
    var mode: TranscriptionMode
    var apiKey: String
    var dictionarySnapshot: String
    var streamingTranscriber: OpenAIRealtimeTranscriber?
    var parakeetStreamSession: (any LocalLiveTranscriptionSession)?
}

/// Scripted results for every dependency of `LiveTranscriptionService`, and a
/// record of the calls, statuses and diagnostics it produced.
private final class Script: @unchecked Sendable {
    static let apiResult = TranscriptionResult(text: "api text", engineName: "OpenAI Audio test")
    static let whisperResult = TranscriptionResult(text: "whisper text", engineName: "whisper test")
    static let appleResult = TranscriptionResult(text: "apple text", engineName: "Apple Speech")
    static let residentResult = TranscriptionResult(text: "resident text", engineName: "resident test")
    static let recommendedCLIResult = TranscriptionResult(
        text: "cli text",
        engineName: "parakeet.cpp 0.6B v2 Q4_K Metal"
    )

    var phonon: Result<String, Error> = .success("phonon text")
    /// One entry per API call, in order. The last entry repeats.
    var api: [Result<TranscriptionResult, Error>] = [.success(Script.apiResult)]
    var whisper: Result<TranscriptionResult, Error> = .success(Script.whisperResult)
    var apple: Result<TranscriptionResult, Error> = .success(Script.appleResult)
    /// Nil returns "cli text" with the requested variant's engine name.
    var cli: Result<TranscriptionResult, Error>?
    var residentAvailable = true
    var resident: Result<TranscriptionResult, Error> = .success(Script.residentResult)
    var realtimeStart: Result<Void, Error> = .success(())
    var realtimeFinish: Result<TranscriptionResult, Error> = .failure(ScriptedError("finish not scripted"))

    private let lock = NSLock()
    private var recordedCalls: [String] = []
    private var recordedStatuses: [String] = []
    private var recordedDiagnostics: [OpenAIRealtimeDiagnostics] = []
    private var apiCallCount = 0
    private(set) var createdRealtime: OpenAIRealtimeTranscriber?

    var calls: [String] { lock.withLock { recordedCalls } }
    var statuses: [String] { lock.withLock { recordedStatuses } }
    var diagnostics: [OpenAIRealtimeDiagnostics] { lock.withLock { recordedDiagnostics } }

    private func record(_ call: String) {
        lock.withLock { recordedCalls.append(call) }
    }

    private func nextAPIResult() -> Result<TranscriptionResult, Error> {
        lock.withLock {
            let result = api[min(apiCallCount, api.count - 1)]
            apiCallCount += 1
            return result
        }
    }

    var service: LiveTranscriptionService {
        var dependencies = LiveTranscriptionService.Dependencies()
        dependencies.transcribePhonon = { audioURL in
            self.record("phonon \(audioURL.path)")
            return try self.phonon.get()
        }
        dependencies.transcribeParakeetCpp = { variant, _, context in
            self.record("cli \(variant) vocabulary=\(context.dictionarySnapshot)")
            if let cli = self.cli { return try cli.get() }
            return TranscriptionResult(text: "cli text", engineName: variant.engineName)
        }
        dependencies.parakeetResidentIsAvailable = {
            self.record("resident available")
            return self.residentAvailable
        }
        dependencies.transcribeParakeetResident = { _, context in
            self.record("resident vocabulary=\(context.dictionarySnapshot)")
            return try self.resident.get()
        }
        dependencies.transcribeOpenAIAPI = { apiKey, _, context in
            self.record("api key=\(apiKey) vocabulary=\(context.dictionarySnapshot)")
            return try self.nextAPIResult().get()
        }
        dependencies.transcribeAppleLocal = { _, context in
            self.record("apple vocabulary=\(context.dictionarySnapshot)")
            return try self.apple.get()
        }
        dependencies.transcribeLocalWhisper = { _, context in
            self.record("whisper vocabulary=\(context.dictionarySnapshot)")
            return try self.whisper.get()
        }
        dependencies.makeRealtimeTranscriber = { apiKey, dictionarySnapshot in
            self.record("realtime create key=\(apiKey) vocabulary=\(dictionarySnapshot)")
            let transcriber = OpenAIRealtimeTranscriber(apiKey: apiKey, dictionarySnapshot: dictionarySnapshot)
            self.lock.withLock { self.createdRealtime = transcriber }
            return transcriber
        }
        dependencies.startRealtime = { _ in
            self.record("realtime start")
            try self.realtimeStart.get()
        }
        dependencies.finishRealtime = { _ in
            self.record("realtime finish")
            return try self.realtimeFinish.get()
        }
        dependencies.realtimeDiagnostics = { _, summary in
            self.record("realtime diagnostics")
            return OpenAIRealtimeDiagnostics(summary: summary, details: "scripted details")
        }
        dependencies.cancelRealtime = { _ in
            self.record("realtime cancel")
        }
        return LiveTranscriptionService(dependencies: dependencies)
    }

    /// Runs one recording the way `AppState` does: begins the mode's handle with the live session
    /// the request carries, gives it the request's realtime transcriber and finishes it on the file.
    func transcribe(_ request: TranscriptionServiceRequest) async throws -> TranscriptionResult {
        var service = service
        service.dependencies.liveParakeetIsAvailable = { request.parakeetStreamSession != nil }
        service.dependencies.beginLiveParakeet = { request.parakeetStreamSession! }
        let handle = service.beginRecording(
            RecordingTranscriptionRequest(
                mode: request.mode,
                dictionarySnapshot: request.dictionarySnapshot,
                attachedToCapture: true,
                apiKey: { request.apiKey }
            ),
            status: { status in self.lock.withLock { self.recordedStatuses.append(status) } },
            recordDiagnostics: { diagnostics in self.lock.withLock { self.recordedDiagnostics.append(diagnostics) } }
        )
        if let realtime = request.streamingTranscriber {
            (handle as? RealtimeBridgeRecordingHandle)?.useRealtimeTranscriber(realtime)
        }
        return try await handle.finish(audioURL: request.audioURL)
    }

    func prepare(mode: TranscriptionMode, apiKey: String) async -> OpenAIRealtimeTranscriber? {
        await service.prepareRealtimeIfNeeded(
            mode: mode,
            apiKey: apiKey,
            dictionarySnapshot: "Turf, Phonon",
            status: { status in self.lock.withLock { self.recordedStatuses.append(status) } },
            recordDiagnostics: { diagnostics in self.lock.withLock { self.recordedDiagnostics.append(diagnostics) } }
        )
    }
}
