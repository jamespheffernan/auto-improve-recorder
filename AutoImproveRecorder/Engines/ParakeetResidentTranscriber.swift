import Foundation

/// Option A: the 0.6B TDT model held resident in-process. Same model and
/// output as the `parakeet-cli` path, minus the ~1.1 s per-invocation model
/// load: stop-to-transcript drops from ~1.4 s to ~0.3 s.
struct ParakeetResidentTranscriber: TranscriptionEngine {
    static var modelPath: String {
        ParakeetCppTranscriber.installBaseURL
            .appendingPathComponent("models/\(ParakeetCppVariant.recommended06B.modelFilename)")
            .path
    }

    static var isAvailable: Bool {
        ParakeetCAPI.isInstalled && FileManager.default.fileExists(atPath: modelPath)
    }

    private let providerName = "parakeet.cpp 0.6B v2 resident"
    private let engineName = "parakeet.cpp 0.6B v2 Q4_K Metal resident"

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionEngineError.audioMissing(audioURL.path)
        }
        let provider = providerName
        let text = try await Task.detached(priority: .userInitiated) {
            let context = try ParakeetResidentRuntime.shared.context(modelPath: Self.modelPath)
            return try context.transcribe(wavPath: audioURL.path, provider: provider)
        }.value
        guard !text.isEmpty else {
            throw TranscriptionEngineError.emptyLocalTranscript(provider: providerName)
        }
        return TranscriptionResult(text: text, engineName: engineName)
    }

    func warmUp() async {
        guard Self.isAvailable else { return }
        await Task.detached(priority: .utility) {
            guard let context = try? ParakeetResidentRuntime.shared.context(modelPath: Self.modelPath) else { return }
            context.warmUpOnce()
        }.value
    }
}
