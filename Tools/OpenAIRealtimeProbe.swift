import AVFoundation
import Foundation

struct ProbeVariant {
    let name: String
    let url: String
    let betaHeader: Bool
    let eventType: String
    let session: [String: Any]
}

struct OpenAIRealtimeProbe {
    static func run() async {
        guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else {
            print("Set OPENAI_API_KEY to run the realtime probe.")
            Foundation.exit(2)
        }

        let audioPath = CommandLine.arguments.dropFirst().first
        let audioData: Data
        do {
            audioData = try makeProbeAudio(path: audioPath)
        } catch {
            print("Could not prepare probe audio: \(error.localizedDescription)")
            Foundation.exit(2)
        }

        let variants = makeVariants()
        var hadSuccess = false
        for variant in variants {
            print("\n=== \(variant.name) ===")
            do {
                let transcript = try await runVariant(variant, apiKey: apiKey, audioData: audioData)
                hadSuccess = true
                print("SUCCESS transcript=\(transcript)")
            } catch {
                print("FAILED \(error.localizedDescription)")
            }
        }

        Foundation.exit(hadSuccess ? 0 : 1)
    }

    private static func makeVariants() -> [ProbeVariant] {
        let gaSession: [String: Any] = [
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
                        "model": "gpt-4o-transcribe",
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

        let manualTurnSession: [String: Any] = [
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
                        "model": "gpt-4o-transcribe",
                        "prompt": "",
                        "language": "en"
                    ],
                    "turn_detection": NSNull()
                ]
            ]
        ]

        let betaStyleSession: [String: Any] = [
            "input_audio_format": "pcm16",
            "input_audio_transcription": [
                "model": "gpt-4o-transcribe",
                "language": "en",
                "prompt": ""
            ],
            "turn_detection": [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500
            ]
        ]

        return [
            ProbeVariant(
                name: "GA intent transcription + session.update",
                url: "wss://api.openai.com/v1/realtime?intent=transcription",
                betaHeader: false,
                eventType: "session.update",
                session: gaSession
            ),
            ProbeVariant(
                name: "GA intent transcription + manual commit session.update",
                url: "wss://api.openai.com/v1/realtime?intent=transcription",
                betaHeader: false,
                eventType: "session.update",
                session: manualTurnSession
            ),
            ProbeVariant(
                name: "GA model query + transcription session.update",
                url: "wss://api.openai.com/v1/realtime?model=gpt-realtime",
                betaHeader: false,
                eventType: "session.update",
                session: gaSession
            ),
            ProbeVariant(
                name: "Beta header + transcription_session.update",
                url: "wss://api.openai.com/v1/realtime?intent=transcription",
                betaHeader: true,
                eventType: "transcription_session.update",
                session: betaStyleSession
            )
        ]
    }

    private static func runVariant(_ variant: ProbeVariant, apiKey: String, audioData: Data) async throws -> String {
        guard let url = URL(string: variant.url) else {
            throw ProbeError.message("Invalid URL: \(variant.url)")
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if variant.betaHeader {
            request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        }

        let socket = session.webSocketTask(with: request)
        socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }

        try await send([
            "type": variant.eventType,
            "session": variant.session
        ], socket: socket)

        try await waitForSessionUpdate(socket: socket)

        let chunkSize = 4_800
        var offset = 0
        while offset < audioData.count {
            let end = min(offset + chunkSize, audioData.count)
            let chunk = audioData.subdata(in: offset..<end)
            try await send([
                "type": "input_audio_buffer.append",
                "audio": chunk.base64EncodedString()
            ], socket: socket)
            offset = end
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        try await send(["type": "input_audio_buffer.commit"], socket: socket)

        let deadline = Date().addingTimeInterval(15)
        var transcript = ""
        while Date() < deadline {
            let event = try await receiveJSON(socket: socket, timeout: 3)
            let type = event["type"] as? String ?? "<missing type>"
            if type == "conversation.item.input_audio_transcription.delta",
               let delta = event["delta"] as? String {
                transcript += delta
            } else if type == "conversation.item.input_audio_transcription.completed",
                      let completed = event["transcript"] as? String {
                return completed
            } else if type == "conversation.item.input_audio_transcription.failed" || type == "error" {
                throw ProbeError.message("server event \(type): \(compactJSON(event))")
            }
        }

        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProbeError.message("Timed out waiting for transcription completion.")
        }
        return transcript
    }

    private static func waitForSessionUpdate(socket: URLSessionWebSocketTask) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            let event = try await receiveJSON(socket: socket, timeout: 3)
            let type = event["type"] as? String ?? "<missing type>"
            print("server \(type)")
            if type == "session.updated" {
                return
            }
            if type == "error" {
                throw ProbeError.message("server error before session.updated: \(compactJSON(event))")
            }
        }
        throw ProbeError.message("Timed out waiting for session.updated.")
    }

    private static func send(_ object: [String: Any], socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let json = String(data: data, encoding: .utf8) else {
            throw ProbeError.message("Could not encode JSON.")
        }
        let redacted = object["type"] as? String == "input_audio_buffer.append"
            ? "{\"type\":\"input_audio_buffer.append\",\"audio\":\"<redacted>\"}"
            : json
        print("client \(redacted)")
        try await socket.send(.string(json))
    }

    private static func receiveJSON(socket: URLSessionWebSocketTask, timeout: TimeInterval) async throws -> [String: Any] {
        try await withThrowingTaskGroup(of: [String: Any].self) { group in
            group.addTask {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text):
                    data = Data(text.utf8)
                case .data(let bytes):
                    data = bytes
                @unknown default:
                    throw ProbeError.message("Unknown WebSocket message.")
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ProbeError.message("Non-JSON server message: \(String(data: data, encoding: .utf8) ?? "<binary>")")
                }
                return json
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ProbeError.message("Receive timed out after \(timeout)s.")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private static func makeProbeAudio(path: String?) throws -> Data {
        if let path {
            return try convertAudioFile(URL(fileURLWithPath: path))
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-realtime-probe-\(UUID().uuidString).caf")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-o",
            temporaryURL.path,
            "--file-format=caff",
            "--data-format=LEI16@24000",
            "openai realtime transcription probe"
        ]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ProbeError.message("macOS say failed with status \(process.terminationStatus).")
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            return try convertAudioFile(temporaryURL)
        } catch {
            print("Warning: macOS say did not produce usable audio here; using a generated tone. Pass a speech file path for end-to-end transcription proof.")
            return makeTonePCM16()
        }
    }

    private static func convertAudioFile(_ url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else {
            throw ProbeError.message("Audio file contains no frames.")
        }
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw ProbeError.message("Could not allocate input buffer.")
        }
        try file.read(into: inputBuffer)

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: inputBuffer.format, to: outputFormat) else {
            throw ProbeError.message("Could not create audio converter.")
        }

        let ratio = 24_000 / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 512
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw ProbeError.message("Could not allocate output buffer.")
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
            return inputBuffer
        }
        if let conversionError {
            throw conversionError
        }

        let audioBuffer = outputBuffer.audioBufferList.pointee.mBuffers
        guard let bytes = audioBuffer.mData else {
            throw ProbeError.message("Converted buffer had no bytes.")
        }
        let byteCount = Int(outputBuffer.frameLength) * Int(outputFormat.streamDescription.pointee.mBytesPerFrame)
        return Data(bytes: bytes, count: byteCount)
    }

    private static func makeTonePCM16() -> Data {
        let sampleRate = 24_000
        let frameCount = sampleRate
        var data = Data(capacity: frameCount * 2)
        for frame in 0..<frameCount {
            let sample = sin(2.0 * Double.pi * 440.0 * Double(frame) / Double(sampleRate))
            var value = Int16(sample * 8_000).littleEndian
            withUnsafeBytes(of: &value) { bytes in
                data.append(contentsOf: bytes)
            }
        }
        return data
    }

    private static func compactJSON(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return "\(object)"
        }
        return json
    }
}

enum ProbeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    await OpenAIRealtimeProbe.run()
    semaphore.signal()
}
semaphore.wait()
