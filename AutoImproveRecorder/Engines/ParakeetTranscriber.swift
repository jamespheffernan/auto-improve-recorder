import Foundation

struct WhisperCppTranscriber: TranscriptionEngine {
    private let executablePath = "/Applications/Field Theory.app/Contents/Resources/whisper-cli"
    private let serverPath = "/Applications/Field Theory.app/Contents/Resources/whisper-server"
    private let modelPath: String = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/fieldtheory-mac/models/ggml-small.en.bin")
        .path

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let text = try await WhisperCppServer.shared.transcribe(
            audioURL: audioURL,
            executablePath: executablePath,
            serverPath: serverPath,
            modelPath: modelPath
        )
        guard !text.isEmpty else {
            throw TranscriptionEngineError.emptyLocalTranscript(provider: "whisper.cpp")
        }
        return TranscriptionResult(text: text, engineName: "whisper.cpp small.en server")
    }

    func warmUp() async {
        try? await WhisperCppServer.shared.warmUp(
            executablePath: executablePath,
            serverPath: serverPath,
            modelPath: modelPath
        )
    }
}

actor WhisperCppServer {
    static let shared = WhisperCppServer()

    private let provider = "whisper.cpp"
    private let host = "127.0.0.1"
    private let port = 8173
    private let inferencePath = "/inference"
    private let startupTimeout: TimeInterval = 30
    private let transcriptionTimeout: TimeInterval = 30
    private var process: Process?
    private var activeServerPath: String?
    private var activeModelPath: String?
    private var stderrPipe: Pipe?

    func transcribe(audioURL: URL, executablePath: String, serverPath: String, modelPath: String) async throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw TranscriptionEngineError.audioMissing(audioURL.path)
        }
        try await ensureUsableRuntime(executablePath: executablePath, serverPath: serverPath, modelPath: modelPath)
        try await ensureServer(serverPath: serverPath, modelPath: modelPath)
        return try await requestTranscription(audioURL: audioURL)
    }

    func warmUp(executablePath: String, serverPath: String, modelPath: String) async throws {
        try await ensureUsableRuntime(executablePath: executablePath, serverPath: serverPath, modelPath: modelPath)
        try await ensureServer(serverPath: serverPath, modelPath: modelPath)
    }

    private func ensureUsableRuntime(executablePath: String, serverPath: String, modelPath: String) async throws {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: serverPath) else {
            if fileManager.isExecutableFile(atPath: executablePath) {
                throw TranscriptionEngineError.executableMissing(provider: provider, path: serverPath)
            }
            throw TranscriptionEngineError.executableMissing(provider: provider, path: executablePath)
        }
        guard fileManager.fileExists(atPath: modelPath) else {
            throw TranscriptionEngineError.modelMissing(provider: provider, path: modelPath)
        }
    }

    private func ensureServer(serverPath: String, modelPath: String) async throws {
        if let process, process.isRunning, activeServerPath == serverPath, activeModelPath == modelPath {
            return
        }

        if process == nil, await probeServer() {
            activeServerPath = serverPath
            activeModelPath = modelPath
            return
        }

        stopServer()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: serverPath)
        process.arguments = [
            "-m", modelPath,
            "-l", "en",
            "-nt",
            "-bs", "1",
            "-bo", "1",
            "-t", "8",
            "--host", host,
            "--port", String(port),
            "--inference-path", inferencePath
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                NSLog("whisper.cpp server: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                NSLog("whisper.cpp server: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        try process.run()
        self.process = process
        self.activeServerPath = serverPath
        self.activeModelPath = modelPath
        self.stderrPipe = stderrPipe

        let deadline = Date().addingTimeInterval(startupTimeout)
        while Date() < deadline {
            if !process.isRunning {
                stopServer()
                throw TranscriptionEngineError.localProcessFailed(provider: provider, status: process.terminationStatus, stderr: "")
            }
            if await probeServer() {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        stopServer()
        throw TranscriptionEngineError.localTimedOut(provider: provider)
    }

    private func requestTranscription(audioURL: URL) async throws -> String {
        let boundary = "AutoImproveRecorder-\(UUID().uuidString)"
        var request = URLRequest(url: URL(string: "http://\(host):\(port)\(inferencePath)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = transcriptionTimeout
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(audioURL: audioURL, boundary: boundary)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw TranscriptionEngineError.localProcessFailed(provider: provider, status: -1, stderr: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let message = String(decoding: data, as: UTF8.self)
            throw TranscriptionEngineError.localProcessFailed(provider: provider, status: -1, stderr: message)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw TranscriptionEngineError.localProcessFailed(
                provider: provider,
                status: -1,
                stderr: String(decoding: data, as: UTF8.self)
            )
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func multipartBody(audioURL: URL, boundary: String) throws -> Data {
        var body = Data()
        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audioURL))
        append("\r\n--\(boundary)--\r\n")
        return body
    }

    private func probeServer() async -> Bool {
        guard let url = URL(string: "http://\(host):\(port)/") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    private func stopServer() {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        activeServerPath = nil
        activeModelPath = nil
        stderrPipe = nil
    }
}

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
