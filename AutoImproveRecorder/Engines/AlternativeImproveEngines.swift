import Foundation

struct GeminiImproveEngine: ImproveEngine {
    private let apiKey: String
    private let model = "gemini-2.5-flash"
    private let provider = "Gemini"

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func improve(
        rawTranscript: String,
        outputMode: OutputMode,
        modificationStrength: Int,
        dictionarySnapshot: String
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw ImproveEngineError.missingProviderAPIKey(provider)
        }

        var components = URLComponents(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        )!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            throw ImproveEngineError.invalidProviderResponse(provider)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45

        let prompt = ImprovePrompt.make(
            rawTranscript: rawTranscript,
            outputMode: outputMode,
            modificationStrength: modificationStrength,
            dictionarySnapshot: dictionarySnapshot
        )
        let body: [String: Any] = [
            "systemInstruction": [
                "parts": [
                    ["text": prompt.instructions]
                ]
            ],
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": prompt.input]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.2
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, httpResponse) = try await SharedNetworkClient.send(request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ImproveEngineError.providerServerError(
                provider: provider,
                status: httpResponse.statusCode,
                message: parseErrorMessage(from: data)
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImproveEngineError.invalidProviderResponse(provider)
        }

        let text = parseOutputText(from: json).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ImproveEngineError.emptyProviderOutput(provider)
        }
        return text
    }

    private func parseOutputText(from json: [String: Any]) -> String {
        guard let candidates = json["candidates"] as? [[String: Any]] else {
            return ""
        }

        var chunks: [String] = []
        for candidate in candidates {
            guard
                let content = candidate["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]]
            else {
                continue
            }
            for part in parts {
                if let text = part["text"] as? String {
                    chunks.append(text)
                }
            }
        }
        return chunks.joined(separator: "\n")
    }

    private func parseErrorMessage(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else {
            return String(decoding: data, as: UTF8.self)
        }
        return error["message"] as? String ?? ""
    }
}

struct AnthropicImproveEngine: ImproveEngine {
    private let apiKey: String
    private let model = "claude-haiku-4-5-20251001"
    private let provider = "Anthropic"

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func improve(
        rawTranscript: String,
        outputMode: OutputMode,
        modificationStrength: Int,
        dictionarySnapshot: String
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw ImproveEngineError.missingProviderAPIKey(provider)
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45

        let prompt = ImprovePrompt.make(
            rawTranscript: rawTranscript,
            outputMode: outputMode,
            modificationStrength: modificationStrength,
            dictionarySnapshot: dictionarySnapshot
        )
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "temperature": 0.2,
            "system": prompt.instructions,
            "messages": [
                [
                    "role": "user",
                    "content": prompt.input
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, httpResponse) = try await SharedNetworkClient.send(request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ImproveEngineError.providerServerError(
                provider: provider,
                status: httpResponse.statusCode,
                message: parseErrorMessage(from: data)
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImproveEngineError.invalidProviderResponse(provider)
        }

        let text = parseOutputText(from: json).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ImproveEngineError.emptyProviderOutput(provider)
        }
        return text
    }

    private func parseOutputText(from json: [String: Any]) -> String {
        guard let content = json["content"] as? [[String: Any]] else {
            return ""
        }

        var chunks: [String] = []
        for item in content {
            if let text = item["text"] as? String {
                chunks.append(text)
            }
        }
        return chunks.joined(separator: "\n")
    }

    private func parseErrorMessage(from data: Data) -> String {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else {
            return String(decoding: data, as: UTF8.self)
        }
        return error["message"] as? String ?? ""
    }
}
