import Foundation

/// What one recording's transcription is started with. The mode and the
/// vocabulary are fixed for the recording.
struct RecordingTranscriptionRequest {
    var mode: TranscriptionMode
    var dictionarySnapshot: String
    /// False for a second transcription of a saved file, such as the backup
    /// microphone's. That handle gets no capture events, no live session and
    /// no realtime transcriber.
    var attachedToCapture: Bool
    /// Read once when the handle finishes, before any transcription work.
    var apiKey: @Sendable () async -> String
}

/// Maps each AIR transcription mode to its configured transcriber and owns
/// AIR's fallback rules: resident Parakeet unavailable and live Parakeet
/// missing, empty or failed both use the recommended one-shot CLI.
struct AIRTranscriberCatalog: @unchecked Sendable {
    /// The engine and realtime calls AIR's transcription makes. The defaults
    /// run the live engines; tests replace them with scripted closures.
    struct Dependencies: @unchecked Sendable {
        var transcribePhonon: (URL) async throws -> String = { audioURL in
            try await PhononTranscriber.shared.transcribe(audioURL: audioURL)
        }
        var transcribeParakeetCpp: (ParakeetCppVariant, URL, TranscriptionContext) async throws -> TranscriptionResult = { variant, audioURL, context in
            let transcriber = ParakeetCppTranscriber(variant: variant)
            return try await transcriber.transcribe(audioURL: audioURL, context: context)
        }
        var parakeetResidentIsAvailable: () -> Bool = {
            ParakeetResidentTranscriber.isAvailable
        }
        var transcribeParakeetResident: (URL, TranscriptionContext) async throws -> TranscriptionResult = { audioURL, context in
            try await ParakeetResidentTranscriber().transcribe(audioURL: audioURL, context: context)
        }
        var liveParakeetIsAvailable: () -> Bool = {
            RecommendedLiveTranscription.isAvailable
        }
        var beginLiveParakeet: () -> any LocalLiveTranscriptionSession = {
            RecommendedLiveTranscription.begin()
        }
        var transcribeOpenAIAPI: (String, URL, TranscriptionContext) async throws -> TranscriptionResult = { apiKey, audioURL, context in
            let transcriber = OpenAIAudioTranscriber(apiKey: apiKey)
            return try await transcriber.transcribe(audioURL: audioURL, context: context)
        }
        var transcribeAppleLocal: (URL, TranscriptionContext) async throws -> TranscriptionResult = { audioURL, context in
            try await AppleLocalAudioTranscriber().transcribe(audioURL: audioURL, context: context)
        }
        var transcribeLocalWhisper: (URL, TranscriptionContext) async throws -> TranscriptionResult = { audioURL, context in
            try await WhisperCppTranscriber().transcribe(audioURL: audioURL, context: context)
        }
        var makeRealtimeTranscriber: (String, String) -> OpenAIRealtimeTranscriber = { apiKey, dictionarySnapshot in
            OpenAIRealtimeTranscriber(apiKey: apiKey, dictionarySnapshot: dictionarySnapshot)
        }
        var startRealtime: (OpenAIRealtimeTranscriber) async throws -> Void = { transcriber in
            try await transcriber.start()
        }
        var finishRealtime: (OpenAIRealtimeTranscriber) async throws -> TranscriptionResult = { transcriber in
            try await transcriber.finish()
        }
        var realtimeDiagnostics: (OpenAIRealtimeTranscriber, String) async -> OpenAIRealtimeDiagnostics = { transcriber, summary in
            await transcriber.diagnostics(summary: summary)
        }
        var cancelRealtime: (OpenAIRealtimeTranscriber) async -> Void = { transcriber in
            await transcriber.cancel()
        }
    }

    typealias Status = @Sendable (String) async -> Void

    var dependencies = Dependencies()

    /// The status shown when a recording stops and its transcription begins.
    /// `fastest` without a realtime transcriber is transcribed by the
    /// recommended one-shot CLI.
    static func stopStatus(for mode: TranscriptionMode) -> String {
        switch mode {
        case .localPhonon2:
            return "Transcribing with Phonon-2."
        case .localWhisper:
            return "Transcribing with local Whisper."
        case .localParakeetCppFast:
            return "Transcribing with Parakeet.cpp Fast."
        case .localParakeetCppRecommended, .fastest:
            return "Transcribing with Parakeet.cpp Recommended."
        case .localParakeetCppResident:
            return "Transcribing with resident Parakeet."
        case .localParakeetStreaming:
            return "Finalizing live Parakeet transcript."
        case .appleLocal:
            return "Transcribing with Apple Speech."
        case .openAIAPI:
            return "Transcribing with OpenAI API."
        }
    }

    /// The configured transcriber for the request's mode. Nil for `fastest`,
    /// which `LiveTranscriptionService` still runs itself.
    func transcriber(for request: RecordingTranscriptionRequest) -> (any RecordingTranscriber)? {
        let dependencies = dependencies
        let context = TranscriptionContext(dictionarySnapshot: request.dictionarySnapshot)

        switch request.mode {
        case .localPhonon2:
            return AIRModeTranscriber(
                engine: PhononRecordingAdapter(
                    warm: { await PhononTranscriber.shared.warmUp() },
                    transcribe: { try await dependencies.transcribePhonon($0) }
                ),
                apiKey: request.apiKey
            ) { engine, audioURL, _, startedAt, status in
                await status("Transcribing with Phonon-2.")
                let result = try await engine.finish(audioURL: audioURL)
                await status(String(format: "Phonon-2 transcript ready in %.1fs.", Date().timeIntervalSince(startedAt)))
                return result
            }

        case .openAIAPI:
            return AIRModeTranscriber(engine: nil, apiKey: request.apiKey) { _, audioURL, apiKey, startedAt, status in
                try await transcribeWithOpenAIAPI(
                    audioURL: audioURL,
                    apiKey: apiKey,
                    context: context,
                    startedAt: startedAt,
                    status: status
                )
            }

        case .localWhisper:
            return AIRModeTranscriber(
                engine: WhisperRecordingAdapter(
                    context: context,
                    warm: { await WhisperCppTranscriber().warmUp() },
                    transcribe: dependencies.transcribeLocalWhisper
                ),
                apiKey: request.apiKey
            ) { engine, audioURL, _, startedAt, status in
                await status("Transcribing with local Whisper.")
                let result = try await engine.finish(audioURL: audioURL)
                let elapsed = Date().timeIntervalSince(startedAt)
                NSLog("whisper.cpp transcription finished in %.2fs.", elapsed)
                await status(String(format: "Local Whisper transcript ready in %.1fs.", elapsed))
                return result
            }

        case .appleLocal:
            return AIRModeTranscriber(
                engine: AppleRecordingAdapter(context: context, transcribe: dependencies.transcribeAppleLocal),
                apiKey: request.apiKey
            ) { engine, audioURL, _, startedAt, status in
                await status("Transcribing with Apple Speech.")
                let result = try await engine.finish(audioURL: audioURL)
                let elapsed = Date().timeIntervalSince(startedAt)
                NSLog("Apple Speech transcription finished in %.2fs.", elapsed)
                await status(String(format: "Apple Speech transcript ready in %.1fs.", elapsed))
                return result
            }

        case .localParakeetCppFast:
            return oneShotTranscriber(variant: .fast110M, context: context, apiKey: request.apiKey)

        case .localParakeetCppRecommended:
            return oneShotTranscriber(variant: .recommended06B, context: context, apiKey: request.apiKey)

        case .localParakeetCppResident:
            // Whether the resident runtime is installed is checked at stop,
            // as before, so a recording is never rejected at start for it.
            return AIRModeTranscriber(
                engine: AIRParakeetResidentRecordingAdapter(
                    context: context,
                    transcribe: dependencies.transcribeParakeetResident
                ),
                apiKey: request.apiKey
            ) { engine, audioURL, _, startedAt, status in
                guard dependencies.parakeetResidentIsAvailable() else {
                    await status("Resident Parakeet unavailable; using Parakeet.cpp Recommended.")
                    return try await transcribeWithParakeetCpp(
                        variant: .recommended06B,
                        audioURL: audioURL,
                        context: context,
                        startedAt: startedAt,
                        status: status
                    )
                }
                await status("Transcribing with resident Parakeet.")
                let result = try await engine.finish(audioURL: audioURL)
                let elapsed = Date().timeIntervalSince(startedAt)
                NSLog("%@ transcription finished in %.2fs.", result.engineName, elapsed)
                await status(String(format: "Parakeet transcript ready in %.1fs.", elapsed))
                return result
            }

        case .localParakeetStreaming:
            // The transcript streams during recording and finish only flushes
            // the tail. Without a live session, or when it gives no text or
            // fails, the recommended one-shot CLI reads the recorded file.
            let hasLiveSession = request.attachedToCapture && dependencies.liveParakeetIsAvailable()
            let live: ParakeetLiveRecordingAdapter? = hasLiveSession
                ? ParakeetLiveRecordingAdapter(
                    warm: { await RecommendedLiveTranscription.warmUp() },
                    beginSession: { dependencies.beginLiveParakeet() }
                )
                : nil
            return AIRModeTranscriber(engine: live, apiKey: request.apiKey) { engine, audioURL, _, startedAt, status in
                if hasLiveSession {
                    do {
                        let result = try await engine.finish(audioURL: audioURL)
                        if !result.text.isEmpty {
                            let elapsed = Date().timeIntervalSince(startedAt)
                            NSLog("%@ transcription finished in %.2fs.", result.engineName, elapsed)
                            await status(String(format: "Live transcript ready in %.1fs.", elapsed))
                            return result
                        }
                        NSLog("parakeet streaming returned an empty transcript; falling back to offline Parakeet.")
                    } catch {
                        NSLog("parakeet streaming finalize failed; falling back to offline Parakeet: \(error.localizedDescription)")
                    }
                }
                await status("Live streaming unavailable; using Parakeet.cpp Recommended.")
                return try await transcribeWithParakeetCpp(
                    variant: .recommended06B,
                    audioURL: audioURL,
                    context: context,
                    startedAt: Date(),
                    status: status
                )
            }

        case .fastest:
            return nil
        }
    }

    private func oneShotTranscriber(
        variant: ParakeetCppVariant,
        context: TranscriptionContext,
        apiKey: @escaping @Sendable () async -> String
    ) -> AIRModeTranscriber {
        AIRModeTranscriber(engine: nil, apiKey: apiKey) { _, audioURL, _, startedAt, status in
            try await transcribeWithParakeetCpp(
                variant: variant,
                audioURL: audioURL,
                context: context,
                startedAt: startedAt,
                status: status
            )
        }
    }

    /// One run of the one-shot CLI with AIR's status lines around it. Also
    /// the fallback of the resident, live and `fastest` modes.
    func transcribeWithParakeetCpp(
        variant: ParakeetCppVariant,
        audioURL: URL,
        context: TranscriptionContext,
        startedAt: Date,
        status: @escaping Status
    ) async throws -> TranscriptionResult {
        let dependencies = dependencies
        await status("Transcribing with \(variant.engineName).")
        let result = try await ParakeetOneShotRecordingAdapter(
            engineName: variant.engineName,
            run: { try await dependencies.transcribeParakeetCpp(variant, $0, context).text }
        ).begin().finish(audioURL: audioURL)
        let elapsed = Date().timeIntervalSince(startedAt)
        NSLog("%@ transcription finished in %.2fs.", variant.engineName, elapsed)
        await status(String(format: "%@ transcript ready in %.1fs.", variant.engineName, elapsed))
        return result
    }

    /// One OpenAI API upload with AIR's status lines around it. Also the
    /// fallback of the `fastest` mode.
    func transcribeWithOpenAIAPI(
        audioURL: URL,
        apiKey: String,
        context: TranscriptionContext,
        startedAt: Date,
        status: @escaping Status
    ) async throws -> TranscriptionResult {
        await status("Transcribing with OpenAI API.")
        let result = try await OpenAIFileRecordingAdapter(
            apiKey: apiKey,
            context: context,
            transcribe: dependencies.transcribeOpenAIAPI
        ).begin().finish(audioURL: audioURL)
        let elapsed = Date().timeIntervalSince(startedAt)
        NSLog("OpenAI API transcription finished in %.2fs.", elapsed)
        await status(String(format: "OpenAI API transcript ready in %.1fs.", elapsed))
        return result
    }
}

/// One mode as AIR runs it: the engine that is attached to the recording,
/// and the steps AIR takes at finish (status lines and fallback).
struct AIRModeTranscriber: RecordingTranscriber, @unchecked Sendable {
    typealias Finish = (
        _ engine: any RecordingSessionHandle,
        _ audioURL: URL,
        _ apiKey: String,
        _ startedAt: Date,
        _ status: @escaping AIRTranscriberCatalog.Status
    ) async throws -> TranscriptionResult

    /// Nil when the mode's engine is made at finish or the recording has no
    /// live session. `finish` then receives a handle that is not used.
    var engine: (any RecordingTranscriber)?
    var apiKey: @Sendable () async -> String
    var finish: Finish

    init(engine: (any RecordingTranscriber)?, apiKey: @escaping @Sendable () async -> String, finish: @escaping Finish) {
        self.engine = engine
        self.apiKey = apiKey
        self.finish = finish
    }

    func warmUp() async { await engine?.warmUp() }

    func begin() -> any RecordingSessionHandle {
        begin(events: { _ in })
    }

    func begin(events: @escaping @Sendable (TranscriptionEvent) async -> Void) -> any RecordingSessionHandle {
        AIRModeRecordingHandle(
            engine: engine?.begin() ?? EngineResultRecordingHandle { _ in throw CancellationError() },
            apiKey: apiKey,
            finish: finish,
            status: { await events(.status($0)) }
        )
    }
}

/// The handle for one AIR recording. The lock guards only the cancelled flag;
/// the engine handle and the finish steps run with the lock released.
final class AIRModeRecordingHandle: RecordingSessionHandle, @unchecked Sendable {
    private let engine: any RecordingSessionHandle
    private let apiKey: @Sendable () async -> String
    private let finishSteps: AIRModeTranscriber.Finish
    private let status: AIRTranscriberCatalog.Status
    private let lock = NSLock()
    private var cancelled = false

    init(
        engine: any RecordingSessionHandle,
        apiKey: @escaping @Sendable () async -> String,
        finish: @escaping AIRModeTranscriber.Finish,
        status: @escaping AIRTranscriberCatalog.Status
    ) {
        self.engine = engine
        self.apiKey = apiKey
        self.finishSteps = finish
        self.status = status
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func receive(_ event: AudioCaptureEvent) {
        guard !isCancelled else { return }
        engine.receive(event)
    }

    func finish(audioURL: URL) async throws -> TranscriptionResult {
        guard !isCancelled else { throw CancellationError() }
        let apiKey = await apiKey()
        return try await finishSteps(engine, audioURL, apiKey, Date(), status)
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        lock.unlock()
        if !wasCancelled {
            engine.cancel()
        }
    }
}
