import AVFoundation
import XCTest
@testable import AutoImproveRecorderAudioPipeline

final class AudioPipelineComponentTests: XCTestCase {
    func testBoundedAudioQueueDropsOldestElementsWhenByteCapIsExceeded() {
        var queue = BoundedAudioQueue<Data>(maxBytes: 10, byteCount: \.count)

        queue.append(Data(repeating: 1, count: 4))
        queue.append(Data(repeating: 2, count: 4))
        queue.append(Data(repeating: 3, count: 4))

        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.pendingBytes, 8)
        XCTAssertEqual(queue.droppedElements, 1)
        XCTAssertEqual(queue.droppedBytes, 4)
        XCTAssertEqual(queue.maxObservedPendingBytes, 12)
        XCTAssertEqual(queue.popFirst(), Data(repeating: 2, count: 4))
    }

    func testBoundedAudioQueueResetClearsPendingDataAndCounters() {
        var queue = BoundedAudioQueue<Data>(maxBytes: 10, byteCount: \.count)
        queue.append(Data(repeating: 1, count: 8))
        queue.append(Data(repeating: 2, count: 8))

        queue.reset()

        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.pendingBytes, 0)
        XCTAssertEqual(queue.droppedElements, 0)
        XCTAssertEqual(queue.droppedBytes, 0)
        XCTAssertEqual(queue.maxObservedPendingBytes, 0)
    }

    func testArchiveAudioWriterReportsOpenFailure() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let writer = ArchiveAudioWriter(
            url: URL(fileURLWithPath: "/tmp/unused.wav"),
            format: format,
            fileFactory: { _, _ in throw StubError.open }
        )

        writer.open()

        XCTAssertEqual(writer.status, .failed(StubError.open.localizedDescription))
        XCTAssertEqual(writer.diagnostics.archiveFailure, StubError.open.localizedDescription)
    }

    func testArchiveAudioWriterReportsWriteFailure() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let writer = ArchiveAudioWriter(
            url: URL(fileURLWithPath: "/tmp/unused.wav"),
            format: format,
            fileFactory: { _, _ in FailingArchiveFile() }
        )
        writer.open()

        writer.append(CapturedAudioBuffer(sequence: 1, buffer: try makeBuffer(format: format, frames: 256)))

        XCTAssertEqual(writer.status, .failed(StubError.write.localizedDescription))
        XCTAssertEqual(writer.diagnostics.archiveFailure, StubError.write.localizedDescription)
    }

    func testFanoutContinuesRealtimeWhenArchiveFails() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        var realtimeCalls = 0
        let fanout = AudioCaptureFanout(
            archiveConsumer: { _ in throw StubError.write },
            realtimeConsumer: { captured in
                realtimeCalls += 1
                return [
                    RealtimeAudioChunk(
                        sequence: captured.sequence,
                        firstCaptureSequence: captured.sequence,
                        lastCaptureSequence: captured.sequence,
                        producedAt: Date(),
                        format: .pcm16Mono24k,
                        data: Data([1, 2, 3])
                    )
                ]
            }
        )

        let chunks = fanout.offer(CapturedAudioBuffer(sequence: 42, buffer: try makeBuffer(format: format, frames: 256)))

        XCTAssertEqual(realtimeCalls, 1)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(fanout.archiveStatus, .failed(StubError.write.localizedDescription))
        XCTAssertEqual(fanout.realtimeStatus, .active)
    }

    func testFanoutContinuesArchiveWhenRealtimeFails() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        var archiveCalls = 0
        let fanout = AudioCaptureFanout(
            archiveConsumer: { _ in archiveCalls += 1 },
            realtimeConsumer: { _ in throw StubError.realtime }
        )

        let chunks = fanout.offer(CapturedAudioBuffer(sequence: 99, buffer: try makeBuffer(format: format, frames: 256)))

        XCTAssertEqual(archiveCalls, 1)
        XCTAssertEqual(chunks.count, 0)
        XCTAssertEqual(fanout.archiveStatus, .writing)
        XCTAssertEqual(fanout.realtimeStatus, .failed(StubError.realtime.localizedDescription))
    }

    private func makeBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw StubError.buffer
        }
        buffer.frameLength = frames
        if let channelData = buffer.floatChannelData {
            for frame in 0..<Int(frames) {
                channelData[0][frame] = Float(frame % 32) / 32.0
            }
        }
        return buffer
    }
}

private final class FailingArchiveFile: AudioArchiveFileWriting {
    let fileURL = URL(fileURLWithPath: "/tmp/failing.wav")

    func write(from buffer: AVAudioPCMBuffer) throws {
        throw StubError.write
    }
}

private enum StubError: LocalizedError {
    case open
    case write
    case realtime
    case buffer

    var errorDescription: String? {
        switch self {
        case .open:
            return "open failed"
        case .write:
            return "write failed"
        case .realtime:
            return "realtime failed"
        case .buffer:
            return "buffer allocation failed"
        }
    }
}
