import AVFoundation
import CryptoKit
import XCTest
@testable import AutoImproveRecorderCore

final class RealtimePCMChunkerTests: XCTestCase {
    func testEmitsExactDefault100msChunkWhenInputAlreadyMatchesRealtimeFormat() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
        let buffer = try makeInt16Buffer(format: format, frames: 2_400)
        let chunker = RealtimePCMChunker()

        let chunks = try chunker.append(CapturedAudioBuffer(sequence: 10, buffer: buffer))

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].data.count, RealtimePCMChunker.defaultChunkByteCount)
        XCTAssertEqual(chunks[0].format, .pcm16Mono24k)
        XCTAssertEqual(chunks[0].firstCaptureSequence, 10)
        XCTAssertEqual(chunks[0].lastCaptureSequence, 10)
        XCTAssertEqual(chunker.finish(), [])
    }

    func testConvertsStereoFloat48kIntoPCM16Chunks() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let buffer = try makeSineBuffer(format: format, frames: 4_800)
        let chunker = RealtimePCMChunker()

        var chunks = try chunker.append(CapturedAudioBuffer(sequence: 10, buffer: buffer))
        chunks.append(contentsOf: try chunker.append(CapturedAudioBuffer(sequence: 11, buffer: buffer)))

        XCTAssertGreaterThanOrEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.data.count, RealtimePCMChunker.defaultChunkByteCount)
        XCTAssertEqual(chunks.first?.format, .pcm16Mono24k)
        XCTAssertEqual(chunks.first?.firstCaptureSequence, 10)
        XCTAssertGreaterThanOrEqual(chunks.first?.lastCaptureSequence ?? 0, 10)
    }

    func testAccumulatesPartialChunksAndFlushesTailOnFinish() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let chunker = RealtimePCMChunker()

        let first = try chunker.append(CapturedAudioBuffer(sequence: 1, buffer: makeSineBuffer(format: format, frames: 1_200)))
        let second = try chunker.append(CapturedAudioBuffer(sequence: 2, buffer: makeSineBuffer(format: format, frames: 1_200)))
        let tail = chunker.finish()

        XCTAssertEqual(first, [])
        XCTAssertEqual(second, [])
        XCTAssertEqual(tail.count, 1)
        XCTAssertGreaterThan(tail[0].data.count, 0)
        XCTAssertLessThan(tail[0].data.count, RealtimePCMChunker.defaultChunkByteCount)
        XCTAssertEqual(tail[0].firstCaptureSequence, 1)
        XCTAssertEqual(tail[0].lastCaptureSequence, 2)
    }

    func testRecreatesConverterWhenInputFormatChanges() throws {
        let firstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let secondFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let chunker = RealtimePCMChunker()

        _ = try chunker.append(CapturedAudioBuffer(sequence: 1, buffer: makeSineBuffer(format: firstFormat, frames: 1_200)))
        _ = try chunker.append(CapturedAudioBuffer(sequence: 2, buffer: makeSineBuffer(format: firstFormat, frames: 1_200)))
        _ = try chunker.append(CapturedAudioBuffer(sequence: 3, buffer: makeSineBuffer(format: secondFormat, frames: 1_200)))

        XCTAssertEqual(chunker.diagnostics.converterRecreateCount, 2)
    }

    func testReusesOneConversionBufferForStableFormatAndCapacity() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let chunker = RealtimePCMChunker()

        for sequence in 0..<100 {
            _ = try chunker.append(
                CapturedAudioBuffer(
                    sequence: UInt64(sequence),
                    buffer: makeSineBuffer(format: format, frames: 256)
                )
            )
        }

        XCTAssertEqual(chunker.conversionBufferAllocationCount, 1)
    }

    func testReallocatesConversionBufferOnlyWhenCapacityGrows() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let chunker = RealtimePCMChunker()

        _ = try chunker.append(
            CapturedAudioBuffer(sequence: 1, buffer: makeSineBuffer(format: format, frames: 256))
        )
        _ = try chunker.append(
            CapturedAudioBuffer(sequence: 2, buffer: makeSineBuffer(format: format, frames: 4_800))
        )
        _ = try chunker.append(
            CapturedAudioBuffer(sequence: 3, buffer: makeSineBuffer(format: format, frames: 1_200))
        )

        XCTAssertEqual(chunker.conversionBufferAllocationCount, 2)
    }

    func testStableConversionByteGoldenWithReusableOutputBuffer() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        let chunker = RealtimePCMChunker()
        var chunks: [RealtimeAudioChunk] = []

        chunks.append(contentsOf: try chunker.append(
            CapturedAudioBuffer(sequence: 10, buffer: makeSineBuffer(format: format, frames: 4_800))
        ))
        chunks.append(contentsOf: try chunker.append(
            CapturedAudioBuffer(sequence: 11, buffer: makeSineBuffer(format: format, frames: 4_800))
        ))
        chunks.append(contentsOf: chunker.finish())
        let pcm = chunks.reduce(into: Data()) { $0.append($1.data) }
        let digest = SHA256.hash(data: pcm).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(pcm.count, 8_192)
        XCTAssertEqual(digest, "5addde01f39bced50f95519ba91209183cb7b87faf4f01339258a8121a52b014")
        XCTAssertEqual(chunker.conversionBufferAllocationCount, 1)
    }

    private func makeSineBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw TestError.bufferAllocation
        }
        buffer.frameLength = frames

        guard let channelData = buffer.floatChannelData else {
            throw TestError.unsupportedFormat
        }

        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                channelData[channel][frame] = Float(sin(Double(frame) * 0.01 + Double(channel) * 0.2)) * 0.25
            }
        }

        return buffer
    }

    private func makeInt16Buffer(format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw TestError.bufferAllocation
        }
        buffer.frameLength = frames

        guard let channelData = buffer.int16ChannelData else {
            throw TestError.unsupportedFormat
        }

        for frame in 0..<Int(frames) {
            channelData[0][frame] = Int16((frame % 512) - 256)
        }

        return buffer
    }
}

private enum TestError: Error {
    case bufferAllocation
    case unsupportedFormat
}
