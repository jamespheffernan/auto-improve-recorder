import AppKit
import AVFoundation
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var phase: RecorderPhase = .idle {
        didSet { menuNeedsUpdate?() }
    }
    @Published var session: TranscriptSession = .empty
    @Published var showRawTranscript = false
    @Published var statusMessage: String?
    @Published var lastOpenAIRealtimeDiagnostics: OpenAIRealtimeDiagnostics? {
        didSet { saveOpenAIRealtimeDiagnostics() }
    }

    @Published var apiKey: String = "" {
        didSet { KeychainStore.saveOpenAIAPIKey(apiKey) }
    }
    @Published var geminiAPIKey: String = "" {
        didSet { KeychainStore.saveGeminiAPIKey(geminiAPIKey) }
    }
    @Published var anthropicAPIKey: String = "" {
        didSet { KeychainStore.saveAnthropicAPIKey(anthropicAPIKey) }
    }
    @Published var autoImproveMode: AutoImproveMode = .automatic {
        didSet { defaults.set(autoImproveMode.rawValue, forKey: Keys.autoImproveMode) }
    }
    @Published var recordingTriggerMode: RecordingTriggerMode = .walkieTalkie {
        didSet {
            defaults.set(recordingTriggerMode.rawValue, forKey: Keys.recordingTriggerMode)
            if recordingTriggerMode != .walkieTalkie {
                unregisterWalkieTalkieLatchHotKey?()
            }
        }
    }
    @Published var recordingHotKey: RecordingHotKey = .r {
        didSet {
            defaults.set(recordingHotKey.rawValue, forKey: Keys.recordingHotKey)
            applyRecordingHotKey(previous: oldValue)
        }
    }
    @Published var transcriptionMode: TranscriptionMode = .localWhisper {
        didSet { defaults.set(transcriptionMode.rawValue, forKey: Keys.transcriptionMode) }
    }
    @Published var improvementMode: ImprovementMode = .ollamaLocal {
        didSet { defaults.set(improvementMode.rawValue, forKey: Keys.improvementMode) }
    }
    @Published var thresholdWords: Int = 35 {
        didSet { defaults.set(thresholdWords, forKey: Keys.thresholdWords) }
    }
    @Published var modificationStrength: Int = 2 {
        didSet { defaults.set(modificationStrength, forKey: Keys.modificationStrength) }
    }
    @Published var outputMode: OutputMode = .lightCleanup {
        didSet { defaults.set(outputMode.rawValue, forKey: Keys.outputMode) }
    }
    @Published var parakeetRuntimePath: String = "" {
        didSet { defaults.set(parakeetRuntimePath, forKey: Keys.parakeetRuntimePath) }
    }
    @Published var parakeetScriptPath: String = "" {
        didSet { defaults.set(parakeetScriptPath, forKey: Keys.parakeetScriptPath) }
    }
    @Published var parakeetCachePath: String = "" {
        didSet { defaults.set(parakeetCachePath, forKey: Keys.parakeetCachePath) }
    }
    @Published var ollamaBaseURL: String = "http://127.0.0.1:11434" {
        didSet { defaults.set(ollamaBaseURL, forKey: Keys.ollamaBaseURL) }
    }
    @Published var ollamaModel: String = "qwen3.5:0.8b-mlx" {
        didSet { defaults.set(ollamaModel, forKey: Keys.ollamaModel) }
    }
    @Published var preferredMicrophoneID: String = "" {
        didSet { defaults.set(preferredMicrophoneID, forKey: Keys.preferredMicrophoneID) }
    }
    @Published var copyFinishedTextToClipboard: Bool = true {
        didSet { defaults.set(copyFinishedTextToClipboard, forKey: Keys.copyFinishedTextToClipboard) }
    }
    @Published var autoSubmitDetectedTextFields: Bool = false {
        didSet { defaults.set(autoSubmitDetectedTextFields, forKey: Keys.autoSubmitDetectedTextFields) }
    }
    @Published var availableMicrophones: [AudioInputDevice] = AudioInputDeviceDiscovery.inputDevices()

    var showPill: (() -> Void)?
    var hidePill: (() -> Void)?
    var showPreview: (() -> Void)?
    var showSettings: (() -> Void)?
    var menuNeedsUpdate: (() -> Void)?
    var registerRecordingHotKey: ((RecordingHotKey) -> Bool)?
    var registerCancelHotKey: (() -> Void)?
    var unregisterCancelHotKey: (() -> Void)?
    var registerWalkieTalkieLatchHotKey: (() -> Void)?
    var unregisterWalkieTalkieLatchHotKey: (() -> Void)?
    var showProcessingSignal: (() -> Void)?
    var flashReadySignal: (() -> Void)?
    var hideProcessingSignal: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let audioRecorder = AudioRecorder()
    private let realtimeAudioSink = OpenAIRealtimeAudioSink()
    private var activeStreamingTranscriber: OpenAIRealtimeTranscriber?
    private var activeRealtimeStartupTask: Task<Void, Never>?
    private var activeRecordingID: UUID?
    private var activeArchiveDraft: TranscriptArchiveDraft?
    private var isStartingRecording = false
    private var activeWalkieTalkieRecording = false
    private var walkieTalkieRecordingLatched = false
    private var walkieTalkieKeyIsDown = false
    private var isRevertingRecordingHotKey = false

    private enum Keys {
        static let autoImproveMode = "autoImproveMode"
        static let recordingTriggerMode = "recordingTriggerMode"
        static let recordingHotKey = "recordingHotKey"
        static let transcriptionMode = "transcriptionMode"
        static let improvementMode = "improvementMode"
        static let thresholdWords = "thresholdWords"
        static let modificationStrength = "modificationStrength"
        static let outputMode = "outputMode"
        static let parakeetRuntimePath = "parakeetRuntimePath"
        static let parakeetScriptPath = "parakeetScriptPath"
        static let parakeetCachePath = "parakeetCachePath"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let ollamaModel = "ollamaModel"
        static let preferredMicrophoneID = "preferredMicrophoneID"
        static let copyFinishedTextToClipboard = "copyFinishedTextToClipboard"
        static let autoSubmitDetectedTextFields = "autoSubmitDetectedTextFields"
        static let lastOpenAIRealtimeErrorSummary = "lastOpenAIRealtimeErrorSummary"
        static let lastOpenAIRealtimeErrorDetails = "lastOpenAIRealtimeErrorDetails"
    }

    private init() {
        apiKey = KeychainStore.loadOpenAIAPIKey() ?? ""
        geminiAPIKey = KeychainStore.loadGeminiAPIKey() ?? ""
        anthropicAPIKey = KeychainStore.loadAnthropicAPIKey() ?? ""
        autoImproveMode = AutoImproveMode(rawValue: defaults.string(forKey: Keys.autoImproveMode) ?? "") ?? .automatic
        recordingTriggerMode = RecordingTriggerMode(rawValue: defaults.string(forKey: Keys.recordingTriggerMode) ?? "") ?? .walkieTalkie
        recordingHotKey = RecordingHotKey(rawValue: defaults.string(forKey: Keys.recordingHotKey) ?? "") ?? .r
        transcriptionMode = TranscriptionMode(rawValue: defaults.string(forKey: Keys.transcriptionMode) ?? "") ?? .localWhisper
        improvementMode = ImprovementMode(rawValue: defaults.string(forKey: Keys.improvementMode) ?? "") ?? .ollamaLocal
        let savedThreshold = defaults.integer(forKey: Keys.thresholdWords)
        thresholdWords = savedThreshold > 0 ? savedThreshold : 35
        let savedStrength = defaults.integer(forKey: Keys.modificationStrength)
        modificationStrength = savedStrength > 0 ? min(max(savedStrength, 1), 5) : 2
        outputMode = OutputMode(rawValue: defaults.string(forKey: Keys.outputMode) ?? "") ?? .lightCleanup
        preferredMicrophoneID = defaults.string(forKey: Keys.preferredMicrophoneID) ?? ""
        if defaults.object(forKey: Keys.copyFinishedTextToClipboard) == nil {
            copyFinishedTextToClipboard = true
        } else {
            copyFinishedTextToClipboard = defaults.bool(forKey: Keys.copyFinishedTextToClipboard)
        }
        autoSubmitDetectedTextFields = defaults.bool(forKey: Keys.autoSubmitDetectedTextFields)
        let savedOpenAISummary = defaults.string(forKey: Keys.lastOpenAIRealtimeErrorSummary) ?? ""
        let savedOpenAIDetails = defaults.string(forKey: Keys.lastOpenAIRealtimeErrorDetails) ?? ""
        let savedOpenAIDiagnostics = OpenAIRealtimeDiagnostics(summary: savedOpenAISummary, details: savedOpenAIDetails)
        lastOpenAIRealtimeDiagnostics = savedOpenAIDiagnostics.isEmpty ? nil : savedOpenAIDiagnostics

        let detected = ParakeetRuntimeDiscovery.detect()
        parakeetRuntimePath = defaults.string(forKey: Keys.parakeetRuntimePath) ?? detected.pythonPath
        parakeetScriptPath = defaults.string(forKey: Keys.parakeetScriptPath) ?? detected.scriptPath
        parakeetCachePath = defaults.string(forKey: Keys.parakeetCachePath) ?? detected.cachePath
        ollamaBaseURL = defaults.string(forKey: Keys.ollamaBaseURL) ?? "http://127.0.0.1:11434"
        ollamaModel = defaults.string(forKey: Keys.ollamaModel) ?? "qwen3.5:0.8b-mlx"
    }

    var isRecording: Bool {
        if case .recording = phase {
            return true
        }
        return false
    }

    var displayText: String {
        showRawTranscript ? session.rawTranscript : session.preferredText
    }

    var canRerunImprove: Bool {
        !session.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !phase.isBusy
    }

    var canCopyOrPaste: Bool {
        !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var accessibilityPasteAvailable: Bool {
        AccessibilityPasteController.isTrusted(prompt: false)
    }

    func refreshMicrophones() {
        availableMicrophones = AudioInputDeviceDiscovery.inputDevices()
    }

    func autodetectParakeetRuntime() {
        let detected = ParakeetRuntimeDiscovery.detect()
        parakeetRuntimePath = detected.pythonPath
        parakeetScriptPath = detected.scriptPath
        parakeetCachePath = detected.cachePath
        statusMessage = detected.isUsable
            ? "Parakeet runtime detected."
            : "Parakeet runtime was not fully detected. Check the paths below."
    }

    func refreshRecordingHotKeyRegistration() {
        applyRecordingHotKey(previous: nil)
    }

    func prewarmLocalModels() {
        let selectedTranscriptionMode = transcriptionMode
        let selectedImprovementMode = improvementMode
        let selectedOllamaBaseURL = ollamaBaseURL
        let selectedOllamaModel = ollamaModel

        Task.detached(priority: .utility) {
            if selectedTranscriptionMode == .localWhisper {
                await WhisperCppTranscriber().warmUp()
            }
            if selectedImprovementMode == .ollamaLocal {
                await OllamaImproveEngine(
                    baseURL: selectedOllamaBaseURL,
                    model: selectedOllamaModel
                ).warmUp()
            }
        }
    }

    func toggleRecording(requestedAt: Date = Date()) {
        if isRecording {
            stopRecording()
        } else {
            startRecording(requestedAt: requestedAt)
        }
    }

    private func applyRecordingHotKey(previous: RecordingHotKey?) {
        guard !isRevertingRecordingHotKey, let registerRecordingHotKey else { return }
        guard registerRecordingHotKey(recordingHotKey) else {
            statusMessage = "Could not register \(recordingHotKey.label)."
            if let previous, previous != recordingHotKey {
                isRevertingRecordingHotKey = true
                recordingHotKey = previous
                isRevertingRecordingHotKey = false
                _ = registerRecordingHotKey(previous)
            }
            return
        }
        if previous != nil {
            statusMessage = "Recording hotkey set to \(recordingHotKey.label)."
        }
    }

    func recordingHotKeyPressed(requestedAt: Date = Date()) {
        guard recordingTriggerMode == .walkieTalkie else {
            toggleRecording(requestedAt: requestedAt)
            return
        }

        guard !walkieTalkieKeyIsDown else { return }
        walkieTalkieKeyIsDown = true

        if isRecording {
            if activeWalkieTalkieRecording && walkieTalkieRecordingLatched {
                stopRecording()
            }
            return
        }

        guard !phase.isBusy, !isStartingRecording else { return }
        activeWalkieTalkieRecording = true
        walkieTalkieRecordingLatched = false
        startRecording(requestedAt: requestedAt)
    }

    func recordingHotKeyReleased() {
        walkieTalkieKeyIsDown = false
        guard recordingTriggerMode == .walkieTalkie else { return }
        stopUnlatchedWalkieTalkieRecordingIfNeeded()
    }

    func latchCurrentWalkieTalkieRecording() {
        guard recordingTriggerMode == .walkieTalkie,
              activeWalkieTalkieRecording,
              isRecording,
              !walkieTalkieRecordingLatched
        else { return }

        walkieTalkieRecordingLatched = true
        unregisterWalkieTalkieLatchHotKey?()
        statusMessage = "Recording latched."
    }

    func startRecording(requestedAt: Date = Date()) {
        guard !phase.isBusy, !isStartingRecording else { return }
        isStartingRecording = true
        logRecordingStartup("start requested", requestedAt: requestedAt)
        Task { await startRecordingFlow(requestedAt: requestedAt) }
    }

    func stopRecording() {
        guard case .recording = phase else { return }
        unregisterCancelHotKey?()
        resetWalkieTalkieRecordingState()
        activeRealtimeStartupTask?.cancel()
        activeRealtimeStartupTask = nil
        activeRecordingID = nil
        let streamingTranscriber = activeStreamingTranscriber
        activeStreamingTranscriber = nil
        guard let audioURL = audioRecorder.stop() else {
            realtimeAudioSink.clear()
            if let streamingTranscriber {
                Task { await streamingTranscriber.cancel() }
            }
            failWithMessage("Recording stopped before an audio file was created.")
            return
        }
        realtimeAudioSink.clear()

        phase = .transcribing
        statusMessage = transcriptionStatusMessage(streamingTranscriber: streamingTranscriber)
        showProcessingSignal?()
        showPill?()
        Task { await processRecording(audioURL: audioURL, streamingTranscriber: streamingTranscriber) }
    }

    func cancelRecording() {
        guard case .recording = phase else { return }
        unregisterCancelHotKey?()
        resetWalkieTalkieRecordingState()
        activeRealtimeStartupTask?.cancel()
        activeRealtimeStartupTask = nil
        activeRecordingID = nil
        let streamingTranscriber = activeStreamingTranscriber
        activeStreamingTranscriber = nil
        let audioURL = audioRecorder.stop()
        realtimeAudioSink.clear()
        if let streamingTranscriber {
            Task { await streamingTranscriber.cancel() }
        }
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        TranscriptArchiveStore.deleteDraft(activeArchiveDraft)
        activeArchiveDraft = nil
        session = .empty
        showRawTranscript = false
        phase = .idle
        statusMessage = "Recording cancelled."
        hideProcessingSignal?()
        hidePill?()
    }

    func copyDisplayText() {
        copyToPasteboard(displayText)
        statusMessage = "Copied."
    }

    func pasteDisplayText() {
        let text = displayText
        copyToPasteboard(text)
        do {
            try AccessibilityPasteController.paste(text: text)
            statusMessage = "Pasted."
        } catch {
            statusMessage = "Copied. Enable Accessibility for AutoImproveRecorder in System Settings to paste automatically."
        }
    }

    func rerunImprove() {
        guard canRerunImprove else { return }
        Task { await improveCurrentTranscript(force: true) }
    }

    func updateDisplayText(_ text: String) {
        if showRawTranscript {
            session.rawTranscript = text
        } else {
            session.improvedText = text
        }
        persistTranscriptArchive(transcriptionEngineName: nil)
    }

    func openSettings() {
        showSettings?()
    }

    func copyOpenAIRealtimeDiagnostics() {
        guard let diagnostics = lastOpenAIRealtimeDiagnostics else { return }
        copyToPasteboard(diagnostics.details.isEmpty ? diagnostics.summary : diagnostics.details)
        statusMessage = "Copied OpenAI diagnostics."
    }

    private func startRecordingFlow(requestedAt: Date) async {
        defer { isStartingRecording = false }
        activeArchiveDraft = nil

        do {
            try await AudioRecorder.requestMicrophonePermission()
            logRecordingStartup("microphone permission ready", requestedAt: requestedAt)

            let recordingID = UUID()
            let archiveDraft = try TranscriptArchiveStore.prepareRecording(createdAt: requestedAt)
            activeArchiveDraft = archiveDraft
            let shouldPrepareRealtime = transcriptionMode == .fastest
            let shouldBufferRealtimeAudio = shouldPrepareRealtime &&
                !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            realtimeAudioSink.reset(bufferPendingAudio: shouldBufferRealtimeAudio)
            let audioURL: URL
            let audioSink = realtimeAudioSink
            do {
                audioURL = try audioRecorder.start(
                    at: archiveDraft.audioURL,
                    bufferSize: 1024,
                    streamHandler: { buffer in
                        audioSink.appendAudioBuffer(buffer)
                    },
                    onFirstBuffer: {
                        NSLog(
                            "Recording startup: first audio buffer after %.3fs.",
                            Date().timeIntervalSince(requestedAt)
                        )
                    }
                )
            } catch {
                realtimeAudioSink.clear()
                throw error
            }
            activeRecordingID = recordingID
            session = TranscriptSession(audioURL: audioURL, rawTranscript: "", improvedText: "", message: nil, improveFailed: false)
            showRawTranscript = false
            if shouldPrepareRealtime {
                statusMessage = shouldBufferRealtimeAudio
                    ? "Recording. Preparing OpenAI realtime transcription."
                    : "Recording for Parakeet fallback."
            } else {
                statusMessage = nil
            }
            phase = .recording(audioURL)
            registerCancelHotKey?()
            finishWalkieTalkieStartIfNeeded()
            guard case .recording = phase else { return }
            showPill?()
            logRecordingStartup("audio engine started and recording UI shown", requestedAt: requestedAt)

            if shouldPrepareRealtime {
                activeRealtimeStartupTask = Task { [weak self] in
                    await self?.prepareRealtimeTranscriberForActiveRecording(
                        recordingID: recordingID,
                        requestedAt: requestedAt
                    )
                }
            }
        } catch {
            TranscriptArchiveStore.deleteDraft(activeArchiveDraft)
            activeRecordingID = nil
            activeRealtimeStartupTask = nil
            activeArchiveDraft = nil
            realtimeAudioSink.clear()
            resetWalkieTalkieRecordingState()
            failWithMessage(error.localizedDescription)
        }
    }

    private func finishWalkieTalkieStartIfNeeded() {
        guard recordingTriggerMode == .walkieTalkie, activeWalkieTalkieRecording else { return }
        registerWalkieTalkieLatchHotKey?()
        if !walkieTalkieKeyIsDown && !walkieTalkieRecordingLatched {
            stopRecording()
        }
    }

    private func stopUnlatchedWalkieTalkieRecordingIfNeeded() {
        guard activeWalkieTalkieRecording, !walkieTalkieRecordingLatched else { return }
        if isRecording {
            stopRecording()
        }
    }

    private func resetWalkieTalkieRecordingState() {
        activeWalkieTalkieRecording = false
        walkieTalkieRecordingLatched = false
        unregisterWalkieTalkieLatchHotKey?()
    }

    private func prepareRealtimeTranscriberForActiveRecording(recordingID: UUID, requestedAt: Date) async {
        let streamingTranscriber = await prepareStreamingTranscriberIfNeeded()

        guard !Task.isCancelled,
              activeRecordingID == recordingID,
              case .recording = phase else {
            if let streamingTranscriber {
                await streamingTranscriber.cancel()
            }
            return
        }

        activeRealtimeStartupTask = nil
        guard let streamingTranscriber else {
            realtimeAudioSink.discardPendingAudio()
            return
        }

        activeStreamingTranscriber = streamingTranscriber
        let replayedBufferCount = realtimeAudioSink.setTranscriber(streamingTranscriber)
        statusMessage = "Recording with OpenAI realtime transcription."
        NSLog(
            "Recording startup: OpenAI realtime ready after %.3fs; replayed %d buffered audio buffers.",
            Date().timeIntervalSince(requestedAt),
            replayedBufferCount
        )
    }

    private func processRecording(audioURL: URL, streamingTranscriber: OpenAIRealtimeTranscriber?) async {
        do {
            let result = try await transcribe(audioURL: audioURL, streamingTranscriber: streamingTranscriber)
            session.rawTranscript = result.text
            session.improvedText = ""
            session.message = nil
            session.improveFailed = false
            persistTranscriptArchive(transcriptionEngineName: result.engineName)

            switch autoImproveMode {
            case .off:
                phase = .ready
                showRawTranscript = true
                statusMessage = "Showing raw transcript."
                finishProcessing()
            case .manual:
                phase = .ready
                showRawTranscript = true
                statusMessage = "Transcript ready."
                finishProcessing()
            case .automatic:
                if wordCount(result.text) >= thresholdWords {
                    // Pipeline scheduling win: signal "transcript captured" the
                    // instant raw text is in hand so the user sees the first
                    // useful result immediately, while the improve roundtrip
                    // is still in flight. The improve completion path still
                    // owns the final paste/clipboard delivery.
                    flashReadySignal?()
                    await improveCurrentTranscript(force: false)
                } else {
                    phase = .ready
                    showRawTranscript = true
                    statusMessage = "Transcript ready."
                    finishProcessing()
                }
            }
        } catch {
            session = TranscriptSession(
                audioURL: audioURL,
                rawTranscript: "",
                improvedText: "",
                message: error.localizedDescription,
                improveFailed: false
            )
            persistTranscriptArchive(transcriptionEngineName: nil)
            phase = .failed
            statusMessage = error.localizedDescription
            finishProcessing()
        }
    }

    private func prepareStreamingTranscriberIfNeeded() async -> OpenAIRealtimeTranscriber? {
        guard transcriptionMode == .fastest else { return nil }

        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let reason = "Fastest mode needs an OpenAI API key. Falling back to Parakeet."
            recordOpenAIRealtimeDiagnostics(OpenAIRealtimeDiagnostics(summary: reason, details: reason))
            statusMessage = reason
            return nil
        }

        let transcriber = OpenAIRealtimeTranscriber(apiKey: apiKey)
        do {
            try await transcriber.start()
            return transcriber
        } catch {
            let summary = "OpenAI streaming unavailable; falling back to Parakeet. \(error.localizedDescription)"
            let diagnostics = await transcriber.diagnostics(summary: summary)
            recordOpenAIRealtimeDiagnostics(diagnostics)
            statusMessage = "OpenAI streaming unavailable; falling back to Parakeet."
            NSLog("OpenAI realtime transcription start failed: \(diagnostics.details)")
            await transcriber.cancel()
            return nil
        }
    }

    private func transcribe(audioURL: URL, streamingTranscriber: OpenAIRealtimeTranscriber?) async throws -> TranscriptionResult {
        let startedAt = Date()

        if transcriptionMode == .openAIAPI {
            return try await transcribeWithOpenAIAPI(audioURL: audioURL, startedAt: startedAt)
        }

        if transcriptionMode == .localWhisper {
            return try await transcribeWithLocalWhisper(audioURL: audioURL, startedAt: startedAt)
        }

        if transcriptionMode == .appleLocal {
            return try await transcribeWithAppleLocal(audioURL: audioURL, startedAt: startedAt)
        }

        if transcriptionMode == .fastest, let streamingTranscriber {
            do {
                let result = try await streamingTranscriber.finish()
                let elapsed = Date().timeIntervalSince(startedAt)
                if shouldVerifyRealtimeTranscript(result.text) {
                    let reason = "OpenAI realtime returned a suspiciously short transcript (‘\(result.text)’); using OpenAI API transcription instead."
                    recordOpenAIRealtimeDiagnostics(await streamingTranscriber.diagnostics(summary: reason))
                    NSLog(reason)
                    statusMessage = "Realtime transcript looked wrong; using OpenAI API."
                    return try await transcribeWithOpenAIAPI(audioURL: audioURL, startedAt: Date())
                }
                statusMessage = String(format: "OpenAI transcript ready in %.1fs.", elapsed)
                return result
            } catch {
                let summary = "OpenAI streaming failed; falling back to OpenAI API. \(error.localizedDescription)"
                let diagnostics = await streamingTranscriber.diagnostics(summary: summary)
                recordOpenAIRealtimeDiagnostics(diagnostics)
                NSLog("OpenAI realtime transcription finalize failed; falling back to OpenAI API: \(diagnostics.details)")
                statusMessage = "OpenAI streaming failed; using OpenAI API."
                return try await transcribeWithOpenAIAPI(audioURL: audioURL, startedAt: Date())
            }
        } else if transcriptionMode == .fastest {
            statusMessage = "Fastest unavailable; falling back to Parakeet."
        }

        let fallbackStartedAt = Date()
        let transcriber = ParakeetTranscriber(
            pythonPath: parakeetRuntimePath,
            scriptPath: parakeetScriptPath,
            cachePath: parakeetCachePath
        )
        let result = try await transcriber.transcribe(audioURL: audioURL)
        let elapsed = Date().timeIntervalSince(fallbackStartedAt)
        NSLog("Parakeet transcription finished in %.2fs via fallback/local mode.", elapsed)
        statusMessage = String(format: "Parakeet transcript ready in %.1fs.", elapsed)
        return result
    }

    private func transcribeWithOpenAIAPI(audioURL: URL, startedAt: Date) async throws -> TranscriptionResult {
        statusMessage = "Transcribing with OpenAI API."
        let transcriber = OpenAIAudioTranscriber(apiKey: apiKey)
        let result = try await transcriber.transcribe(audioURL: audioURL)
        let elapsed = Date().timeIntervalSince(startedAt)
        NSLog("OpenAI API transcription finished in %.2fs.", elapsed)
        statusMessage = String(format: "OpenAI API transcript ready in %.1fs.", elapsed)
        return result
    }

    private func transcribeWithAppleLocal(audioURL: URL, startedAt: Date) async throws -> TranscriptionResult {
        statusMessage = "Transcribing with Apple Speech."
        let result = try await AppleLocalAudioTranscriber().transcribe(audioURL: audioURL)
        let elapsed = Date().timeIntervalSince(startedAt)
        NSLog("Apple Speech transcription finished in %.2fs.", elapsed)
        statusMessage = String(format: "Apple Speech transcript ready in %.1fs.", elapsed)
        return result
    }

    private func transcribeWithLocalWhisper(audioURL: URL, startedAt: Date) async throws -> TranscriptionResult {
        statusMessage = "Transcribing with local Whisper."
        let result = try await WhisperCppTranscriber().transcribe(audioURL: audioURL)
        let elapsed = Date().timeIntervalSince(startedAt)
        NSLog("whisper.cpp transcription finished in %.2fs.", elapsed)
        statusMessage = String(format: "Local Whisper transcript ready in %.1fs.", elapsed)
        return result
    }

    private func shouldVerifyRealtimeTranscript(_ text: String) -> Bool {
        let words = text
            .split { !$0.isLetter && !$0.isNumber }
            .filter { !$0.isEmpty }
        return words.count <= 2
    }

    private func improveCurrentTranscript(force: Bool) async {
        let raw = session.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        if autoImproveMode == .off && !force {
            return
        }

        phase = .improving
        statusMessage = "Improving with \(improvementMode.detailLabel)."
        showProcessingSignal?()
        showPill?()

        do {
            let engine = makeImproveEngine()
            // Progressive update path: invoke streaming improve. The engine
            // calls back with the cumulative improved text; we hop to main
            // and update session.improvedText so the preview pill / UI can
            // paint the partial result immediately. The first delta also
            // fires flashReadySignal? (see flashFirstImprovedDelta) which is
            // the user-visible "first improved character" moment.
            //
            // Paste / clipboard side-effects ONLY happen in finishProcessing()
            // after this call returns -- that guarantees no double-paste even
            // though we update session.improvedText many times during stream.
            var sawFirstDelta = false
            let improved = try await engine.improveStreaming(
                rawTranscript: raw,
                outputMode: outputMode,
                modificationStrength: cleanupStrength,
                onDelta: { [weak self] partial in
                    let firstThisDelta = !sawFirstDelta
                    sawFirstDelta = true
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // Show the partial improved text in the preview surface.
                        // Suppressing showRawTranscript flips the menu/pill onto
                        // the (still-incomplete) improved buffer.
                        self.session.improvedText = partial
                        self.showRawTranscript = false
                        if firstThisDelta {
                            // First-visible moment for streamed improvements.
                            self.flashFirstImprovedDelta()
                        }
                    }
                }
            )
            session.improvedText = improved
            session.message = nil
            session.improveFailed = false
            showRawTranscript = false
            phase = .ready
            statusMessage = "Improved text ready."
            persistTranscriptArchive(transcriptionEngineName: nil)
        } catch {
            session.improvedText = ""
            session.message = "Improve failed; showing raw transcript. \(error.localizedDescription)"
            session.improveFailed = true
            showRawTranscript = true
            phase = .ready
            statusMessage = session.message
            persistTranscriptArchive(transcriptionEngineName: nil)
        }

        finishProcessing()
    }

    /// First improved character is visible in the preview. Flash the same
    /// "ready signal" the user gets on the raw transcript path so they know
    /// improvement is underway and partial text is already onscreen. We do
    /// NOT paste here -- paste/clipboard happens once at finishProcessing()
    /// to preserve the no-double-paste guardrail.
    private func flashFirstImprovedDelta() {
        flashReadySignal?()
    }

    private func makeImproveEngine() -> any ImproveEngine {
        switch improvementMode {
        case .openAI:
            return OpenAIImproveEngine(apiKey: apiKey)
        case .geminiFlash:
            return GeminiImproveEngine(apiKey: geminiAPIKey)
        case .claudeHaiku:
            return AnthropicImproveEngine(apiKey: anthropicAPIKey)
        case .appleLocal:
            return AppleLocalImproveEngine()
        case .ollamaLocal:
            return OllamaImproveEngine(baseURL: ollamaBaseURL, model: ollamaModel)
        }
    }

    private var cleanupStrength: Int {
        switch outputMode {
        case .verbatim:
            return 1
        case .lightCleanup:
            return 2
        case .promptCleanup:
            return 3
        case .structuredTask:
            return 4
        }
    }

    private func persistTranscriptArchive(transcriptionEngineName: String?) {
        guard let archiveDraft = activeArchiveDraft ?? archiveDraftFromSession() else { return }
        let record = TranscriptArchiveRecord(
            id: archiveDraft.id,
            createdAt: archiveDraft.createdAt,
            updatedAt: Date(),
            audioPath: archiveDraft.audioURL.path,
            rawTranscript: session.rawTranscript,
            cleanedTranscript: session.improvedText,
            finalTranscript: session.preferredText,
            improveFailed: session.improveFailed,
            message: session.message ?? statusMessage,
            transcriptionMode: transcriptionMode.rawValue,
            transcriptionEngine: transcriptionEngineName,
            improvementMode: improvementMode.rawValue,
            cleanupMode: outputMode.rawValue,
            autoImproveMode: autoImproveMode.rawValue,
            thresholdWords: thresholdWords
        )
        TranscriptArchiveStore.save(record)
    }

    private func archiveDraftFromSession() -> TranscriptArchiveDraft? {
        guard let audioURL = session.audioURL else { return nil }
        let directoryURL = audioURL.deletingLastPathComponent()
        let id = directoryURL.lastPathComponent
        guard !id.isEmpty else { return nil }
        return TranscriptArchiveDraft(
            id: id,
            createdAt: Date(),
            directoryURL: directoryURL,
            audioURL: audioURL
        )
    }

    private func transcriptionStatusMessage(streamingTranscriber: OpenAIRealtimeTranscriber?) -> String {
        if streamingTranscriber != nil {
            return "Finalizing OpenAI streaming transcript."
        }

        switch transcriptionMode {
        case .localWhisper:
            return "Transcribing with local Whisper."
        case .localParakeet, .fastest:
            return "Transcribing with local Parakeet."
        case .appleLocal:
            return "Transcribing with Apple Speech."
        case .openAIAPI:
            return "Transcribing with OpenAI API."
        }
    }

    private func finishProcessing() {
        unregisterCancelHotKey?()
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            completeWithText(text)
            flashReadySignal?()
        } else {
            hideProcessingSignal?()
        }
        hidePill?()
    }

    private func completeWithText(_ text: String) {
        if AccessibilityPasteController.focusedElementAcceptsText(promptForPermission: true) {
            do {
                try AccessibilityPasteController.paste(
                    text: text,
                    leaveClipboardChanged: copyFinishedTextToClipboard,
                    submitAfterPaste: autoSubmitDetectedTextFields
                )
                if autoSubmitDetectedTextFields {
                    statusMessage = copyFinishedTextToClipboard
                        ? "Pasted, submitted, and copied to clipboard."
                        : "Pasted and submitted."
                } else {
                    statusMessage = copyFinishedTextToClipboard
                        ? "Pasted and copied to clipboard."
                        : "Pasted."
                }
                return
            } catch {
                if copyFinishedTextToClipboard {
                    copyToPasteboard(text)
                    statusMessage = "Copied. Enable Accessibility for AutoImproveRecorder in System Settings " +
                        "to paste automatically."
                } else {
                    statusMessage = "Text ready. Enable Accessibility for AutoImproveRecorder in System Settings " +
                        "to paste automatically."
                }
                return
            }
        }

        if copyFinishedTextToClipboard {
            copyToPasteboard(text)
            statusMessage = "Copied to clipboard."
        } else {
            statusMessage = "Text ready."
        }
    }

    private func completionNotificationBody() -> String {
        let raw = session.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let improved = session.improvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let wasImproved = !session.improveFailed && !raw.isEmpty && !improved.isEmpty && improved != raw

        let textFieldDestination = autoSubmitDetectedTextFields
            ? "pasted into and submitted from a focused text field"
            : "pasted into a focused text field"
        let destination = copyFinishedTextToClipboard
            ? "\(textFieldDestination) or copied to the clipboard"
            : "\(textFieldDestination) when available"

        if session.improveFailed {
            return "Improve failed, so the raw transcript is \(destination)."
        }

        if wasImproved {
            return "Improved text is \(destination)."
        }

        switch autoImproveMode {
        case .off:
            return "Raw transcript is \(destination)."
        case .manual:
            return "Transcript is \(destination). Open Preview to improve it."
        case .automatic:
            return "Transcript is \(destination)."
        }
    }

    private func failWithMessage(_ message: String) {
        unregisterCancelHotKey?()
        session.message = message
        phase = .failed
        statusMessage = message
        hideProcessingSignal?()
        hidePill?()
        showPreview?()
    }

    private func recordOpenAIRealtimeDiagnostics(_ diagnostics: OpenAIRealtimeDiagnostics) {
        guard !diagnostics.isEmpty else { return }
        lastOpenAIRealtimeDiagnostics = diagnostics
        NSLog("Last OpenAI realtime diagnostics: \(diagnostics.details)")
    }

    private func logRecordingStartup(_ message: String, requestedAt: Date) {
        NSLog("Recording startup: \(message) after %.3fs.", Date().timeIntervalSince(requestedAt))
    }

    private func saveOpenAIRealtimeDiagnostics() {
        // Pipeline scheduling: when this runs while transcribe / improve are
        // active, the synchronous UserDefaults writes show up on the critical
        // path. Defer the persistence to a background queue so the main
        // actor returns immediately. The menu refresh stays on the main actor
        // because it touches UI.
        let summary = lastOpenAIRealtimeDiagnostics?.summary ?? ""
        let details = lastOpenAIRealtimeDiagnostics?.details ?? ""
        DispatchQueue.global(qos: .utility).async {
            let defaults = UserDefaults.standard
            defaults.set(summary, forKey: Keys.lastOpenAIRealtimeErrorSummary)
            defaults.set(details, forKey: Keys.lastOpenAIRealtimeErrorDetails)
        }
        menuNeedsUpdate?()
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

private final class OpenAIRealtimeAudioSink {
    private let lock = NSLock()
    private let maxPendingSeconds = 15.0
    private var transcriber: OpenAIRealtimeTranscriber?
    private var shouldBufferPendingAudio = false
    private var isReplayingPendingAudio = false
    private var pendingBuffers: [AVAudioPCMBuffer] = []
    private var pendingFrameCount: AVAudioFramePosition = 0

    func reset(bufferPendingAudio: Bool) {
        lock.lock()
        transcriber = nil
        shouldBufferPendingAudio = bufferPendingAudio
        isReplayingPendingAudio = false
        pendingBuffers.removeAll()
        pendingFrameCount = 0
        lock.unlock()
    }

    @discardableResult
    func setTranscriber(_ transcriber: OpenAIRealtimeTranscriber) -> Int {
        lock.lock()
        self.transcriber = transcriber
        shouldBufferPendingAudio = false
        isReplayingPendingAudio = true
        var buffersToReplay = pendingBuffers
        pendingBuffers.removeAll()
        pendingFrameCount = 0
        lock.unlock()

        var replayedBufferCount = 0
        while true {
            for buffer in buffersToReplay {
                transcriber.appendAudioBuffer(buffer)
            }
            replayedBufferCount += buffersToReplay.count

            lock.lock()
            if pendingBuffers.isEmpty {
                isReplayingPendingAudio = false
                lock.unlock()
                break
            }
            buffersToReplay = pendingBuffers
            pendingBuffers.removeAll()
            pendingFrameCount = 0
            lock.unlock()
        }

        return replayedBufferCount
    }

    func appendAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        if let transcriber, !isReplayingPendingAudio {
            lock.unlock()
            transcriber.appendAudioBuffer(buffer)
            return
        }

        guard (shouldBufferPendingAudio || isReplayingPendingAudio),
              let copiedBuffer = Self.copyBuffer(buffer) else {
            lock.unlock()
            return
        }

        pendingBuffers.append(copiedBuffer)
        pendingFrameCount += AVAudioFramePosition(copiedBuffer.frameLength)
        trimPendingBuffersIfNeeded(sampleRate: copiedBuffer.format.sampleRate)
        lock.unlock()
    }

    func discardPendingAudio() {
        lock.lock()
        pendingBuffers.removeAll()
        pendingFrameCount = 0
        shouldBufferPendingAudio = false
        isReplayingPendingAudio = false
        lock.unlock()
    }

    func clear() {
        lock.lock()
        transcriber = nil
        shouldBufferPendingAudio = false
        isReplayingPendingAudio = false
        pendingBuffers.removeAll()
        pendingFrameCount = 0
        lock.unlock()
    }

    private func trimPendingBuffersIfNeeded(sampleRate: Double) {
        guard sampleRate > 0 else { return }
        let maxPendingFrames = AVAudioFramePosition(sampleRate * maxPendingSeconds)
        while pendingFrameCount > maxPendingFrames, !pendingBuffers.isEmpty {
            let removed = pendingBuffers.removeFirst()
            pendingFrameCount -= AVAudioFramePosition(removed.frameLength)
        }
    }

    private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copiedBuffer.frameLength = buffer.frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copiedBuffer.mutableAudioBufferList)

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            guard let sourceData = sourceBuffers[index].mData,
                  let destinationData = destinationBuffers[index].mData else {
                continue
            }
            let byteCount = Int(sourceBuffers[index].mDataByteSize)
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = sourceBuffers[index].mDataByteSize
        }

        return copiedBuffer
    }
}
