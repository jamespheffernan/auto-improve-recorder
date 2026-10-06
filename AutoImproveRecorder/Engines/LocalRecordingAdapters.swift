import Foundation

/// Phonon-2. It reads the saved file at finish and ignores capture buffers.
struct PhononRecordingAdapter: RecordingTranscriber {
    var engineName = "Phonon-2"
    var warm: @Sendable () async -> Void
    var transcribe: @Sendable (URL) async throws -> String

    func warmUp() async { await warm() }

    func begin() -> any RecordingSessionHandle {
        SavedFileRecordingHandle(engineName: engineName, transcribe: transcribe)
    }
}

extension PhononRecordingAdapter {
    /// The process-wide Phonon worker.
    static let shared = PhononRecordingAdapter(
        warm: { await PhononTranscriber.shared.warmUp() },
        transcribe: { try await PhononTranscriber.shared.transcribe(audioURL: $0) }
    )
}

/// Live Parakeet. Each recording gets its own live session, which receives
/// every capture event and is finalized at finish.
struct ParakeetLiveRecordingAdapter: RecordingTranscriber {
    var warm: @Sendable () async -> Void
    var beginSession: @Sendable () -> any LocalLiveTranscriptionSession

    func warmUp() async { await warm() }

    func begin() -> any RecordingSessionHandle {
        LiveRecordingHandle(session: beginSession())
    }
}

extension ParakeetLiveRecordingAdapter {
    static let recommended = ParakeetLiveRecordingAdapter(
        warm: { await RecommendedLiveTranscription.warmUp() },
        beginSession: { RecommendedLiveTranscription.begin() }
    )
}

/// Parakeet through the in-process C API with a model that stays loaded. It
/// reads the saved file at finish and ignores capture buffers.
struct ParakeetResidentRecordingAdapter: RecordingTranscriber {
    var engineName: String
    var warm: @Sendable () async -> Void
    var transcribe: @Sendable (URL) async throws -> String

    func warmUp() async { await warm() }

    func begin() -> any RecordingSessionHandle {
        SavedFileRecordingHandle(engineName: engineName, transcribe: transcribe)
    }
}

extension ParakeetResidentRecordingAdapter {
    /// The shared resident runtime with one model file under `<root>/models`.
    /// The model path is under the root the library loaded from, or under
    /// the current root while no load has succeeded.
    static func runtime(modelFilename: String, provider: String) -> ParakeetResidentRecordingAdapter {
        let modelPath: @Sendable () -> String = {
            ParakeetResidentRuntime.shared.modelPath(filename: modelFilename)
        }
        return ParakeetResidentRecordingAdapter(
            engineName: provider,
            warm: {
                guard ParakeetCAPI.isInstalled,
                      FileManager.default.fileExists(atPath: modelPath()) else { return }
                await Task.detached(priority: .utility) {
                    guard let context = try? ParakeetResidentRuntime.shared.context(
                        modelPath: modelPath()
                    ) else { return }
                    context.warmUpOnce()
                }.value
            },
            transcribe: { audioURL in
                guard FileManager.default.fileExists(atPath: audioURL.path) else {
                    throw ParakeetRunnerError.audioMissing(audioURL.path)
                }
                let text = try await Task.detached(priority: .userInitiated) {
                    let context = try ParakeetResidentRuntime.shared.context(modelPath: modelPath())
                    return try context.transcribe(wavPath: audioURL.path, provider: provider)
                }.value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw ParakeetRunnerError.emptyTranscript
                }
                return text
            }
        )
    }
}

/// Parakeet through one CLI run per recording. It reads the saved file at
/// finish, ignores capture buffers and has nothing to warm.
struct ParakeetOneShotRecordingAdapter: RecordingTranscriber {
    var engineName: String
    var run: @Sendable (URL) async throws -> String

    func warmUp() async {}

    func begin() -> any RecordingSessionHandle {
        SavedFileRecordingHandle(engineName: engineName, transcribe: run)
    }
}

extension ParakeetOneShotRecordingAdapter {
    static func process(_ process: ParakeetOneShotProcess) -> ParakeetOneShotRecordingAdapter {
        ParakeetOneShotRecordingAdapter(
            engineName: ParakeetOneShotProcess.engineName,
            run: { try await process.transcribe(audioURL: $0) }
        )
    }
}

/// The handle for engines that read the saved file.
final class SavedFileRecordingHandle: RecordingSessionHandle, @unchecked Sendable {
    private let engineName: String
    private let transcribe: @Sendable (URL) async throws -> String
    private let lock = NSLock()
    private var cancelled = false

    init(engineName: String, transcribe: @escaping @Sendable (URL) async throws -> String) {
        self.engineName = engineName
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
        return TranscriptionResult(text: try await transcribe(audioURL), engineName: engineName)
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// The handle for one live session. The lock guards only the cancelled flag;
/// the session is always called with the lock released.
final class LiveRecordingHandle: RecordingSessionHandle, @unchecked Sendable {
    private let session: any LocalLiveTranscriptionSession
    private let lock = NSLock()
    private var cancelled = false

    init(session: any LocalLiveTranscriptionSession) {
        self.session = session
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func receive(_ event: AudioCaptureEvent) {
        guard !isCancelled else { return }
        switch event {
        case .captured(let captured):
            session.append(captured)
        case .failure(let failure):
            session.recordCaptureFailure(failure)
        }
    }

    func finish(audioURL: URL) async throws -> TranscriptionResult {
        guard !isCancelled else { throw CancellationError() }
        return TranscriptionResult(text: try await session.finalize(), engineName: session.engineName)
    }

    func cancel() {
        lock.lock()
        let wasCancelled = cancelled
        cancelled = true
        lock.unlock()
        if !wasCancelled {
            session.cancel()
        }
    }
}
