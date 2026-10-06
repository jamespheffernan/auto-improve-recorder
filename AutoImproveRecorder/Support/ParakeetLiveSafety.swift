import Foundation

/// Runtime limits for the resident live transcription path. The model itself
/// is large, so AIR only recommends it on machines where its measured working
/// set leaves useful headroom. Audio waiting behind a cold model load is also
/// bounded; crossing the bound makes the saved WAV fallback authoritative.
enum ParakeetLiveSafetyPolicy {
    static let minimumPhysicalMemoryBytes: UInt64 = 16 * 1_024 * 1_024 * 1_024
    static let maximumQueuedAudioBytes = 4 * 1_024 * 1_024
    static let requiredRuntimeSymbols = [
        "parakeet_capi_load",
        "parakeet_capi_transcribe_path",
        "parakeet_capi_transcribe_pcm",
        "parakeet_capi_stream_begin",
        "parakeet_capi_stream_feed",
        "parakeet_capi_stream_finalize",
        "parakeet_capi_stream_free",
        "parakeet_capi_free_string",
        "parakeet_capi_last_error"
    ]

    static func passesMemoryGate(physicalMemoryBytes: UInt64) -> Bool {
        physicalMemoryBytes >= minimumPhysicalMemoryBytes
    }

    static func shouldSelectByDefault(
        physicalMemoryBytes: UInt64,
        liveRuntimeInstalled: Bool,
        offlineFallbackInstalled: Bool
    ) -> Bool {
        passesMemoryGate(physicalMemoryBytes: physicalMemoryBytes) &&
            liveRuntimeInstalled &&
            offlineFallbackInstalled
    }
}

/// Thread-safe admission gate between the real-time audio callback and the
/// serial Parakeet inference queue. It makes cancellation immediate and caps
/// copied audio while a cold model is loading.
final class ParakeetLiveInputAdmission: @unchecked Sendable {
    private let maximumQueuedBytes: Int
    private let lock = NSLock()
    private var queuedBytes = 0
    private var acceptingInput = true
    private var cancelled = false
    private var overflowed = false

    init(maximumQueuedBytes: Int = ParakeetLiveSafetyPolicy.maximumQueuedAudioBytes) {
        self.maximumQueuedBytes = max(1, maximumQueuedBytes)
    }

    func reserve(byteCount: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingInput, byteCount >= 0 else { return false }
        guard byteCount <= maximumQueuedBytes - queuedBytes else {
            acceptingInput = false
            overflowed = true
            return false
        }
        queuedBytes += byteCount
        return true
    }

    func complete(byteCount: Int) {
        lock.lock()
        queuedBytes = max(0, queuedBytes - max(0, byteCount))
        lock.unlock()
    }

    func closeForFinalize() {
        lock.lock()
        acceptingInput = false
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        acceptingInput = false
        cancelled = true
        lock.unlock()
    }

    var shouldProcessQueuedInput: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled && !overflowed
    }

    var failureMessage: String? {
        lock.lock()
        defer { lock.unlock() }
        guard overflowed else { return nil }
        return "Live transcription could not keep up with audio capture; using the saved recording instead."
    }

    var queuedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queuedBytes
    }
}
