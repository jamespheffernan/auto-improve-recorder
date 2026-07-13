import Foundation

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
            return "localParakeetCppRecommended"
        case .resident:
            return "localParakeetCppResident"
        case .fast:
            return "localParakeetCppFast"
        case .allLocal:
            return "localParakeetCppRecommended"
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
