import Foundation

protocol TranscriptionService {
    func prepareRealtimeIfNeeded(
        mode: TranscriptionMode,
        apiKey: String,
        dictionarySnapshot: String,
        status: @escaping (String) async -> Void,
        recordDiagnostics: @escaping (OpenAIRealtimeDiagnostics) async -> Void
    ) async -> OpenAIRealtimeTranscriber?

    /// Starts the transcription work for one recording in the request's mode.
    /// It is called before the first capture buffer and does not wait for a
    /// model to load.
    func beginRecording(
        _ request: RecordingTranscriptionRequest,
        status: @escaping @Sendable (String) async -> Void,
        recordDiagnostics: @escaping @Sendable (OpenAIRealtimeDiagnostics) async -> Void
    ) -> any RecordingSessionHandle
}

struct LiveTranscriptionService: TranscriptionService {
    typealias Dependencies = AIRTranscriberCatalog.Dependencies

    var dependencies = Dependencies()

    private var catalog: AIRTranscriberCatalog {
        AIRTranscriberCatalog(dependencies: dependencies)
    }

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

        let transcriber = dependencies.makeRealtimeTranscriber(apiKey, dictionarySnapshot)
        do {
            try await dependencies.startRealtime(transcriber)
            return transcriber
        } catch {
            let summary = "OpenAI streaming unavailable; falling back to Parakeet. \(error.localizedDescription)"
            let diagnostics = await dependencies.realtimeDiagnostics(transcriber, summary)
            await recordDiagnostics(diagnostics)
            await status("OpenAI streaming unavailable; falling back to Parakeet.")
            NSLog("OpenAI realtime transcription start failed: \(diagnostics.details)")
            await dependencies.cancelRealtime(transcriber)
            return nil
        }
    }

    func beginRecording(
        _ request: RecordingTranscriptionRequest,
        status: @escaping @Sendable (String) async -> Void,
        recordDiagnostics: @escaping @Sendable (OpenAIRealtimeDiagnostics) async -> Void
    ) -> any RecordingSessionHandle {
        if let transcriber = catalog.transcriber(for: request) {
            return transcriber.begin(events: { event in
                switch event {
                case .status(let message):
                    await status(message)
                }
            })
        }

        // `fastest`: the realtime transcriber is still made and owned outside
        // the handle, so the handle only runs the finish steps.
        let service = self
        return RealtimeBridgeRecordingHandle { streamingTranscriber, audioURL in
            let apiKey = await request.apiKey()
            let startedAt = Date()
            return try await service.transcribeFastest(
                streamingTranscriber: streamingTranscriber,
                audioURL: audioURL,
                apiKey: apiKey,
                context: TranscriptionContext(dictionarySnapshot: request.dictionarySnapshot),
                startedAt: startedAt,
                status: status,
                recordDiagnostics: recordDiagnostics
            )
        }
    }

    private func transcribeFastest(
        streamingTranscriber: OpenAIRealtimeTranscriber?,
        audioURL: URL,
        apiKey: String,
        context: TranscriptionContext,
        startedAt: Date,
        status: @escaping @Sendable (String) async -> Void,
        recordDiagnostics: @escaping (OpenAIRealtimeDiagnostics) async -> Void
    ) async throws -> TranscriptionResult {
        if let streamingTranscriber {
            do {
                let result = try await dependencies.finishRealtime(streamingTranscriber)
                let elapsed = Date().timeIntervalSince(startedAt)
                if shouldVerifyRealtimeTranscript(result.text) {
                    let reason = "OpenAI realtime returned a suspiciously short transcript (‘\(result.text)’); using OpenAI API transcription instead."
                    await recordDiagnostics(await dependencies.realtimeDiagnostics(streamingTranscriber, reason))
                    NSLog(reason)
                    await status("Realtime transcript looked wrong; using OpenAI API.")
                    return try await catalog.transcribeWithOpenAIAPI(
                        audioURL: audioURL,
                        apiKey: apiKey,
                        context: context,
                        startedAt: Date(),
                        status: status
                    )
                }
                await status(String(format: "OpenAI transcript ready in %.1fs.", elapsed))
                return result
            } catch {
                let summary = "OpenAI streaming failed; falling back to OpenAI API. \(error.localizedDescription)"
                let diagnostics = await dependencies.realtimeDiagnostics(streamingTranscriber, summary)
                await recordDiagnostics(diagnostics)
                NSLog("OpenAI realtime transcription finalize failed; falling back to OpenAI API: \(diagnostics.details)")
                await status("OpenAI streaming failed; using OpenAI API.")
                return try await catalog.transcribeWithOpenAIAPI(
                    audioURL: audioURL,
                    apiKey: apiKey,
                    context: context,
                    startedAt: Date(),
                    status: status
                )
            }
        }

        await status("Fastest unavailable; falling back to Parakeet.cpp Recommended.")
        return try await catalog.transcribeWithParakeetCpp(
            variant: .recommended06B,
            audioURL: audioURL,
            context: context,
            startedAt: Date(),
            status: status
        )
    }

    private func shouldVerifyRealtimeTranscript(_ text: String) -> Bool {
        let words = text
            .split { !$0.isLetter && !$0.isNumber }
            .filter { !$0.isEmpty }
        return words.count <= 2
    }
}

/// The handle for a `fastest` recording until its realtime path moves behind
/// the handle. `AppState` still owns the realtime transcriber and the audio
/// sink: it feeds and cancels them itself and gives the transcriber to this
/// handle when the recording stops.
final class RealtimeBridgeRecordingHandle: RecordingSessionHandle, @unchecked Sendable {
    private let finishSteps: (OpenAIRealtimeTranscriber?, URL) async throws -> TranscriptionResult
    private let lock = NSLock()
    private var cancelled = false
    private var realtimeTranscriber: OpenAIRealtimeTranscriber?

    init(finish: @escaping (OpenAIRealtimeTranscriber?, URL) async throws -> TranscriptionResult) {
        self.finishSteps = finish
    }

    /// Called at stop, before `finish`, with the transcriber that is ready.
    /// Without it `finish` uses the recommended one-shot CLI.
    func useRealtimeTranscriber(_ transcriber: OpenAIRealtimeTranscriber?) {
        lock.lock()
        realtimeTranscriber = transcriber
        lock.unlock()
    }

    func receive(_ event: AudioCaptureEvent) {}

    func finish(audioURL: URL) async throws -> TranscriptionResult {
        lock.lock()
        let wasCancelled = cancelled
        let transcriber = realtimeTranscriber
        realtimeTranscriber = nil
        lock.unlock()
        guard !wasCancelled else { throw CancellationError() }
        return try await finishSteps(transcriber, audioURL)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        realtimeTranscriber = nil
        lock.unlock()
    }
}
