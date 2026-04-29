import Foundation

struct ParakeetRuntime: Equatable {
    var pythonPath: String
    var scriptPath: String
    var cachePath: String

    var isUsable: Bool {
        let fileManager = FileManager.default
        return fileManager.isExecutableFile(atPath: normalizedPythonPath)
            && fileManager.fileExists(atPath: scriptPath)
    }

    var normalizedPythonPath: String {
        ParakeetRuntimeDiscovery.normalizedPythonPath(from: pythonPath)
    }
}

enum ParakeetRuntimeDiscovery {
    static let fieldTheoryScriptPath = "/Applications/Field Theory.app/Contents/Resources/scripts/parakeet-transcribe.py"

    static func detect() -> ParakeetRuntime {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let base = home
            .appendingPathComponent("Library/Application Support/fieldtheory-mac/build-parakeet")
        let python = base.appendingPathComponent("venv/bin/python").path
        let cache = base.appendingPathComponent("cache").path

        return ParakeetRuntime(
            pythonPath: python,
            scriptPath: fieldTheoryScriptPath,
            cachePath: cache
        )
    }

    static func normalizedPythonPath(from path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue {
            let venvPython = (expanded as NSString).appendingPathComponent("venv/bin/python")
            if FileManager.default.isExecutableFile(atPath: venvPython) {
                return venvPython
            }
        }
        return expanded
    }
}

struct ParakeetTranscriber: TranscriptionEngine {
    private let runtime: ParakeetRuntime
    private let modelName = "nemo-parakeet-tdt-0.6b-v2"

    init(pythonPath: String, scriptPath: String, cachePath: String) {
        self.runtime = ParakeetRuntime(
            pythonPath: pythonPath,
            scriptPath: (scriptPath as NSString).expandingTildeInPath,
            cachePath: (cachePath as NSString).expandingTildeInPath
        )
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let text = try await ParakeetServer.shared.transcribe(
            audioURL: audioURL,
            runtime: runtime,
            modelName: modelName
        )
        return TranscriptionResult(text: text, engineName: "NVIDIA Parakeet TDT 0.6B server via onnx-asr")
    }
}

actor ParakeetServer {
    static let shared = ParakeetServer()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutHandle: FileHandle?
    private var stderrPipe: Pipe?
    private var activeRuntime: ParakeetRuntime?
    private var activeModelName: String?
    private let startupTimeout: TimeInterval = 45
    private let transcriptionTimeout: TimeInterval = 180

    func transcribe(audioURL: URL, runtime: ParakeetRuntime, modelName: String) async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw TranscriptionEngineError.audioMissing(audioURL.path)
        }

        try await ensureServer(runtime: runtime, modelName: modelName)

        let command: [String: Any] = [
            "cmd": "transcribe",
            "audio": audioURL.path,
            "timestamps": false
        ]
        let commandData = try JSONSerialization.data(withJSONObject: command)
        guard let commandLine = String(data: commandData, encoding: .utf8), let stdinPipe else {
            throw TranscriptionEngineError.processFailed(status: -1, stderr: "Parakeet server stdin is unavailable.")
        }

        try stdinPipe.fileHandleForWriting.write(contentsOf: Data((commandLine + "\n").utf8))
        let line = try await readLine(timeout: transcriptionTimeout)
        let response = try parseResponse(line)

        guard let ok = response["ok"] as? Bool, ok else {
            let error = response["error"] as? String ?? "Unknown Parakeet server error."
            throw TranscriptionEngineError.processFailed(status: -1, stderr: error)
        }
        guard let text = response["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranscriptionEngineError.emptyTranscript
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func ensureServer(runtime: ParakeetRuntime, modelName: String) async throws {
        if let process, process.isRunning, activeRuntime == runtime, activeModelName == modelName {
            return
        }

        stopServer()

        let fileManager = FileManager.default
        let pythonPath = runtime.normalizedPythonPath
        guard fileManager.isExecutableFile(atPath: pythonPath) else {
            throw TranscriptionEngineError.runtimeMissing(runtime.pythonPath)
        }
        guard fileManager.fileExists(atPath: runtime.scriptPath) else {
            throw TranscriptionEngineError.scriptMissing(runtime.scriptPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            runtime.scriptPath,
            "--server",
            "--model",
            modelName
        ]

        var environment = ProcessInfo.processInfo.environment
        if !runtime.cachePath.isEmpty {
            environment["FIELD_THEORY_PARAKEET_CACHE_DIR"] = runtime.cachePath
        }
        process.environment = environment

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                NSLog("Parakeet server: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        try process.run()

        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrPipe = stderrPipe
        self.activeRuntime = runtime
        self.activeModelName = modelName

        let line = try await readLine(timeout: startupTimeout)
        let response = try parseResponse(line)
        guard let ok = response["ok"] as? Bool, ok, response["ready"] as? Bool == true else {
            let error = response["error"] as? String ?? "Parakeet server did not become ready."
            stopServer()
            throw TranscriptionEngineError.processFailed(status: -1, stderr: error)
        }
    }

    private func stopServer() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdinPipe?.fileHandleForWriting.closeFile()
        stdoutHandle?.closeFile()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutHandle = nil
        stderrPipe = nil
        activeRuntime = nil
        activeModelName = nil
    }

    private func readLine(timeout: TimeInterval) async throws -> String {
        guard let stdoutHandle else {
            throw TranscriptionEngineError.processFailed(status: -1, stderr: "Parakeet server stdout is unavailable.")
        }

        return try await Task.detached(priority: .userInitiated) {
            let deadline = Date().addingTimeInterval(timeout)
            var bytes: [UInt8] = []

            while Date() < deadline {
                let data = stdoutHandle.availableData
                if data.isEmpty {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                for byte in data {
                    if byte == 10 {
                        return String(decoding: bytes, as: UTF8.self)
                    }
                    bytes.append(byte)
                }
            }
            throw TranscriptionEngineError.timedOut
        }.value
    }

    private func parseResponse(_ line: String) throws -> [String: Any] {
        let data = Data(line.utf8)
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionEngineError.processFailed(status: -1, stderr: "Invalid Parakeet server response: \(line)")
        }
        return response
    }
}
