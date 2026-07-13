import XCTest
@testable import AutoImproveRecorderDictionaryCore

final class LocalModelModeTests: XCTestCase {
    func testPresetActionMappings() {
        XCTAssertEqual(LocalModelPreset.recommended.transcriptionModeRawValue, "localParakeetCppRecommended")
        XCTAssertNil(LocalModelPreset.recommended.improvementModeRawValue)

        XCTAssertEqual(LocalModelPreset.resident.transcriptionModeRawValue, "localParakeetCppResident")
        XCTAssertNil(LocalModelPreset.resident.improvementModeRawValue)

        XCTAssertEqual(LocalModelPreset.fast.transcriptionModeRawValue, "localParakeetCppFast")
        XCTAssertNil(LocalModelPreset.fast.improvementModeRawValue)

        XCTAssertEqual(LocalModelPreset.allLocal.transcriptionModeRawValue, "localParakeetCppRecommended")
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
}
