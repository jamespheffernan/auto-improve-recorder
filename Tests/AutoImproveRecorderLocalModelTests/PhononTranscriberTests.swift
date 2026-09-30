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
            echo '{"model":"FermionResearch/Phonon-2","text":"Hello, James.","truncated":false}'
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

    private func fakeRuntime(body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhononTests-\(UUID().uuidString)")
        let fm = FileManager.default
        let model = root.appendingPathComponent("models/speech/FermionResearch__Phonon-2/model_phonon2_c4c_int6")
        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("runtime/bin"), withIntermediateDirectories: true)
        for file in ["complete.json", "worker.py", "recording.wav"] {
            try Data().write(to: root.appendingPathComponent(file))
        }
        try Data().write(to: model.appendingPathComponent("model.fermion"))
        let script = """
        #!/bin/sh
        root=$(dirname "$2")
        printf 'start\\n' >> "$root/starts"
        echo '{"ready":true,"model":"FermionResearch/Phonon-2"}'
        \(body)

        """
        let executable = root.appendingPathComponent("runtime/bin/python")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return root
    }
}
