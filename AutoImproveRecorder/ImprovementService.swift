import Foundation

struct ProviderCredentials {
    var openAIAPIKey: String
    var geminiAPIKey: String
    var anthropicAPIKey: String
}

struct ImprovementServiceRequest {
    var rawTranscript: String
    var mode: ImprovementMode
    var outputMode: OutputMode
    var modificationStrength: Int
    var dictionarySnapshot: String
    var credentials: ProviderCredentials
    var ollama: OllamaSettings
    var onDelta: (String) -> Void
}

protocol ImprovementService {
    func improve(_ request: ImprovementServiceRequest) async throws -> String
}

struct LiveImprovementService: ImprovementService {
    func improve(_ request: ImprovementServiceRequest) async throws -> String {
        let engine = makeImproveEngine(
            mode: request.mode,
            credentials: request.credentials,
            ollama: request.ollama
        )
        return try await engine.improveStreaming(
            rawTranscript: request.rawTranscript,
            outputMode: request.outputMode,
            modificationStrength: request.modificationStrength,
            dictionarySnapshot: request.dictionarySnapshot,
            onDelta: request.onDelta
        )
    }

    private func makeImproveEngine(
        mode: ImprovementMode,
        credentials: ProviderCredentials,
        ollama: OllamaSettings
    ) -> any ImproveEngine {
        switch mode {
        case .openAI:
            return OpenAIImproveEngine(apiKey: credentials.openAIAPIKey)
        case .geminiFlash:
            return GeminiImproveEngine(apiKey: credentials.geminiAPIKey)
        case .claudeHaiku:
            return AnthropicImproveEngine(apiKey: credentials.anthropicAPIKey)
        case .appleLocal:
            return AppleLocalImproveEngine()
        case .ollamaLocal:
            return OllamaImproveEngine(baseURL: ollama.baseURL, model: ollama.model)
        }
    }
}
