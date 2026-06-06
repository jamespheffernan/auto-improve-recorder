import Foundation

struct LocalModelInventoryInput: Codable, Equatable, Sendable {
    var parakeetCppBasePath: String
    var ollamaBaseURL: String
    var ollamaModel: String
    var hasOpenAIAPIKey: Bool

    static let liveDefault = LocalModelInventoryInput(
        parakeetCppBasePath: LocalModelInventory.defaultParakeetCppBasePath,
        ollamaBaseURL: "http://127.0.0.1:11434",
        ollamaModel: LocalModelInventory.qwenOllamaModel,
        hasOpenAIAPIKey: false
    )
}

struct LocalModelInventory: Sendable {
    static let qwenOllamaModel = "qwen3.5:0.8b-mlx"
    static let defaultParakeetCppBasePath = "~/Library/Application Support/AutoImproveRecorder/ParakeetCpp"
    static let recommendedModelFilename = "tdt-0.6b-v2-q4_k.gguf"
    static let fastModelFilename = "tdt_ctc-110m-q4_k.gguf"

    private let probe: any LocalRuntimeProbe
    private let now: @Sendable () -> Date

    init(probe: any LocalRuntimeProbe = DefaultLocalRuntimeProbe(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.probe = probe
        self.now = now
    }

    func statuses(input: LocalModelInventoryInput) async -> [LocalModelStatus] {
        async let ollamaStatus = ollamaQwenStatus(input: input)

        let recommended = parakeetStatus(
            descriptor: Self.descriptor(for: .parakeetCppRecommended),
            input: input,
            modelFilename: Self.recommendedModelFilename,
            modelName: "Parakeet.cpp 0.6B Recommended"
        )
        let fast = parakeetStatus(
            descriptor: Self.descriptor(for: .parakeetCppFast),
            input: input,
            modelFilename: Self.fastModelFilename,
            modelName: "Parakeet.cpp 110M Fast"
        )
        let apple = appleSpeechStatus()
        let cloud = cloudRealtimeStatus(hasOpenAIAPIKey: input.hasOpenAIAPIKey)
        let qwen = await ollamaStatus
        let allLocal = allLocalStatus(recommended: recommended, qwen: qwen)

        return [recommended, fast, allLocal, apple, cloud, qwen]
    }

    static func descriptor(for id: LocalModelID) -> LocalModelDescriptor {
        switch id {
        case .parakeetCppRecommended:
            return LocalModelDescriptor(
                id: id,
                title: "Recommended local transcription",
                subtitle: "Parakeet.cpp 0.6B for best local accuracy.",
                kind: .transcription,
                ownership: .airOwned,
                capabilities: .localTranscription
            )
        case .parakeetCppFast:
            return LocalModelDescriptor(
                id: id,
                title: "Fast local transcription",
                subtitle: "Parakeet.cpp 110M for lower latency.",
                kind: .transcription,
                ownership: .airOwned,
                capabilities: .localTranscription
            )
        case .allLocal:
            return LocalModelDescriptor(
                id: id,
                title: "All Local",
                subtitle: "Recommended transcription plus Ollama qwen3.5 cleanup.",
                kind: .preset,
                ownership: .airOwned,
                capabilities: .localPreset
            )
        case .appleSpeech:
            return LocalModelDescriptor(
                id: id,
                title: "Apple Speech",
                subtitle: "Apple on-device transcription when this Mac supports it.",
                kind: .transcription,
                ownership: .appleSystem,
                capabilities: .localTranscription
            )
        case .cloudRealtime:
            return LocalModelDescriptor(
                id: id,
                title: "Cloud Realtime",
                subtitle: "Streams microphone audio to OpenAI for low latency.",
                kind: .transcription,
                ownership: .externalApp,
                capabilities: .cloudRealtime
            )
        case .ollamaQwen35:
            return LocalModelDescriptor(
                id: id,
                title: "Ollama qwen3.5 cleanup",
                subtitle: "qwen3.5:0.8b-mlx for local transcript cleanup.",
                kind: .improvement,
                ownership: .externalApp,
                capabilities: .localImprovement
            )
        }
    }

    private func parakeetStatus(
        descriptor: LocalModelDescriptor,
        input: LocalModelInventoryInput,
        modelFilename: String,
        modelName: String
    ) -> LocalModelStatus {
        let basePath = expandedPath(input.parakeetCppBasePath)
        let cliPath = "\(basePath)/bin/parakeet-cli"
        let modelPath = "\(basePath)/models/\(modelFilename)"
        let dylibPattern = "\(basePath)/lib/libggml*.dylib"

        let cliReady = probe.isExecutableFile(atPath: cliPath)
        let hasRuntimeLibraries = !probe.paths(matching: dylibPattern).isEmpty
        let hasModel = probe.fileExists(atPath: modelPath)

        if !cliReady || !hasRuntimeLibraries {
            return status(
                descriptor,
                state: .needsRuntime,
                detail: "\(modelName) needs the AIR-owned Parakeet.cpp runtime.",
                issues: [
                    .error("Parakeet.cpp runtime missing. Expected parakeet-cli and runtime libraries under \(basePath).")
                ]
            )
        }

        if !hasModel {
            return status(
                descriptor,
                state: .needsModel,
                detail: "\(modelName) runtime is present, but the model file is missing.",
                issues: [
                    .warning("Missing model file: \(modelFilename). Downloads are not implemented in this first slice.")
                ]
            )
        }

        return status(
            descriptor,
            state: .installed,
            detail: "\(modelName) is installed. AIR has not loaded it in Settings.",
            issues: []
        )
    }

    private func ollamaQwenStatus(input: LocalModelInventoryInput) async -> LocalModelStatus {
        let descriptor = Self.descriptor(for: .ollamaQwen35)
        guard let baseURL = URL(string: input.ollamaBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = baseURL.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            return status(
                descriptor,
                state: .externalAppRequired,
                detail: "Ollama base URL is not valid.",
                issues: [.error("Set Ollama Base URL to a local endpoint such as http://127.0.0.1:11434.")]
            )
        }

        do {
            let tags = try await probe.ollamaModelTags(baseURL: baseURL)
            guard tags.contains(Self.qwenOllamaModel) else {
                return status(
                    descriptor,
                    state: .needsModel,
                    detail: "Ollama is reachable, but \(Self.qwenOllamaModel) is not installed.",
                    issues: [.warning("Run `ollama pull \(Self.qwenOllamaModel)` before using All Local cleanup.")]
                )
            }

            return status(
                descriptor,
                state: .ready,
                detail: "Ollama reports \(Self.qwenOllamaModel) is available.",
                issues: []
            )
        } catch {
            return status(
                descriptor,
                state: .externalAppRequired,
                detail: "Ollama is not reachable at \(input.ollamaBaseURL).",
                issues: [.warning("Start Ollama locally before using All Local cleanup.")]
            )
        }
    }

    private func allLocalStatus(recommended: LocalModelStatus, qwen: LocalModelStatus) -> LocalModelStatus {
        let descriptor = Self.descriptor(for: .allLocal)
        let issues = recommended.issues + qwen.issues

        guard recommended.state == .installed || recommended.state == .ready else {
            return status(
                descriptor,
                state: recommended.state,
                detail: "All Local needs Parakeet.cpp Recommended before it can be used.",
                issues: issues
            )
        }

        guard qwen.state == .ready || qwen.state == .installed else {
            return status(
                descriptor,
                state: qwen.state,
                detail: "All Local needs Ollama \(Self.qwenOllamaModel) for local cleanup.",
                issues: issues
            )
        }

        return status(
            descriptor,
            state: .ready,
            detail: "Ready for local transcription and local cleanup.",
            issues: []
        )
    }

    private func appleSpeechStatus() -> LocalModelStatus {
        let descriptor = Self.descriptor(for: .appleSpeech)
        let version = probe.operatingSystemVersion()
        guard version.majorVersion >= 26 else {
            return status(
                descriptor,
                state: .unavailable,
                detail: "Apple Speech is only available through AIR on macOS 26 or later.",
                issues: [.info("There is no AIR download or install action for Apple Speech.")]
            )
        }

        return status(
            descriptor,
            state: .installed,
            detail: "This Mac may support Apple Speech. AIR will verify locale support when transcription starts.",
            issues: [.info("Apple Speech is managed by macOS; AIR cannot download or install it.")]
        )
    }

    private func cloudRealtimeStatus(hasOpenAIAPIKey: Bool) -> LocalModelStatus {
        let descriptor = Self.descriptor(for: .cloudRealtime)
        guard hasOpenAIAPIKey else {
            return status(
                descriptor,
                state: .needsRuntime,
                detail: "Cloud Realtime streams microphone audio to OpenAI and needs an API key.",
                issues: [.warning("Add an OpenAI API key before using Cloud Realtime.")]
            )
        }

        return status(
            descriptor,
            state: .ready,
            detail: "Cloud Realtime can use the configured OpenAI API key.",
            issues: []
        )
    }

    private func status(
        _ descriptor: LocalModelDescriptor,
        state: LocalModelState,
        detail: String,
        issues: [LocalModelIssue]
    ) -> LocalModelStatus {
        LocalModelStatus(
            descriptor: descriptor,
            state: state,
            detail: detail,
            issues: issues,
            checkedAt: now()
        )
    }

    private func expandedPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
