import CoreAudio
import Foundation

/// Input device discovery, default-input pinning and device-change observation.
protocol MicrophoneDeviceClient {
    func inputDevices() -> [AudioInputDevice]
    func setDefaultInputDeviceID(_ deviceID: AudioObjectID) throws
    /// Starts observing input device changes. Observation ends when the returned object is released.
    func observeDeviceChanges(_ onDevicesChanged: @escaping () -> Void) -> AnyObject?
}

struct LiveMicrophoneDeviceClient: MicrophoneDeviceClient {
    func inputDevices() -> [AudioInputDevice] {
        AudioInputDeviceDiscovery.inputDevices()
    }

    func setDefaultInputDeviceID(_ deviceID: AudioObjectID) throws {
        try AudioInputDeviceDiscovery.setDefaultInputDeviceID(deviceID)
    }

    func observeDeviceChanges(_ onDevicesChanged: @escaping () -> Void) -> AnyObject? {
        let observer = MicrophoneDeviceObserver(onDevicesChanged: onDevicesChanged)
        observer.start()
        return observer
    }
}

/// The lock file other tools read to see that AIR is using the microphone.
protocol MicrophoneUseLockClient {
    func write(reason: String)
    func clear()
}

struct FileMicrophoneUseLockClient: MicrophoneUseLockClient {
    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ??
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("AutoImproveRecorder", isDirectory: true)
    }

    private var url: URL {
        directoryURL.appendingPathComponent("mic-active.lock")
    }

    func write(reason: String) {
        let body = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        reason=\(reason)
        updatedAt=\(ISO8601DateFormatter().string(from: Date()))
        """
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

struct EnginePrewarmRequest: Equatable {
    var transcriptionMode: TranscriptionMode
    var improvementMode: ImprovementMode
    var ollamaBaseURL: String
    var ollamaModel: String
    var hasOpenAIKey: Bool
}

/// Warms the transcription and improvement engines the request's modes will use.
protocol EnginePrewarmClient {
    func prewarm(_ request: EnginePrewarmRequest)
}

struct LiveEnginePrewarmClient: EnginePrewarmClient {
    func prewarm(_ request: EnginePrewarmRequest) {
        let selectedTranscriptionMode = request.transcriptionMode
        let selectedImprovementMode = request.improvementMode
        let selectedOllamaBaseURL = request.ollamaBaseURL
        let selectedOllamaModel = request.ollamaModel
        let hasOpenAIKey = request.hasOpenAIKey
        let parakeetWarmupTargets = ParakeetWarmupPolicy.targets(
            transcriptionModeRawValue: selectedTranscriptionMode.rawValue
        )

        Task.detached(priority: .utility) {
            switch selectedTranscriptionMode {
            case .localPhonon2:
                await PhononTranscriber.shared.warmUp()
            case .localWhisper:
                await WhisperCppTranscriber().warmUp()
            case .localParakeetCppFast,
                 .localParakeetCppRecommended,
                 .localParakeetCppResident,
                 .localParakeetStreaming,
                 .fastest:
                for target in parakeetWarmupTargets {
                    switch target {
                    case .fastOneShot:
                        await ParakeetCppWarmKeeper.shared.warmIfStale(variant: .fast110M)
                    case .recommendedOneShot:
                        await Self.warmParakeetCppRecommended()
                    case .residentRecommended:
                        await Self.warmParakeetResidentRecommended()
                    case .liveRecommended:
                        await RecommendedLiveTranscription.warmUp()
                    }
                }
            case .appleLocal, .openAIAPI:
                break
            }
        }

        Task.detached(priority: .utility) {
            if selectedTranscriptionMode == .openAIAPI ||
                (selectedTranscriptionMode == .fastest && hasOpenAIKey) ||
                selectedImprovementMode == .openAI {
                await SharedNetworkClient.prewarm(host: URL(string: "https://api.openai.com")!)
            }
            switch selectedImprovementMode {
            case .geminiFlash:
                await SharedNetworkClient.prewarm(host: URL(string: "https://generativelanguage.googleapis.com")!)
            case .claudeHaiku:
                await SharedNetworkClient.prewarm(host: URL(string: "https://api.anthropic.com")!)
            case .ollamaLocal:
                await OllamaImproveEngine(
                    baseURL: selectedOllamaBaseURL,
                    model: selectedOllamaModel
                ).warmUp()
            case .openAI, .appleLocal:
                break
            }
        }
    }

    /// One-shot CLI path warmed via OS page cache and Metal shader cache.
    private static func warmParakeetCppRecommended() async {
        await ParakeetCppWarmKeeper.shared.warmIfStale(variant: .recommended06B)
    }

    /// Explicit resident mode only. This keeps the 0.6B model in process.
    private static func warmParakeetResidentRecommended() async {
        await ParakeetResidentTranscriber().warmUp()
    }
}
