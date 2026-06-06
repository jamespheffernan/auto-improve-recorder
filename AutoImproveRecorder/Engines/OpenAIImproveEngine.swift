import Foundation

struct OpenAIImproveEngine: ImproveEngine {
    private let apiKey: String
    private let model = "gpt-5-mini"
    /// Override the Responses endpoint for tests / benches against a local mock server.
    /// Production code paths leave this `nil` and hit api.openai.com.
    let endpointOverride: URL?

    init(apiKey: String, endpointOverride: URL? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.endpointOverride = endpointOverride
    }

    private var endpoint: URL {
        if let override = endpointOverride { return override }
        return URL(string: "https://api.openai.com/v1/responses")!
    }

    func improve(
        rawTranscript: String,
        outputMode: OutputMode,
        modificationStrength: Int,
        dictionarySnapshot: String
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw ImproveEngineError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
            "instructions": prompt.instructions,
            "input": prompt.input
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        // Use the shared keep-alive session with HTTP/3 hint, gzip Accept-Encoding,
        // and a single 429/503 retry. See .autoresearch/ios-network-latency.jsonl for
        // the per-trial measurements that motivated this change.
        let (data, httpResponse) = try await SharedNetworkClient.send(request)

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

    // MARK: - Streaming (SSE) override
    //
    // Uses the OpenAI Responses API streaming protocol:
    //   request body has `"stream": true`
    //   response is text/event-stream with `event: response.output_text.delta`
    //   data lines: `{"type":"response.output_text.delta","delta":"..."}`
    //   terminates on `event: response.completed` (or `data: [DONE]`).
    //
    // We also accept the IOSNetworkBench MockServer's `X-Bench-Stream: 1`
    // request hint when an endpointOverride is supplied; this keeps the same
    // engine code testable against the local fake server without hitting
    // OpenAI in CI.
    func improveStreaming(
        rawTranscript: String,
        outputMode: OutputMode,
        modificationStrength: Int,
        dictionarySnapshot: String,
        onDelta: @escaping (String) -> Void
    ) async throws -> String {
        guard !apiKey.isEmpty else {
            throw ImproveEngineError.missingAPIKey
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Bench server hint -- production OpenAI ignores unknown headers.
        request.setValue("1", forHTTPHeaderField: "X-Bench-Stream")
        request.timeoutInterval = 60

        let prompt = ImprovePrompt.make(
            rawTranscript: rawTranscript,
            outputMode: outputMode,
            modificationStrength: modificationStrength,
            dictionarySnapshot: dictionarySnapshot
        )

        let body: [String: Any] = [
            "model": model,
            "instructions": prompt.instructions,
            "input": prompt.input,
            "stream": true
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        // Route through SharedNetworkClient.stream so callers inherit the
        // initial-response 429/503 retry/backoff layer. Mid-stream errors are
        // still surfaced (we never silently re-issue the prompt once tokens
        // have begun flowing). See SharedNetworkClient.swift docstring.
        let (bytes, httpResponse) = try await SharedNetworkClient.stream(request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            // Drain a little of the body for the error message; the bytes
            // stream still works as an AsyncSequence here.
            var errorBytes = Data()
            for try await byte in bytes {
                errorBytes.append(byte)
                if errorBytes.count > 4096 { break }
                if Task.isCancelled { throw CancellationError() }
            }
            throw ImproveEngineError.serverError(
                status: httpResponse.statusCode,
                message: parseErrorMessage(from: errorBytes)
            )
        }

        var assembled = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line.isEmpty { continue }
            if !line.hasPrefix("data:") { continue }
            // Strip "data:" and at most one leading space (per RFC).
            var payload = String(line.dropFirst(5))
            if payload.hasPrefix(" ") { payload.removeFirst() }
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }

            guard let payloadData = payload.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
                continue
            }
            // 1) Text delta event -- append.
            if let delta = obj["delta"] as? String {
                assembled += delta
                onDelta(assembled)
                continue
            }
            // 2) Completion / terminator events -- stop reading.
            if let type = obj["type"] as? String {
                if type == "response.completed" || type == "response.error" || type == "response.failed" {
                    break
                }
            }
            // 3) Some servers emit a final {"output_text": "..."} record. If
            //    so, prefer it over assembled deltas (rare, but keeps us
            //    byte-equal to the buffered path).
            if let final = obj["output_text"] as? String, !final.isEmpty {
                assembled = final
                onDelta(assembled)
            }
        }

        let trimmed = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ImproveEngineError.emptyOutput
        }
        return trimmed
    }
}
