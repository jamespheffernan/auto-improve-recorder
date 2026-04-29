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
    private let timeout: TimeInterval = 180

    init(pythonPath: String, scriptPath: String, cachePath: String) {
        self.runtime = ParakeetRuntime(
            pythonPath: pythonPath,
            scriptPath: (scriptPath as NSString).expandingTildeInPath,
            cachePath: (cachePath as NSString).expandingTildeInPath
        )
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        try await Task.detached(priority: .userInitiated) {
            try runTranscription(audioURL: audioURL)
        }.value
    }

    private func runTranscription(audioURL: URL) throws -> TranscriptionResult {
        let fileManager = FileManager.default
        let pythonPath = runtime.normalizedPythonPath

        guard fileManager.isExecutableFile(atPath: pythonPath) else {
            throw TranscriptionEngineError.runtimeMissing(runtime.pythonPath)
        }
        guard fileManager.fileExists(atPath: runtime.scriptPath) else {
            throw TranscriptionEngineError.scriptMissing(runtime.scriptPath)
        }
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw TranscriptionEngineError.audioMissing(audioURL.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            runtime.scriptPath,
            "--audio",
            audioURL.path,
            "--model",
            modelName
        ]

        var environment = ProcessInfo.processInfo.environment
        if !runtime.cachePath.isEmpty {
            environment["FIELD_THEORY_PARAKEET_CACHE_DIR"] = runtime.cachePath
        }
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            throw TranscriptionEngineError.timedOut
        }

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorOutput = String(decoding: errorData, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw TranscriptionEngineError.processFailed(
                status: process.terminationStatus,
                stderr: errorOutput
            )
        }

        guard !output.isEmpty else {
            throw TranscriptionEngineError.emptyTranscript
        }

        return TranscriptionResult(text: output, engineName: "NVIDIA Parakeet TDT 0.6B via onnx-asr")
    }
}
