import AVFoundation
import Foundation

enum OpenAIRealtimeTranscriptionError: LocalizedError {
    case missingAPIKey
    case invalidWebSocketURL
    case conversionFailed(String)
    case invalidServerEvent
    case serverError(String)
    case webSocketFailed(String)
    case emptyTranscript

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
        case .serverError(let message):
            return "OpenAI realtime transcription failed: \(message)"
        case .webSocketFailed(let message):
            return "OpenAI realtime WebSocket failed: \(message)"
        case .emptyTranscript:
            return "OpenAI realtime returned an empty transcript."
        }
    }
}

final class OpenAIRealtimeTranscriber {
    private let connection: OpenAIRealtimeTranscriptionConnection
    private let converter = PCM16MonoAudioConverter()
    private let audioLock = NSLock()
    private var acceptingAudio = true

    init(apiKey: String) {
        connection = OpenAIRealtimeTranscriptionConnection(apiKey: apiKey)
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

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        audioLock.lock()
        defer { audioLock.unlock() }

        guard acceptingAudio else { return }

        do {
            guard let data = try converter.convert(buffer: buffer), !data.isEmpty else { return }
            Task {
                await connection.enqueueAudio(data)
            }
        } catch {
            Task {
                await connection.recordFailure(error)
            }
        }
    }

    func finish() async throws -> TranscriptionResult {
        stopAcceptingAudio()
        return try await connection.finish()
    }

    func cancel() async {
        stopAcceptingAudio()
        await connection.cancel()
    }

    private func stopAcceptingAudio() {
        audioLock.lock()
        acceptingAudio = false
        audioLock.unlock()
    }
}

private final class PCM16MonoAudioConverter {
    private let outputSampleRate = 24_000.0
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init() {
        outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: true
        )!
    }

    func convert(buffer: AVAudioPCMBuffer) throws -> Data? {
        guard buffer.frameLength > 0 else { return nil }

        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converterInputFormat = buffer.format
        }

        guard let converter else {
            throw OpenAIRealtimeTranscriptionError.conversionFailed("Could not create AVAudioConverter.")
        }

        let ratio = outputSampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 512
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw OpenAIRealtimeTranscriptionError.conversionFailed("Could not allocate output buffer.")
        }

        var didProvideInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideInput {
                status.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw OpenAIRealtimeTranscriptionError.conversionFailed(conversionError.localizedDescription)
        }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else { return nil }

        let byteCount = Int(outputBuffer.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        guard byteCount > 0 else { return nil }
        return Data(bytes: bytes, count: byteCount)
    }
}

private actor OpenAIRealtimeTranscriptionConnection {
    private let apiKey: String
    private let transcriptionModel = "gpt-4o-transcribe"
    private let webSocketURL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendChain: Task<Void, Error> = Task {}

    private var isClosed = false
    private var isFinishing = false
    private var failure: Error?

    private var partialTranscripts: [String: String] = [:]
    private var completedTranscripts: [String: String] = [:]
    private var commitOrder: [String] = []
    private var eventOrder: [String] = []
    private var lastTranscriptUpdate = Date.distantPast

    private var appendedBytes = 0
    private var appendedEvents = 0
    private var startedAt: Date?

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func start() async throws {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIRealtimeTranscriptionError.missingAPIKey
        }
        guard let webSocketURL else {
            throw OpenAIRealtimeTranscriptionError.invalidWebSocketURL
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: webSocketURL)
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let task = session.webSocketTask(with: request)
        urlSession = session
        webSocketTask = task
        startedAt = Date()

        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveMessages()
        }

        try await sendEvent([
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": 24_000
                        ],
                        "noise_reduction": [
                            "type": "near_field"
                        ],
                        "transcription": [
                            "model": transcriptionModel,
                            "prompt": "",
                            "language": "en"
                        ],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 500
                        ]
                    ]
                ]
            ]
        ])

        NSLog("OpenAI realtime transcription started with transcription session / \(transcriptionModel).")
    }

    func enqueueAudio(_ data: Data) {
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

        let finishStartedAt = Date()
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
            let waitedForFinalize = Date().timeIntervalSince(finishStartedAt)
            let sawCompletionAfterFinish = completedTranscripts.count > completedCountAtFinish

            if !text.isEmpty, quietFor >= 0.7, sawCompletionAfterFinish || waitedForFinalize >= 1.5 {
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
        return TranscriptionResult(text: text, engineName: "OpenAI Realtime \(transcriptionModel)")
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
            try await webSocketTask.send(.string(json))
        }
    }

    private func sendEvent(_ event: [String: Any]) async throws {
        guard let webSocketTask else {
            throw OpenAIRealtimeTranscriptionError.webSocketFailed("WebSocket is unavailable.")
        }

        let json = try makeJSONString(event)
        try await webSocketTask.send(.string(json))
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

        switch type {
        case "error":
            handleErrorEvent(json)
        case "input_audio_buffer.committed":
            handleCommittedEvent(json)
        case "conversation.item.input_audio_transcription.delta":
            handleDeltaEvent(json)
        case "conversation.item.input_audio_transcription.completed":
            handleCompletedEvent(json)
        case "conversation.item.input_audio_transcription.failed":
            let message = nestedString(json["error"], key: "message") ?? "Input audio transcription failed."
            recordFailure(OpenAIRealtimeTranscriptionError.serverError(message))
        default:
            break
        }
    }

    private func handleErrorEvent(_ json: [String: Any]) {
        let errorObject = json["error"] as? [String: Any]
        let code = errorObject?["code"] as? String
        let message = errorObject?["message"] as? String ?? "Unknown realtime API error."

        if isFinishing, isEmptyCommitError(code: code, message: message) {
            return
        }

        recordFailure(OpenAIRealtimeTranscriptionError.serverError(message))
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

    private func isEmptyCommitError(code: String?, message: String) -> Bool {
        if let code, code.localizedCaseInsensitiveContains("empty") {
            return true
        }
        let lowercased = message.lowercased()
        return lowercased.contains("empty") || lowercased.contains("buffer too small")
    }
}
