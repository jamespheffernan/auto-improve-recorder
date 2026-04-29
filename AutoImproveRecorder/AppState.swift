import AppKit
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

    @Published var apiKey: String = "" {
        didSet { KeychainStore.saveOpenAIAPIKey(apiKey) }
    }
    @Published var autoImproveMode: AutoImproveMode = .automatic {
        didSet { defaults.set(autoImproveMode.rawValue, forKey: Keys.autoImproveMode) }
    }
    @Published var thresholdWords: Int = 75 {
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
    @Published var preferredMicrophoneID: String = "" {
        didSet { defaults.set(preferredMicrophoneID, forKey: Keys.preferredMicrophoneID) }
    }
    @Published var availableMicrophones: [AudioInputDevice] = AudioInputDeviceDiscovery.inputDevices()

    var showPill: (() -> Void)?
    var hidePill: (() -> Void)?
    var showPreview: (() -> Void)?
    var showSettings: (() -> Void)?
    var menuNeedsUpdate: (() -> Void)?
    var registerCancelHotKey: (() -> Void)?
    var unregisterCancelHotKey: (() -> Void)?

    private let defaults = UserDefaults.standard
    private let audioRecorder = AudioRecorder()

    private enum Keys {
        static let autoImproveMode = "autoImproveMode"
        static let thresholdWords = "thresholdWords"
        static let modificationStrength = "modificationStrength"
        static let outputMode = "outputMode"
        static let parakeetRuntimePath = "parakeetRuntimePath"
        static let parakeetScriptPath = "parakeetScriptPath"
        static let parakeetCachePath = "parakeetCachePath"
        static let preferredMicrophoneID = "preferredMicrophoneID"
    }

    private init() {
        apiKey = KeychainStore.loadOpenAIAPIKey() ?? ""
        autoImproveMode = AutoImproveMode(rawValue: defaults.string(forKey: Keys.autoImproveMode) ?? "") ?? .automatic
        let savedThreshold = defaults.integer(forKey: Keys.thresholdWords)
        thresholdWords = savedThreshold > 0 ? savedThreshold : 75
        let savedStrength = defaults.integer(forKey: Keys.modificationStrength)
        modificationStrength = savedStrength > 0 ? min(max(savedStrength, 1), 5) : 2
        outputMode = OutputMode(rawValue: defaults.string(forKey: Keys.outputMode) ?? "") ?? .lightCleanup
        preferredMicrophoneID = defaults.string(forKey: Keys.preferredMicrophoneID) ?? ""

        let detected = ParakeetRuntimeDiscovery.detect()
        parakeetRuntimePath = defaults.string(forKey: Keys.parakeetRuntimePath) ?? detected.pythonPath
        parakeetScriptPath = defaults.string(forKey: Keys.parakeetScriptPath) ?? detected.scriptPath
        parakeetCachePath = defaults.string(forKey: Keys.parakeetCachePath) ?? detected.cachePath
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

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard !phase.isBusy else { return }
        Task { await startRecordingFlow() }
    }

    func stopRecording() {
        guard case .recording = phase else { return }
        unregisterCancelHotKey?()
        guard let audioURL = audioRecorder.stop() else {
            failWithMessage("Recording stopped before an audio file was created.")
            return
        }

        phase = .transcribing
        statusMessage = "Transcribing with local Parakeet."
        showPill?()
        Task { await processRecording(audioURL: audioURL) }
    }

    func cancelRecording() {
        guard case .recording = phase else { return }
        unregisterCancelHotKey?()
        let audioURL = audioRecorder.stop()
        if let audioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        session = .empty
        showRawTranscript = false
        phase = .idle
        statusMessage = "Recording cancelled."
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

    func openSettings() {
        showSettings?()
    }

    private func startRecordingFlow() async {
        do {
            try await AudioRecorder.requestMicrophonePermission()
            let audioURL = try audioRecorder.start()
            session = TranscriptSession(audioURL: audioURL, rawTranscript: "", improvedText: "", message: nil, improveFailed: false)
            showRawTranscript = false
            statusMessage = nil
            phase = .recording(audioURL)
            registerCancelHotKey?()
            showPill?()
        } catch {
            failWithMessage(error.localizedDescription)
        }
    }

    private func processRecording(audioURL: URL) async {
        do {
            let transcriber = ParakeetTranscriber(
                pythonPath: parakeetRuntimePath,
                scriptPath: parakeetScriptPath,
                cachePath: parakeetCachePath
            )
            let result = try await transcriber.transcribe(audioURL: audioURL)
            session.rawTranscript = result.text
            session.improvedText = result.text
            session.message = nil
            session.improveFailed = false

            switch autoImproveMode {
            case .off:
                phase = .ready
                statusMessage = "Showing raw transcript."
                finishProcessing()
            case .manual:
                phase = .ready
                statusMessage = "Transcript ready."
                finishProcessing()
            case .automatic:
                if wordCount(result.text) >= thresholdWords {
                    await improveCurrentTranscript(force: false)
                } else {
                    phase = .ready
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
            phase = .failed
            statusMessage = error.localizedDescription
            finishProcessing()
        }
    }

    private func improveCurrentTranscript(force: Bool) async {
        let raw = session.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        if autoImproveMode == .off && !force {
            return
        }

        phase = .improving
        statusMessage = "Improving with gpt-5.4-mini."
        showPill?()

        do {
            let engine = OpenAIImproveEngine(apiKey: apiKey)
            let improved = try await engine.improve(
                rawTranscript: raw,
                outputMode: outputMode,
                modificationStrength: modificationStrength
            )
            session.improvedText = improved
            session.message = nil
            session.improveFailed = false
            showRawTranscript = false
            phase = .ready
            statusMessage = "Improved text ready."
        } catch {
            session.improvedText = raw
            session.message = "Improve failed; showing raw transcript. \(error.localizedDescription)"
            session.improveFailed = true
            showRawTranscript = false
            phase = .ready
            statusMessage = session.message
        }

        finishProcessing()
    }

    private func finishProcessing() {
        unregisterCancelHotKey?()
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            copyToPasteboard(text)
            statusMessage = "Copied to clipboard."
        }
        hidePill?()
    }

    private func failWithMessage(_ message: String) {
        unregisterCancelHotKey?()
        session.message = message
        phase = .failed
        statusMessage = message
        hidePill?()
        showPreview?()
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
