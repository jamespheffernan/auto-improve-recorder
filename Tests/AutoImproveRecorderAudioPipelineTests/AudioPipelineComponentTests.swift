import AVFoundation
import XCTest
@testable import AutoImproveRecorderCore

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

    func testArchiveAudioWriterReportsFinishFailure() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let writer = ArchiveAudioWriter(
            url: URL(fileURLWithPath: "/tmp/unused.wav"),
            format: format,
            fileFactory: { _, _ in FinishFailingArchiveFile() }
        )
        writer.open()

        let status = writer.finish()

        XCTAssertEqual(status, .failed(StubError.finish.localizedDescription))
        XCTAssertEqual(writer.diagnostics.archiveFailure, StubError.finish.localizedDescription)
    }

    func testArchiveAudioWriterAcceptsWirelessInt16MonoBuffer() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wireless-archive-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = ArchiveAudioWriter(url: url, format: format)
        writer.open()

        writer.append(CapturedAudioBuffer(
            sequence: 0,
            buffer: try makeBuffer(format: format, frames: 320)
        ))

        XCTAssertEqual(writer.finish(), .finished(url))
        XCTAssertEqual(writer.diagnostics.archiveWriteCount, 1)
        XCTAssertGreaterThan(try Data(contentsOf: url).count, 640)
    }

    func testStopResultRejectsOpenWriteAndFinishFailures() {
        let url = URL(fileURLWithPath: "/tmp/incomplete.wav")

        for failure in [StubError.open, .write, .finish] {
            let result = AudioRecordingStopResult(
                audioURL: url,
                archiveStatus: .failed(failure.localizedDescription),
                diagnostics: AudioCaptureDiagnostics(archiveFailure: failure.localizedDescription)
            )

            XCTAssertEqual(result.archiveFailureMessage, failure.localizedDescription)
        }
    }

    func testCapturedAudioBufferCopiesOnceAndOwnsIndependentBytes() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let source = try makeBuffer(format: format, frames: 256)
        let expectedFirstSample = source.floatChannelData![0][1]

        let captured = try XCTUnwrap(CapturedAudioBuffer.copying(sequence: 7, buffer: source))
        source.floatChannelData![0][1] = -1

        XCTAssertEqual(captured.sequence, 7)
        XCTAssertEqual(captured.byteCount, 256 * MemoryLayout<Float>.size)
        XCTAssertEqual(captured.buffer.floatChannelData![0][1], expectedFirstSample)
    }

    func testCapturedAudioBufferFactoryReportsInjectedAllocationFailure() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let source = try makeBuffer(format: format, frames: 256)
        let factory = CapturedAudioBufferFactory { _, _ in nil }

        let event = factory.capture(sequence: 17, buffer: source)

        guard case .failure(let failure) = event else {
            return XCTFail("Injected allocation failure must be explicit.")
        }
        XCTAssertEqual(failure, .sharedBufferAllocationFailed(sequence: 17))
        XCTAssertTrue(failure.localizedDescription.contains("cannot be transcribed safely"))
    }

    func testFanoutSharesOneCapturedBlockIdentityWithBothConsumers() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        var archived: CapturedAudioBuffer?
        var streamed: CapturedAudioBuffer?
        let fanout = AudioCaptureFanout(
            archiveConsumer: { archived = $0 },
            realtimeConsumer: { captured in
                streamed = captured
                return []
            }
        )
        let captured = try XCTUnwrap(
            CapturedAudioBuffer.copying(
                sequence: 42,
                buffer: makeBuffer(format: format, frames: 256)
            )
        )

        _ = fanout.offer(captured)

        XCTAssertTrue(archived === captured)
        XCTAssertTrue(streamed === captured)
    }

    func testArchiveAndRealtimeCanReadSameImmutableBlockConcurrently() throws {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        )!
        let captured = try XCTUnwrap(
            CapturedAudioBuffer.copying(
                sequence: 73,
                buffer: makeBuffer(format: format, frames: 256)
            )
        )
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "air.capture.concurrent-read", attributes: .concurrent)
        let resultLock = NSLock()
        var identities: [ObjectIdentifier] = []
        var samples: [[Float]] = []

        for _ in 0..<2 {
            group.enter()
            queue.async {
                let channel = captured.buffer.floatChannelData![0]
                let readSamples = Array(UnsafeBufferPointer(start: channel, count: Int(captured.frameLength)))
                resultLock.lock()
                identities.append(ObjectIdentifier(captured))
                samples.append(readSamples)
                resultLock.unlock()
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(identities, [ObjectIdentifier(captured), ObjectIdentifier(captured)])
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0], samples[1])
    }

    func testReusableAudioPCMBufferIsBoundedAndGrowsOnlyWhenNeeded() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let pool = ReusableAudioPCMBuffer()

        let first = pool.buffer(format: format, minimumFrameCapacity: 512)
        first?.frameLength = 128
        let reused = pool.buffer(format: format, minimumFrameCapacity: 256)
        let grown = pool.buffer(format: format, minimumFrameCapacity: 1_024)

        XCTAssertTrue(first === reused)
        XCTAssertEqual(reused?.frameLength, 0)
        XCTAssertFalse(grown === first)
        XCTAssertEqual(pool.allocationCount, 2)
    }

    func testReusableAudioPCMBufferReportsInjectedOutputAllocationFailure() {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let pool = ReusableAudioPCMBuffer { _, _ in nil }

        let output = pool.buffer(format: format, minimumFrameCapacity: 512)

        XCTAssertNil(output)
        XCTAssertEqual(pool.allocationCount, 0)
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

    func finish() throws {}
}

private final class FinishFailingArchiveFile: AudioArchiveFileWriting {
    let fileURL = URL(fileURLWithPath: "/tmp/failing-finish.wav")

    func write(from buffer: AVAudioPCMBuffer) throws {}

    func finish() throws {
        throw StubError.finish
    }
}

private enum StubError: LocalizedError {
    case open
    case write
    case finish
    case realtime
    case buffer

    var errorDescription: String? {
        switch self {
        case .open:
            return "open failed"
        case .write:
            return "write failed"
        case .finish:
            return "finish failed"
        case .realtime:
            return "realtime failed"
        case .buffer:
            return "buffer allocation failed"
        }
    }
}
