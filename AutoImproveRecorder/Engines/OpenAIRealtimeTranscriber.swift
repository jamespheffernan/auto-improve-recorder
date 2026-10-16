import AVFoundation
import Foundation

enum OpenAIRealtimeTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidWebSocketURL
    case conversionFailed(String)
    case invalidServerEvent
    case sessionUpdateTimedOut(String)
    case serverError(String)
    case webSocketFailed(String)
    case emptyTranscript
    case finalizeTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenAI realtime transcription needs an API key."
        case .invalidWebSocketURL:
            return "OpenAI realtime transcription URL is invalid."
        case .conversionFailed(let message):
            return "OpenAI realtime audio conversion failed: \(message)"
        case .invalidServerEvent:
            return "OpenAI realtime returned an invalid event."
        case .sessionUpdateTimedOut(let message):
            return "OpenAI realtime session configuration was not acknowledged: \(message)"
        case .serverError(let message):
            return "OpenAI realtime transcription failed: \(message)"
        case .webSocketFailed(let message):
            return "OpenAI realtime WebSocket failed: \(message)"
        case .emptyTranscript:
            return "OpenAI realtime returned an empty transcript."
        case .finalizeTimedOut(let message):
            return "OpenAI realtime transcription did not finish in time: \(message)"
        }
    }
}

final class OpenAIRealtimeTranscriber {
    private let connection: OpenAIRealtimeTranscriptionConnection
    private let chunker = RealtimePCMChunker()
    private let admissionLock = NSLock()
    private let audioQueue = DispatchQueue(
        label: "com.fieldtheory.air.openai-realtime-audio",
        qos: .userInitiated
    )
    private var acceptingAudio = true
    private var captureFailure: AudioCaptureFailure?
    private var appendChain: Task<Void, Never> = Task {}
    private var captureDiagnosticLines: [String] = []

    init(apiKey: String, dictionarySnapshot: String = "") {
        connection = OpenAIRealtimeTranscriptionConnection(
            apiKey: apiKey,
            dictionarySnapshot: dictionarySnapshot
        )
    }

    deinit {
        let connection = connection
        Task {
            await connection.cancel()
        }
    }

    func start() async throws {
        try await connection.start()
    }

    func appendAudioBuffer(_ captured: CapturedAudioBuffer) {
        admissionLock.lock()
        guard acceptingAudio else {
            admissionLock.unlock()
            return
        }
        audioQueue.async { [weak self] in
            self?.appendCapturedOnQueue(captured)
        }
        admissionLock.unlock()
    }

    func appendRealtimeAudioChunk(_ chunk: RealtimeAudioChunk) {
        admissionLock.lock()
        guard acceptingAudio else {
            admissionLock.unlock()
            return
        }
        audioQueue.async { [weak self] in
            self?.enqueueChunksOnQueue([chunk])
        }
        admissionLock.unlock()
    }

    func recordCaptureFailure(_ failure: AudioCaptureFailure) {
        admissionLock.lock()
        acceptingAudio = false
        if captureFailure == nil {
            captureFailure = failure
        }
        admissionLock.unlock()
        audioQueue.async { [weak self] in
            self?.captureDiagnosticLines.append(failure.localizedDescription)
        }
    }

    func recordCaptureDiagnostics(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        audioQueue.async { [weak self] in
            self?.captureDiagnosticLines.append(contentsOf: lines)
        }
    }

    func finish() async throws -> TranscriptionResult {
        let (pendingAppends, captureFailure) = stopAcceptingAudio()
        await pendingAppends.value
        if let captureFailure {
            await connection.cancel()
            throw captureFailure
        }
        return try await connection.finish()
    }

    func cancel() async {
        _ = stopAcceptingAudio()
        await connection.cancel()
    }

    func diagnostics(summary: String? = nil) async -> OpenAIRealtimeDiagnostics {
        let connectionDiagnostics = await connection.diagnostics(summary: summary)
        let audioDetails = realtimeAudioDiagnosticDetails()
        let details = audioDetails.isEmpty
            ? connectionDiagnostics.details
            : connectionDiagnostics.details + "\n" + audioDetails
        return OpenAIRealtimeDiagnostics(summary: connectionDiagnostics.summary, details: details)
    }

    private func stopAcceptingAudio() -> (Task<Void, Never>, AudioCaptureFailure?) {
        admissionLock.lock()
        acceptingAudio = false
        let pendingAppends = audioQueue.sync {
            enqueueChunksOnQueue(chunker.finish())
            return appendChain
        }
        let captureFailure = captureFailure
        admissionLock.unlock()
        return (pendingAppends, captureFailure)
    }

    private func appendCapturedOnQueue(_ captured: CapturedAudioBuffer) {
        do {
            enqueueChunksOnQueue(try chunker.append(captured))
        } catch {
            Task {
                await connection.recordFailure(error)
            }
        }
    }

    private func enqueueChunksOnQueue(_ chunks: [RealtimeAudioChunk]) {
        guard !chunks.isEmpty else { return }
        let previousAppend = appendChain
        let connection = connection
        appendChain = Task {
            await previousAppend.value
            for chunk in chunks {
                await connection.enqueueAudio(chunk)
            }
        }
    }

    private func realtimeAudioDiagnosticDetails() -> String {
        let (diagnostics, captureDiagnosticLines) = audioQueue.sync {
            (chunker.diagnostics, self.captureDiagnosticLines)
        }

        var lines: [String] = []
        lines.append("Realtime audio chunk size: \(diagnostics.chunkByteCount) bytes")
        lines.append("Realtime audio chunks produced: \(diagnostics.realtimeChunksProduced)")
        lines.append("Realtime converter recreates: \(diagnostics.converterRecreateCount)")
        lines.append("Realtime pending bytes max: \(diagnostics.realtimePendingBytesMax)")
        if let conversionFailure = diagnostics.conversionFailure {
            lines.append("Realtime conversion failure: \(conversionFailure)")
        }
        lines.append(contentsOf: captureDiagnosticLines)
        return lines.joined(separator: "\n")
    }
}

private actor OpenAIRealtimeTranscriptionConnection {
    private let apiKey: String
    private let dictionarySnapshot: String
    private let transcriptionModel = "gpt-4o-transcribe"
    private let webSocketURLString = "wss://api.openai.com/v1/realtime?intent=transcription"

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var webSocketDelegate: OpenAIRealtimeWebSocketDelegate?
    private var receiveTask: Task<Void, Never>?
    private var sendChain: Task<Void, Error> = Task {}

    private var isClosed = false
    private var isFinishing = false
    private var failure: Error?
    private var sawSessionCreated = false
    private var sawSessionUpdated = false

    private var partialTranscripts: [String: String] = [:]
    private var completedTranscripts: [String: String] = [:]
    private var commitOrder: [String] = []
    private var eventOrder: [String] = []
    private var lastTranscriptUpdate = Date.distantPast

    private var appendedBytes = 0
    private var appendedEvents = 0
    private var startedAt: Date?
    private var openedAt: Date?
    private var closedAt: Date?
    private var closeDescription: String?
    private var lastReceiveError: String?
    private var lastSendError: String?
    private var sessionCreatedJSON: String?
    private var sessionUpdatedJSON: String?
    private var lastErrorEventJSON: String?
    private var lastFailedTranscriptionJSON: String?
    private var recentServerEvents: [String] = []

    init(apiKey: String, dictionarySnapshot: String) {
        self.apiKey = apiKey
        self.dictionarySnapshot = dictionarySnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func start() async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIRealtimeTranscriptionError.missingAPIKey
        }
        guard let webSocketURL = URL(string: webSocketURLString) else {
            throw OpenAIRealtimeTranscriptionError.invalidWebSocketURL
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 600
        let delegate = OpenAIRealtimeWebSocketDelegate(connection: self)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: webSocketURL)
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketDelegate = delegate
        webSocketTask = task
        startedAt = Date()

        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }

        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "noise_reduction": NSNull(),
                        "transcription": [
                            "model": transcriptionModel,
                            "prompt": transcriptionPrompt,
                            "language": "en"
                        ],
                        "turn_detection": NSNull()
                    ]
                ]
            ]
        ]
        try await sendEvent(sessionUpdate)
        try await waitForSessionUpdated(timeout: 8)

        NSLog("OpenAI realtime transcription started with endpoint \(webSocketURLString), model \(transcriptionModel), payload \(sessionPayloadShape).")
    }

    func enqueueAudio(_ chunk: RealtimeAudioChunk) {
        enqueueAudio(chunk.data)
    }

    private func enqueueAudio(_ data: Data) {
        guard !data.isEmpty, !isClosed, failure == nil else { return }
        appendedBytes += data.count
        appendedEvents += 1

        do {
            let json = try makeJSONString([
                "type": "input_audio_buffer.append",
                "audio": data.base64EncodedString()
            ])
            enqueueSend(json)
        } catch {
            recordFailure(error)
        }
    }

    func finish() async throws -> TranscriptionResult {
        isFinishing = true
        defer { _ = close() }

        let completedCountAtFinish = completedTranscripts.count

        do {
            try await sendChain.value
            try throwIfFailed()
            try await sendEvent(["type": "input_audio_buffer.commit"])
        } catch {
            throw error
        }

        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            try throwIfFailed()

            let text = assembledTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
            let quietFor = Date().timeIntervalSince(lastTranscriptUpdate)
            let sawCompletionAfterFinish = completedTranscripts.count > completedCountAtFinish

            if !text.isEmpty, quietFor >= 0.7, sawCompletionAfterFinish {
                logFinish(text: text, usedTimeout: false)
                return TranscriptionResult(text: text, engineName: "OpenAI Realtime \(transcriptionModel)")
            }

            try await Task.sleep(nanoseconds: 150_000_000)
        }

        let text = assembledTranscript().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw OpenAIRealtimeTranscriptionError.emptyTranscript
        }
        logFinish(text: text, usedTimeout: true)
        throw OpenAIRealtimeTranscriptionError.finalizeTimedOut(
            "No completed transcript event arrived after manual commit; falling back to saved-audio transcription."
        )
    }

    func cancel() {
        isFinishing = false
        if close() {
            NSLog("OpenAI realtime transcription cancelled.")
        }
    }

    func recordFailure(_ error: Error) {
        guard failure == nil, !isClosed else { return }
        failure = error
        NSLog("OpenAI realtime transcription failure: \(error.localizedDescription)")
    }

    private func enqueueSend(_ json: String) {
        guard let webSocketTask else {
            recordFailure(OpenAIRealtimeTranscriptionError.webSocketFailed("WebSocket is unavailable."))
            return
        }

        let previous = sendChain
        sendChain = Task {
            try await previous.value
            try Task.checkCancellation()
            do {
                try await webSocketTask.send(.string(json))
            } catch {
                self.recordSendError(error)
                throw error
            }
        }
    }

    private func sendEvent(_ event: [String: Any], logPayload: Bool = false) async throws {
        guard let webSocketTask else {
            throw OpenAIRealtimeTranscriptionError.webSocketFailed("WebSocket is unavailable.")
        }

        let json = try makeJSONString(event)
        if logPayload {
            NSLog("OpenAI realtime client event: \(json)")
        } else if let type = event["type"] as? String {
            NSLog("OpenAI realtime client event: \(type)")
        }
        do {
            try await webSocketTask.send(.string(json))
        } catch {
            recordSendError(error)
            throw error
        }
    }

    private func receiveMessages() async {
        while true {
            guard let webSocketTask else { return }

            do {
                let message = try await webSocketTask.receive()
                switch message {
                case .string(let text):
                    handleServerEvent(Data(text.utf8))
                case .data(let data):
                    handleServerEvent(data)
                @unknown default:
                    break
                }
            } catch {
                guard !isClosed else { return }
                lastReceiveError = error.localizedDescription
                recordFailure(OpenAIRealtimeTranscriptionError.webSocketFailed(error.localizedDescription))
                return
            }
        }
    }

    private func handleServerEvent(_ data: Data) {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else {
            recordFailure(OpenAIRealtimeTranscriptionError.invalidServerEvent)
            return
        }

        let rawJSON = prettyJSONString(from: json) ?? String(data: data, encoding: .utf8) ?? "<non-utf8 server event>"
        let redactedDiagnosticJSON = RealtimeDiagnosticsRedactor.redactedJSON(json, fallback: rawJSON)
        recordServerEvent(type: type, rawJSON: redactedDiagnosticJSON)

        switch type {
        case "session.created", "transcription_session.created":
            sawSessionCreated = true
            sessionCreatedJSON = redactedDiagnosticJSON
        case "session.updated", "transcription_session.updated":
            sawSessionUpdated = true
            sessionUpdatedJSON = redactedDiagnosticJSON
        case "error":
            handleErrorEvent(json, diagnosticJSON: redactedDiagnosticJSON)
        case "input_audio_buffer.committed":
            handleCommittedEvent(json)
        case "conversation.item.input_audio_transcription.delta":
            handleDeltaEvent(json)
        case "conversation.item.input_audio_transcription.completed":
            handleCompletedEvent(json)
        case "conversation.item.input_audio_transcription.failed":
            lastFailedTranscriptionJSON = redactedDiagnosticJSON
            let rawMessage = nestedString(json["error"], key: "message") ?? "Input audio transcription failed."
            let message = RealtimeDiagnosticsRedactor.sanitizedProviderErrorMessage(
                rawMessage,
                dictionarySnapshot: dictionarySnapshot
            )
            recordFailure(OpenAIRealtimeTranscriptionError.serverError(message))
        default:
            break
        }
    }

    private func handleErrorEvent(_ json: [String: Any], diagnosticJSON: String) {
        lastErrorEventJSON = diagnosticJSON
        let errorObject = json["error"] as? [String: Any]
        let code = errorObject?["code"] as? String
        let rawMessage = errorObject?["message"] as? String ?? "Unknown realtime API error."

        if isFinishing, isEmptyCommitError(code: code, message: rawMessage) {
            return
        }

        recordFailure(OpenAIRealtimeTranscriptionError.serverError(
            RealtimeDiagnosticsRedactor.sanitizedProviderErrorMessage(
                rawMessage,
                dictionarySnapshot: dictionarySnapshot
            )
        ))
    }

    func webSocketDidOpen() {
        openedAt = Date()
        NSLog("OpenAI realtime WebSocket opened: \(webSocketURLString)")
    }

    func webSocketDidClose(code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closedAt = Date()
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        closeDescription = "code=\(code.rawValue) reason=\(reasonText)"
        NSLog("OpenAI realtime WebSocket closed: \(closeDescription ?? "unknown")")
        guard !isClosed, failure == nil, code != .normalClosure else { return }
        recordFailure(OpenAIRealtimeTranscriptionError.webSocketFailed(closeDescription ?? "WebSocket closed unexpectedly."))
    }

    func diagnostics(summary: String? = nil) -> OpenAIRealtimeDiagnostics {
        let resolvedSummary = summary ?? failure?.localizedDescription ?? "No OpenAI realtime error recorded."
        return OpenAIRealtimeDiagnostics(summary: resolvedSummary, details: diagnosticDetails(summary: resolvedSummary))
    }

    private func waitForSessionUpdated(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try throwIfFailed()
            if sawSessionUpdated {
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        let message = "Timed out after \(String(format: "%.1f", timeout))s waiting for session.updated. sawSessionCreated=\(sawSessionCreated), endpoint=\(webSocketURLString)"
        let error = OpenAIRealtimeTranscriptionError.sessionUpdateTimedOut(message)
        recordFailure(error)
        throw error
    }

    private func recordSendError(_ error: Error) {
        lastSendError = error.localizedDescription
        recordFailure(OpenAIRealtimeTranscriptionError.webSocketFailed("Send failed: \(error.localizedDescription)"))
    }

    private func recordServerEvent(type: String, rawJSON: String) {
        let entry = "\(type): \(capped(rawJSON, maxLength: 1_500))"
        recentServerEvents.append(entry)
        if recentServerEvents.count > 12 {
            recentServerEvents.removeFirst(recentServerEvents.count - 12)
        }

        switch type {
        case "session.created", "session.updated", "transcription_session.created", "transcription_session.updated", "error", "conversation.item.input_audio_transcription.failed":
            NSLog("OpenAI realtime server event \(type): \(rawJSON)")
        default:
            break
        }
    }

    private func handleCommittedEvent(_ json: [String: Any]) {
        guard let itemID = json["item_id"] as? String, !itemID.isEmpty else { return }
        let previousItemID = json["previous_item_id"] as? String
        addCommittedItem(itemID, after: previousItemID)
    }

    private func handleDeltaEvent(_ json: [String: Any]) {
        guard
            let itemID = json["item_id"] as? String,
            let delta = json["delta"] as? String,
            !delta.isEmpty
        else {
            return
        }

        partialTranscripts[itemID, default: ""] += delta
        addEventItem(itemID)
        lastTranscriptUpdate = Date()
    }

    private func handleCompletedEvent(_ json: [String: Any]) {
        guard
            let itemID = json["item_id"] as? String,
            let transcript = json["transcript"] as? String
        else {
            return
        }

        completedTranscripts[itemID] = transcript
        addEventItem(itemID)
        lastTranscriptUpdate = Date()
    }

    private func addCommittedItem(_ itemID: String, after previousItemID: String?) {
        guard !commitOrder.contains(itemID) else { return }

        if
            let previousItemID,
            let previousIndex = commitOrder.firstIndex(of: previousItemID)
        {
            commitOrder.insert(itemID, at: min(previousIndex + 1, commitOrder.count))
        } else {
            commitOrder.append(itemID)
        }
    }

    private func addEventItem(_ itemID: String) {
        guard !eventOrder.contains(itemID) else { return }
        eventOrder.append(itemID)
    }

    private func assembledTranscript() -> String {
        var orderedIDs: [String] = []
        for itemID in commitOrder where !orderedIDs.contains(itemID) {
            orderedIDs.append(itemID)
        }
        for itemID in eventOrder where !orderedIDs.contains(itemID) {
            orderedIDs.append(itemID)
        }

        return orderedIDs
            .compactMap { itemID in
                (completedTranscripts[itemID] ?? partialTranscripts[itemID])?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func throwIfFailed() throws {
        if let failure {
            throw failure
        }
    }

    private func close() -> Bool {
        guard !isClosed else { return false }
        isClosed = true
        sendChain.cancel()
        receiveTask?.cancel()
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        webSocketTask = nil
        urlSession = nil
        webSocketDelegate = nil
        return true
    }

    private func logFinish(text: String, usedTimeout: Bool) {
        let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let timeoutSuffix = usedTimeout ? " after finalize timeout" : ""
        NSLog(
            "OpenAI realtime transcription finished\(timeoutSuffix): %.2fs, %d chunks, %d bytes, %d chars.",
            elapsed,
            appendedEvents,
            appendedBytes,
            text.count
        )
    }

    private func diagnosticDetails(summary: String) -> String {
        var lines: [String] = []
        lines.append("Summary: \(summary)")
        lines.append("Endpoint: \(webSocketURLString)")
        lines.append("Model: \(transcriptionModel)")
        lines.append("Payload: \(sessionPayloadShape)")
        lines.append("Dictionary prompt: \(dictionarySnapshot.isEmpty ? "empty" : "present")")
        lines.append("Audio format: 24kHz mono little-endian pcm16 appended as base64 input_audio_buffer.append")
        lines.append("Chunks sent: \(appendedEvents)")
        lines.append("Bytes sent: \(appendedBytes)")
        lines.append("Saw session.created: \(sawSessionCreated)")
        lines.append("Saw session.updated: \(sawSessionUpdated)")
        if let startedAt {
            lines.append("Started: \(startedAt)")
        }
        if let openedAt {
            lines.append("WebSocket opened: \(openedAt)")
        }
        if let closedAt {
            lines.append("WebSocket closed: \(closedAt)")
        }
        if let closeDescription {
            lines.append("Close: \(closeDescription)")
        }
        if let lastSendError {
            lines.append("Last send error: \(lastSendError)")
        }
        if let lastReceiveError {
            lines.append("Last receive error: \(lastReceiveError)")
        }
        if let sessionCreatedJSON {
            lines.append("session.created: \(sessionCreatedJSON)")
        }
        if let sessionUpdatedJSON {
            lines.append("session.updated: \(sessionUpdatedJSON)")
        }
        if let lastErrorEventJSON {
            lines.append("Last server error event: \(lastErrorEventJSON)")
        }
        if let lastFailedTranscriptionJSON {
            lines.append("Last failed transcription event: \(lastFailedTranscriptionJSON)")
        }
        if !recentServerEvents.isEmpty {
            lines.append("Recent server events:")
            lines.append(contentsOf: recentServerEvents.map { "- \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    private func makeJSONString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw OpenAIRealtimeTranscriptionError.invalidServerEvent
        }
        return json
    }

    private func nestedString(_ value: Any?, key: String) -> String? {
        guard let dictionary = value as? [String: Any] else { return nil }
        return dictionary[key] as? String
    }

    private func prettyJSONString(from object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func capped(_ string: String, maxLength: Int) -> String {
        guard string.count > maxLength else { return string }
        let index = string.index(string.startIndex, offsetBy: maxLength)
        return String(string[..<index]) + "...<truncated>"
    }

    private func isEmptyCommitError(code: String?, message: String) -> Bool {
        if let code, code.localizedCaseInsensitiveContains("empty") {
            return true
        }
        let lowercased = message.lowercased()
        return lowercased.contains("empty") || lowercased.contains("buffer too small")
    }

    private var transcriptionPrompt: String {
        guard !dictionarySnapshot.isEmpty else { return "" }
        return "Prefer these user dictionary terms exactly when they are spoken: \(dictionarySnapshot)"
    }

    private var sessionPayloadShape: String {
        "GA session.update transcription session: session.type=transcription, audio.input.format=audio/pcm rate=24000, noise_reduction=null, transcription.model=gpt-4o-transcribe, prompt=\(dictionarySnapshot.isEmpty ? "empty" : "dictionary"), turn_detection=null/manual commit"
    }
}

private final class OpenAIRealtimeWebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private weak var connection: OpenAIRealtimeTranscriptionConnection?

    init(connection: OpenAIRealtimeTranscriptionConnection) {
        self.connection = connection
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task {
            await connection?.webSocketDidOpen()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task {
            await connection?.webSocketDidClose(code: closeCode, reason: reason)
        }
    }
}
