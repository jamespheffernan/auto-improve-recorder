import Foundation

struct TranscriptionResult: Equatable {
    var text: String
    var engineName: String
}

protocol TranscriptionEngine {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

enum TranscriptionEngineError: LocalizedError {
    case audioMissing(String)
    case emptyLocalTranscript(provider: String)

    var errorDescription: String? {
        switch self {
        case .audioMissing(let path):
            return "Recording file not found at \(path). The audio was not deleted."
        case .emptyLocalTranscript(let provider):
            return "\(provider) did not detect speech. The recording was kept."
        }
    }
}

enum ParakeetCppVariant {
    case recommended06B

    var modelFilename: String {
        "tdt-0.6b-v2-q4_k.gguf"
    }
}

enum ParakeetCppTranscriber {
    static var installBaseURL: URL {
        if AutoSendRuntimeInstaller.isReady() { return AutoSendRuntimeInstaller.destination }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoImproveRecorder/ParakeetCpp")
    }
}

enum LocalModelInventory {
    static let liveRecommendedModelFilename = "nemotron-3.5-asr-streaming-0.6b-q8_0.gguf"
}

final class ParakeetLiveInputAdmission: @unchecked Sendable {
    private static let maximumQueuedBytes = 4 * 1_024 * 1_024
    private let lock = NSLock()
    private var queuedBytes = 0
    private var acceptingInput = true
    private var cancelled = false
    private var overflowed = false

    func reserve(byteCount: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingInput, byteCount >= 0 else { return false }
        guard byteCount <= Self.maximumQueuedBytes - queuedBytes else {
            acceptingInput = false
            overflowed = true
            return false
        }
        queuedBytes += byteCount
        return true
    }

    func complete(byteCount: Int) {
        lock.lock()
        queuedBytes = max(0, queuedBytes - max(0, byteCount))
        lock.unlock()
    }

    func closeForFinalize() {
        lock.lock()
        acceptingInput = false
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        acceptingInput = false
        cancelled = true
        lock.unlock()
    }

    var shouldProcessQueuedInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && !overflowed
    }

    var failureMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        return overflowed
            ? "Live transcription could not keep up with audio capture; using the saved recording instead."
            : nil
    }
}
