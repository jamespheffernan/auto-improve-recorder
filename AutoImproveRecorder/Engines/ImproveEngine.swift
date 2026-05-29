import Foundation

protocol ImproveEngine {
    func improve(rawTranscript: String, outputMode: OutputMode, modificationStrength: Int) async throws -> String

    /// Streaming-aware improve. Default implementation falls back to the
    /// buffered `improve(...)` call and emits a single `onDelta` containing
    /// the full improved text. Engines that support real server-side
    /// streaming (e.g. OpenAI Responses SSE) override this to invoke
    /// `onDelta` repeatedly with cumulative improved text as it arrives.
    ///
    /// Contract:
    /// - `onDelta(partialFullText)` MUST receive the cumulative improved text
    ///   so far (NOT individual deltas) so callers can update the UI by
    ///   replacing the displayed string. The final `onDelta` call MUST be
    ///   byte-equal to the value returned by `improve(...)` for the same
    ///   prompt / settings (modulo trailing whitespace trim).
    /// - The returned `String` is the final, trimmed improved text. It is
    ///   identical to the last `onDelta` payload after trim.
    /// - `onDelta` is invoked from a background task; callers needing main
    ///   actor execution must hop themselves.
    func improveStreaming(
        rawTranscript: String,
        outputMode: OutputMode,
        modificationStrength: Int,
        onDelta: @escaping (String) -> Void
    ) async throws -> String
}

extension ImproveEngine {
    /// Default fallback: just runs the buffered improve and emits the entire
    /// result as one synthetic delta. Engines that support SSE override.
    func improveStreaming(
        rawTranscript: String,
        outputMode: OutputMode,
        modificationStrength: Int,
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        let full = try await improve(
            rawTranscript: rawTranscript,
            outputMode: outputMode,
            modificationStrength: modificationStrength
        )
        onDelta(full)
        return full
    }
}

enum ImproveEngineError: LocalizedError {
    case missingAPIKey
    case missingProviderAPIKey(String)
    case invalidResponse
    case invalidProviderResponse(String)
    case serverError(status: Int, message: String)
    case providerServerError(provider: String, status: Int, message: String)
    case localProviderUnavailable(provider: String, message: String)
    case localModelUnavailable(provider: String, model: String, setupCommand: String)
    case emptyOutput
    case emptyProviderOutput(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API key is missing. Add it in Settings."
        case .missingProviderAPIKey(let provider):
            return "\(provider) API key is missing. Add it in Settings."
        case .invalidResponse:
            return "OpenAI returned a response the app could not read."
        case .invalidProviderResponse(let provider):
            return "\(provider) returned a response the app could not read."
        case .serverError(let status, let message):
            if message.isEmpty {
                return "OpenAI request failed with HTTP \(status)."
            }
            return "OpenAI request failed with HTTP \(status): \(message)"
        case .providerServerError(let provider, let status, let message):
            if message.isEmpty {
                return "\(provider) request failed with HTTP \(status)."
            }
            return "\(provider) request failed with HTTP \(status): \(message)"
        case .localProviderUnavailable(let provider, let message):
            return "\(provider) is unavailable. \(message)"
        case .localModelUnavailable(let provider, let model, let setupCommand):
            return "\(provider) model \(model) is not available. Run `\(setupCommand)`, then try again."
        case .emptyOutput:
            return "OpenAI returned empty improved text."
        case .emptyProviderOutput(let provider):
            return "\(provider) returned empty improved text."
        }
    }
}

struct ImprovePrompt {
    var instructions: String
    var input: String

    static func make(rawTranscript: String, outputMode: OutputMode, modificationStrength: Int) -> ImprovePrompt {
        let strength = min(max(modificationStrength, 1), 5)
        let instructions = """
        You improve dictated text for direct use.

        Preserve the speaker's intent, thinking process, uncertainty, constraints, names, numbers, code references, ordering, and domain-specific wording. Do not remove a thought just because it is tentative, self-correcting, or exploratory. Only remove words that are clearly disposable dictation artifacts, such as filler sounds, accidental duplicate words, and abandoned fragments that carry no meaning.

        Do not add facts. Do not answer the speaker. Do not make the text more decisive than the transcript. Return only the improved text with no preface, labels, markdown fence, or commentary.
        """
        let input = """
        Cleanup level: \(outputMode.label)
        Cleanup instruction: \(outputMode.promptInstruction)
        Cleanup intensity: \(outputMode.promptIntensity)
        Legacy strength setting: \(strength) out of 5. Treat this as secondary to the cleanup level above; never use it as permission to drop substantive thoughts.

        Raw transcript:
        \(rawTranscript)
        """
        return ImprovePrompt(instructions: instructions, input: input)
    }
}
