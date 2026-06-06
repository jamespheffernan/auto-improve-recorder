import AVFoundation
import Foundation

enum RealtimePCMChunkerError: LocalizedError, Equatable {
    case invalidInputFormat
    case converterCreationFailed
    case outputBufferAllocationFailed
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat:
            return "Input audio format is not valid for realtime conversion."
        case .converterCreationFailed:
            return "Could not create realtime audio converter."
        case .outputBufferAllocationFailed:
            return "Could not allocate realtime audio conversion buffer."
        case .conversionFailed(let message):
            return "Realtime audio conversion failed: \(message)"
        }
    }
}

final class RealtimePCMChunker {
    static let defaultChunkByteCount = 4_800

    private let outputFormat: AVAudioFormat
    private let chunkByteCount: Int
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var pendingData = Data()
    private var pendingFirstCaptureSequence: UInt64?
    private var pendingLastCaptureSequence: UInt64?
    private var nextChunkSequence: UInt64 = 0
    private(set) var diagnostics = AudioCaptureDiagnostics()

    init(chunkByteCount: Int = RealtimePCMChunker.defaultChunkByteCount) {
        precondition(chunkByteCount > 0, "chunkByteCount must be positive")
        self.chunkByteCount = chunkByteCount
        self.outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: RealtimeAudioFormat.pcm16Mono24k.sampleRate,
            channels: RealtimeAudioFormat.pcm16Mono24k.channelCount,
            interleaved: true
        )!
        diagnostics.chunkByteCount = chunkByteCount
    }

    func append(_ captured: CapturedAudioBuffer) throws -> [RealtimeAudioChunk] {
        guard captured.frameLength > 0 else { return [] }
        guard captured.format.sampleRate > 0, captured.format.channelCount > 0 else {
            throw record(RealtimePCMChunkerError.invalidInputFormat)
        }

        if converter == nil || converterInputFormat?.isEqual(captured.format) != true {
            guard let newConverter = AVAudioConverter(from: captured.format, to: outputFormat) else {
                throw record(RealtimePCMChunkerError.converterCreationFailed)
            }
            newConverter.primeMethod = .none
            converter = newConverter
            converterInputFormat = captured.format
            diagnostics.converterRecreateCount += 1
        }

        guard let converter else {
            throw record(RealtimePCMChunkerError.converterCreationFailed)
        }

        let ratio = outputFormat.sampleRate / captured.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(captured.frameLength) * ratio) + 512
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw record(RealtimePCMChunkerError.outputBufferAllocationFailed)
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
            return captured.buffer
        }

        if let conversionError {
            throw record(RealtimePCMChunkerError.conversionFailed(conversionError.localizedDescription))
        }

        let convertedData = pcmData(from: outputBuffer)
        guard !convertedData.isEmpty else { return [] }

        if pendingData.isEmpty {
            pendingFirstCaptureSequence = captured.sequence
        }
        pendingLastCaptureSequence = captured.sequence
        pendingData.append(convertedData)
        diagnostics.realtimePendingBytesMax = max(diagnostics.realtimePendingBytesMax, pendingData.count)

        return drainFullChunks(producedAt: Date())
    }

    func finish() -> [RealtimeAudioChunk] {
        guard !pendingData.isEmpty else { return [] }
        let chunk = makeChunk(byteCount: pendingData.count, producedAt: Date())
        pendingData.removeAll(keepingCapacity: true)
        pendingFirstCaptureSequence = nil
        pendingLastCaptureSequence = nil
        return [chunk]
    }

    private func drainFullChunks(producedAt: Date) -> [RealtimeAudioChunk] {
        var chunks: [RealtimeAudioChunk] = []
        while pendingData.count >= chunkByteCount {
            chunks.append(makeChunk(byteCount: chunkByteCount, producedAt: producedAt))
            pendingData.removeFirst(chunkByteCount)
            if pendingData.isEmpty {
                pendingFirstCaptureSequence = nil
                pendingLastCaptureSequence = nil
            }
        }
        return chunks
    }

    private func makeChunk(byteCount: Int, producedAt: Date) -> RealtimeAudioChunk {
        let chunkData = pendingData.prefix(byteCount)
        let chunk = RealtimeAudioChunk(
            sequence: nextChunkSequence,
            firstCaptureSequence: pendingFirstCaptureSequence ?? 0,
            lastCaptureSequence: pendingLastCaptureSequence ?? pendingFirstCaptureSequence ?? 0,
            producedAt: producedAt,
            format: .pcm16Mono24k,
            data: Data(chunkData)
        )
        nextChunkSequence += 1
        diagnostics.realtimeChunksProduced += 1
        return chunk
    }

    private func pcmData(from buffer: AVAudioPCMBuffer) -> Data {
        let byteCount = Int(buffer.frameLength) * RealtimeAudioFormat.pcm16Mono24k.bytesPerFrame
        guard byteCount > 0 else { return Data() }

        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard let firstBuffer = audioBuffers.first,
              let data = firstBuffer.mData else {
            return Data()
        }

        return Data(bytes: data, count: min(byteCount, Int(firstBuffer.mDataByteSize)))
    }

    private func record(_ error: RealtimePCMChunkerError) -> RealtimePCMChunkerError {
        diagnostics.conversionFailure = error.localizedDescription
        return error
    }
}
