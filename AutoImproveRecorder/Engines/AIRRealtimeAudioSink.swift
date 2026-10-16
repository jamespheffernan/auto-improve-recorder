import Foundation

/// What the realtime audio sink feeds: the realtime transcriber in the app,
/// a fake in tests.
protocol RealtimeAudioSinkConsumer: AnyObject {
    func appendAudioBuffer(_ captured: CapturedAudioBuffer)
    func recordCaptureFailure(_ failure: AudioCaptureFailure)
    func recordCaptureDiagnostics(_ lines: [String])
}

extension OpenAIRealtimeTranscriber: RealtimeAudioSinkConsumer {}

/// Holds captured audio for the realtime transcriber while its socket is
/// starting, replays it in capture order once the transcriber is attached,
/// then forwards each buffer as it arrives. At most 8 MiB is held. `now` is
/// read only for the replay lag in the diagnostics.
final class OpenAIRealtimeAudioSink {
    private let lock = NSLock()
    private let maxPendingAudioBytes = 8 * 1024 * 1024
    private let now: () -> Date
    private var transcriber: (any RealtimeAudioSinkConsumer)?
    private var shouldBufferPendingAudio = false
    private var isReplayingPendingAudio = false
    private var pendingBuffers: BoundedAudioQueue<CapturedAudioBuffer>
    private var captureFailure: AudioCaptureFailure?
    private var firstPendingBufferAt: Date?
    private var maxReplayLagMs: Double = 0

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
        pendingBuffers = BoundedAudioQueue<CapturedAudioBuffer>(
            maxBytes: maxPendingAudioBytes,
            byteCount: \.byteCount
        )
    }

    func reset(bufferPendingAudio: Bool) {
        lock.lock()
        transcriber = nil
        shouldBufferPendingAudio = bufferPendingAudio
        isReplayingPendingAudio = false
        pendingBuffers.reset()
        captureFailure = nil
        firstPendingBufferAt = nil
        maxReplayLagMs = 0
        lock.unlock()
    }

    @discardableResult
    func setTranscriber(_ transcriber: any RealtimeAudioSinkConsumer) -> Int {
        lock.lock()
        if let captureFailure {
            shouldBufferPendingAudio = false
            isReplayingPendingAudio = false
            pendingBuffers.reset()
            firstPendingBufferAt = nil
            lock.unlock()
            transcriber.recordCaptureFailure(captureFailure)
            return 0
        }
        self.transcriber = transcriber
        shouldBufferPendingAudio = false
        isReplayingPendingAudio = true
        var buffersToReplay = pendingBuffers.snapshot()
        var replayBaseLagMs = firstPendingBufferAt.map { now().timeIntervalSince($0) * 1000 } ?? 0
        pendingBuffers.removeAll(keepingCapacity: true)
        firstPendingBufferAt = nil
        lock.unlock()

        var replayedBufferCount = 0
        while true {
            for buffer in buffersToReplay {
                recordReplayLag(for: buffer, baseLagMs: replayBaseLagMs)
                transcriber.appendAudioBuffer(buffer)
            }
            replayedBufferCount += buffersToReplay.count

            lock.lock()
            if pendingBuffers.isEmpty {
                let diagnostics = diagnosticsLinesLocked(replayedBufferCount: replayedBufferCount)
                isReplayingPendingAudio = false
                lock.unlock()
                transcriber.recordCaptureDiagnostics(diagnostics)
                break
            }
            buffersToReplay = pendingBuffers.snapshot()
            replayBaseLagMs = firstPendingBufferAt.map { now().timeIntervalSince($0) * 1000 } ?? 0
            pendingBuffers.removeAll(keepingCapacity: true)
            firstPendingBufferAt = nil
            lock.unlock()
        }

        return replayedBufferCount
    }

    func appendAudioBuffer(_ captured: CapturedAudioBuffer) {
        lock.lock()
        guard captureFailure == nil else {
            lock.unlock()
            return
        }
        if let transcriber, !isReplayingPendingAudio {
            lock.unlock()
            transcriber.appendAudioBuffer(captured)
            return
        }

        guard shouldBufferPendingAudio || isReplayingPendingAudio else {
            lock.unlock()
            return
        }

        if pendingBuffers.isEmpty {
            firstPendingBufferAt = now()
        }
        let droppedBefore = pendingBuffers.droppedElements
        pendingBuffers.append(captured)
        if pendingBuffers.droppedElements > droppedBefore {
            firstPendingBufferAt = now()
        }
        lock.unlock()
    }

    func recordCaptureFailure(_ failure: AudioCaptureFailure) {
        lock.lock()
        if captureFailure == nil {
            captureFailure = failure
        }
        let activeTranscriber = transcriber
        shouldBufferPendingAudio = false
        isReplayingPendingAudio = false
        pendingBuffers.reset()
        firstPendingBufferAt = nil
        lock.unlock()
        activeTranscriber?.recordCaptureFailure(failure)
    }

    func captureFailureSnapshot() -> AudioCaptureFailure? {
        lock.lock()
        let failure = captureFailure
        lock.unlock()
        return failure
    }

    func discardPendingAudio() {
        lock.lock()
        pendingBuffers.reset()
        firstPendingBufferAt = nil
        maxReplayLagMs = 0
        shouldBufferPendingAudio = false
        isReplayingPendingAudio = false
        lock.unlock()
    }

    func clear() {
        lock.lock()
        transcriber = nil
        shouldBufferPendingAudio = false
        isReplayingPendingAudio = false
        pendingBuffers.reset()
        captureFailure = nil
        firstPendingBufferAt = nil
        maxReplayLagMs = 0
        lock.unlock()
    }

    private func recordReplayLag(for captured: CapturedAudioBuffer, baseLagMs: Double) {
        let sampleRate = captured.format.sampleRate
        guard sampleRate > 0 else { return }
        let durationMs = Double(captured.frameLength) / sampleRate * 1000
        lock.lock()
        maxReplayLagMs = max(maxReplayLagMs, baseLagMs + durationMs)
        lock.unlock()
    }

    private func diagnosticsLinesLocked(replayedBufferCount: Int) -> [String] {
        var lines: [String] = []
        lines.append("Realtime pending buffers replayed: \(replayedBufferCount)")
        lines.append("Realtime pending queue max bytes: \(pendingBuffers.maxObservedPendingBytes)")
        lines.append("Realtime pending queue dropped buffers: \(pendingBuffers.droppedElements)")
        lines.append("Realtime pending queue dropped bytes: \(pendingBuffers.droppedBytes)")
        lines.append("Realtime replay lag max: \(String(format: "%.1f", maxReplayLagMs))ms")
        return lines
    }

}
