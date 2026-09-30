import Darwin
import Foundation

/// Each app owns one worker. A serial queue keeps MLX inference off the main
/// thread and prevents requests from consuming each other's responses.
final class PhononTranscriber: @unchecked Sendable {
    static let shared = PhononTranscriber()
    static let modelID = "FermionResearch/Phonon-2"
    static var runtimeURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoImproveRecorder/Phonon2")
    }
    static var isInstalled: Bool { isInstalled(at: runtimeURL) }

    static func isInstalled(at root: URL) -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: root.appendingPathComponent("runtime/bin/python").path)
            && ["worker.py", "complete.json", "models/speech/FermionResearch__Phonon-2/model_phonon2_c4c_int6/model.fermion"].allSatisfy {
                fm.fileExists(atPath: root.appendingPathComponent($0).path)
            }
    }

    private let root: URL
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.turfterrace.phonon2", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pendingOutput = Data()

    init(root: URL = PhononTranscriber.runtimeURL, timeout: TimeInterval = 180) {
        self.root = root
        self.timeout = timeout
    }

    func warmUp() async {
        do { _ = try await perform(audioURL: nil) }
        catch { NSLog("Phonon-2 warm-up: %@", error.localizedDescription) }
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw failure("Recording file not found. The audio was not deleted.")
        }
        return try await perform(audioURL: audioURL)
    }

    func shutdown() {
        queue.async { self.stopWorker() }
    }

    private func perform(audioURL: URL?) async throws -> String {
        let cancellation = PhononCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try cancellation.check()
                        try self.startWorker(cancellation: cancellation)
                        guard let audioURL else {
                            continuation.resume(returning: "")
                            return
                        }
                        let data = try JSONSerialization.data(withJSONObject: ["audio": audioURL.path])
                        try self.input?.write(contentsOf: data + Data([10]))
                        let response = try self.readResponse(cancellation: cancellation)
                        try cancellation.check()
                        let text = try Self.transcript(from: response)
                        continuation.resume(returning: text)
                    } catch {
                        // Discard unread output before the next operation, including cancellation.
                        self.stopWorker()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func transcript(from response: [String: Any]) throws -> String {
        if let message = response["error"] as? String { throw failure(message) }
        guard response["model"] as? String == modelID,
              let text = response["text"] as? String else {
            throw failure("Phonon-2 returned invalid output. The recording was kept.")
        }
        guard response["truncated"] as? Bool == false else {
            throw failure("Phonon-2 returned an incomplete transcript. The recording was kept.")
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw failure("Phonon-2 did not detect speech. The recording was kept.")
        }
        return cleaned
    }

    private func startWorker(cancellation: PhononCancellation) throws {
        if process?.isRunning == true { return }
        stopWorker()
        guard Self.isInstalled(at: root) else {
            throw failure("Phonon-2 is not installed or its drive is unavailable. Install Phonon-2 or choose Parakeet in Settings.")
        }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = root.appendingPathComponent("runtime/bin/python")
        child.arguments = ["-u", root.appendingPathComponent("worker.py").path,
                           root.appendingPathComponent("models/speech/FermionResearch__Phonon-2/model_phonon2_c4c_int6").path]
        child.standardInput = stdin
        child.standardOutput = stdout
        // Stderr is inherited, so dependency diagnostics cannot fill an unread pipe.
        child.standardError = FileHandle.standardError
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["HF_HOME"] = root.appendingPathComponent("hf-cache").path
        environment["FERMION_CACHE_DIR"] = root.appendingPathComponent("models").path
        child.environment = environment
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output = stdout.fileHandleForReading
        let response = try readResponse(cancellation: cancellation)
        guard response["ready"] as? Bool == true, response["model"] as? String == Self.modelID else {
            throw failure("Phonon-2 could not load. The recording was kept.")
        }
        NSLog("Phonon-2 resident worker ready (pid %d).", child.processIdentifier)
    }

    private func readResponse(cancellation: PhononCancellation) throws -> [String: Any] {
        guard let output else { throw failure("Phonon-2 worker is unavailable.") }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try cancellation.check()
            if let newline = pendingOutput.firstIndex(of: 10) {
                let line = Data(pendingOutput[..<newline])
                pendingOutput.removeSubrange(...newline)
                guard let response = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw failure("Phonon-2 returned invalid output.")
                }
                return response
            }
            var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw failure("Could not read the Phonon-2 response.")
            }
            if ready > 0 {
                var bytes = [UInt8](repeating: 0, count: 65536)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                guard count > 0 else { throw failure("Phonon-2 stopped unexpectedly. The recording was kept.") }
                pendingOutput.append(contentsOf: bytes.prefix(count))
                guard pendingOutput.count <= 4 * 1024 * 1024 else {
                    throw failure("Phonon-2 returned too much output. The recording was kept.")
                }
            }
        }
        throw failure("Phonon-2 transcription timed out. The recording was kept.")
    }

    private func stopWorker() {
        try? input?.close()
        try? output?.close()
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process = nil
        input = nil
        output = nil
        pendingOutput.removeAll()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "PhononTranscriber", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private func failure(_ message: String) -> NSError { Self.failure(message) }
}

private final class PhononCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}
