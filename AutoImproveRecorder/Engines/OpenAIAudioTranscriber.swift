import Foundation
import AVFoundation
import AudioToolbox

struct OpenAIAudioTranscriber: TranscriptionEngine {
    private let apiKey: String
    private let model = "gpt-4o-transcribe"
    /// On-device pre-upload AAC encoding. Bench (.autoresearch/air-opus-upload.jsonl,
    /// loop wave 8) measured a 35x byte reduction on the long-120s fixture and an
    /// ~20x p95 latency win at LTE 5 Mbps over baseline 48k mono WAV. AAC-LC mono
    /// 16 kHz @ 24 kbps preserves Whisper / gpt-4o-transcribe accuracy in published
    /// benchmarks (<1% WER delta vs uncompressed). When encoding fails we fall back
    /// to the original audio file unchanged.
    private let aacBitrate: Int

    init(apiKey: String, aacBitrate: Int = 24_000) {
        self.apiKey = apiKey
        self.aacBitrate = aacBitrate
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw OpenAIAudioTranscriptionError.missingAPIKey
        }
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw TranscriptionEngineError.audioMissing(audioURL.path)
        }

        // Pre-upload encode to AAC-in-M4A. Falls back to original on any error so
        // we never break the user flow because of a codec hiccup.
        let uploadURL: URL
        let cleanupURL: URL?
        let contentType: String
        let fileExt: String
        if aacBitrate > 0,
           let encoded = try? Self.encodeAACM4A(source: audioURL, bitrate: aacBitrate) {
            uploadURL = encoded
            cleanupURL = encoded
            contentType = "audio/mp4"
            fileExt = "m4a"
        } else {
            uploadURL = audioURL
            cleanupURL = nil
            contentType = "audio/wav"
            fileExt = audioURL.pathExtension.isEmpty ? "wav" : audioURL.pathExtension
        }
        defer {
            if let cleanupURL { try? FileManager.default.removeItem(at: cleanupURL) }
        }

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try makeMultipartBody(
            audioURL: uploadURL,
            boundary: boundary,
            contentType: contentType,
            filename: "audio.\(fileExt)"
        )

        // Shared keep-alive session: connection reuse + HTTP/3 hint + 429 retry.
        // Replaced URLSession.shared (which historically used .ephemeral defaults inside
        // this app) with the bench-validated client. See .autoresearch/ios-network-latency.jsonl.
        let (data, httpResponse) = try await SharedNetworkClient.send(request)
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OpenAIAudioTranscriptionError.serverError(
                status: httpResponse.statusCode,
                message: parseErrorMessage(from: data)
            )
        }

        // We request response_format=text in makeMultipartBody, so the
        // transcript body usually arrives as plain UTF-8. Some error paths still
        // return JSON, so fall back to the legacy {"text":"…"} shape if the
        // body looks JSON-encoded.
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            let candidate = utf8.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.hasPrefix("{") {
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let nested = object["text"] as? String
                else {
                    throw OpenAIAudioTranscriptionError.invalidResponse
                }
                text = nested
            } else {
                text = candidate
            }
        } else {
            throw OpenAIAudioTranscriptionError.invalidResponse
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw OpenAIAudioTranscriptionError.emptyTranscript
        }

        return TranscriptionResult(text: trimmedText, engineName: "OpenAI Audio \(model)")
    }

    private func makeMultipartBody(
        audioURL: URL,
        boundary: String,
        contentType: String,
        filename: String
    ) throws -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        append("\(model)\r\n")

        // Bench (.autoresearch/transcription-latency.jsonl, 6-pass × 25 runs on
        // long-120s fixture) showed response_format=text shaved p95 by 10–26%
        // by skipping the JSON serialize/parse roundtrip on both sides. Trial
        // log entries with variant="plain-text".
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
        append("text\r\n")

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: \(contentType)\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n")

        append("--\(boundary)--\r\n")
        return body
    }

    /// Encode a source audio file (WAV or any AVAudioFile-readable container) to
    /// AAC-LC mono 16 kHz in an .m4a container at the given bitrate (bps).
    /// Returns the URL of the temp .m4a file. Caller must delete when done.
    /// Bench reference: .autoresearch/air-opus-upload.jsonl loop wave 8.
    static func encodeAACM4A(source: URL, bitrate: Int) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("openai-pre-\(UUID().uuidString).m4a")

        let inFile = try AVAudioFile(forReading: source)
        let inFormat = inFile.processingFormat
        let totalFrames = AVAudioFrameCount(inFile.length)

        let pcmTarget = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000.0,
            channels: 1,
            interleaved: false
        )!

        let pcmBuffer: AVAudioPCMBuffer
        if inFormat.sampleRate != pcmTarget.sampleRate || inFormat.channelCount != pcmTarget.channelCount {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: totalFrames) else {
                throw OpenAIAudioTranscriptionError.invalidResponse
            }
            try inFile.read(into: inBuf)
            guard let conv = AVAudioConverter(from: inFormat, to: pcmTarget) else {
                throw OpenAIAudioTranscriptionError.invalidResponse
            }
            let ratio = pcmTarget.sampleRate / inFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(totalFrames) * ratio + 1024)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: pcmTarget, frameCapacity: outCap) else {
                throw OpenAIAudioTranscriptionError.invalidResponse
            }
            var consumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true; status.pointee = .haveData; return inBuf
            }
            var convErr: NSError?
            _ = conv.convert(to: outBuf, error: &convErr, withInputFrom: inputBlock)
            if let convErr {
                throw OpenAIAudioTranscriptionError.serverError(status: -1, message: "PCM convert: \(convErr.localizedDescription)")
            }
            pcmBuffer = outBuf
        } else {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: totalFrames) else {
                throw OpenAIAudioTranscriptionError.invalidResponse
            }
            try inFile.read(into: inBuf)
            pcmBuffer = inBuf
        }

        try? FileManager.default.removeItem(at: dest)
        let writer = try AVAssetWriter(outputURL: dest, fileType: .m4a)
        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: bitrate
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw OpenAIAudioTranscriptionError.invalidResponse
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw OpenAIAudioTranscriptionError.serverError(status: -1, message: writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        let frameLength = pcmBuffer.frameLength
        let chunkFrames: AVAudioFrameCount = 4096
        var offset: AVAudioFrameCount = 0
        let asbd = pcmTarget.streamDescription.pointee
        var asbdMutable = asbd
        var formatDesc: CMAudioFormatDescription?
        let fdStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbdMutable,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard fdStatus == noErr, let fd = formatDesc else {
            throw OpenAIAudioTranscriptionError.serverError(status: Int(fdStatus), message: "CMAudioFormatDescriptionCreate")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var writeError: Error?
        let queue = DispatchQueue(label: "openai-aac-writer")
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if offset >= frameLength {
                    input.markAsFinished()
                    writer.finishWriting { semaphore.signal() }
                    return
                }
                let take = min(chunkFrames, frameLength - offset)
                let bytesPerFrame = Int(asbd.mBytesPerFrame)
                let byteCount = Int(take) * bytesPerFrame
                let mem = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
                if let src = pcmBuffer.floatChannelData?[0] {
                    let off = Int(offset)
                    let dst = mem.assumingMemoryBound(to: Float.self)
                    for i in 0..<Int(take) { dst[i] = src[off + i] }
                }
                var blockBuffer: CMBlockBuffer?
                let bbStatus = CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: mem,
                    blockLength: byteCount,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: byteCount,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
                guard bbStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
                    writeError = OpenAIAudioTranscriptionError.serverError(status: Int(bbStatus), message: "CMBlockBufferCreate")
                    mem.deallocate()
                    input.markAsFinished()
                    writer.finishWriting { semaphore.signal() }
                    return
                }
                var sampleBuffer: CMSampleBuffer?
                let pts = CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(asbd.mSampleRate))
                let sbStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: bb,
                    formatDescription: fd,
                    sampleCount: CMItemCount(take),
                    presentationTimeStamp: pts,
                    packetDescriptions: nil,
                    sampleBufferOut: &sampleBuffer
                )
                guard sbStatus == noErr, let sb = sampleBuffer else {
                    writeError = OpenAIAudioTranscriptionError.serverError(status: Int(sbStatus), message: "SampleBufferCreate")
                    input.markAsFinished()
                    writer.finishWriting { semaphore.signal() }
                    return
                }
                if !input.append(sb) {
                    writeError = writer.error ?? OpenAIAudioTranscriptionError.invalidResponse
                    input.markAsFinished()
                    writer.finishWriting { semaphore.signal() }
                    return
                }
                offset += take
            }
        }
        semaphore.wait()
        if let err = writeError { throw err }
        guard writer.status == .completed else {
            throw OpenAIAudioTranscriptionError.serverError(status: writer.status.rawValue, message: writer.error?.localizedDescription ?? "writer not completed")
        }
        return dest
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
