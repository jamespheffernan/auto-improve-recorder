import XCTest
@testable import AutoImproveRecorderCore

/// The one-shot CLI runner against a temporary install root. The CLI is a
/// shell script written by the test; no model is loaded.
final class LocalTranscriptionProcessTests: XCTestCase {
    private var root: URL!
    private var audioURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("one-shot-process-\(UUID().uuidString)")
        for folder in ["bin", "models", "lib"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder),
                withIntermediateDirectories: true
            )
        }
        audioURL = root.appendingPathComponent("recording.wav")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testErrorMessagesAreTheOnesTheUserSees() {
        let expected: [(ParakeetRunnerError, String)] = [
            (.audioMissing("/a.wav"), "Recording file not found at /a.wav."),
            (.runtimeMissing("/r/bin/parakeet-cli"), "Parakeet runtime not found at /r/bin/parakeet-cli."),
            (.modelMissing("/r/models/m.gguf"), "Parakeet model not found at /r/models/m.gguf."),
            (.timedOut, "Parakeet transcription timed out. The recording was kept."),
            (.processFailed(""), "Parakeet transcription failed. The recording was kept."),
            (.processFailed("bad model"), "Parakeet transcription failed: bad model"),
            (.invalidOutput, "Parakeet returned invalid output. The recording was kept."),
            (.emptyTranscript, "Parakeet did not detect speech. The recording was kept.")
        ]
        for (error, message) in expected {
            XCTAssertEqual(error.localizedDescription, message)
        }
    }

    func testOutputParsingTrimsTheTextFieldAndRejectsOtherOutput() throws {
        XCTAssertEqual(
            try ParakeetOneShotProcess.transcript(fromOutput: Data(#"{"text": "  hello there \n"}"#.utf8)),
            "hello there"
        )
        for output in ["", "hello", #"{"words": []}"#, #"{"text": 3}"#] {
            XCTAssertThrowsError(try ParakeetOneShotProcess.transcript(fromOutput: Data(output.utf8))) {
                XCTAssertEqual(
                    $0.localizedDescription,
                    "Parakeet returned invalid output. The recording was kept."
                )
            }
        }
        XCTAssertThrowsError(try ParakeetOneShotProcess.transcript(fromOutput: Data(#"{"text": " \n"}"#.utf8))) {
            XCTAssertEqual($0.localizedDescription, "Parakeet did not detect speech. The recording was kept.")
        }
    }

    func testMissingAudioThenRuntimeThenModelIsReportedWithItsPath() async throws {
        let process = ParakeetOneShotProcess(configuration: configuration)
        let cli = root.appendingPathComponent("bin/parakeet-cli")
        let model = root.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf")

        await assertFailure(of: process, "Recording file not found at \(audioURL.path).")
        try Data().write(to: audioURL)
        await assertFailure(of: process, "Parakeet runtime not found at \(cli.path).")
        try writeCLI("exit 0")
        await assertFailure(of: process, "Parakeet model not found at \(model.path).")
    }

    func testRunsTheCLIInTheInstallRootWithTheModelAndTheRecording() async throws {
        try Data().write(to: audioURL)
        try Data().write(to: root.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf"))
        try writeCLI("""
        if [ -f models/tdt-0.6b-v2-q4_k.gguf ]; then where=in-root; else where=elsewhere; fi
        printf '{"text": "  %s|%s  "}' "$where" "$*"
        """)

        let text = try await ParakeetOneShotProcess(configuration: configuration)
            .transcribe(audioURL: audioURL)

        let model = root.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf").path
        XCTAssertEqual(text, "in-root|transcribe --model \(model) --input \(audioURL.path) --json")
    }

    func testANonZeroExitReportsTrimmedStandardError() async throws {
        try Data().write(to: audioURL)
        try Data().write(to: root.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf"))
        let process = ParakeetOneShotProcess(configuration: configuration)

        try writeCLI("echo '  model exploded  ' >&2\nexit 3")
        await assertFailure(of: process, "Parakeet transcription failed: model exploded")
        try writeCLI("exit 3")
        await assertFailure(of: process, "Parakeet transcription failed. The recording was kept.")
    }

    func testOutputWithOkFalseIsAFailureWithTheReportedError() async throws {
        XCTAssertThrowsError(try ParakeetOneShotProcess.transcript(
            fromOutput: Data(#"{"ok": false, "error": "model file is corrupt", "text": "partial"}"#.utf8)
        )) {
            XCTAssertEqual($0.localizedDescription, "Parakeet transcription failed: model file is corrupt")
        }
        XCTAssertThrowsError(try ParakeetOneShotProcess.transcript(fromOutput: Data(#"{"ok": false}"#.utf8))) {
            XCTAssertEqual($0.localizedDescription, "Parakeet transcription failed: Unknown parakeet.cpp error.")
        }
        XCTAssertEqual(
            try ParakeetOneShotProcess.transcript(fromOutput: Data(#"{"ok": true, "text": "fine"}"#.utf8)),
            "fine"
        )

        // The same through a CLI run that exits with status 0.
        try Data().write(to: audioURL)
        try Data().write(to: root.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf"))
        try writeCLI(#"echo '{"ok": false, "error": "model file is corrupt", "text": "partial"}'"#)
        await assertFailure(
            of: ParakeetOneShotProcess(configuration: configuration),
            "Parakeet transcription failed: model file is corrupt"
        )
    }

    func testARunThatIgnoresSIGTERMPastItsDeadlineIsKilled() async throws {
        try Data().write(to: audioURL)
        try Data().write(to: root.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf"))
        // The CLI writes its process ID into the install root, ignores SIGTERM and never exits.
        try writeCLI("trap '' TERM\necho $$ > pid\nwhile :; do :; done")
        let process = ParakeetOneShotProcess(configuration: configuration, timeout: 1, terminationGrace: 0.2)

        await assertFailure(of: process, "Parakeet transcription timed out. The recording was kept.")

        let recorded = try String(contentsOf: root.appendingPathComponent("pid"))
        let pid = try XCTUnwrap(Int32(recorded.trimmingCharacters(in: .whitespacesAndNewlines)))
        // Signal 0 sends nothing and reports whether the process exists.
        let result = Darwin.kill(pid, 0)
        let code = errno
        if result == 0 {
            Darwin.kill(pid, SIGKILL)
        }
        XCTAssertEqual(result, -1, "the CLI process is still running")
        XCTAssertEqual(code, ESRCH)
    }

    func testRuntimeIsInstalledNeedsTheCLITheModelAndAGgmlLibrary() throws {
        let process = ParakeetOneShotProcess(configuration: configuration)
        XCTAssertFalse(process.runtimeIsInstalled)
        try writeCLI("exit 0")
        XCTAssertFalse(process.runtimeIsInstalled)
        try Data().write(to: root.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf"))
        XCTAssertFalse(process.runtimeIsInstalled)
        try Data().write(to: root.appendingPathComponent("lib/libparakeet.dylib"))
        XCTAssertFalse(process.runtimeIsInstalled)
        try Data().write(to: root.appendingPathComponent("lib/libggml-base.dylib"))
        XCTAssertTrue(process.runtimeIsInstalled)
    }

    private var configuration: ParakeetRuntimeConfiguration {
        let root = root!
        return ParakeetRuntimeConfiguration { root }
    }

    func testACLIThatCannotBeLaunchedReportsTheLaunchErrorAndLeavesNoPipeReaderBlocked() async throws {
        try Data().write(to: audioURL)
        try Data().write(to: root.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf"))
        // A directory passes the executable check and cannot be launched.
        let cliURL = root.appendingPathComponent("bin/parakeet-cli")
        try FileManager.default.createDirectory(at: cliURL, withIntermediateDirectories: false)
        let process = ParakeetOneShotProcess(configuration: configuration)

        func openFileDescriptorCount() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        }
        let runs = 20
        let descriptorsBefore = try openFileDescriptorCount()
        let startedAt = Date()
        for _ in 0..<runs {
            do {
                _ = try await process.transcribe(audioURL: audioURL)
                XCTFail("transcribe should throw")
            } catch {
                XCTAssertFalse(error is ParakeetRunnerError, "expected the launch error, got \(error)")
                XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
                XCTAssertEqual((error as NSError).code, Int(EACCES))
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 10)

        // A reader blocked on a pipe keeps that pipe's two descriptors open. Each run has two pipes.
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThan(try openFileDescriptorCount() - descriptorsBefore, runs)
    }

    private func writeCLI(_ body: String) throws {
        let url = root.appendingPathComponent("bin/parakeet-cli")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func assertFailure(
        of process: ParakeetOneShotProcess,
        _ message: String,
        line: UInt = #line
    ) async {
        do {
            _ = try await process.transcribe(audioURL: audioURL)
            XCTFail("transcribe should throw", line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, message, line: line)
        }
    }
}
