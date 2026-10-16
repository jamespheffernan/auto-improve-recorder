import AVFoundation
import XCTest
@testable import AutoImproveRecorderCore

/// Records what `OpenAIRealtimeAudioSink` does today: what it holds before a
/// consumer is attached, what it drops at its 8 MiB limit, the order it
/// replays in and the diagnostic lines it gives the consumer.
final class AIRRealtimeAudioSinkTests: XCTestCase {
    private let failure = AudioCaptureFailure.sharedBufferAllocationFailed(sequence: 7)

    private func captured(_ sequence: UInt64, frames: AVAudioFrameCount = 1_600) throws -> CapturedAudioBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return try XCTUnwrap(CapturedAudioBuffer.copying(sequence: sequence, buffer: buffer))
    }

    func testOverflowAtTheQueueLimitDropsTheOldestBuffersAndCountsThem() throws {
        let sink = OpenAIRealtimeAudioSink()
        let consumer = FakeConsumer()
        sink.reset(bufferPendingAudio: true)
        // Each buffer is 1 MiB, so eight fill the 8 MiB queue exactly.
        let oneMiBOfFrames: AVAudioFrameCount = 262_144
        var bytesPerBuffer = 0
        for sequence in 1...10 {
            let buffer = try captured(UInt64(sequence), frames: oneMiBOfFrames)
            bytesPerBuffer = buffer.byteCount
            sink.appendAudioBuffer(buffer)
        }
        XCTAssertEqual(bytesPerBuffer, 1_048_576)

        XCTAssertEqual(sink.setTranscriber(consumer), 8)

        XCTAssertEqual(consumer.sequences, [3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(consumer.diagnostics.count, 1)
        XCTAssertEqual(Array(consumer.diagnostics[0].prefix(4)), [
            "Realtime pending buffers replayed: 8",
            "Realtime pending queue max bytes: \(9 * bytesPerBuffer)",
            "Realtime pending queue dropped buffers: 2",
            "Realtime pending queue dropped bytes: \(2 * bytesPerBuffer)"
        ])
    }

    func testReplayKeepsCaptureOrderThenForwardsEachNewBuffer() throws {
        let sink = OpenAIRealtimeAudioSink()
        let consumer = FakeConsumer()
        sink.reset(bufferPendingAudio: true)
        for sequence in 1...3 {
            sink.appendAudioBuffer(try captured(UInt64(sequence)))
        }

        XCTAssertEqual(sink.setTranscriber(consumer), 3)
        sink.appendAudioBuffer(try captured(4))

        XCTAssertEqual(consumer.sequences, [1, 2, 3, 4])
        XCTAssertEqual(consumer.diagnostics.count, 1)
    }

    func testBufferArrivingDuringReplayIsDeliveredAfterTheReplayedBuffers() throws {
        let sink = OpenAIRealtimeAudioSink()
        let consumer = FakeConsumer()
        consumer.blocksFirstAppend = true
        sink.reset(bufferPendingAudio: true)
        sink.appendAudioBuffer(try captured(1))
        sink.appendAudioBuffer(try captured(2))

        let replayed = expectation(description: "replay returns")
        var replayedCount = 0
        DispatchQueue.global().async {
            replayedCount = sink.setTranscriber(consumer)
            replayed.fulfill()
        }
        XCTAssertEqual(consumer.entered.wait(timeout: .now() + 5), .success)
        // The consumer is blocked on buffer 1. This call returns without waiting for it.
        sink.appendAudioBuffer(try captured(3))
        XCTAssertEqual(consumer.sequences, [1])
        consumer.release.signal()
        wait(for: [replayed], timeout: 5)

        XCTAssertEqual(replayedCount, 3)
        XCTAssertEqual(consumer.sequences, [1, 2, 3])
        XCTAssertEqual(consumer.diagnostics.first?.first, "Realtime pending buffers replayed: 3")
        sink.appendAudioBuffer(try captured(4))
        XCTAssertEqual(consumer.sequences, [1, 2, 3, 4])
    }

    func testCaptureFailureBeforeAConsumerIsAttachedDropsPendingAudioAndReachesTheConsumer() throws {
        let sink = OpenAIRealtimeAudioSink()
        let consumer = FakeConsumer()
        sink.reset(bufferPendingAudio: true)
        sink.appendAudioBuffer(try captured(1))
        sink.recordCaptureFailure(failure)
        sink.recordCaptureFailure(.sharedBufferAllocationFailed(sequence: 8))
        sink.appendAudioBuffer(try captured(2))
        XCTAssertEqual(sink.captureFailureSnapshot(), failure)

        XCTAssertEqual(sink.setTranscriber(consumer), 0)
        sink.appendAudioBuffer(try captured(3))

        XCTAssertEqual(consumer.failures, [failure])
        XCTAssertEqual(consumer.sequences, [])
        XCTAssertEqual(consumer.diagnostics.count, 0)
    }

    func testCaptureFailureAfterAConsumerIsAttachedReachesItAndStopsForwarding() throws {
        let sink = OpenAIRealtimeAudioSink()
        let consumer = FakeConsumer()
        sink.reset(bufferPendingAudio: true)
        XCTAssertEqual(sink.setTranscriber(consumer), 0)
        sink.appendAudioBuffer(try captured(1))
        sink.recordCaptureFailure(failure)
        sink.appendAudioBuffer(try captured(2))

        XCTAssertEqual(consumer.failures, [failure])
        XCTAssertEqual(consumer.sequences, [1])
    }

    func testResetClearAndDiscardForgetTheConsumerThePendingAudioAndTheFailure() throws {
        let sink = OpenAIRealtimeAudioSink()
        let first = FakeConsumer()
        sink.reset(bufferPendingAudio: true)
        sink.setTranscriber(first)
        sink.recordCaptureFailure(failure)

        sink.clear()
        XCTAssertNil(sink.captureFailureSnapshot())
        sink.appendAudioBuffer(try captured(1))
        XCTAssertEqual(first.sequences, [])

        // Without buffering, audio before a consumer is not kept.
        let second = FakeConsumer()
        sink.reset(bufferPendingAudio: false)
        sink.appendAudioBuffer(try captured(2))
        XCTAssertEqual(sink.setTranscriber(second), 0)
        XCTAssertEqual(second.sequences, [])

        // A reset forgets the failure, the consumer and the pending audio.
        sink.recordCaptureFailure(failure)
        sink.reset(bufferPendingAudio: true)
        XCTAssertNil(sink.captureFailureSnapshot())
        sink.appendAudioBuffer(try captured(3))
        XCTAssertEqual(second.sequences, [])

        // Discarding drops what is pending and stops buffering.
        sink.discardPendingAudio()
        sink.appendAudioBuffer(try captured(4))
        let third = FakeConsumer()
        XCTAssertEqual(sink.setTranscriber(third), 0)
        XCTAssertEqual(third.sequences, [])
        XCTAssertEqual(third.diagnostics.first?.first, "Realtime pending buffers replayed: 0")
    }

    func testDiagnosticTextAfterReplay() throws {
        let clock = FakeClock()
        let sink = OpenAIRealtimeAudioSink(now: { clock.now })
        let consumer = FakeConsumer()
        sink.reset(bufferPendingAudio: true)
        let buffer = try captured(1)
        sink.appendAudioBuffer(buffer)
        sink.appendAudioBuffer(try captured(2))
        // Half a second passes before the consumer is attached; each buffer is 100 ms long.
        clock.advance(by: 0.5)

        sink.setTranscriber(consumer)

        XCTAssertEqual(consumer.diagnostics, [[
            "Realtime pending buffers replayed: 2",
            "Realtime pending queue max bytes: \(2 * buffer.byteCount)",
            "Realtime pending queue dropped buffers: 0",
            "Realtime pending queue dropped bytes: 0",
            "Realtime replay lag max: 600.0ms"
        ]])
    }
}

private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

/// Records what the sink gives it. With `blocksFirstAppend`, the first buffer
/// signals `entered` and waits for `release`.
private final class FakeConsumer: RealtimeAudioSinkConsumer, @unchecked Sendable {
    var blocksFirstAppend = false
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var recordedSequences: [UInt64] = []
    private var recordedFailures: [AudioCaptureFailure] = []
    private var recordedDiagnostics: [[String]] = []

    var sequences: [UInt64] { lock.withLock { recordedSequences } }
    var failures: [AudioCaptureFailure] { lock.withLock { recordedFailures } }
    var diagnostics: [[String]] { lock.withLock { recordedDiagnostics } }

    func appendAudioBuffer(_ captured: CapturedAudioBuffer) {
        let isFirst = lock.withLock {
            recordedSequences.append(captured.sequence)
            return recordedSequences.count == 1
        }
        if isFirst && blocksFirstAppend {
            entered.signal()
            release.wait()
        }
    }

    func recordCaptureFailure(_ failure: AudioCaptureFailure) {
        lock.withLock { recordedFailures.append(failure) }
    }

    func recordCaptureDiagnostics(_ lines: [String]) {
        lock.withLock { recordedDiagnostics.append(lines) }
    }
}
