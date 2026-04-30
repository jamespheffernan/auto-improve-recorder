import Foundation

struct OpenAIAudioTranscriber: TranscriptionEngine {
    private let apiKey: String
    private let model = "gpt-4o-transcribe"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIAudioTranscriptionError.missingAPIKey
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionEngineError.audioMissing(audioURL.path)
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try makeMultipartBody(audioURL: audioURL, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIAudioTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIAudioTranscriptionError.serverError(
                status: httpResponse.statusCode,
                message: parseErrorMessage(from: data)
            )
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String
        else {
            throw OpenAIAudioTranscriptionError.invalidResponse
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw OpenAIAudioTranscriptionError.emptyTranscript
        }

        return TranscriptionResult(text: trimmedText, engineName: "OpenAI Audio \(model)")
    }

    private func makeMultipartBody(audioURL: URL, boundary: String) throws -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n")

        append("--\(boundary)--\r\n")
        return body
    }

    private func parseErrorMessage(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum OpenAIAudioTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case serverError(status: Int, message: String)
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI API transcription needs an API key."
        case .invalidResponse:
            return "OpenAI API transcription returned a response the app could not read."
        case .serverError(let status, let message):
            if message.isEmpty {
                return "OpenAI API transcription failed with HTTP \(status)."
            }
            return "OpenAI API transcription failed with HTTP \(status): \(message)"
        case .emptyTranscript:
            return "OpenAI API transcription returned an empty transcript."
        }
    }
}
