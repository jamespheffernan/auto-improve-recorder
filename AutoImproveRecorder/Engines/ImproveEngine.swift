import Foundation

protocol ImproveEngine {
    func improve(rawTranscript: String, outputMode: OutputMode, modificationStrength: Int) async throws -> String
}

enum ImproveEngineError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case serverError(status: Int, message: String)
    case emptyOutput

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is missing. Add it in Settings."
        case .invalidResponse:
            return "OpenAI returned a response the app could not read."
        case .serverError(let status, let message):
            if message.isEmpty {
                return "OpenAI request failed with HTTP \(status)."
            }
            return "OpenAI request failed with HTTP \(status): \(message)"
        case .emptyOutput:
            return "OpenAI returned empty improved text."
        }
    }
}
