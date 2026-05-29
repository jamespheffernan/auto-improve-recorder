import Foundation
import AVFoundation
import AudioToolbox

// EDIT BOUNDARY: this file may be tuned by trials.

enum PreprocessError: Error {
    case readFailed(String)
    case writeFailed(String)
    case formatUnsupported(String)
    case encodeFailed(String)
}

/// File-extension hint for the `filename=` field in the multipart upload —
/// OpenAI dispatches its decoder by extension, so this matters.
struct PreprocessedAudio {
    let url: URL
    let suggestedFilename: String
    let contentType: String
}

enum Preprocess {
    /// Downsample (and downmix to mono) a WAV file to 16 kHz / 16-bit PCM.
    /// Whisper and gpt-4o-transcribe internally resample to 16 kHz, so sending
    /// 16 kHz mono cuts upload bytes ~4x for typical 48 kHz stereo input
    /// without changing the model's input.
    static func downsamplePCM16Mono16k(source: URL) throws -> URL {
        let inFile = try AVAudioFile(forReading: source)
        let inFormat = inFile.processingFormat
        let frameCount = AVAudioFrameCount(inFile.length)
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw PreprocessError.readFailed("AVAudioPCMBuffer alloc")
        }
        try inFile.read(into: inBuffer)

        let outSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-pre-\(UUID().uuidString).wav")

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000.0,
            channels: 1,
            interleaved: true
        ) else {
            throw PreprocessError.formatUnsupported("output PCM16 mono 16k")
        }

        // Pin the processing format to PCM16 mono 16k interleaved so that
        // AVAudioFile.write(from:) does no implicit conversion (which is what
        // tripped CAAssertRtn previously when source != processingFormat).
        let outFile: AVAudioFile
        do {
            outFile = try AVAudioFile(
                forWriting: dest,
                settings: outSettings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            throw PreprocessError.writeFailed(error.localizedDescription)
        }

        if inFormat.sampleRate == outFormat.sampleRate,
           inFormat.channelCount == outFormat.channelCount,
           inFormat.commonFormat == outFormat.commonFormat,
           inFormat.isInterleaved == outFormat.isInterleaved {
            // Same shape — just rewrite at the target encoding.
            try outFile.write(from: inBuffer)
            return dest
        }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw PreprocessError.formatUnsupported("converter unavailable")
        }

        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outFrameCapacity = AVAudioFrameCount(Double(frameCount) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrameCapacity) else {
            throw PreprocessError.writeFailed("output buffer alloc")
        }

        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return inBuffer
        }
        var error: NSError?
        let result = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if result == .error, let error {
            throw PreprocessError.writeFailed(error.localizedDescription)
        }
        try outFile.write(from: outBuffer)
        return dest
    }

    /// Encode a WAV source to AAC-in-M4A at the given bitrate (bps).
    /// AAC is broadly supported by OpenAI Whisper / gpt-4o-transcribe (via .m4a).
    /// At 24-32 kbps mono, achieves ~50-150x reduction over 48k stereo WAV.
    static func encodeAACM4A(source: URL, bitrate: Int) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("bench-pre-\(UUID().uuidString).m4a")

        // AVAssetWriter is the canonical AAC-in-M4A path on Apple platforms.
        // We feed it CMSampleBuffers built from the source's PCM frames.
        let inFile = try AVAudioFile(forReading: source)
        let inFormat = inFile.processingFormat
        let totalFrames = AVAudioFrameCount(inFile.length)

        // Downmix to mono 16 kHz first if not already; AAC encoder accepts any
        // rate but speech codecs prefer 16 kHz.
        let pcmTarget = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000.0,
            channels: 1,
            interleaved: false
        )!

        let needsConvert = !(inFormat.sampleRate == pcmTarget.sampleRate
                             && inFormat.channelCount == pcmTarget.channelCount)
        let pcmBuffer: AVAudioPCMBuffer
        if needsConvert {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: totalFrames) else {
                throw PreprocessError.readFailed("PCM input alloc")
            }
            try inFile.read(into: inBuf)
            guard let conv = AVAudioConverter(from: inFormat, to: pcmTarget) else {
                throw PreprocessError.formatUnsupported("PCM converter")
            }
            let ratio = pcmTarget.sampleRate / inFormat.sampleRate
            let outCap = AVAudioFrameCount(Double(totalFrames) * ratio + 1024)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: pcmTarget, frameCapacity: outCap) else {
                throw PreprocessError.readFailed("PCM output alloc")
            }
            var consumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, status in
                if consumed { status.pointee = .endOfStream; return nil }
                consumed = true; status.pointee = .haveData; return inBuf
            }
            var convErr: NSError?
            _ = conv.convert(to: outBuf, error: &convErr, withInputFrom: inputBlock)
            if let convErr { throw PreprocessError.encodeFailed("PCM convert: \(convErr.localizedDescription)") }
            pcmBuffer = outBuf
        } else {
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: totalFrames) else {
                throw PreprocessError.readFailed("PCM input alloc")
            }
            try inFile.read(into: inBuf)
            pcmBuffer = inBuf
        }

        // Now build AVAssetWriter for .m4a (mpeg4 + AAC).
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
            throw PreprocessError.formatUnsupported("AAC writer cannot accept input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw PreprocessError.encodeFailed("startWriting: \(writer.error?.localizedDescription ?? "?")")
        }
        writer.startSession(atSourceTime: .zero)

        // Push the PCM buffer through as CMSampleBuffers in chunks of ~1024 frames.
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
            throw PreprocessError.encodeFailed("CMAudioFormatDescriptionCreate \(fdStatus)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var writeError: Error?
        let queue = DispatchQueue(label: "bench-aac-writer")
        input.requestMediaDataWhenReady(on: queue) {
            while input.isReadyForMoreMediaData {
                if offset >= frameLength {
                    input.markAsFinished()
                    writer.finishWriting {
                        semaphore.signal()
                    }
                    return
                }
                let take = min(chunkFrames, frameLength - offset)

                // Copy PCM slice into a fresh interleaved-float CMBlockBuffer.
                let bytesPerFrame = Int(asbd.mBytesPerFrame)
                let byteCount = Int(take) * bytesPerFrame
                let sampleData = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
                if let src = pcmBuffer.floatChannelData?[0] {
                    // Mono float32 non-interleaved == interleaved; copy directly.
                    let off = Int(offset)
                    let dst = sampleData.assumingMemoryBound(to: Float.self)
                    for i in 0..<Int(take) {
                        dst[i] = src[off + i]
                    }
                }
                var blockBuffer: CMBlockBuffer?
                let bbStatus = CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: sampleData,
                    blockLength: byteCount,
                    blockAllocator: kCFAllocatorDefault,
                    customBlockSource: nil,
                    offsetToData: 0,
                    dataLength: byteCount,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
                guard bbStatus == kCMBlockBufferNoErr, let bb = blockBuffer else {
                    writeError = PreprocessError.encodeFailed("CMBlockBufferCreate \(bbStatus)")
                    sampleData.deallocate()
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
                    writeError = PreprocessError.encodeFailed("SampleBuffer \(sbStatus)")
                    input.markAsFinished()
                    writer.finishWriting { semaphore.signal() }
                    return
                }
                if !input.append(sb) {
                    writeError = writer.error ?? PreprocessError.encodeFailed("append failed")
                    input.markAsFinished()
                    writer.finishWriting { semaphore.signal() }
                    return
                }
                offset += take
            }
        }

        // Wait synchronously — this function is not on the main thread in the bench.
        semaphore.wait()
        if let err = writeError {
            throw err
        }
        if writer.status != .completed {
            throw PreprocessError.encodeFailed("writer status=\(writer.status.rawValue) err=\(writer.error?.localizedDescription ?? "")")
        }
        return dest
    }
}
