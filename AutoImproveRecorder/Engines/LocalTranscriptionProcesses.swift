import Foundation

/// One `parakeet-cli` run per saved recording, with the install root as the
/// working directory. The root is resolved again on every run.
struct ParakeetOneShotProcess: Sendable {
    static let engineName = "parakeet.cpp 0.6B v2 Q4_K"
    static let executablePath = "bin/parakeet-cli"
    static let modelPath = "models/tdt-0.6b-v2-q4_k.gguf"

    let configuration: ParakeetRuntimeConfiguration
    private let timeout: TimeInterval
    /// How long a run that passed its deadline has to exit after SIGTERM
    /// before it is sent SIGKILL.
    private let terminationGrace: TimeInterval

    init(
        configuration: ParakeetRuntimeConfiguration,
        timeout: TimeInterval = 180,
        terminationGrace: TimeInterval = 2
    ) {
        self.configuration = configuration
        self.timeout = timeout
        self.terminationGrace = terminationGrace
    }

    /// True when the CLI, its model and a ggml library are all present under
    /// the install root.
    var runtimeIsInstalled: Bool {
        let baseURL = configuration.resolveRoot()
        let cli = baseURL.appendingPathComponent(Self.executablePath).path
        let model = baseURL.appendingPathComponent(Self.modelPath).path
        return FileManager.default.isExecutableFile(atPath: cli) &&
            FileManager.default.fileExists(atPath: model) &&
            hasRuntimeLibrary(baseURL: baseURL)
    }

    func transcribe(audioURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try run(audioURL: audioURL, timeout: timeout)
        }.value
    }

    private func run(audioURL: URL, timeout: TimeInterval) throws -> String {
        let baseURL = configuration.resolveRoot()
        let executableURL = baseURL.appendingPathComponent(Self.executablePath)
        let modelURL = baseURL.appendingPathComponent(Self.modelPath)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ParakeetRunnerError.audioMissing(audioURL.path)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw ParakeetRunnerError.runtimeMissing(executableURL.path)
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ParakeetRunnerError.modelMissing(modelURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "transcribe",
            "--model", modelURL.path,
            "--input", audioURL.path,
            "--json"
        ]
        process.currentDirectoryURL = baseURL

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let readGroup = DispatchGroup()
        let dataLock = NSLock()
        var stdout = Data()
        var stderr = Data()
        for (pipe, assign) in [
            (stdoutPipe, { (data: Data) in stdout = data }),
            (stderrPipe, { (data: Data) in stderr = data })
        ] {
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                dataLock.lock()
                assign(data)
                dataLock.unlock()
                readGroup.leave()
            }
        }

        try process.run()
        let deadline = DispatchTime.now() + timeout
        if process.waitUntilExitOrTimeout(deadline: deadline) == false {
            process.terminate()
            if process.waitUntilExitOrTimeout(deadline: .now() + terminationGrace) == false,
               process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = process.waitUntilExitOrTimeout(deadline: .now() + 1)
            }
            _ = readGroup.wait(timeout: .now() + 1)
            throw ParakeetRunnerError.timedOut
        }
        readGroup.wait()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ParakeetRunnerError.processFailed(message)
        }
        return try Self.transcript(fromOutput: stdout)
    }

    /// Reads the `text` field of the CLI's JSON output and trims it. Output
    /// with `"ok": false` is a failure with the error the CLI reported.
    static func transcript(fromOutput stdout: Data) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            throw ParakeetRunnerError.invalidOutput
        }
        if let ok = object["ok"] as? Bool, !ok {
            throw ParakeetRunnerError.processFailed(
                object["error"] as? String ?? "Unknown parakeet.cpp error."
            )
        }
        guard let text = object["text"] as? String else {
            throw ParakeetRunnerError.invalidOutput
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw ParakeetRunnerError.emptyTranscript
        }
        return cleaned
    }

    private func hasRuntimeLibrary(baseURL: URL) -> Bool {
        let libraryURL = baseURL.appendingPathComponent("lib")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return files.contains { $0.lastPathComponent.hasPrefix("libggml") && $0.pathExtension == "dylib" }
    }
}

/// The errors of the one-shot and resident Parakeet runners that Auto Send
/// Recorder uses. The user sees these messages.
enum ParakeetRunnerError: LocalizedError {
    case audioMissing(String)
    case runtimeMissing(String)
    case modelMissing(String)
    case timedOut
    case processFailed(String)
    case invalidOutput
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .audioMissing(let path):
            return "Recording file not found at \(path)."
        case .runtimeMissing(let path):
            return "Parakeet runtime not found at \(path)."
        case .modelMissing(let path):
            return "Parakeet model not found at \(path)."
        case .timedOut:
            return "Parakeet transcription timed out. The recording was kept."
        case .processFailed(let message):
            return message.isEmpty
                ? "Parakeet transcription failed. The recording was kept."
                : "Parakeet transcription failed: \(message)"
        case .invalidOutput:
            return "Parakeet returned invalid output. The recording was kept."
        case .emptyTranscript:
            return "Parakeet did not detect speech. The recording was kept."
        }
    }
}

private extension Process {
    func waitUntilExitOrTimeout(deadline: DispatchTime) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        terminationHandler = { _ in semaphore.signal() }
        if !isRunning { return true }
        return semaphore.wait(timeout: deadline) == .success
    }
}
