import Foundation

struct OpenAIImproveEngine: ImproveEngine {
    private let apiKey: String
    private let model = "gpt-5.4-mini"

    init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func improve(rawTranscript: String, outputMode: OutputMode, modificationStrength: Int) async throws -> String {
        guard !apiKey.isEmpty else {
            throw ImproveEngineError.missingAPIKey
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 45

        let strength = min(max(modificationStrength, 1), 5)
        let instructions = """
        You improve dictated text for direct use. Preserve the speaker's intent, constraints, names, numbers, code references, and domain-specific wording. Remove filler words, false starts, repeated phrases, and speech disfluencies. Do not add facts. Return only the improved text with no preface, labels, markdown fence, or commentary.
        """
        let input = """
        Output mode: \(outputMode.label)
        Mode instruction: \(outputMode.promptInstruction)
        Modification strength: \(strength) out of 5, where 1 means minimal edits and 5 means a stronger rewrite while preserving intent.

        Raw transcript:
        \(rawTranscript)
        """

        let body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImproveEngineError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ImproveEngineError.serverError(
                status: httpResponse.statusCode,
                message: parseErrorMessage(from: data)
            )
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImproveEngineError.invalidResponse
        }

        let text = parseOutputText(from: json)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ImproveEngineError.emptyOutput
        }
        return text
    }

    private func parseOutputText(from json: [String: Any]) -> String {
        if let outputText = json["output_text"] as? String {
            return outputText
        }

        guard let output = json["output"] as? [[String: Any]] else {
            return ""
        }

        var chunks: [String] = []
        for item in output {
            guard let content = item["content"] as? [[String: Any]] else {
                continue
            }
            for contentItem in content {
                if let text = contentItem["text"] as? String {
                    chunks.append(text)
                } else if let text = contentItem["output_text"] as? String {
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
