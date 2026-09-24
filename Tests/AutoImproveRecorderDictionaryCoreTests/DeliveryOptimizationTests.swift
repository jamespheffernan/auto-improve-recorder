import Foundation
import XCTest
@testable import AutoImproveRecorderDictionaryCore

final class DeliveryOptimizationTests: XCTestCase {
    func testDeliveryRequestDefaultsToLegacyOnly() {
        let request = DeliveryRequest(
            text: "Text",
            globalSettings: GlobalCompletionSettings(
                copyFinishedTextToClipboard: false,
                autoSubmitDetectedTextFields: true
            ),
            rules: []
        )

        XCTAssertEqual(request.optimizationMode, .legacyOnly)
        XCTAssertEqual(request.sendSettlementDelayNanoseconds, 80_000_000)
    }

    func testCapabilityKeyRequiresEveryEnvironmentField() {
        let values = ["com.example.Editor", "1.2", "45", "AXTextArea", "AXStandard", "composer"]

        for index in values.indices {
            var candidate = values
            candidate[index] = "  "
            XCTAssertNil(makeKey(candidate), "Field at index \(index) must not be empty")
        }
    }

    func testCapabilityKeyDecoderRejectsEmptyIdentifier() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "bundleIdentifier": "com.example.Editor",
            "appMarketingVersion": "1.2",
            "appBuildVersion": "45",
            "role": "AXTextArea",
            "subrole": "AXStandard",
            "accessibilityIdentifier": ""
        ])

        XCTAssertThrowsError(try JSONDecoder().decode(DeliveryCapabilityKey.self, from: data))
    }

    func testQualifiedRecordAndStoreRoundTripExactly() throws {
        let record = makeRecord()
        let store = TechnicalDeliveryCapabilityStore(records: [record])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(store)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(TechnicalDeliveryCapabilityStore.self, from: encoded)

        XCTAssertEqual(decoded, store)
        XCTAssertEqual(
            decoded.decision(for: makeEnvironment(), mode: .qualifiedCapabilities),
            .useQualified(.acknowledgedClipboardPaste)
        )
    }

    func testStoreDecoderRejectsDuplicateKeys() throws {
        let record = makeRecord()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode([record, record])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(try decoder.decode(TechnicalDeliveryCapabilityStore.self, from: encoded))
    }

    func testLegacyModeNeverUsesQualifiedRecord() {
        XCTAssertEqual(
            decide(record: makeRecord(), mode: .legacyOnly),
            .useLegacy(.optimizationDisabled)
        )
    }

    func testMissingCapabilityUsesLegacy() {
        XCTAssertEqual(
            decide(record: nil),
            .useLegacy(.capabilityMissing)
        )
    }

    func testEveryCapabilityKeyMismatchUsesLegacy() {
        let mismatches: [(DeliveryCapabilityKey, DeliveryQualificationFailure)] = [
            (key(bundleIdentifier: "com.example.Other"), .bundleIdentifierMismatch),
            (key(appMarketingVersion: "2.0"), .appMarketingVersionMismatch),
            (key(appBuildVersion: "46"), .appBuildVersionMismatch),
            (key(role: "AXTextField"), .roleMismatch),
            (key(subrole: "AXSearchField"), .subroleMismatch),
            (key(accessibilityIdentifier: "other-composer"), .accessibilityIdentifierMismatch)
        ]

        for (candidate, failure) in mismatches {
            XCTAssertEqual(
                decide(record: makeRecord(key: candidate)),
                .useLegacy(failure)
            )
        }
    }

    func testSchemaImplementationAndMacOSBuildMustMatchExactly() {
        XCTAssertEqual(
            decide(record: makeRecord(schemaVersion: 2)),
            .useLegacy(.schemaMismatch)
        )
        XCTAssertEqual(
            decide(record: makeRecord(implementationVersion: "delivery-v2")),
            .useLegacy(.implementationMismatch)
        )
        XCTAssertEqual(
            decide(record: makeRecord(macOSBuild: "24B99")),
            .useLegacy(.macOSBuildMismatch)
        )
    }

    func testQualificationRequiresSupportedFastStrategy() {
        XCTAssertEqual(
            decide(record: makeRecord(strategy: .legacyClipboardPaste)),
            .useLegacy(.unsupportedStrategy)
        )
    }

    func testQualificationRequiresExactIntendedStrategy() {
        XCTAssertEqual(
            decide(record: makeRecord(strategy: .directAccessibilityInsertion)),
            .useLegacy(.strategyMismatch)
        )
    }

    func testQualificationRequiresThreeHundredTwentyErrorFreeOperations() {
        XCTAssertEqual(
            decide(record: makeRecord(operationCount: 319)),
            .useLegacy(.insufficientOperations)
        )
        XCTAssertEqual(
            decide(record: makeRecord(errorCount: 1)),
            .useLegacy(.observedErrors)
        )
    }

    func testQualificationRequiresAtLeastTwentyFivePercentMedianImprovement() {
        XCTAssertEqual(
            decide(record: makeRecord(p50Nanoseconds: 751, p95Nanoseconds: 850, p99Nanoseconds: 900)),
            .useLegacy(.insufficientMedianImprovement)
        )
        XCTAssertEqual(
            decide(record: makeRecord(p50Nanoseconds: 750, p95Nanoseconds: 850, p99Nanoseconds: 900)),
            .useQualified(.acknowledgedClipboardPaste)
        )
    }

    func testStoreDoesNotUseNearMatch() {
        let store = TechnicalDeliveryCapabilityStore(
            records: [makeRecord(key: key(appBuildVersion: "44"))]
        )

        XCTAssertEqual(
            store.decision(for: makeEnvironment(), mode: .qualifiedCapabilities),
            .useLegacy(.capabilityMissing)
        )
    }

    func testUTF16ReplacementHandlesEmojiAndSetsCaret() throws {
        let text = "A👩🏽‍💻B"
        let range = (text as NSString).range(of: "👩🏽‍💻")

        let result = try UTF16TextReplacement.replacing(
            UTF16TextSelection(location: range.location, length: range.length),
            in: text,
            with: "🚀"
        )

        XCTAssertEqual(result.text, "A🚀B")
        XCTAssertEqual(result.caret, UTF16TextSelection(location: 3, length: 0))
    }

    func testUTF16ReplacementHandlesComposedCharacters() throws {
        let text = "Cafe\u{301}"
        let range = (text as NSString).range(of: "e\u{301}")

        let result = try UTF16TextReplacement.replacing(
            UTF16TextSelection(location: range.location, length: range.length),
            in: text,
            with: "é"
        )

        XCTAssertEqual(result.text, "Café")
        XCTAssertEqual(result.caret, UTF16TextSelection(location: 4, length: 0))
    }

    func testUTF16ReplacementHandlesCJK() throws {
        let text = "你好世界"
        let range = (text as NSString).range(of: "好世")

        let result = try UTF16TextReplacement.replacing(
            UTF16TextSelection(location: range.location, length: range.length),
            in: text,
            with: "新"
        )

        XCTAssertEqual(result.text, "你新界")
        XCTAssertEqual(result.caret, UTF16TextSelection(location: 2, length: 0))
    }

    func testUTF16ReplacementHandlesMultilineText() throws {
        let text = "one\ntwo\nthree"
        let range = (text as NSString).range(of: "two\n")

        let result = try UTF16TextReplacement.replacing(
            UTF16TextSelection(location: range.location, length: range.length),
            in: text,
            with: "2\nlines\n"
        )

        XCTAssertEqual(result.text, "one\n2\nlines\nthree")
        XCTAssertEqual(result.caret.location, ("one\n2\nlines\n" as NSString).length)
    }

    func testUTF16ReplacementRejectsRangeInsideSurrogatePair() {
        XCTAssertThrowsError(
            try UTF16TextReplacement.replacing(
                UTF16TextSelection(location: 1, length: 1),
                in: "🚀",
                with: "X"
            )
        ) { error in
            XCTAssertEqual(error as? UTF16ReplacementError, .invalidRange)
        }
    }

    private func decide(
        record: DeliveryCapabilityRecord?,
        mode: DeliveryOptimizationMode = .qualifiedCapabilities
    ) -> DeliveryQualificationDecision {
        DeliveryCapabilityQualifier.decide(
            record: record,
            environment: makeEnvironment(),
            mode: mode
        )
    }

    private func makeEnvironment() -> DeliveryCapabilityEnvironment {
        DeliveryCapabilityEnvironment(
            key: key(),
            intendedStrategy: .acknowledgedClipboardPaste,
            schemaVersion: 1,
            implementationVersion: "delivery-v1",
            macOSBuild: "24A335"
        )
    }

    private func makeRecord(
        key: DeliveryCapabilityKey? = nil,
        strategy: DeliveryStrategy = .acknowledgedClipboardPaste,
        schemaVersion: Int = 1,
        implementationVersion: String = "delivery-v1",
        macOSBuild: String = "24A335",
        operationCount: UInt64 = 320,
        errorCount: UInt64 = 0,
        p50Nanoseconds: UInt64 = 700,
        p95Nanoseconds: UInt64 = 850,
        p99Nanoseconds: UInt64 = 900
    ) -> DeliveryCapabilityRecord {
        DeliveryCapabilityRecord(
            key: key ?? self.key(),
            strategy: strategy,
            schemaVersion: schemaVersion,
            implementationVersion: implementationVersion,
            macOSBuild: macOSBuild,
            operationCount: operationCount,
            errorCount: errorCount,
            legacyP50Nanoseconds: 1_000,
            p50Nanoseconds: p50Nanoseconds,
            p95Nanoseconds: p95Nanoseconds,
            p99Nanoseconds: p99Nanoseconds,
            qualifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )!
    }

    private func key(
        bundleIdentifier: String = "com.example.Editor",
        appMarketingVersion: String = "1.2",
        appBuildVersion: String = "45",
        role: String = "AXTextArea",
        subrole: String = "AXStandard",
        accessibilityIdentifier: String = "composer"
    ) -> DeliveryCapabilityKey {
        DeliveryCapabilityKey(
            bundleIdentifier: bundleIdentifier,
            appMarketingVersion: appMarketingVersion,
            appBuildVersion: appBuildVersion,
            role: role,
            subrole: subrole,
            accessibilityIdentifier: accessibilityIdentifier
        )!
    }

    private func makeKey(_ values: [String]) -> DeliveryCapabilityKey? {
        DeliveryCapabilityKey(
            bundleIdentifier: values[0],
            appMarketingVersion: values[1],
            appBuildVersion: values[2],
            role: values[3],
            subrole: values[4],
            accessibilityIdentifier: values[5]
        )
    }
}
