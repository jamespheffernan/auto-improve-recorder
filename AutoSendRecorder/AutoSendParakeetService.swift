import Foundation

private struct AutoSendParakeetLiveSession: AutoSendLiveTranscriptFinalizing, @unchecked Sendable {
    let session: any LocalLiveTranscriptionSession

    func finalize() async throws -> String {
        try await session.finalize()
    }

    func cancel() {
        session.cancel()
    }
}

struct AutoSendOneShotParakeet: AutoSendOneShotTranscribing {
    private let timeout: TimeInterval = 180

    func transcribe(audioURL: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try run(audioURL: audioURL, timeout: timeout)
        }.value
    }

    private func run(audioURL: URL, timeout: TimeInterval) throws -> String {
        let baseURL = ParakeetRuntimeConfiguration.app.resolveRoot()
        let executableURL = baseURL.appendingPathComponent("bin/parakeet-cli")
        let modelURL = baseURL.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw AutoSendParakeetError.audioMissing(audioURL.path)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw AutoSendParakeetError.runtimeMissing(executableURL.path)
        }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw AutoSendParakeetError.modelMissing(modelURL.path)
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
            throw AutoSendParakeetError.timedOut
        }
        readGroup.wait()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AutoSendParakeetError.processFailed(message)
        }
        guard let object = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any],
              let text = object["text"] as? String else {
            throw AutoSendParakeetError.invalidOutput
        }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw AutoSendParakeetError.emptyTranscript
        }
        return cleaned
    }
}

extension ParakeetRuntimeConfiguration {
    /// ASR's Parakeet root: its own versioned runtime once the installer
    /// reports it ready, otherwise AIR's install root.
    static let app = ParakeetRuntimeConfiguration.preferring(
        { AutoSendRuntimeInstaller.destination },
        whenReady: { AutoSendRuntimeInstaller.isReady() },
        otherwise: {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/AutoImproveRecorder/ParakeetCpp")
        }
    )
}

struct AutoSendFastResidentParakeet: AutoSendOneShotTranscribing {
    /// Resolved on first use and then fixed for the life of the process.
    private static var modelPath: String {
        ParakeetResidentRuntime.shared.cachedModelPath(filename: "tdt_ctc-110m-q4_k.gguf")
    }
    private let provider = "parakeet.cpp 110M resident"

    func transcribe(audioURL: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw AutoSendParakeetError.audioMissing(audioURL.path)
        }
        let provider = provider
        let text = try await Task.detached(priority: .userInitiated) {
            let context = try ParakeetResidentRuntime.shared.context(modelPath: Self.modelPath)
            return try context.transcribe(wavPath: audioURL.path, provider: provider)
        }.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AutoSendParakeetError.emptyTranscript
        }
        return text
    }

    func warmUp() async {
        guard ParakeetCAPI.isInstalled,
              FileManager.default.fileExists(atPath: Self.modelPath) else { return }
        await Task.detached(priority: .utility) {
            guard let context = try? ParakeetResidentRuntime.shared.context(
                modelPath: Self.modelPath
            ) else { return }
            context.warmUpOnce()
        }.value
    }
}

final class AutoSendParakeetService: AutoSendTranscriptService, @unchecked Sendable {
    private let lock = NSLock()
    private let fallback = AutoSendParakeetFallbackPipeline(oneShot: AutoSendOneShotParakeet())
    private let fastResident = AutoSendFastResidentParakeet()
    private var liveSession: (any LocalLiveTranscriptionSession)?
    private var liveOperationID: AutoSendOperationID?
    private var liveSource: AutoSendRecordingSource?
    private var selectedModel: AutoSendTranscriptionModel
    private var operationModel: AutoSendTranscriptionModel?

    init(model: AutoSendTranscriptionModel = .phonon2) {
        selectedModel = model
    }

    func selectModel(_ model: AutoSendTranscriptionModel) {
        lock.lock()
        selectedModel = model
        lock.unlock()
    }

    private var currentModel: AutoSendTranscriptionModel {
        lock.lock()
        defer { lock.unlock() }
        return selectedModel
    }

    var liveModeIsSafe: Bool {
        let baseURL = ParakeetRuntimeConfiguration.app.resolveRoot()
        let cli = baseURL.appendingPathComponent("bin/parakeet-cli").path
        let fallbackModel = baseURL.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf").path
        return ProcessInfo.processInfo.physicalMemory >= 16 * 1_024 * 1_024 * 1_024 &&
            FileManager.default.isExecutableFile(atPath: cli) &&
            FileManager.default.fileExists(atPath: fallbackModel) &&
            hasOneShotRuntimeLibrary(baseURL: baseURL) &&
            RecommendedLiveTranscription.isAvailable
    }

    func beginRecording(
        operationID: AutoSendOperationID,
        source: AutoSendRecordingSource
    ) {
        let model = currentModel
        let session = model == .parakeet && liveModeIsSafe && source != .esp32Button
            ? RecommendedLiveTranscription.begin()
            : nil
        lock.lock()
        liveSession?.cancel()
        liveSession = session
        liveOperationID = operationID
        liveSource = source
        operationModel = model
        lock.unlock()
    }

    func handleCaptureEvent(_ event: AudioCaptureEvent, operationID: AutoSendOperationID) {
        lock.lock()
        let session = liveOperationID == operationID ? liveSession : nil
        lock.unlock()
        switch event {
        case .captured(let captured):
            session?.append(captured)
        case .failure(let failure):
            session?.recordCaptureFailure(failure)
        }
    }

    func transcribe(audioURL: URL, operationID: AutoSendOperationID) async throws -> String {
        let state = takeTranscriptionState(operationID: operationID)
        if (state?.model ?? currentModel) == .phonon2 {
            return try await PhononTranscriber.shared.transcribe(audioURL: audioURL)
        }
        let pipeline = AutoSendSourceAwareTranscriptionPipeline(
            fastWireless: fastResident,
            fallback: fallback
        )
        return try await pipeline.transcribe(
            source: state?.source ?? .macHotKey,
            liveSession: state?.session.map(AutoSendParakeetLiveSession.init),
            audioURL: audioURL
        )
    }

    func cancel(operationID: AutoSendOperationID) async {
        let state = takeTranscriptionState(operationID: operationID)
        state?.session?.cancel()
    }

    func warmUp() async {
        if currentModel == .phonon2 {
            await PhononTranscriber.shared.warmUp()
            return
        }
        await fastResident.warmUp()
        if liveModeIsSafe {
            await RecommendedLiveTranscription.warmUp()
        }
    }

    private func hasOneShotRuntimeLibrary(baseURL: URL) -> Bool {
        let libraryURL = baseURL.appendingPathComponent("lib")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: libraryURL,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return files.contains { $0.lastPathComponent.hasPrefix("libggml") && $0.pathExtension == "dylib" }
    }

    private func takeTranscriptionState(
        operationID: AutoSendOperationID
    ) -> (session: (any LocalLiveTranscriptionSession)?, source: AutoSendRecordingSource, model: AutoSendTranscriptionModel)? {
        lock.lock()
        defer { lock.unlock() }
        guard liveOperationID == operationID else { return nil }
        let session = liveSession
        let source = liveSource ?? .macHotKey
        let model = operationModel ?? selectedModel
        liveSession = nil
        liveOperationID = nil
        liveSource = nil
        operationModel = nil
        return (session, source, model)
    }
}

enum AutoSendParakeetError: LocalizedError {
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
