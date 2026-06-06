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

    func improve(
        rawTranscript: String,
        outputMode: OutputMode,
        modificationStrength: Int,
        dictionarySnapshot: String
    ) async throws -> String {
        let model = model.isEmpty ? Self.defaultModel : model
        if let bypassText = Self.pasteReadyBypassText(
            rawTranscript,
            outputMode: outputMode,
            dictionarySnapshot: dictionarySnapshot
        ) {
            return bypassText
        }

        let prompt = ImprovePrompt.make(
            rawTranscript: rawTranscript,
            outputMode: outputMode,
            modificationStrength: modificationStrength,
            dictionarySnapshot: dictionarySnapshot
        )
        let numPredict = Self.adaptiveNumPredict(for: rawTranscript, outputMode: outputMode)
        let request = try makeRequest(
            model: model,
            systemPrompt: prompt.instructions,
            userPrompt: "/no_think\n\n\(prompt.input)",
            stream: false,
            temperature: 0.2,
            numPredict: numPredict
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
        dictionarySnapshot: String,
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        let model = model.isEmpty ? Self.defaultModel : model
        if let bypassText = Self.pasteReadyBypassText(
            rawTranscript,
            outputMode: outputMode,
            dictionarySnapshot: dictionarySnapshot
        ) {
            onDelta(bypassText)
            return bypassText
        }

        let prompt = ImprovePrompt.make(
            rawTranscript: rawTranscript,
            outputMode: outputMode,
            modificationStrength: modificationStrength,
            dictionarySnapshot: dictionarySnapshot
        )
        let numPredict = Self.adaptiveNumPredict(for: rawTranscript, outputMode: outputMode)
        let request = try makeRequest(
            model: model,
            systemPrompt: prompt.instructions,
            userPrompt: "/no_think\n\n\(prompt.input)",
            stream: true,
            temperature: 0.2,
            numPredict: numPredict
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

    private static func adaptiveNumPredict(for rawTranscript: String, outputMode: OutputMode) -> Int {
        let estimatedInputTokens = max(24, rawTranscript.count / 4)
        let ratio: Double
        switch outputMode {
        case .verbatim:
            ratio = 1.15
        case .lightCleanup:
            ratio = 1.0
        case .promptCleanup:
            ratio = 1.05
        case .structuredTask:
            ratio = 0.8
        }
        return min(320, max(96, Int(Double(estimatedInputTokens) * ratio) + 48))
    }

    private static func pasteReadyBypassText(
        _ rawTranscript: String,
        outputMode: OutputMode,
        dictionarySnapshot: String
    ) -> String? {
        guard outputMode == .lightCleanup || outputMode == .verbatim else { return nil }
        guard dictionarySnapshot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let text = rawTranscript
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let words = text.split { character in
            !character.isLetter && !character.isNumber && character != "'"
        }
        guard (6...90).contains(words.count) else { return nil }
        guard !containsPattern(transformRequestPattern, in: text) else { return nil }
        guard !containsPattern(fillerPattern, in: text) else { return nil }
        guard !containsPattern(speechArtifactPattern, in: text) else { return nil }
        guard !hasRepeatedAdjacentWord(words) else { return nil }
        if words.count > 12 {
            guard containsPattern(sentencePunctuationPattern, in: text) else { return nil }
        }
        guard containsPattern(terminalPunctuationPattern, in: text) else { return nil }
        if let first = text.first, first.isLowercase {
            return nil
        }
        return text
    }

    private static let fillerPattern =
        #"(?i)\b(um+|uh+|er+|ah+|you know|i mean|sort of|kind of|basically|actually)\b"#
    private static let speechArtifactPattern =
        #"(?i)\b(wait actually|no sorry|scratch that|start over|what i mean|let me rephrase|new paragraph)\b|\bdot\s+[A-Za-z0-9_]+\b|\bslash\s+[A-Za-z0-9_]+\b"#
    private static let transformRequestPattern =
        #"(?i)\b(make this into|turn this into|convert this|rewrite this|clean this up|make it sound|summari[sz]e|format this|structure this|write (?:\w+\s+){0,3}(email|slack|message|prompt|task))\b"#
    private static let sentencePunctuationPattern = #"[,.!?;:]"#
    private static let terminalPunctuationPattern = #"[.!?]["')\]]*$"#

    private static func containsPattern(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func hasRepeatedAdjacentWord(_ words: [Substring]) -> Bool {
        guard words.count > 1 else { return false }
        for index in words.indices.dropLast() {
            let current = words[index].lowercased()
            let next = words[words.index(after: index)].lowercased()
            if current == next && current.count > 2 {
                return true
            }
        }
        return false
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
