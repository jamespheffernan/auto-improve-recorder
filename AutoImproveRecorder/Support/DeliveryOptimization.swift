import Foundation

enum DeliveryOptimizationMode: String, Codable, Equatable {
    case legacyOnly
    case qualifiedCapabilities
}

enum DeliveryStrategy: String, Codable, Equatable {
    case legacyClipboardPaste
    case acknowledgedClipboardPaste
    case directAccessibilityInsertion
}

enum DeliveryFallback: String, Codable, Equatable {
    case notRequired
    case optimizationDisabled
    case capabilityUnavailable
}

struct DeliveryTimingValues: Codable, Equatable {
    var pasteEventNanoseconds: UInt64
    var settlementNanoseconds: UInt64
    var finalGuardNanoseconds: UInt64
    var sendEventNanoseconds: UInt64
    var totalNanoseconds: UInt64

    static let zero = DeliveryTimingValues(
        pasteEventNanoseconds: 0,
        settlementNanoseconds: 0,
        finalGuardNanoseconds: 0,
        sendEventNanoseconds: 0,
        totalNanoseconds: 0
    )
}

enum DeliveryTimingPhase: String, Codable, Equatable {
    case pasteEvent
    case settlement
    case finalGuard
    case sendEvent
    case total
}

struct DeliveryTimingSample: Equatable {
    let phase: DeliveryTimingPhase
    let strategy: DeliveryStrategy
    let elapsedNanoseconds: UInt64
}

struct PasteExecutionRequest: Equatable {
    var text: String
    var leaveClipboardChanged: Bool
    var sendCommand: SendCommand?
    var expectedDestination: DeliveryDestination?
    var unknownDestinationPolicy: UnknownDestinationPolicy
    var settlementDelayNanoseconds: UInt64
    var optimizationMode: DeliveryOptimizationMode

    init(
        text: String,
        leaveClipboardChanged: Bool,
        sendCommand: SendCommand?,
        expectedDestination: DeliveryDestination?,
        unknownDestinationPolicy: UnknownDestinationPolicy,
        settlementDelayNanoseconds: UInt64,
        optimizationMode: DeliveryOptimizationMode = .legacyOnly
    ) {
        self.text = text
        self.leaveClipboardChanged = leaveClipboardChanged
        self.sendCommand = sendCommand
        self.expectedDestination = expectedDestination
        self.unknownDestinationPolicy = unknownDestinationPolicy
        self.settlementDelayNanoseconds = settlementDelayNanoseconds
        self.optimizationMode = optimizationMode
    }
}

struct PasteExecutionResult: Equatable {
    var sendExecution: SendCommandExecution
    var strategy: DeliveryStrategy
    var fallback: DeliveryFallback
    var timing: DeliveryTimingValues
}

struct DeliveryCapabilityKey: Codable, Hashable {
    let bundleIdentifier: String
    let appMarketingVersion: String
    let appBuildVersion: String
    let role: String
    let subrole: String
    let accessibilityIdentifier: String

    init?(
        bundleIdentifier: String,
        appMarketingVersion: String,
        appBuildVersion: String,
        role: String,
        subrole: String,
        accessibilityIdentifier: String
    ) {
        guard Self.isPresent(bundleIdentifier),
              Self.isPresent(appMarketingVersion),
              Self.isPresent(appBuildVersion),
              Self.isPresent(role),
              Self.isPresent(subrole),
              Self.isPresent(accessibilityIdentifier) else {
            return nil
        }

        self.bundleIdentifier = bundleIdentifier
        self.appMarketingVersion = appMarketingVersion
        self.appBuildVersion = appBuildVersion
        self.role = role
        self.subrole = subrole
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bundleIdentifier = try container.decode(String.self, forKey: .bundleIdentifier)
        let appMarketingVersion = try container.decode(String.self, forKey: .appMarketingVersion)
        let appBuildVersion = try container.decode(String.self, forKey: .appBuildVersion)
        let role = try container.decode(String.self, forKey: .role)
        let subrole = try container.decode(String.self, forKey: .subrole)
        let accessibilityIdentifier = try container.decode(String.self, forKey: .accessibilityIdentifier)

        guard let value = Self(
            bundleIdentifier: bundleIdentifier,
            appMarketingVersion: appMarketingVersion,
            appBuildVersion: appBuildVersion,
            role: role,
            subrole: subrole,
            accessibilityIdentifier: accessibilityIdentifier
        ) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Capability key fields must not be empty.")
            )
        }
        self = value
    }

    private static func isPresent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct DeliveryCapabilityRecord: Codable, Equatable {
    let key: DeliveryCapabilityKey
    let strategy: DeliveryStrategy
    let schemaVersion: Int
    let implementationVersion: String
    let macOSBuild: String
    let operationCount: UInt64
    let errorCount: UInt64
    let legacyP50Nanoseconds: UInt64
    let p50Nanoseconds: UInt64
    let p95Nanoseconds: UInt64
    let p99Nanoseconds: UInt64
    let qualifiedAt: Date

    init?(
        key: DeliveryCapabilityKey,
        strategy: DeliveryStrategy,
        schemaVersion: Int,
        implementationVersion: String,
        macOSBuild: String,
        operationCount: UInt64,
        errorCount: UInt64,
        legacyP50Nanoseconds: UInt64,
        p50Nanoseconds: UInt64,
        p95Nanoseconds: UInt64,
        p99Nanoseconds: UInt64,
        qualifiedAt: Date
    ) {
        guard schemaVersion > 0,
              !implementationVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !macOSBuild.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              errorCount <= operationCount,
              legacyP50Nanoseconds > 0,
              p50Nanoseconds > 0,
              p50Nanoseconds <= p95Nanoseconds,
              p95Nanoseconds <= p99Nanoseconds else {
            return nil
        }

        self.key = key
        self.strategy = strategy
        self.schemaVersion = schemaVersion
        self.implementationVersion = implementationVersion
        self.macOSBuild = macOSBuild
        self.operationCount = operationCount
        self.errorCount = errorCount
        self.legacyP50Nanoseconds = legacyP50Nanoseconds
        self.p50Nanoseconds = p50Nanoseconds
        self.p95Nanoseconds = p95Nanoseconds
        self.p99Nanoseconds = p99Nanoseconds
        self.qualifiedAt = qualifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(DeliveryCapabilityKey.self, forKey: .key)
        let strategy = try container.decode(DeliveryStrategy.self, forKey: .strategy)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let implementationVersion = try container.decode(String.self, forKey: .implementationVersion)
        let macOSBuild = try container.decode(String.self, forKey: .macOSBuild)
        let operationCount = try container.decode(UInt64.self, forKey: .operationCount)
        let errorCount = try container.decode(UInt64.self, forKey: .errorCount)
        let legacyP50Nanoseconds = try container.decode(UInt64.self, forKey: .legacyP50Nanoseconds)
        let p50Nanoseconds = try container.decode(UInt64.self, forKey: .p50Nanoseconds)
        let p95Nanoseconds = try container.decode(UInt64.self, forKey: .p95Nanoseconds)
        let p99Nanoseconds = try container.decode(UInt64.self, forKey: .p99Nanoseconds)
        let qualifiedAt = try container.decode(Date.self, forKey: .qualifiedAt)

        guard let value = Self(
            key: key,
            strategy: strategy,
            schemaVersion: schemaVersion,
            implementationVersion: implementationVersion,
            macOSBuild: macOSBuild,
            operationCount: operationCount,
            errorCount: errorCount,
            legacyP50Nanoseconds: legacyP50Nanoseconds,
            p50Nanoseconds: p50Nanoseconds,
            p95Nanoseconds: p95Nanoseconds,
            p99Nanoseconds: p99Nanoseconds,
            qualifiedAt: qualifiedAt
        ) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Capability record values are invalid.")
            )
        }
        self = value
    }
}

struct DeliveryCapabilityEnvironment: Equatable {
    let key: DeliveryCapabilityKey
    let intendedStrategy: DeliveryStrategy
    let schemaVersion: Int
    let implementationVersion: String
    let macOSBuild: String
}

enum DeliveryQualificationFailure: Equatable {
    case optimizationDisabled
    case capabilityMissing
    case bundleIdentifierMismatch
    case appMarketingVersionMismatch
    case appBuildVersionMismatch
    case roleMismatch
    case subroleMismatch
    case accessibilityIdentifierMismatch
    case schemaMismatch
    case implementationMismatch
    case macOSBuildMismatch
    case unsupportedStrategy
    case strategyMismatch
    case insufficientOperations
    case observedErrors
    case insufficientMedianImprovement
}

enum DeliveryQualificationDecision: Equatable {
    case useLegacy(DeliveryQualificationFailure)
    case useQualified(DeliveryStrategy)
}

enum DeliveryCapabilityQualifier {
    static let minimumOperationCount: UInt64 = 320

    static func decide(
        record: DeliveryCapabilityRecord?,
        environment: DeliveryCapabilityEnvironment,
        mode: DeliveryOptimizationMode
    ) -> DeliveryQualificationDecision {
        guard mode == .qualifiedCapabilities else {
            return .useLegacy(.optimizationDisabled)
        }
        guard let record else {
            return .useLegacy(.capabilityMissing)
        }
        guard record.key.bundleIdentifier == environment.key.bundleIdentifier else {
            return .useLegacy(.bundleIdentifierMismatch)
        }
        guard record.key.appMarketingVersion == environment.key.appMarketingVersion else {
            return .useLegacy(.appMarketingVersionMismatch)
        }
        guard record.key.appBuildVersion == environment.key.appBuildVersion else {
            return .useLegacy(.appBuildVersionMismatch)
        }
        guard record.key.role == environment.key.role else {
            return .useLegacy(.roleMismatch)
        }
        guard record.key.subrole == environment.key.subrole else {
            return .useLegacy(.subroleMismatch)
        }
        guard record.key.accessibilityIdentifier == environment.key.accessibilityIdentifier else {
            return .useLegacy(.accessibilityIdentifierMismatch)
        }
        guard record.schemaVersion == environment.schemaVersion else {
            return .useLegacy(.schemaMismatch)
        }
        guard record.implementationVersion == environment.implementationVersion else {
            return .useLegacy(.implementationMismatch)
        }
        guard record.macOSBuild == environment.macOSBuild else {
            return .useLegacy(.macOSBuildMismatch)
        }
        guard record.strategy != .legacyClipboardPaste else {
            return .useLegacy(.unsupportedStrategy)
        }
        guard record.strategy == environment.intendedStrategy else {
            return .useLegacy(.strategyMismatch)
        }
        guard record.operationCount >= minimumOperationCount else {
            return .useLegacy(.insufficientOperations)
        }
        guard record.errorCount == 0 else {
            return .useLegacy(.observedErrors)
        }
        guard record.p50Nanoseconds <= maximumQualifiedP50(for: record.legacyP50Nanoseconds) else {
            return .useLegacy(.insufficientMedianImprovement)
        }
        return .useQualified(record.strategy)
    }

    private static func maximumQualifiedP50(for legacyP50: UInt64) -> UInt64 {
        let quotient = legacyP50 / 4
        let remainder = legacyP50 % 4
        return quotient * 3 + (remainder * 3) / 4
    }
}

/// This store is loaded only from an explicit technical qualification artifact.
/// It has no API that records or learns from a user delivery.
struct TechnicalDeliveryCapabilityStore: Codable, Equatable {
    let records: [DeliveryCapabilityRecord]

    init(records: [DeliveryCapabilityRecord] = []) {
        self.records = records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let records = try container.decode([DeliveryCapabilityRecord].self)
        guard Set(records.map(\.key)).count == records.count else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Capability keys must be unique."
            )
        }
        self.records = records
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(records)
    }

    func decision(
        for environment: DeliveryCapabilityEnvironment,
        mode: DeliveryOptimizationMode
    ) -> DeliveryQualificationDecision {
        guard mode == .qualifiedCapabilities else {
            return .useLegacy(.optimizationDisabled)
        }
        let exactRecord = records.first { $0.key == environment.key }
        return DeliveryCapabilityQualifier.decide(
            record: exactRecord,
            environment: environment,
            mode: mode
        )
    }
}

struct UTF16TextSelection: Codable, Equatable {
    let location: Int
    let length: Int
}

struct UTF16ReplacementResult: Equatable {
    let text: String
    let caret: UTF16TextSelection
}

enum UTF16ReplacementError: Error, Equatable {
    case invalidRange
}

enum UTF16TextReplacement {
    static func replacing(
        _ selection: UTF16TextSelection,
        in text: String,
        with replacement: String
    ) throws -> UTF16ReplacementResult {
        guard selection.location >= 0,
              selection.length >= 0,
              selection.location <= Int.max - selection.length else {
            throw UTF16ReplacementError.invalidRange
        }

        let range = NSRange(location: selection.location, length: selection.length)
        let utf16Text = text as NSString
        guard range.location + range.length <= utf16Text.length,
              !splitsSurrogatePair(at: range.location, in: utf16Text),
              !splitsSurrogatePair(at: range.location + range.length, in: utf16Text) else {
            throw UTF16ReplacementError.invalidRange
        }
        guard let swiftRange = Range(range, in: text),
              NSRange(swiftRange, in: text) == range else {
            throw UTF16ReplacementError.invalidRange
        }

        let result = utf16Text.replacingCharacters(in: range, with: replacement)
        let replacementLength = (replacement as NSString).length
        guard selection.location <= Int.max - replacementLength else {
            throw UTF16ReplacementError.invalidRange
        }

        return UTF16ReplacementResult(
            text: result,
            caret: UTF16TextSelection(
                location: selection.location + replacementLength,
                length: 0
            )
        )
    }

    private static func splitsSurrogatePair(at index: Int, in text: NSString) -> Bool {
        guard index > 0, index < text.length else {
            return false
        }
        return (0xD800 ... 0xDBFF).contains(text.character(at: index - 1)) &&
            (0xDC00 ... 0xDFFF).contains(text.character(at: index))
    }
}
