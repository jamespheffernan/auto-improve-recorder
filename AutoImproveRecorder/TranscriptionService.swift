import Foundation

struct TranscriptionServiceRequest {
    var audioURL: URL
    var mode: TranscriptionMode
    var apiKey: String
    var dictionarySnapshot: String
    var streamingTranscriber: OpenAIRealtimeTranscriber?
}

protocol TranscriptionService {
    func prepareRealtimeIfNeeded(
        mode: TranscriptionMode,
        apiKey: String,
        dictionarySnapshot: String,
        status: @escaping (String) async -> Void,
        recordDiagnostics: @escaping (OpenAIRealtimeDiagnostics) async -> Void
    ) async -> OpenAIRealtimeTranscriber?

    func transcribe(
        _ request: TranscriptionServiceRequest,
        status: @escaping (String) async -> Void,
        recordDiagnostics: @escaping (OpenAIRealtimeDiagnostics) async -> Void
    ) async throws -> TranscriptionResult
}

struct LiveTranscriptionService: TranscriptionService {
    func prepareRealtimeIfNeeded(
        mode: TranscriptionMode,
        apiKey: String,
        dictionarySnapshot: String,
        status: @escaping (String) async -> Void,
        recordDiagnostics: @escaping (OpenAIRealtimeDiagnostics) async -> Void
    ) async -> OpenAIRealtimeTranscriber? {
        guard mode == .fastest else { return nil }

        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let reason = "Fastest mode needs an OpenAI API key. Falling back to Parakeet."
            await recordDiagnostics(OpenAIRealtimeDiagnostics(summary: reason, details: reason))
            await status(reason)
            return nil
        }

        let transcriber = OpenAIRealtimeTranscriber(apiKey: apiKey, dictionarySnapshot: dictionarySnapshot)
        do {
            try await transcriber.start()
            return transcriber
        } catch {
            let summary = "OpenAI streaming unavailable; falling back to Parakeet. \(error.localizedDescription)"
            let diagnostics = await transcriber.diagnostics(summary: summary)
            await recordDiagnostics(diagnostics)
            await status("OpenAI streaming unavailable; falling back to Parakeet.")
            NSLog("OpenAI realtime transcription start failed: \(diagnostics.details)")
            await transcriber.cancel()
            return nil
        }
    }

    func transcribe(
        _ request: TranscriptionServiceRequest,
        status: @escaping (String) async -> Void,
        recordDiagnostics: @escaping (OpenAIRealtimeDiagnostics) async -> Void
    ) async throws -> TranscriptionResult {
        let startedAt = Date()
        let context = TranscriptionContext(dictionarySnapshot: request.dictionarySnapshot)

        switch request.mode {
        case .openAIAPI:
            return try await transcribeWithOpenAIAPI(
                audioURL: request.audioURL,
                apiKey: request.apiKey,
                context: context,
                startedAt: startedAt,
                status: status
            )

        case .localWhisper:
            return try await transcribeWithLocalWhisper(
                audioURL: request.audioURL,
                context: context,
                startedAt: startedAt,
                status: status
            )

        case .appleLocal:
            return try await transcribeWithAppleLocal(
                audioURL: request.audioURL,
                context: context,
                startedAt: startedAt,
                status: status
            )

        case .localParakeetCppFast:
            return try await transcribeWithParakeetCpp(
                variant: .fast110M,
                audioURL: request.audioURL,
                context: context,
                startedAt: startedAt,
                status: status
            )

        case .localParakeetCppRecommended:
            return try await transcribeWithParakeetCpp(
                variant: .recommended06B,
                audioURL: request.audioURL,
                context: context,
                startedAt: startedAt,
                status: status
            )

        case .fastest:
            return try await transcribeFastest(
                request,
                context: context,
                startedAt: startedAt,
                status: status,
                recordDiagnostics: recordDiagnostics
            )
        }
    }

    private func transcribeFastest(
        _ request: TranscriptionServiceRequest,
        context: TranscriptionContext,
        startedAt: Date,
        status: @escaping (String) async -> Void,
        recordDiagnostics: @escaping (OpenAIRealtimeDiagnostics) async -> Void
    ) async throws -> TranscriptionResult {
        if let streamingTranscriber = request.streamingTranscriber {
            do {
                let result = try await streamingTranscriber.finish()
                let elapsed = Date().timeIntervalSince(startedAt)
                if shouldVerifyRealtimeTranscript(result.text) {
                    let reason = "OpenAI realtime returned a suspiciously short transcript (‘\(result.text)’); using OpenAI API transcription instead."
                    await recordDiagnostics(await streamingTranscriber.diagnostics(summary: reason))
                    NSLog(reason)
                    await status("Realtime transcript looked wrong; using OpenAI API.")
                    return try await transcribeWithOpenAIAPI(
                        audioURL: request.audioURL,
                        apiKey: request.apiKey,
                        context: context,
                        startedAt: Date(),
                        status: status
                    )
                }
                await status(String(format: "OpenAI transcript ready in %.1fs.", elapsed))
                return result
            } catch {
                let summary = "OpenAI streaming failed; falling back to OpenAI API. \(error.localizedDescription)"
                let diagnostics = await streamingTranscriber.diagnostics(summary: summary)
                await recordDiagnostics(diagnostics)
                NSLog("OpenAI realtime transcription finalize failed; falling back to OpenAI API: \(diagnostics.details)")
                await status("OpenAI streaming failed; using OpenAI API.")
                return try await transcribeWithOpenAIAPI(
                    audioURL: request.audioURL,
                    apiKey: request.apiKey,
                    context: context,
                    startedAt: Date(),
                    status: status
                )
            }
        }

        await status("Fastest unavailable; falling back to Parakeet.cpp Recommended.")
        return try await transcribeWithParakeetCpp(
            variant: .recommended06B,
            audioURL: request.audioURL,
            context: context,
            startedAt: Date(),
            status: status
        )
    }

    private func transcribeWithParakeetCpp(
        variant: ParakeetCppVariant,
        audioURL: URL,
        context: TranscriptionContext,
        startedAt: Date,
        status: @escaping (String) async -> Void
    ) async throws -> TranscriptionResult {
        await status("Transcribing with \(variant.engineName).")
        let transcriber = ParakeetCppTranscriber(variant: variant)
        let result = try await transcriber.transcribe(audioURL: audioURL, context: context)
        let elapsed = Date().timeIntervalSince(startedAt)
        NSLog("%@ transcription finished in %.2fs.", variant.engineName, elapsed)
        await status(String(format: "%@ transcript ready in %.1fs.", variant.engineName, elapsed))
        return result
    }

    private func transcribeWithOpenAIAPI(
        audioURL: URL,
        apiKey: String,
        context: TranscriptionContext,
        startedAt: Date,
        status: @escaping (String) async -> Void
    ) async throws -> TranscriptionResult {
        await status("Transcribing with OpenAI API.")
        let transcriber = OpenAIAudioTranscriber(apiKey: apiKey)
        let result = try await transcriber.transcribe(audioURL: audioURL, context: context)
        let elapsed = Date().timeIntervalSince(startedAt)
        NSLog("OpenAI API transcription finished in %.2fs.", elapsed)
        await status(String(format: "OpenAI API transcript ready in %.1fs.", elapsed))
        return result
    }

    private func transcribeWithAppleLocal(
        audioURL: URL,
        context: TranscriptionContext,
        startedAt: Date,
        status: @escaping (String) async -> Void
    ) async throws -> TranscriptionResult {
        await status("Transcribing with Apple Speech.")
        let result = try await AppleLocalAudioTranscriber().transcribe(audioURL: audioURL, context: context)
        let elapsed = Date().timeIntervalSince(startedAt)
        NSLog("Apple Speech transcription finished in %.2fs.", elapsed)
        await status(String(format: "Apple Speech transcript ready in %.1fs.", elapsed))
        return result
    }

    private func transcribeWithLocalWhisper(
        audioURL: URL,
        context: TranscriptionContext,
        startedAt: Date,
        status: @escaping (String) async -> Void
    ) async throws -> TranscriptionResult {
        await status("Transcribing with local Whisper.")
        let result = try await WhisperCppTranscriber().transcribe(audioURL: audioURL, context: context)
        let elapsed = Date().timeIntervalSince(startedAt)
        NSLog("whisper.cpp transcription finished in %.2fs.", elapsed)
        await status(String(format: "Local Whisper transcript ready in %.1fs.", elapsed))
        return result
    }

    private func shouldVerifyRealtimeTranscript(_ text: String) -> Bool {
        let words = text
            .split { !$0.isLetter && !$0.isNumber }
            .filter { !$0.isEmpty }
        return words.count <= 2
    }
}
