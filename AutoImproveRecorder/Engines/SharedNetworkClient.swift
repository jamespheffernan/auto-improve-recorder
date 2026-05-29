// SharedNetworkClient: shared URLSession + retry/backoff used by all REST engines.
//
// Why a shared session?
//   The previous code created a fresh `URLSessionConfiguration.ephemeral` for every
//   improve/transcribe call, throwing away the connection (TLS handshake + TCP open
//   + DNS) on each request. The IOSNetworkBench (.autoresearch/ios-network-latency.jsonl)
//   measured a 6-9% p95 reduction on a single transcribe+improve pair just by switching
//   to a shared persistent session with HTTP/2/3 hints and `Accept-Encoding: gzip`.
//
// Retry policy: a single retry on 429 / 503 with jittered exponential backoff.
//   On a fresh session this barely matters; on a shared session a transient 429 from
//   the upstream gateway no longer breaks the user's flow.
//
// Streaming extension (.autoresearch/air-stream-shared-client.jsonl, loop wave 4):
//   `stream(_:)` mirrors `send(_:)` but returns the raw byte AsyncSequence so
//   callers can surface partial output to the UI (perceived TTFB). Retry on the
//   *initial* response status (429/503) only; if the connection drops mid-stream
//   we propagate the error rather than silently re-issuing the prompt.
//   `streamSSE(_:)` is a thin protocol layer that yields decoded delta strings
//   so the OpenAI Responses streaming endpoint can be consumed without leaking
//   SSE parsing into every caller.

import Foundation

enum SharedNetworkClient {
    /// Persistent session reused across all improve/transcribe engines.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        // HTTP/3 hint - URLSession will probe Alt-Svc / SVCB and use QUIC where available.
        // The key was added on iOS 16/macOS 13 and is exposed via KVC. Some
        // newer macOS builds report `setValue:forUndefinedKey:` if the key
        // isn't recognised; guard with a responds-to check before setting.
        let httpThreeCapableSelector = NSSelectorFromString("setAssumesHTTP3Capable:")
        if (configuration as NSObject).responds(to: httpThreeCapableSelector) {
            configuration.setValue(true, forKey: "assumesHTTP3Capable")
        }
        // Accept gzip on every response by default (OpenAI/Anthropic/Gemini all support it).
        var headers = configuration.httpAdditionalHeaders ?? [:]
        if headers["Accept-Encoding"] == nil {
            headers["Accept-Encoding"] = "gzip"
        }
        configuration.httpAdditionalHeaders = headers
        return URLSession(configuration: configuration)
    }()

    /// Run a request with one retry on 429 / 503. Honors the `Retry-After` header when present.
    static func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempts = 0
        while true {
            attempts += 1
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let status = httpResponse.statusCode
            if (status == 429 || status == 503) && attempts <= 2 {
                let waitMs = retryWaitMs(httpResponse: httpResponse, attempts: attempts)
                try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
                continue
            }
            return (data, httpResponse)
        }
    }

    /// Open a streaming response on the shared session.
    ///
    /// Returns the raw byte stream plus the headers, after retrying once on a
    /// 429/503 *initial* status. We do not retry mid-stream: once the body has
    /// started flowing we let the caller see the partial content rather than
    /// silently replaying the prompt against the model. Honours `Retry-After`
    /// the same way `send(_:)` does.
    static func stream(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        var attempts = 0
        while true {
            attempts += 1
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let status = httpResponse.statusCode
            if (status == 429 || status == 503) && attempts <= 2 {
                // Drain any partial body so URLSession can recycle the connection.
                for try await _ in bytes { /* discard */ }
                let waitMs = retryWaitMs(httpResponse: httpResponse, attempts: attempts)
                try? await Task.sleep(nanoseconds: UInt64(waitMs) * 1_000_000)
                continue
            }
            return (bytes, httpResponse)
        }
    }

    /// Decode an OpenAI Responses-style SSE byte stream into incremental string deltas.
    ///
    /// Yields each `response.output_text.delta` as it arrives, then finishes when
    /// `response.completed` (or `[DONE]`) is observed. Other events are ignored.
    /// The returned stream finishes (rather than throws) on graceful end so callers
    /// can treat partial output as a degraded-but-usable result.
    static func streamSSE(_ request: URLRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        return AsyncThrowingStream<SSEEvent, Error> { continuation in
            let task = Task {
                do {
                    let (bytes, http) = try await stream(request)
                    guard (200..<300).contains(http.statusCode) else {
                        continuation.finish(throwing: URLError(.init(rawValue: http.statusCode)))
                        return
                    }
                    var dataBuf = ""
                    var eventName: String? = nil
                    for try await line in bytes.lines {
                        if line.isEmpty {
                            // Dispatch the accumulated event.
                            if !dataBuf.isEmpty {
                                let trimmed = dataBuf.hasSuffix("\n") ? String(dataBuf.dropLast()) : dataBuf
                                continuation.yield(SSEEvent(name: eventName, data: trimmed))
                            }
                            dataBuf = ""
                            eventName = nil
                            continue
                        }
                        if line.hasPrefix("event:") {
                            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
                            continue
                        }
                        if line.hasPrefix("data:") {
                            // Strip leading "data:" plus single optional space.
                            var rest = Substring(line.dropFirst(5))
                            if rest.first == " " { rest = rest.dropFirst() }
                            dataBuf.append(contentsOf: rest)
                            dataBuf.append("\n")
                            continue
                        }
                        // Ignore comments / id: / retry: lines.
                    }
                    // Flush trailing event if the server omitted the terminator.
                    if !dataBuf.isEmpty {
                        let trimmed = dataBuf.hasSuffix("\n") ? String(dataBuf.dropLast()) : dataBuf
                        continuation.yield(SSEEvent(name: eventName, data: trimmed))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Issue a streaming request and accumulate the full text. Returns the
    /// assembled string and the milliseconds to first delta token, suitable for
    /// non-streaming callers that just want the existing String contract.
    static func streamingResponseText(_ request: URLRequest) async throws -> StreamingTextResult {
        let start = Date()
        var firstTokenMs: Int? = nil
        var assembled = ""
        var byteCount = 0
        for try await event in streamSSE(request) {
            byteCount += event.data.utf8.count
            // Try to decode JSON payload. Unparsable lines are ignored so a
            // future server-side schema bump degrades gracefully.
            guard let payload = event.data.data(using: .utf8) else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
                if event.data == "[DONE]" { break }
                continue
            }
            let type = obj["type"] as? String
            if type == "response.output_text.delta", let delta = obj["delta"] as? String {
                if firstTokenMs == nil {
                    firstTokenMs = Int(Date().timeIntervalSince(start) * 1000)
                }
                assembled += delta
            } else if type == "response.completed" {
                break
            }
        }
        return StreamingTextResult(
            text: assembled.trimmingCharacters(in: .whitespacesAndNewlines),
            firstTokenMs: firstTokenMs,
            bytesIn: byteCount
        )
    }

    /// Best-effort connection prewarm. Performs a HEAD against the host so a TLS
    /// handshake + TCP open is paid before the real request. Errors are swallowed
    /// because a missing prewarm endpoint should never break the real flow.
    static func prewarm(host url: URL) async {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        _ = try? await session.data(for: request)
    }

    private static func retryWaitMs(httpResponse: HTTPURLResponse, attempts: Int) -> Int {
        if let header = httpResponse.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header) {
            return Int(min(seconds * 1000, 4000))
        }
        // Exponential backoff with +/-25% jitter, capped at 1.5 s.
        let base = 200 * Int(pow(2.0, Double(attempts - 1)))
        let jitter = Int.random(in: -base/4 ... base/4)
        return min(max(50, base + jitter), 1500)
    }
}

struct SSEEvent {
    let name: String?
    let data: String
}

struct StreamingTextResult {
    let text: String
    let firstTokenMs: Int?
    let bytesIn: Int
}
