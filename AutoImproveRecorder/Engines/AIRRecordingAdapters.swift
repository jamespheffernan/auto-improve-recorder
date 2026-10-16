import Foundation

/// OpenAI's file transcription API. It uploads the saved file at finish and
/// ignores capture buffers. The key is the one read when the recording stopped.
struct OpenAIFileRecordingAdapter: RecordingTranscriber, @unchecked Sendable {
    var apiKey: String
    var context: TranscriptionContext
    var transcribe: (String, URL, TranscriptionContext) async throws -> TranscriptionResult

    func warmUp() async {}

    func begin() -> any RecordingSessionHandle {
        let apiKey = apiKey
        let context = context
        let transcribe = transcribe
        return EngineResultRecordingHandle { audioURL in
            try await transcribe(apiKey, audioURL, context)
        }
    }
}

/// Apple Speech. It reads the saved file at finish, ignores capture buffers
/// and has nothing to warm.
struct AppleRecordingAdapter: RecordingTranscriber, @unchecked Sendable {
    var context: TranscriptionContext
    var transcribe: (URL, TranscriptionContext) async throws -> TranscriptionResult

    func warmUp() async {}

    func begin() -> any RecordingSessionHandle {
        let context = context
        let transcribe = transcribe
        return EngineResultRecordingHandle { audioURL in
            try await transcribe(audioURL, context)
        }
    }
}

/// The local whisper.cpp server. It sends the saved file at finish and
/// ignores capture buffers.
struct WhisperRecordingAdapter: RecordingTranscriber, @unchecked Sendable {
    var context: TranscriptionContext
    var warm: () async -> Void
    var transcribe: (URL, TranscriptionContext) async throws -> TranscriptionResult

    func warmUp() async { await warm() }

    func begin() -> any RecordingSessionHandle {
        let context = context
        let transcribe = transcribe
        return EngineResultRecordingHandle { audioURL in
            try await transcribe(audioURL, context)
        }
    }
}

/// AIR's resident Parakeet engine. It reads the saved file at finish and
/// ignores capture buffers. The result keeps the engine's own name and the
/// errors are the engine's own.
struct AIRParakeetResidentRecordingAdapter: RecordingTranscriber, @unchecked Sendable {
    var context: TranscriptionContext
    var transcribe: (URL, TranscriptionContext) async throws -> TranscriptionResult

    func warmUp() async {}

    func begin() -> any RecordingSessionHandle {
        let context = context
        let transcribe = transcribe
        return EngineResultRecordingHandle { audioURL in
            try await transcribe(audioURL, context)
        }
    }
}

/// The handle for AIR engines that read the saved file and return their own
/// engine name with the text.
final class EngineResultRecordingHandle: RecordingSessionHandle, @unchecked Sendable {
    private let transcribe: (URL) async throws -> TranscriptionResult
    private let lock = NSLock()
    private var cancelled = false

    init(transcribe: @escaping (URL) async throws -> TranscriptionResult) {
        self.transcribe = transcribe
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func receive(_ event: AudioCaptureEvent) {}

    func finish(audioURL: URL) async throws -> TranscriptionResult {
        guard !isCancelled else { throw CancellationError() }
        return try await transcribe(audioURL)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
