import Foundation

struct TranscriptionResult: Equatable {
    var text: String
    var engineName: String
}

protocol TranscriptionEngine {
    func transcribe(audioURL: URL) async throws -> TranscriptionResult
}

enum TranscriptionEngineError: LocalizedError {
    case runtimeMissing(String)
    case scriptMissing(String)
    case audioMissing(String)
    case timedOut
    case processFailed(status: Int32, stderr: String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .runtimeMissing(let path):
            return "Parakeet runtime not found at \(path). Open Settings and run Auto-detect, or point Runtime Path at Field Theory's build-parakeet venv."
        case .scriptMissing(let path):
            return "Parakeet script not found at \(path). Install or restore Field Theory, then run Auto-detect in Settings."
        case .audioMissing(let path):
            return "Recording file not found at \(path). Try recording again."
        case .timedOut:
            return "Parakeet transcription timed out. The local model may still be loading; try again after the first warm-up finishes."
        case .processFailed(_, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "Parakeet transcription failed without an error message."
            }
            return "Parakeet transcription failed: \(detail)"
        case .emptyTranscript:
            return "Parakeet returned an empty transcript. Check the selected microphone and try again."
        }
    }
}
