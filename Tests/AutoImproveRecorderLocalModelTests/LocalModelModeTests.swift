import XCTest
@testable import AutoImproveRecorderDictionaryCore

final class LocalModelModeTests: XCTestCase {
    func testPresetActionMappings() {
        XCTAssertEqual(LocalModelPreset.recommended.transcriptionModeRawValue, "localParakeetStreaming")
        XCTAssertNil(LocalModelPreset.recommended.improvementModeRawValue)

        XCTAssertEqual(LocalModelPreset.resident.transcriptionModeRawValue, "localParakeetCppResident")
        XCTAssertNil(LocalModelPreset.resident.improvementModeRawValue)

        XCTAssertEqual(LocalModelPreset.fast.transcriptionModeRawValue, "localParakeetCppFast")
        XCTAssertNil(LocalModelPreset.fast.improvementModeRawValue)

        XCTAssertEqual(LocalModelPreset.allLocal.transcriptionModeRawValue, "localParakeetStreaming")
        XCTAssertEqual(LocalModelPreset.allLocal.improvementModeRawValue, "ollamaLocal")
        XCTAssertEqual(LocalModelPreset.allLocal.ollamaModel, "qwen3.5:0.8b-mlx")

        XCTAssertEqual(LocalModelPreset.appleSpeech.transcriptionModeRawValue, "appleLocal")
        XCTAssertNil(LocalModelPreset.appleSpeech.improvementModeRawValue)

        XCTAssertEqual(LocalModelPreset.cloudRealtime.transcriptionModeRawValue, "fastest")
        XCTAssertNil(LocalModelPreset.cloudRealtime.improvementModeRawValue)
    }

    func testInventoryInputRoundTrip() throws {
        let input = LocalModelInventoryInput(
            parakeetCppBasePath: "/air",
            ollamaBaseURL: "http://127.0.0.1:11434",
            ollamaModel: "qwen3.5:0.8b-mlx",
            hasOpenAIAPIKey: true
        )

        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(LocalModelInventoryInput.self, from: data)

        XCTAssertEqual(decoded, input)
    }

    func testParakeetLiveMemoryGateRequiresSixteenGiB() {
        XCTAssertFalse(ParakeetLiveSafetyPolicy.passesMemoryGate(physicalMemoryBytes: 8 * 1_024 * 1_024 * 1_024))
        XCTAssertTrue(ParakeetLiveSafetyPolicy.passesMemoryGate(physicalMemoryBytes: 16 * 1_024 * 1_024 * 1_024))
    }

    func testParakeetLiveDefaultRequiresMemoryRuntimeAndFallback() {
        let enoughMemory: UInt64 = 24 * 1_024 * 1_024 * 1_024
        XCTAssertTrue(ParakeetLiveSafetyPolicy.shouldSelectByDefault(
            physicalMemoryBytes: enoughMemory,
            liveRuntimeInstalled: true,
            offlineFallbackInstalled: true
        ))
        XCTAssertFalse(ParakeetLiveSafetyPolicy.shouldSelectByDefault(
            physicalMemoryBytes: enoughMemory,
            liveRuntimeInstalled: false,
            offlineFallbackInstalled: true
        ))
        XCTAssertFalse(ParakeetLiveSafetyPolicy.shouldSelectByDefault(
            physicalMemoryBytes: enoughMemory,
            liveRuntimeInstalled: true,
            offlineFallbackInstalled: false
        ))
    }

    func testLiveWarmupDoesNotLoadOneShotFallback() {
        XCTAssertEqual(
            ParakeetWarmupPolicy.targets(transcriptionModeRawValue: "localParakeetStreaming"),
            [.liveRecommended]
        )
    }

    func testExplicitAndFallbackModesKeepTheirSingleWarmupTarget() {
        XCTAssertEqual(
            ParakeetWarmupPolicy.targets(transcriptionModeRawValue: "localParakeetCppRecommended"),
            [.recommendedOneShot]
        )
        XCTAssertEqual(
            ParakeetWarmupPolicy.targets(transcriptionModeRawValue: "fastest"),
            [.recommendedOneShot]
        )
        XCTAssertEqual(
            ParakeetWarmupPolicy.targets(transcriptionModeRawValue: "localParakeetCppResident"),
            [.residentRecommended]
        )
        XCTAssertEqual(
            ParakeetWarmupPolicy.targets(transcriptionModeRawValue: "localParakeetCppFast"),
            [.fastOneShot]
        )
    }

    func testParakeetLiveInputAdmissionBoundsQueuedAudio() {
        let admission = ParakeetLiveInputAdmission(maximumQueuedBytes: 100)

        XCTAssertTrue(admission.reserve(byteCount: 60))
        XCTAssertFalse(admission.reserve(byteCount: 41))
        XCTAssertFalse(admission.shouldProcessQueuedInput)
        XCTAssertNotNil(admission.failureMessage)
        XCTAssertEqual(admission.queuedByteCount, 60)
        admission.complete(byteCount: 60)
        XCTAssertEqual(admission.queuedByteCount, 0)
        XCTAssertFalse(admission.reserve(byteCount: 1))
    }

    func testParakeetLiveInputAdmissionCancelsSynchronously() {
        let admission = ParakeetLiveInputAdmission(maximumQueuedBytes: 100)
        XCTAssertTrue(admission.reserve(byteCount: 60))

        admission.cancel()

        XCTAssertFalse(admission.shouldProcessQueuedInput)
        XCTAssertNil(admission.failureMessage)
        XCTAssertFalse(admission.reserve(byteCount: 1))
    }

    func testParakeetLiveFinalizeClosesNewInputButDrainsAcceptedInput() {
        let admission = ParakeetLiveInputAdmission(maximumQueuedBytes: 100)
        XCTAssertTrue(admission.reserve(byteCount: 60))

        admission.closeForFinalize()

        XCTAssertTrue(admission.shouldProcessQueuedInput)
        XCTAssertFalse(admission.reserve(byteCount: 1))
    }
}
