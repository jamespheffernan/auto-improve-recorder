import Darwin
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

enum ParakeetCppVariant: Sendable {
    case fast110M
    case recommended06B

    var providerName: String {
        switch self {
        case .fast110M:
            return "parakeet.cpp 110M Q4_K"
        case .recommended06B:
            return "parakeet.cpp 0.6B v2 Q4_K"
        }
    }

    var engineName: String {
        switch self {
        case .fast110M:
            return "parakeet.cpp 110M Q4_K CPU"
        case .recommended06B:
            return "parakeet.cpp 0.6B v2 Q4_K Metal"
        }
    }

    var modelFilename: String {
        switch self {
        case .fast110M:
            return "tdt_ctc-110m-q4_k.gguf"
        case .recommended06B:
            return "tdt-0.6b-v2-q4_k.gguf"
        }
    }

    var forceCPU: Bool {
        switch self {
        case .fast110M:
            return true
        case .recommended06B:
            return false
        }
    }
}

struct ParakeetCppTranscriber: TranscriptionEngine {
    private let variant: ParakeetCppVariant
    private let timeout: TimeInterval = 180

    init(variant: ParakeetCppVariant) {
        self.variant = variant
    }

    func transcribe(audioURL: URL) async throws -> TranscriptionResult {
        let selectedVariant = variant
        let selectedTimeout = timeout
        let text = try await Task.detached(priority: .userInitiated) {
            try Self.runTranscription(
                audioURL: audioURL,
                variant: selectedVariant,
                timeout: selectedTimeout
            )
        }.value

        guard !text.isEmpty else {
            throw TranscriptionEngineError.emptyLocalTranscript(provider: variant.providerName)
        }
        return TranscriptionResult(text: text, engineName: variant.engineName)
    }

    func warmUp() async {
        let selectedVariant = variant
        try? await Task.detached(priority: .utility) {
            _ = try Self.runInfo(variant: selectedVariant)
        }.value
    }

    static func isInstalled(variant: ParakeetCppVariant, fileManager: FileManager = .default) -> Bool {
        let cliPath = installBaseURL.appendingPathComponent("bin/parakeet-cli").path
        let modelPath = installBaseURL.appendingPathComponent("models/\(variant.modelFilename)").path
        let libraryURL = installBaseURL.appendingPathComponent("lib", isDirectory: true)
        let hasRuntimeLibrary = ((try? fileManager.contentsOfDirectory(atPath: libraryURL.path)) ?? [])
            .contains { filename in
                filename.hasPrefix("libggml") && filename.hasSuffix(".dylib")
            }

        return fileManager.isExecutableFile(atPath: cliPath) &&
            fileManager.fileExists(atPath: modelPath) &&
            hasRuntimeLibrary
    }

    private static func runTranscription(audioURL: URL, variant: ParakeetCppVariant, timeout: TimeInterval) throws -> String {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw TranscriptionEngineError.audioMissing(audioURL.path)
        }

        let cliPath = installBaseURL.appendingPathComponent("bin/parakeet-cli").path
        let modelPath = installBaseURL.appendingPathComponent("models/\(variant.modelFilename)").path
        guard fileManager.isExecutableFile(atPath: cliPath) else {
            throw TranscriptionEngineError.executableMissing(provider: variant.providerName, path: cliPath)
        }
        guard fileManager.fileExists(atPath: modelPath) else {
            throw TranscriptionEngineError.modelMissing(provider: variant.providerName, path: modelPath)
        }

        let stdout = try runProcess(
            executablePath: cliPath,
            arguments: [
                "transcribe",
                "--model",
                modelPath,
                "--input",
                audioURL.path,
                "--json"
            ],
            forceCPU: variant.forceCPU,
            timeout: timeout,
            provider: variant.providerName
        )
        return try parseTranscript(stdout, provider: variant.providerName)
    }

    private static func runInfo(variant: ParakeetCppVariant) throws -> String {
        let cliPath = installBaseURL.appendingPathComponent("bin/parakeet-cli").path
        let modelPath = installBaseURL.appendingPathComponent("models/\(variant.modelFilename)").path
        return try runProcess(
            executablePath: cliPath,
            arguments: ["info", modelPath],
            forceCPU: variant.forceCPU,
            timeout: 10,
            provider: variant.providerName
        )
    }

    private static var installBaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AutoImproveRecorder/ParakeetCpp")
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        forceCPU: Bool,
        timeout: TimeInterval,
        provider: String
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        var environment = ProcessInfo.processInfo.environment
        if forceCPU {
            environment["PARAKEET_DEVICE"] = "cpu"
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        try process.run()

        let readGroup = DispatchGroup()
        let outputLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stdoutData = data
            outputLock.unlock()
            readGroup.leave()
        }

        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stderrData = data
            outputLock.unlock()
            readGroup.leave()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
            _ = readGroup.wait(timeout: .now() + 1)
            throw TranscriptionEngineError.localTimedOut(provider: provider)
        }
        readGroup.wait()

        outputLock.lock()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        outputLock.unlock()
        guard process.terminationStatus == 0 else {
            throw TranscriptionEngineError.localProcessFailed(provider: provider, status: process.terminationStatus, stderr: stderr)
        }
        return stdout
    }

    private static func parseTranscript(_ stdout: String, provider: String) throws -> String {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return trimmed
        }

        if let ok = object["ok"] as? Bool, !ok {
            let error = object["error"] as? String ?? "Unknown parakeet.cpp error."
            throw TranscriptionEngineError.localProcessFailed(provider: provider, status: -1, stderr: error)
        }
        return (object["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
