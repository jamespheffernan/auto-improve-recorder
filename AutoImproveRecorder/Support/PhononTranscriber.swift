import Darwin
import Foundation

/// Each app owns one worker. A serial queue keeps Core ML inference off the main
/// thread and prevents requests from consuming each other's responses.
final class PhononTranscriber: @unchecked Sendable {
    static let shared = PhononTranscriber()
    static let modelID = "FluidInference/phonon-2-coreml"
    static var runtimeURL: URL {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("PhononCoreML"),
           isInstalled(at: bundled) {
            return bundled
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoImproveRecorder/PhononCoreML")
    }
    static var isInstalled: Bool {
        guard #available(macOS 15, *) else { return false }
        return isInstalled(at: runtimeURL)
    }

    static func isInstalled(at root: URL) -> Bool {
        let fm = FileManager.default
        let components = ["Preprocessor", "Encoder", "Decoder", "JointDecisionv3"]
        let required = ["complete.json", "models/parakeet_vocab.json"] + components.flatMap {
            ["models/\($0).mlmodelc/coremldata.bin", "models/\($0).mlmodelc/model.mil",
             "models/\($0).mlmodelc/weights/weight.bin"]
        }
        return fm.isExecutableFile(atPath: root.appendingPathComponent("bin/phonon-coreml").path)
            && required.allSatisfy {
                fm.fileExists(atPath: root.appendingPathComponent($0).path)
            }
    }

    private let root: URL
    private let timeout: TimeInterval
    private let startupTimeout: TimeInterval
    private let queue = DispatchQueue(label: "com.turfterrace.phonon2", qos: .userInitiated)
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var pendingOutput = Data()

    init(root: URL = PhononTranscriber.runtimeURL, timeout: TimeInterval = 180,
         startupTimeout: TimeInterval = 600) {
        self.root = root
        self.timeout = timeout
        self.startupTimeout = startupTimeout
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
        guard #available(macOS 15, *) else {
            throw failure("Phonon-2 Neural Engine needs macOS 15 or newer. Choose Parakeet in Settings.")
        }
        guard Self.isInstalled(at: root) else {
            throw failure("Phonon-2 Neural Engine is not installed or its drive is unavailable. Reinstall this build or choose Parakeet in Settings.")
        }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = root.appendingPathComponent("bin/phonon-coreml")
        child.arguments = [root.path]
        child.standardInput = stdin
        child.standardOutput = stdout
        // Stderr is inherited, so dependency diagnostics cannot fill an unread pipe.
        child.standardError = FileHandle.standardError
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output = stdout.fileHandleForReading
        // First load compiles the sparse encoder for this Mac; later loads use Core ML's cache.
        let response = try readResponse(cancellation: cancellation, timeout: startupTimeout)
        if let message = response["error"] as? String { throw failure(message) }
        guard response["ready"] as? Bool == true, response["model"] as? String == Self.modelID else {
            throw failure("Phonon-2 could not load. The recording was kept.")
        }
        NSLog("Phonon-2 Core ML / Neural Engine worker ready (pid %d).", child.processIdentifier)
    }

    private func readResponse(cancellation: PhononCancellation, timeout: TimeInterval? = nil) throws -> [String: Any] {
        guard let output else { throw failure("Phonon-2 worker is unavailable.") }
        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
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
