import Foundation
import XCTest
@testable import AutoImproveRecorderDictionaryCore

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
                "/air/models/\(LocalModelInventory.recommendedModelFilename)"
            ],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib"],
            ollamaTags: [LocalModelInventory.qwenOllamaModel]
        )

        XCTAssertEqual(statuses[.ollamaQwen35]?.state, .ready)
        XCTAssertEqual(statuses[.allLocal]?.state, .ready)
    }

    func testOllamaReachableWithoutQwenReportsNeedsModel() async {
        let statuses = await statuses(
            files: [
                "/air/bin/parakeet-cli",
                "/air/models/\(LocalModelInventory.recommendedModelFilename)"
            ],
            executables: ["/air/bin/parakeet-cli"],
            dylibs: ["/air/lib/libggml.dylib"],
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

    func testFastestModeFallsBackToInstalledParakeetCppRecommended() {
        let fallback = FastestTranscriptionFallbackSelector.fallback(isParakeetCppRecommendedInstalled: true)

        XCTAssertEqual(fallback, .parakeetCppRecommended)
    }

    func testFastestModeStillTargetsParakeetCppRecommendedWhenRecommendedInstallIsMissing() {
        let fallback = FastestTranscriptionFallbackSelector.fallback(isParakeetCppRecommendedInstalled: false)

        XCTAssertEqual(fallback, .parakeetCppRecommended)
    }

    private func statuses(
        files: Set<String> = [],
        executables: Set<String> = [],
        dylibs: [String] = [],
        ollamaTags: [String] = [],
        ollamaError: Error? = nil,
        hasOpenAIAPIKey: Bool = false,
        osVersion: OperatingSystemVersion = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
    ) async -> [LocalModelID: LocalModelStatus] {
        let probe = FakeLocalRuntimeProbe(
            files: files,
            executables: executables,
            dylibs: dylibs,
            ollamaTags: ollamaTags,
            ollamaError: ollamaError,
            osVersion: osVersion
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
}

private struct FakeLocalRuntimeProbe: LocalRuntimeProbe {
    var files: Set<String>
    var executables: Set<String>
    var dylibs: [String]
    var ollamaTags: [String]
    var ollamaError: Error?
    var osVersion: OperatingSystemVersion

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
}
