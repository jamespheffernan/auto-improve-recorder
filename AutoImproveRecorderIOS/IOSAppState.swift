import Foundation
import UIKit

enum IOSProcessingMode: String, CaseIterable, Identifiable {
    case openAI
    case appleLocal
    case localTranscriptionOpenAIImprove

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .appleLocal:
            return "Apple local"
        case .localTranscriptionOpenAIImprove:
            return "Local transcription + cloud improve"
        }
    }
}

struct IOSTranscriptHistoryItem: Identifiable, Codable, Equatable {
    let id: UUID
    var createdAt: Date
    var rawTranscript: String
    var improvedText: String
    var improveFailed: Bool

    var preferredText: String {
        if !improvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return improvedText
        }
        return rawTranscript
    }
}

@MainActor
final class IOSAppState: ObservableObject {
    @Published var phase: RecorderPhase = .idle
    @Published var session: TranscriptSession = .empty
    @Published var statusMessage: String?
    @Published var showRawTranscript = false
    @Published var history: [IOSTranscriptHistoryItem] = [] {
        didSet { saveHistory() }
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
    @Published var improvementMode: ImprovementMode = .openAI {
        didSet { defaults.set(improvementMode.rawValue, forKey: Keys.improvementMode) }
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
    @Published var copyFinishedTextToClipboard: Bool = true {
        didSet { defaults.set(copyFinishedTextToClipboard, forKey: Keys.copyFinishedTextToClipboard) }
    }
    @Published var processingMode: IOSProcessingMode = .openAI {
        didSet { defaults.set(processingMode.rawValue, forKey: Keys.processingMode) }
    }

    private let defaults = UserDefaults.standard
    // Lazy: AudioRecorder()'s `AVAudioEngine()` allocation is heavy. Defer it until
    // first use (record tap or audio session warmup) so it doesn't block app cold start.
    private lazy var audioRecorder = AudioRecorder()
    private var currentHistoryID: UUID?
    private var recordingStartupTask: Task<Void, Never>?
    private var recordingEngineReady = false
    private var stopWhenEngineIsReady = false

    private enum Keys {
        static let processingMode = "iosProcessingMode"
        static let improvementMode = "iosImprovementMode"
        static let autoImproveMode = "iosAutoImproveMode"
        static let thresholdWords = "iosThresholdWords"
        static let modificationStrength = "iosModificationStrength"
        static let outputMode = "iosOutputMode"
        static let copyFinishedTextToClipboard = "iosCopyFinishedTextToClipboard"
        static let history = "iosTranscriptHistory"
    }

    init() {
        apiKey = KeychainStore.loadOpenAIAPIKey() ?? ""
        geminiAPIKey = KeychainStore.loadGeminiAPIKey() ?? ""
        anthropicAPIKey = KeychainStore.loadAnthropicAPIKey() ?? ""
        processingMode = IOSProcessingMode(rawValue: defaults.string(forKey: Keys.processingMode) ?? "") ?? .openAI
        improvementMode = ImprovementMode(rawValue: defaults.string(forKey: Keys.improvementMode) ?? "") ?? .openAI
        if improvementMode == .ollamaLocal {
            improvementMode = .openAI
        }
        autoImproveMode = AutoImproveMode(rawValue: defaults.string(forKey: Keys.autoImproveMode) ?? "") ?? .automatic
        let savedThreshold = defaults.integer(forKey: Keys.thresholdWords)
        thresholdWords = savedThreshold > 0 ? savedThreshold : 75
        let savedStrength = defaults.integer(forKey: Keys.modificationStrength)
        modificationStrength = savedStrength > 0 ? min(max(savedStrength, 1), 5) : 2
        outputMode = OutputMode(rawValue: defaults.string(forKey: Keys.outputMode) ?? "") ?? .lightCleanup
        if defaults.object(forKey: Keys.copyFinishedTextToClipboard) == nil {
            copyFinishedTextToClipboard = true
        } else {
            copyFinishedTextToClipboard = defaults.bool(forKey: Keys.copyFinishedTextToClipboard)
        }
        history = loadHistory()
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

    var canCopy: Bool {
        !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canRerunImprove: Bool {
        !session.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !phase.isBusy
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
        let requestedAt = Date()
        let audioURL = AudioRecorder.makeRecordingURL()
        session = TranscriptSession(
            audioURL: audioURL,
            rawTranscript: "",
            improvedText: "",
            message: nil,
            improveFailed: false,
            dictionarySnapshot: ""
        )
        currentHistoryID = nil
        showRawTranscript = false
        recordingEngineReady = false
        stopWhenEngineIsReady = false
        phase = .recording(audioURL)
        statusMessage = "Recording."
        recordingStartupTask?.cancel()
        recordingStartupTask = nil

        if AudioRecorder.hasMicrophonePermission {
            do {
                try armRecorder(at: audioURL, requestedAt: requestedAt)
                recordingEngineReady = true
            } catch {
                recordingEngineReady = false
                failWithMessage(error.localizedDescription)
            }
        } else {
            recordingStartupTask = Task { await startRecordingFlow(audioURL: audioURL, requestedAt: requestedAt) }
        }
    }

    func stopRecording() {
        guard case .recording(let activeURL) = phase else { return }
        guard recordingEngineReady else {
            stopWhenEngineIsReady = true
            statusMessage = "Stopping."
            return
        }
        completeStopRecording(fallbackURL: activeURL)
    }

    func prepareForFastRecordingStart() {
        guard AudioRecorder.hasMicrophonePermission else { return }
        // Run off the main actor so the brief HAL-priming wait does not block UI.
        let recorder = audioRecorder
        Task.detached(priority: .userInitiated) {
            recorder.prepareForFastStartIfAuthorized()
        }
    }

    func releaseFastRecordingResourcesIfIdle() {
        guard !isRecording else { return }
        audioRecorder.releaseWarmResources()
    }

    private func completeStopRecording(fallbackURL: URL) {
        recordingStartupTask?.cancel()
        recordingStartupTask = nil
        recordingEngineReady = false
        stopWhenEngineIsReady = false

        let audioURL = audioRecorder.stop() ?? fallbackURL
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            failWithMessage("Recording stopped before an audio file was created.")
            return
        }

        phase = .transcribing
        statusMessage = "Transcribing with OpenAI."
        Task { await processRecording(audioURL: audioURL) }
    }

    func copyDisplayText() {
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        statusMessage = "Copied."
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
        persistCurrentSessionToHistory()
    }

    func copyHistoryItem(_ item: IOSTranscriptHistoryItem, useRaw: Bool) {
        let text = historyText(for: item, useRaw: useRaw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        statusMessage = "Copied from history."
    }

    func restoreHistoryItem(_ item: IOSTranscriptHistoryItem, useRaw: Bool) {
        session = TranscriptSession(
            audioURL: nil,
            rawTranscript: item.rawTranscript,
            improvedText: item.improvedText,
            message: nil,
            improveFailed: item.improveFailed,
            dictionarySnapshot: ""
        )
        showRawTranscript = useRaw
        phase = .ready
        currentHistoryID = item.id
        statusMessage = "Loaded from history."
    }

    func deleteHistoryItem(_ item: IOSTranscriptHistoryItem) {
        history.removeAll { $0.id == item.id }
        if currentHistoryID == item.id {
            currentHistoryID = nil
        }
        statusMessage = "Removed from history."
    }

    func historyText(for item: IOSTranscriptHistoryItem, useRaw: Bool) -> String {
        if useRaw {
            return item.rawTranscript
        }
        return item.preferredText
    }

    private func armRecorder(at audioURL: URL, requestedAt: Date) throws {
        _ = try audioRecorder.start(
            at: audioURL,
            onFirstBuffer: {
                NSLog(
                    "iOS recording startup: first audio buffer after %.3fs.",
                    Date().timeIntervalSince(requestedAt)
                )
            }
        )
    }

    private func startRecordingFlow(audioURL: URL, requestedAt: Date) async {
        do {
            try await AudioRecorder.requestMicrophonePermission()
            try armRecorder(at: audioURL, requestedAt: requestedAt)
            recordingEngineReady = true
            statusMessage = "Recording."
            if stopWhenEngineIsReady {
                completeStopRecording(fallbackURL: audioURL)
            }
        } catch {
            recordingStartupTask = nil
            recordingEngineReady = false
            stopWhenEngineIsReady = false
            failWithMessage(error.localizedDescription)
        }
    }

    private func processRecording(audioURL: URL) async {
        do {
            let transcriber = makeTranscriber()
            let result = try await transcriber.transcribe(audioURL: audioURL)
            session.rawTranscript = result.text
            session.improvedText = ""
            session.message = nil
            session.improveFailed = false

            switch autoImproveMode {
            case .off:
                phase = .ready
                showRawTranscript = true
                statusMessage = "Raw transcript ready."
                finishProcessing()
            case .manual:
                phase = .ready
                showRawTranscript = true
                statusMessage = "Transcript ready."
                finishProcessing()
            case .automatic:
                if wordCount(result.text) >= thresholdWords {
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
                improveFailed: false,
                dictionarySnapshot: ""
            )
            phase = .failed
            statusMessage = error.localizedDescription
        }
    }

    private func makeTranscriber() -> any TranscriptionEngine {
        switch processingMode {
        case .openAI:
            return OpenAIAudioTranscriber(apiKey: apiKey)
        case .appleLocal, .localTranscriptionOpenAIImprove:
            return AppleLocalAudioTranscriber()
        }
    }

    private func improveCurrentTranscript(force: Bool) async {
        let raw = session.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if autoImproveMode == .off && !force {
            return
        }

        phase = .improving
        statusMessage = processingMode == .appleLocal
            ? "Improving with Apple local model."
            : "Improving with \(improvementMode.detailLabel)."

        do {
            let engine = makeImproveEngine()
            // Progressive update path: see AppState.swift (macOS) for the
            // protocol / no-double-paste contract. Mirror it here so iOS gets
            // the same first-visible-character speedup. iOS has no paste
            // side-effect, so updating session.improvedText each delta is
            // safe.
            var sawFirstDelta = false
            let improved = try await engine.improveStreaming(
                rawTranscript: raw,
                outputMode: outputMode,
                modificationStrength: cleanupStrength,
                dictionarySnapshot: "",
                onDelta: { [weak self] partial in
                    let firstThisDelta = !sawFirstDelta
                    sawFirstDelta = true
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.session.improvedText = partial
                        self.showRawTranscript = false
                        _ = firstThisDelta // reserved for future first-visible signal
                    }
                }
            )
            session.improvedText = improved
            session.message = nil
            session.improveFailed = false
            showRawTranscript = false
            phase = .ready
            statusMessage = "Improved text ready."
        } catch {
            session.improvedText = ""
            session.message = "Improve failed; showing raw transcript. \(error.localizedDescription)"
            session.improveFailed = true
            showRawTranscript = true
            phase = .ready
            statusMessage = session.message
        }

        finishProcessing()
    }

    private func makeImproveEngine() -> any ImproveEngine {
        switch processingMode {
        case .appleLocal:
            return AppleLocalImproveEngine()
        case .openAI, .localTranscriptionOpenAIImprove:
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
                return UnavailableImproveEngine(message: "Ollama local improvement is only available in the macOS app.")
            }
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

    private func finishProcessing() {
        let text = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        persistCurrentSessionToHistory()
        if copyFinishedTextToClipboard {
            UIPasteboard.general.string = text
            statusMessage = "Copied to clipboard."
        }
    }

    private func persistCurrentSessionToHistory() {
        let raw = session.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let improved = session.improvedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty || !improved.isEmpty else { return }

        let id = currentHistoryID ?? UUID()
        currentHistoryID = id
        let createdAt = history.first { $0.id == id }?.createdAt ?? Date()

        let item = IOSTranscriptHistoryItem(
            id: id,
            createdAt: createdAt,
            rawTranscript: session.rawTranscript,
            improvedText: session.improvedText,
            improveFailed: session.improveFailed
        )

        history.removeAll { $0.id == id }
        history.insert(item, at: 0)
        if history.count > 50 {
            history = Array(history.prefix(50))
        }
    }

    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Keys.history)
    }

    private func loadHistory() -> [IOSTranscriptHistoryItem] {
        guard let data = defaults.data(forKey: Keys.history),
              let items = try? JSONDecoder().decode([IOSTranscriptHistoryItem].self, from: data)
        else {
            return []
        }
        return items
    }

    private func failWithMessage(_ message: String) {
        phase = .failed
        statusMessage = message
        session.message = message
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

private struct UnavailableImproveEngine: ImproveEngine {
    let message: String

    func improve(
        rawTranscript: String,
        outputMode: OutputMode,
        modificationStrength: Int,
        dictionarySnapshot: String
    ) async throws -> String {
        throw ImproveEngineError.localProviderUnavailable(provider: "Ollama", message: message)
    }
}
