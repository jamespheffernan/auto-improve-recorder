import Foundation

/// AIR's `fastest` mode: OpenAI realtime transcription while recording.
/// Without a key or a started socket the recommended one-shot CLI reads the
/// recorded file; when the realtime finish fails or gives two words or fewer
/// the OpenAI API does.
struct AIRRealtimeTranscriber: RecordingTranscriber, @unchecked Sendable {
    var catalog: AIRTranscriberCatalog
    var request: RecordingTranscriptionRequest

    func warmUp() async {}

    func begin() -> any RecordingSessionHandle {
        begin(events: { _ in })
    }

    func begin(events: @escaping @Sendable (TranscriptionEvent) async -> Void) -> any RecordingSessionHandle {
        AIRRealtimeRecordingHandle(catalog: catalog, request: request, events: events)
    }
}

/// The handle for one `fastest` recording. It owns the audio sink, the
/// socket's startup and the realtime transcriber. The lock guards the fields
/// below it; the sink, the transcriber and `events` are called with the lock
/// released.
final class AIRRealtimeRecordingHandle: RecordingSessionHandle, @unchecked Sendable {
    private enum Socket {
        case notStarted
        case starting
        /// Started; the sink is replaying the audio it held.
        case replaying(OpenAIRealtimeTranscriber)
        case ready(OpenAIRealtimeTranscriber)
        /// No key, a failed start, given up, or taken by `finish` or `cancel`.
        case unavailable
    }

    private let catalog: AIRTranscriberCatalog
    private let request: RecordingTranscriptionRequest
    private let events: @Sendable (TranscriptionEvent) async -> Void
    private let sink = OpenAIRealtimeAudioSink()
    private let createdAt = Date()

    private let lock = NSLock()
    private var socket = Socket.notStarted
    private var startupTask: Task<String?, Never>?
    /// True once the recording is stopping, finishing or cancelled. A socket
    /// that starts after that is cancelled and not used.
    private var closed = false
    private var cancelled = false
    private var replayWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        catalog: AIRTranscriberCatalog,
        request: RecordingTranscriptionRequest,
        events: @escaping @Sendable (TranscriptionEvent) async -> Void
    ) {
        self.catalog = catalog
        self.request = request
        self.events = events
        sink.reset(
            bufferPendingAudio: request.attachedToCapture &&
                !request.apiKeyAtStart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    var captureFailure: AudioCaptureFailure? {
        sink.captureFailureSnapshot()
    }

    func receive(_ event: AudioCaptureEvent) {
        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        guard !wasCancelled else { return }
        switch event {
        case .captured(let captured):
            sink.appendAudioBuffer(captured)
        case .failure(let failure):
            sink.recordCaptureFailure(failure)
        }
    }

    func prepare() async -> String? {
        guard let task = beginStartup() else { return nil }
        return await task.value
    }

    func captureWillStop() -> String? {
        lock.lock()
        closed = true
        let task = startupTask
        var hasTranscriber = false
        switch socket {
        case .replaying, .ready:
            hasTranscriber = true
        case .notStarted, .starting, .unavailable:
            break
        }
        lock.unlock()
        guard !hasTranscriber else { return "Finalizing OpenAI streaming transcript." }
        task?.cancel()
        return nil
    }

    func finish(audioURL: URL) async throws -> TranscriptionResult {
        var (transcriber, isReplaying) = try closeForFinish()
        if isReplaying {
            await withCheckedContinuation { continuation in
                if !self.waitForReplay(continuation) {
                    continuation.resume()
                }
            }
            (transcriber, _) = try closeForFinish()
        }
        sink.clear()
        let apiKey = await request.apiKey()
        return try await transcribeFastest(
            streamingTranscriber: transcriber,
            audioURL: audioURL,
            apiKey: apiKey,
            context: TranscriptionContext(dictionarySnapshot: request.dictionarySnapshot),
            startedAt: Date()
        )
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        closed = true
        let task = startupTask
        startupTask = nil
        var transcriber: OpenAIRealtimeTranscriber?
        // A transcriber whose replay is running is cancelled when the replay ends.
        if case .ready(let ready) = socket {
            transcriber = ready
            socket = .unavailable
        }
        lock.unlock()
        guard !wasCancelled else { return }
        task?.cancel()
        sink.clear()
        if let transcriber {
            let cancelRealtime = catalog.dependencies.cancelRealtime
            Task { await cancelRealtime(transcriber) }
        }
    }

    // MARK: Startup

    private func beginStartup() -> Task<String?, Never>? {
        lock.lock()
        defer { lock.unlock() }
        guard request.attachedToCapture, !closed, case .notStarted = socket else { return nil }
        socket = .starting
        let task = Task { await self.startSocket() }
        startupTask = task
        return task
    }

    private func startSocket() async -> String? {
        let dependencies = catalog.dependencies
        let apiKey = await request.apiKey()
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard markUnavailableUnlessClosed() else { return nil }
            let reason = "Fastest mode needs an OpenAI API key. Falling back to Parakeet."
            await events(.diagnostic(TranscriptionDiagnostic(summary: reason, details: reason)))
            sink.discardPendingAudio()
            return reason
        }

        let transcriber = dependencies.makeRealtimeTranscriber(apiKey, request.dictionarySnapshot)
        do {
            try await dependencies.startRealtime(transcriber)
        } catch {
            guard markUnavailableUnlessClosed() else {
                await dependencies.cancelRealtime(transcriber)
                return nil
            }
            let summary = "OpenAI streaming unavailable; falling back to Parakeet. \(error.localizedDescription)"
            let diagnostics = await dependencies.realtimeDiagnostics(transcriber, summary)
            await events(.diagnostic(TranscriptionDiagnostic(summary: diagnostics.summary, details: diagnostics.details)))
            NSLog("OpenAI realtime transcription start failed: \(diagnostics.details)")
            await dependencies.cancelRealtime(transcriber)
            sink.discardPendingAudio()
            return "OpenAI streaming unavailable; falling back to Parakeet."
        }

        guard beginReplay(of: transcriber) else {
            await dependencies.cancelRealtime(transcriber)
            return nil
        }
        let replayedBufferCount = sink.setTranscriber(dependencies.realtimeAudioConsumer(transcriber))
        let captureFailure = sink.captureFailureSnapshot()
        let (wasCancelled, wasClosed) = endReplay(of: transcriber)
        if wasCancelled {
            await dependencies.cancelRealtime(transcriber)
            return nil
        }
        NSLog(
            "Recording startup: OpenAI realtime ready %.3fs after the handle began; replayed %d buffered audio buffers.",
            Date().timeIntervalSince(createdAt),
            replayedBufferCount
        )
        guard !wasClosed else { return nil }
        if let captureFailure {
            return "Recording degraded. Stop and try again. \(captureFailure.localizedDescription)"
        }
        return "Recording with OpenAI realtime transcription."
    }

    /// False when the recording stopped or was cancelled while the socket was
    /// starting. Nothing is reported for that socket then.
    private func markUnavailableUnlessClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        socket = .unavailable
        return true
    }

    private func beginReplay(of transcriber: OpenAIRealtimeTranscriber) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return false }
        socket = .replaying(transcriber)
        return true
    }

    private func endReplay(of transcriber: OpenAIRealtimeTranscriber) -> (wasCancelled: Bool, wasClosed: Bool) {
        lock.lock()
        socket = cancelled ? .unavailable : .ready(transcriber)
        let state = (cancelled, closed)
        let waiters = replayWaiters
        replayWaiters = []
        lock.unlock()
        waiters.forEach { $0.resume() }
        return state
    }

    // MARK: Finish

    /// Takes the ready transcriber for `finish`. A socket that is still
    /// starting is given up, so `finish` uses the recommended one-shot CLI.
    private func closeForFinish() throws -> (transcriber: OpenAIRealtimeTranscriber?, isReplaying: Bool) {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            throw CancellationError()
        }
        closed = true
        let task = startupTask
        var transcriber: OpenAIRealtimeTranscriber?
        var isReplaying = false
        switch socket {
        case .ready(let ready):
            transcriber = ready
            socket = .unavailable
        case .replaying:
            isReplaying = true
        case .notStarted, .starting, .unavailable:
            break
        }
        lock.unlock()
        if transcriber == nil, !isReplaying {
            task?.cancel()
        }
        return (transcriber, isReplaying)
    }

    /// False when the replay has already ended.
    private func waitForReplay(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .replaying = socket else { return false }
        replayWaiters.append(continuation)
        return true
    }

    private func transcribeFastest(
        streamingTranscriber: OpenAIRealtimeTranscriber?,
        audioURL: URL,
        apiKey: String,
        context: TranscriptionContext,
        startedAt: Date
    ) async throws -> TranscriptionResult {
        let dependencies = catalog.dependencies
        let events = events
        let status: AIRTranscriberCatalog.Status = { await events(.status($0)) }
        let recordDiagnostics: (OpenAIRealtimeDiagnostics) async -> Void = { diagnostics in
            await events(.diagnostic(TranscriptionDiagnostic(summary: diagnostics.summary, details: diagnostics.details)))
        }

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
