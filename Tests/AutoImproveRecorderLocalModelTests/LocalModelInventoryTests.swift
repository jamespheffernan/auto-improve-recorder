import Foundation
import XCTest
@testable import AutoImproveRecorderCore

final class LocalModelInventoryTests: XCTestCase {
    func testMissingParakeetCppTreeReportsRuntimeMissing() async {
        let statuses = await statuses(files: [], executables: [], dylibs: [])

        XCTAssertEqual(statuses[.parakeetCppRecommended]?.state, .needsRuntime)
        XCTAssertEqual(statuses[.parakeetCppResident]?.state, .needsRuntime)
        XCTAssertEqual(statuses[.parakeetCppFast]?.state, .needsRuntime)
    }

    func testCliPresentButRecommendedModelMissingReportsNeedsModel() async {
        let statuses = await statuses(
            files: ["/air/bin/parakeet-cli", "/air/models/\(LocalModelInventory.fastModelFilename)"],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib"]
        )

        XCTAssertEqual(statuses[.parakeetCppRecommended]?.state, .needsModel)
        XCTAssertEqual(statuses[.parakeetCppFast]?.state, .installed)
    }

    func testCliPresentButFastModelMissingReportsNeedsModel() async {
        let statuses = await statuses(
            files: ["/air/bin/parakeet-cli", "/air/models/\(LocalModelInventory.recommendedModelFilename)"],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib"]
        )

        XCTAssertEqual(statuses[.parakeetCppRecommended]?.state, .installed)
        XCTAssertEqual(statuses[.parakeetCppFast]?.state, .needsModel)
    }

    func testFullParakeetCppInstallReportsInstalled() async {
        let statuses = await statuses(
            files: [
                "/air/bin/parakeet-cli",
                "/air/models/\(LocalModelInventory.recommendedModelFilename)",
                "/air/models/\(LocalModelInventory.fastModelFilename)"
            ],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib"]
        )

        XCTAssertEqual(statuses[.parakeetCppRecommended]?.state, .installed)
        XCTAssertEqual(statuses[.parakeetCppResident]?.state, .needsRuntime)
        XCTAssertEqual(statuses[.parakeetCppFast]?.state, .installed)
    }

    func testFullLiveRecommendationReportsReady() async {
        let statuses = await statuses(
            files: [
                "/air/bin/parakeet-cli",
                "/air/capi/libparakeet.dylib",
                "/air/models/\(LocalModelInventory.recommendedModelFilename)",
                "/air/models/\(LocalModelInventory.liveRecommendedModelFilename)"
            ],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib", "/air/capi/libggml.dylib"]
        )

        XCTAssertEqual(statuses[.parakeetCppRecommended]?.state, .ready)
        XCTAssertTrue(statuses[.parakeetCppRecommended]?.descriptor.capabilities.supportsRealtime == true)
    }

    func testMissingLiveModelKeepsOneShotRecommendationUsable() async {
        let statuses = await statuses(
            files: [
                "/air/bin/parakeet-cli",
                "/air/capi/libparakeet.dylib",
                "/air/models/\(LocalModelInventory.recommendedModelFilename)"
            ],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib", "/air/capi/libggml.dylib"]
        )

        XCTAssertEqual(statuses[.parakeetCppRecommended]?.state, .installed)
        XCTAssertTrue(statuses[.parakeetCppRecommended]?.detail.contains("One-shot") == true)
    }

    func testMissingLiveSymbolsKeepsOneShotRecommendationUsable() async {
        let status = await fullLiveRecommendationStatus(runtimeCapability: .missingSymbols)

        XCTAssertEqual(status?.state, .installed)
        XCTAssertTrue(status?.detail.contains("incompatible") == true)
    }

    func testUnloadableLiveRuntimeKeepsOneShotRecommendationUsable() async {
        let status = await fullLiveRecommendationStatus(runtimeCapability: .loadFailed)

        XCTAssertEqual(status?.state, .installed)
        XCTAssertTrue(status?.detail.contains("could not load") == true)
    }

    func testLiveRecommendationNeedsSixteenGiB() async {
        let statuses = await statuses(
            files: [
                "/air/bin/parakeet-cli",
                "/air/capi/libparakeet.dylib",
                "/air/models/\(LocalModelInventory.recommendedModelFilename)",
                "/air/models/\(LocalModelInventory.liveRecommendedModelFilename)"
            ],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib", "/air/capi/libggml.dylib"],
            physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024
        )

        XCTAssertEqual(statuses[.parakeetCppRecommended]?.state, .installed)
        XCTAssertTrue(statuses[.parakeetCppRecommended]?.detail.contains("One-shot") == true)
    }

    func testResidentRuntimeReportsInstalledOnlyWhenCAPIIsPresent() async {
        let statuses = await statuses(
            files: [
                "/air/capi/libparakeet.dylib",
                "/air/models/\(LocalModelInventory.recommendedModelFilename)"
            ],
            dylibs: ["/air/capi/libggml.dylib"]
        )

        XCTAssertEqual(statuses[.parakeetCppResident]?.state, .installed)
    }

    func testOllamaReachableWithQwenReportsReady() async {
        let statuses = await statuses(
            files: [
                "/air/bin/parakeet-cli",
                "/air/capi/libparakeet.dylib",
                "/air/models/\(LocalModelInventory.recommendedModelFilename)",
                "/air/models/\(LocalModelInventory.liveRecommendedModelFilename)"
            ],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib", "/air/capi/libggml.dylib"],
            ollamaTags: [LocalModelInventory.qwenOllamaModel]
        )

        XCTAssertEqual(statuses[.ollamaQwen35]?.state, .ready)
        XCTAssertEqual(statuses[.allLocal]?.state, .ready)
    }

    func testOllamaReachableWithoutQwenReportsNeedsModel() async {
        let statuses = await statuses(
            files: [
                "/air/bin/parakeet-cli",
                "/air/capi/libparakeet.dylib",
                "/air/models/\(LocalModelInventory.recommendedModelFilename)",
                "/air/models/\(LocalModelInventory.liveRecommendedModelFilename)"
            ],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib", "/air/capi/libggml.dylib"],
            ollamaTags: ["llama3.2"]
        )

        XCTAssertEqual(statuses[.ollamaQwen35]?.state, .needsModel)
        XCTAssertEqual(statuses[.allLocal]?.state, .needsModel)
    }

    func testAppleSpeechUnavailableState() async {
        let statuses = await statuses(osVersion: OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0))

        XCTAssertEqual(statuses[.appleSpeech]?.state, .unavailable)
        XCTAssertTrue(statuses[.appleSpeech]?.detail.contains("macOS 26") == true)
    }

    func testCloudRealtimeCopyForFastestMode() async {
        let statuses = await statuses(hasOpenAIAPIKey: false)

        XCTAssertEqual(statuses[.cloudRealtime]?.descriptor.title, "Cloud Realtime")
        XCTAssertEqual(LocalModelPreset.cloudRealtime.transcriptionModeRawValue, "fastest")
        XCTAssertTrue(statuses[.cloudRealtime]?.detail.contains("streams microphone audio to OpenAI") == true)
    }

    private func statuses(
        files: Set<String> = [],
        executables: Set<String> = [],
        dylibs: [String] = [],
        ollamaTags: [String] = [],
        ollamaError: Error? = nil,
        hasOpenAIAPIKey: Bool = false,
        osVersion: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0),
        physicalMemoryBytes: UInt64 = 24 * 1_024 * 1_024 * 1_024,
        runtimeCapability: ParakeetLiveRuntimeCapability = .ready
    ) async -> [LocalModelID: LocalModelStatus] {
        let probe = FakeLocalRuntimeProbe(
            files: files,
            executables: executables,
            dylibs: dylibs,
            ollamaTags: ollamaTags,
            ollamaError: ollamaError,
            osVersion: osVersion,
            physicalMemory: physicalMemoryBytes,
            runtimeCapability: runtimeCapability
        )
        let inventory = LocalModelInventory(
            probe: probe,
            now: { Date(timeIntervalSince1970: 1_780_606_800) }
        )
        let input = LocalModelInventoryInput(
            parakeetCppBasePath: "/air",
            ollamaBaseURL: "http://127.0.0.1:11434",
            ollamaModel: LocalModelInventory.qwenOllamaModel,
            hasOpenAIAPIKey: hasOpenAIAPIKey
        )

        return await Dictionary(uniqueKeysWithValues: inventory.statuses(input: input).map { ($0.id, $0) })
    }

    private func fullLiveRecommendationStatus(
        runtimeCapability: ParakeetLiveRuntimeCapability
    ) async -> LocalModelStatus? {
        let statuses = await statuses(
            files: [
                "/air/bin/parakeet-cli",
                "/air/capi/libparakeet.dylib",
                "/air/models/\(LocalModelInventory.recommendedModelFilename)",
                "/air/models/\(LocalModelInventory.liveRecommendedModelFilename)"
            ],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib", "/air/capi/libggml.dylib"],
            runtimeCapability: runtimeCapability
        )
        return statuses[.parakeetCppRecommended]
    }
}

private struct FakeLocalRuntimeProbe: LocalRuntimeProbe {
    var files: Set<String>
    var executables: Set<String>
    var dylibs: [String]
    var ollamaTags: [String]
    var ollamaError: Error?
    var osVersion: OperatingSystemVersion
    var physicalMemory: UInt64
    var runtimeCapability: ParakeetLiveRuntimeCapability

    func fileExists(atPath path: String) -> Bool {
        files.contains(path)
    }

    func isExecutableFile(atPath path: String) -> Bool {
        executables.contains(path)
    }

    func paths(matching pattern: String) -> [String] {
        switch pattern {
        case "/air/lib/libggml*.dylib":
            return dylibs.filter { $0.hasPrefix("/air/lib/") }
        case "/air/capi/libggml*.dylib":
            return dylibs.filter { $0.hasPrefix("/air/capi/") }
        default:
            return []
        }
    }

    func ollamaModelTags(baseURL: URL) async throws -> [String] {
        if let ollamaError {
            throw ollamaError
        }
        return ollamaTags
    }

    func operatingSystemVersion() -> OperatingSystemVersion {
        osVersion
    }

    func physicalMemoryBytes() -> UInt64 {
        physicalMemory
    }

    func parakeetLiveRuntimeCapability(libraryPath: String) -> ParakeetLiveRuntimeCapability {
        runtimeCapability
    }
}
