import Foundation

struct OllamaImproveEngine: ImproveEngine {
    private static let defaultModel = "qwen3.5:0.8b-mlx"

    private let baseURL: String
    private let model: String
    private let provider = "Ollama"

    init(baseURL: String, model: String) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func improve(rawTranscript: String, outputMode: OutputMode, modificationStrength: Int) async throws -> String {
        let model = model.isEmpty ? Self.defaultModel : model

        let prompt = ImprovePrompt.make(
            rawTranscript: rawTranscript,
            outputMode: outputMode,
            modificationStrength: modificationStrength
        )
        let request = try makeRequest(
            model: model,
            systemPrompt: prompt.instructions,
            userPrompt: "/no_think\n\n\(prompt.input)",
            stream: false,
            temperature: 0.2,
            numPredict: 320
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw ImproveEngineError.localProviderUnavailable(
                provider: provider,
                message: "Start Ollama at \(normalizedBaseURL), then run `ollama pull \(model)` if the model is missing."
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImproveEngineError.invalidProviderResponse(provider)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = parseErrorMessage(from: data)
            if isMissingModelError(message: message) {
                throw ImproveEngineError.localModelUnavailable(
                    provider: provider,
                    model: model,
                    setupCommand: "ollama pull \(model)"
                )
            }
            throw ImproveEngineError.providerServerError(
                provider: provider,
                status: httpResponse.statusCode,
                message: message
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImproveEngineError.invalidProviderResponse(provider)
        }

        let text = (parseOutputText(from: json) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ImproveEngineError.emptyProviderOutput(provider)
        }
        return text
    }

    func improveStreaming(
        rawTranscript: String,
        outputMode: OutputMode,
        modificationStrength: Int,
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        let model = model.isEmpty ? Self.defaultModel : model
        let prompt = ImprovePrompt.make(
            rawTranscript: rawTranscript,
            outputMode: outputMode,
            modificationStrength: modificationStrength
        )
        let request = try makeRequest(
            model: model,
            systemPrompt: prompt.instructions,
            userPrompt: "/no_think\n\n\(prompt.input)",
            stream: true,
            temperature: 0.2,
            numPredict: 320
        )

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await Self.session.bytes(for: request)
        } catch {
            throw ImproveEngineError.localProviderUnavailable(
                provider: provider,
                message: "Start Ollama at \(normalizedBaseURL), then run `ollama pull \(model)` if the model is missing."
            )
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImproveEngineError.invalidProviderResponse(provider)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
                if errorData.count > 4096 { break }
            }
            let message = parseErrorMessage(from: errorData)
            if isMissingModelError(message: message) {
                throw ImproveEngineError.localModelUnavailable(
                    provider: provider,
                    model: model,
                    setupCommand: "ollama pull \(model)"
                )
            }
            throw ImproveEngineError.providerServerError(provider: provider, status: httpResponse.statusCode, message: message)
        }

        var assembled = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let error = json["error"] as? String, !error.isEmpty {
                throw ImproveEngineError.providerServerError(provider: provider, status: httpResponse.statusCode, message: error)
            }
            if let chunk = parseOutputText(from: json), !chunk.isEmpty {
                assembled += chunk
                onDelta(assembled)
            }
            if json["done"] as? Bool == true {
                break
            }
        }

        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ImproveEngineError.emptyProviderOutput(provider)
        }
        onDelta(trimmed)
        return trimmed
    }

    func warmUp() async {
        let model = model.isEmpty ? Self.defaultModel : model
        guard let request = try? makeRequest(
            model: model,
            systemPrompt: "Return exactly OK.",
            userPrompt: "/no_think\n\nOK",
            stream: false,
            temperature: 0.0,
            numPredict: 4
        ) else {
            return
        }
        _ = try? await Self.session.data(for: request)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()

    private var normalizedBaseURL: String {
        let fallback = "http://127.0.0.1:11434"
        let base = baseURL.isEmpty ? fallback : baseURL
        return base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func endpointURL() throws -> URL {
        guard let url = URL(string: "\(normalizedBaseURL)/api/chat") else {
            throw ImproveEngineError.invalidProviderResponse(provider)
        }
        return url
    }

    private func makeRequest(
        model: String,
        systemPrompt: String,
        userPrompt: String,
        stream: Bool,
        temperature: Double,
        numPredict: Int
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpointURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45
        let body: [String: Any] = [
            "model": model,
            "messages": [
                [
                    "role": "system",
                    "content": systemPrompt
                ],
                [
                    "role": "user",
                    "content": userPrompt
                ]
            ],
            "think": false,
            "keep_alive": "30m",
            "options": [
                "temperature": temperature,
                "num_predict": numPredict
            ],
            "stream": stream
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return request
    }

    private func parseOutputText(from json: [String: Any]) -> String? {
        if let message = json["message"] as? [String: Any],
           let content = message["content"] as? String {
            return content
        }

        guard let choices = json["choices"] as? [[String: Any]] else {
            return nil
        }

        var chunks: [String] = []
        for choice in choices {
            guard let message = choice["message"] as? [String: Any] else {
                continue
            }
            if let content = message["content"] as? String {
                chunks.append(content)
            }
        }
        return chunks.joined(separator: "\n")
    }

    private func parseErrorMessage(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(decoding: data, as: UTF8.self)
        }

        if let error = json["error"] as? String {
            return error
        }
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String ?? ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func isMissingModelError(message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("model") && (
            normalized.contains("not found") ||
                normalized.contains("pull") ||
                normalized.contains("does not exist")
        )
    }
}
