import Foundation

enum ParakeetLiveRuntimeCapability: Equatable, Sendable {
    case ready
    case loadFailed
    case missingSymbols
}

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

enum ParakeetWarmupTarget: Equatable, Sendable {
    case fastOneShot
    case recommendedOneShot
    case residentRecommended
    case liveRecommended
}

enum ParakeetWarmupPolicy {
    static func targets(transcriptionModeRawValue: String) -> [ParakeetWarmupTarget] {
        switch transcriptionModeRawValue {
        case "localParakeetCppFast":
            return [.fastOneShot]
        case "localParakeetCppRecommended", "fastest":
            return [.recommendedOneShot]
        case "localParakeetCppResident":
            return [.residentRecommended]
        case "localParakeetStreaming":
            // The saved-WAV fallback remains available, but it must not load a
            // second heavy model unless the live path actually fails.
            return [.liveRecommended]
        default:
            return []
        }
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

enum LocalModelID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case parakeetCppRecommended
    case parakeetCppResident
    case parakeetCppFast
    case allLocal
    case appleSpeech
    case cloudRealtime
    case ollamaQwen35

    var id: String { rawValue }
}

enum LocalModelKind: String, Codable, Equatable, Sendable {
    case transcription
    case improvement
    case preset
}

enum LocalModelOwnership: String, Codable, Equatable, Sendable {
    case airOwned
    case appleSystem
    case externalApp
}

enum LocalModelState: String, Codable, Equatable, Sendable {
    case ready = "Ready"
    case installed = "Installed"
    case needsModel = "Needs model"
    case needsRuntime = "Needs runtime"
    case externalAppRequired = "External app required"
    case unavailable = "Unavailable"
    case checking = "Checking"
    case loading = "Loading"
    case failed = "Failed"
    case downloading = "Downloading"

    var label: String { rawValue }
}

enum LocalModelIssueSeverity: String, Codable, Equatable, Sendable {
    case info
    case warning
    case error
}

struct LocalModelIssue: Codable, Equatable, Sendable {
    var severity: LocalModelIssueSeverity
    var message: String

    static func info(_ message: String) -> LocalModelIssue {
        LocalModelIssue(severity: .info, message: message)
    }

    static func warning(_ message: String) -> LocalModelIssue {
        LocalModelIssue(severity: .warning, message: message)
    }

    static func error(_ message: String) -> LocalModelIssue {
        LocalModelIssue(severity: .error, message: message)
    }
}

struct LocalModelCapabilities: Codable, Equatable, Sendable {
    var supportsTranscription: Bool
    var supportsImprovement: Bool
    var supportsRealtime: Bool
    var supportsDictionaryContext: Bool
    var staysOnDevice: Bool

    static let localTranscription = LocalModelCapabilities(
        supportsTranscription: true,
        supportsImprovement: false,
        supportsRealtime: false,
        supportsDictionaryContext: true,
        staysOnDevice: true
    )

    static let localRealtimeTranscription = LocalModelCapabilities(
        supportsTranscription: true,
        supportsImprovement: false,
        supportsRealtime: true,
        supportsDictionaryContext: true,
        staysOnDevice: true
    )

    static let localImprovement = LocalModelCapabilities(
        supportsTranscription: false,
        supportsImprovement: true,
        supportsRealtime: false,
        supportsDictionaryContext: true,
        staysOnDevice: true
    )

    static let localPreset = LocalModelCapabilities(
        supportsTranscription: true,
        supportsImprovement: true,
        supportsRealtime: false,
        supportsDictionaryContext: true,
        staysOnDevice: true
    )

    static let cloudRealtime = LocalModelCapabilities(
        supportsTranscription: true,
        supportsImprovement: false,
        supportsRealtime: true,
        supportsDictionaryContext: true,
        staysOnDevice: false
    )

}

struct LocalModelDescriptor: Codable, Equatable, Identifiable, Sendable {
    var id: LocalModelID
    var title: String
    var subtitle: String
    var kind: LocalModelKind
    var ownership: LocalModelOwnership
    var capabilities: LocalModelCapabilities
}

struct LocalModelStatus: Codable, Equatable, Identifiable, Sendable {
    var descriptor: LocalModelDescriptor
    var state: LocalModelState
    var detail: String
    var issues: [LocalModelIssue]
    var checkedAt: Date?

    var id: LocalModelID { descriptor.id }

    var primaryIssueText: String? {
        issues.first { $0.severity == .error }?.message ??
            issues.first { $0.severity == .warning }?.message ??
            issues.first?.message
    }
}

enum LocalModelPreset: String, CaseIterable, Codable, Identifiable, Sendable {
    case recommended
    case resident
    case fast
    case allLocal
    case appleSpeech
    case cloudRealtime

    var id: String { rawValue }

    var transcriptionModeRawValue: String {
        switch self {
        case .recommended:
            return "localParakeetStreaming"
        case .resident:
            return "localParakeetCppResident"
        case .fast:
            return "localParakeetCppFast"
        case .allLocal:
            return "localParakeetStreaming"
        case .appleSpeech:
            return "appleLocal"
        case .cloudRealtime:
            return "fastest"
        }
    }

    var improvementModeRawValue: String? {
        switch self {
        case .allLocal:
            return "ollamaLocal"
        case .recommended, .resident, .fast, .appleSpeech, .cloudRealtime:
            return nil
        }
    }

    var ollamaModel: String? {
        switch self {
        case .allLocal:
            return LocalModelInventory.qwenOllamaModel
        case .recommended, .resident, .fast, .appleSpeech, .cloudRealtime:
            return nil
        }
    }
}
