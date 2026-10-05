import Foundation
import XCTest
@testable import AutoImproveRecorderDictionaryCore

final class PhononTranscriberTests: XCTestCase {
    func testValidResponsePreservesPunctuation() throws {
        XCTAssertEqual(try PhononTranscriber.transcript(from: [
            "model": PhononTranscriber.modelID, "text": "  Hello, James.\n", "truncated": false
        ]), "Hello, James.")
    }

    func testIncompleteEmptyWrongModelAndErrorResponsesCannotBeDelivered() {
        for response: [String: Any] in [
            ["model": PhononTranscriber.modelID, "text": "partial", "truncated": true],
            ["model": PhononTranscriber.modelID, "text": "partial"],
            ["model": PhononTranscriber.modelID, "text": " \n", "truncated": false],
            ["model": "Phonon-1", "text": "wrong model", "truncated": false],
            ["error": "decode failed"],
        ] {
            XCTAssertThrowsError(try PhononTranscriber.transcript(from: response))
        }
    }

    func testMissingRuntimeFailsWithoutRemovingRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("recording.wav")
        try Data([1, 2, 3]).write(to: audio)
        XCTAssertFalse(PhononTranscriber.isInstalled(at: root))
        do {
            _ = try await PhononTranscriber(root: root).transcribe(audioURL: audio)
            XCTFail("Expected a missing-runtime error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not installed"))
        }
        XCTAssertEqual(try Data(contentsOf: audio), Data([1, 2, 3]))
    }

    func testWorkerIsReusedAcrossRecordings() async throws {
        let root = try fakeRuntime(body: """
        while IFS= read -r request; do
            echo '{"model":"FluidInference/phonon-2-coreml","text":"Hello, James.","truncated":false}'
        done
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = PhononTranscriber(root: root, timeout: 3)
        defer { transcriber.shutdown() }
        for _ in 0..<2 {
            let text = try await transcriber.transcribe(audioURL: root.appendingPathComponent("recording.wav"))
            XCTAssertEqual(text, "Hello, James.")
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("starts")), "start\n")
    }

    func testCrashedWorkerDoesNotTerminateAppAndNextAttemptRestartsIt() async throws {
        let root = try fakeRuntime(body: "exit 1")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = PhononTranscriber(root: root, timeout: 2)
        for _ in 0..<2 {
            do {
                _ = try await transcriber.transcribe(audioURL: root.appendingPathComponent("recording.wav"))
                XCTFail("Expected worker failure")
            } catch { /* The saved audio remains retryable. */ }
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("starts")), "start\nstart\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("recording.wav").path))
    }

    func testUnresponsiveWorkerTimesOut() async throws {
        let root = try fakeRuntime(body: "while IFS= read -r request; do :; done")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await PhononTranscriber(root: root, timeout: 0.2)
                .transcribe(audioURL: root.appendingPathComponent("recording.wav"))
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    }

    func testCancellationStopsUnresponsiveWorker() async throws {
        let root = try fakeRuntime(body: "while IFS= read -r request; do :; done")
        defer { try? FileManager.default.removeItem(at: root) }
        let transcriber = PhononTranscriber(root: root, timeout: 10)
        let task = Task { try await transcriber.transcribe(audioURL: root.appendingPathComponent("recording.wav")) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMissingModelComponentCannotStartWorker() throws {
        let root = try fakeRuntime(body: "exit 1")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("models/Encoder.mlmodelc/weights/weight.bin"))
        XCTAssertFalse(PhononTranscriber.isInstalled(at: root))
    }

    func testOldMLXWorkerCannotMasqueradeAsCoreML() async throws {
        let root = try fakeRuntime(body: "exit 1")
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/phonon-coreml")
        try "#!/bin/sh\necho '{\"ready\":true,\"model\":\"FermionResearch/Phonon-2\"}'\n".write(
            to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        do {
            _ = try await PhononTranscriber(root: root, timeout: 2)
                .transcribe(audioURL: root.appendingPathComponent("recording.wav"))
            XCTFail("Expected a wrong-backend error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("could not load"))
        }
    }

    func testRealCoreMLRuntimeThroughAppBridge() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PHONON_COREML_TEST_ROOT"],
              let audioPath = environment["PHONON_COREML_TEST_AUDIO"] else {
            throw XCTSkip("Set PHONON_COREML_TEST_ROOT and PHONON_COREML_TEST_AUDIO for real-model verification")
        }
        let transcriber = PhononTranscriber(root: URL(fileURLWithPath: path))
        defer { transcriber.shutdown() }
        let audio = URL(fileURLWithPath: audioPath)
        let first = try await transcriber.transcribe(audioURL: audio)
        let second = try await transcriber.transcribe(audioURL: audio)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        if let longPath = environment["PHONON_COREML_TEST_LONG_AUDIO"] {
            let longText = try await transcriber.transcribe(audioURL: URL(fileURLWithPath: longPath))
            XCTAssertFalse(longText.isEmpty)
        }
    }

    private func fakeRuntime(body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhononTests-\(UUID().uuidString)")
        let fm = FileManager.default
        let model = root.appendingPathComponent("models")
        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        for file in ["complete.json", "recording.wav"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        try Data().write(to: model.appendingPathComponent("parakeet_vocab.json"))
        for component in ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"] {
            let directory = model.appendingPathComponent("\(component).mlmodelc")
            try fm.createDirectory(at: directory.appendingPathComponent("weights"), withIntermediateDirectories: true)
            for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                try Data().write(to: directory.appendingPathComponent(file))
            }
        }
        let script = """
        #!/bin/sh
        root="$1"
        printf 'start\\n' >> "$root/starts"
        echo '{"ready":true,"model":"FluidInference/phonon-2-coreml"}'
        \(body)

        """
        let executable = root.appendingPathComponent("bin/phonon-coreml")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return root
    }
}
