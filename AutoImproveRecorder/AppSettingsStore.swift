import Foundation

struct OllamaSettings: Codable, Equatable {
    var baseURL: String
    var model: String
}

struct AppSettingsSnapshot: Codable, Equatable {
    var autoImproveMode: AutoImproveMode
    var recordingTriggerMode: RecordingTriggerMode
    var recordingHotKey: RecordingHotKey
    var transcriptionMode: TranscriptionMode
    var improvementMode: ImprovementMode
    var thresholdWords: Int
    var modificationStrength: Int
    var outputMode: OutputMode
    var ollama: OllamaSettings
    var preferredMicrophoneID: String
    var completion: GlobalCompletionSettings
    var appDeliveryRules: [AppDeliveryRule]
}

enum SettingsSaveReason: Equatable {
    case general
    case recordingHotKey
    case recordingTrigger
    case appDeliveryRules
    case textField
}

protocol SettingsStore: AnyObject {
    func load() -> AppSettingsSnapshot
    func save(_ snapshot: AppSettingsSnapshot, reason: SettingsSaveReason)
    func saveDebounced(_ snapshot: AppSettingsSnapshot, reason: SettingsSaveReason)
}

final class UserDefaultsSettingsStore: SettingsStore {
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.fieldtheory.air.settings-store", qos: .utility)
    private let lock = NSLock()
    private var pendingSave: DispatchWorkItem?
    private var pendingSaveID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettingsSnapshot {
        let thresholdWords = positiveInteger(forKey: Keys.thresholdWords, fallback: 35)
        let modificationStrength = min(max(positiveInteger(forKey: Keys.modificationStrength, fallback: 2), 1), 5)
        let completion = GlobalCompletionSettings(
            copyFinishedTextToClipboard: bool(forKey: Keys.copyFinishedTextToClipboard, defaultValue: true),
            autoSubmitDetectedTextFields: defaults.bool(forKey: Keys.autoSubmitDetectedTextFields)
        )

        return AppSettingsSnapshot(
            autoImproveMode: rawValue(forKey: Keys.autoImproveMode, fallback: .automatic),
            recordingTriggerMode: rawValue(forKey: Keys.recordingTriggerMode, fallback: .walkieTalkie),
            recordingHotKey: rawValue(forKey: Keys.recordingHotKey, fallback: .defaultValue),
            transcriptionMode: transcriptionMode(forKey: Keys.transcriptionMode),
            improvementMode: rawValue(forKey: Keys.improvementMode, fallback: .ollamaLocal),
            thresholdWords: thresholdWords,
            modificationStrength: modificationStrength,
            outputMode: rawValue(forKey: Keys.outputMode, fallback: .lightCleanup),
            ollama: OllamaSettings(
                baseURL: defaults.string(forKey: Keys.ollamaBaseURL) ?? "http://127.0.0.1:11434",
                model: defaults.string(forKey: Keys.ollamaModel) ?? "qwen3.5:0.8b-mlx"
            ),
            preferredMicrophoneID: defaults.string(forKey: Keys.preferredMicrophoneID) ?? "",
            completion: completion,
            appDeliveryRules: AppDeliveryRuleStore.load(from: defaults, key: Keys.appDeliveryRules)
        )
    }

    func save(_ snapshot: AppSettingsSnapshot, reason: SettingsSaveReason) {
        lock.lock()
        pendingSave?.cancel()
        pendingSave = nil
        pendingSaveID = nil
        write(snapshot)
        lock.unlock()
    }

    func saveDebounced(_ snapshot: AppSettingsSnapshot, reason: SettingsSaveReason) {
        let saveID = UUID()
        let workItem = DispatchWorkItem { [weak self] in
            self?.writePendingSave(snapshot, id: saveID)
        }

        lock.lock()
        pendingSave?.cancel()
        pendingSave = workItem
        pendingSaveID = saveID
        lock.unlock()

        queue.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func writePendingSave(_ snapshot: AppSettingsSnapshot, id: UUID) {
        lock.lock()
        guard pendingSaveID == id else {
            lock.unlock()
            return
        }
        pendingSave = nil
        pendingSaveID = nil
        write(snapshot)
        lock.unlock()
    }

    private func write(_ snapshot: AppSettingsSnapshot) {
        defaults.set(snapshot.autoImproveMode.rawValue, forKey: Keys.autoImproveMode)
        defaults.set(snapshot.recordingTriggerMode.rawValue, forKey: Keys.recordingTriggerMode)
        defaults.set(snapshot.recordingHotKey.rawValue, forKey: Keys.recordingHotKey)
        defaults.set(snapshot.transcriptionMode.rawValue, forKey: Keys.transcriptionMode)
        defaults.set(snapshot.improvementMode.rawValue, forKey: Keys.improvementMode)
        defaults.set(snapshot.thresholdWords, forKey: Keys.thresholdWords)
        defaults.set(snapshot.modificationStrength, forKey: Keys.modificationStrength)
        defaults.set(snapshot.outputMode.rawValue, forKey: Keys.outputMode)
        defaults.set(snapshot.ollama.baseURL, forKey: Keys.ollamaBaseURL)
        defaults.set(snapshot.ollama.model, forKey: Keys.ollamaModel)
        defaults.set(snapshot.preferredMicrophoneID, forKey: Keys.preferredMicrophoneID)
        defaults.set(snapshot.completion.copyFinishedTextToClipboard, forKey: Keys.copyFinishedTextToClipboard)
        defaults.set(snapshot.completion.autoSubmitDetectedTextFields, forKey: Keys.autoSubmitDetectedTextFields)
        AppDeliveryRuleStore.save(snapshot.appDeliveryRules, to: defaults, key: Keys.appDeliveryRules)
    }

    private func positiveInteger(forKey key: String, fallback: Int) -> Int {
        let value = defaults.integer(forKey: key)
        return value > 0 ? value : fallback
    }

    private func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    private func rawValue<Value>(forKey key: String, fallback: Value) -> Value where Value: RawRepresentable, Value.RawValue == String {
        guard let rawValue = defaults.string(forKey: key),
              let value = Value(rawValue: rawValue) else {
            return fallback
        }
        return value
    }

    private func transcriptionMode(forKey key: String) -> TranscriptionMode {
        switch defaults.string(forKey: key) {
        case "localParakeet":
            // Keep the historical alias on its original one-shot path. Only a
            // missing setting opts into the new measured live recommendation.
            return .localParakeetCppRecommended
        case let rawValue?:
            return TranscriptionMode(rawValue: rawValue) ?? .localParakeetCppRecommended
        case nil:
            return defaultTranscriptionMode()
        }
    }

    private func defaultTranscriptionMode() -> TranscriptionMode {
        let liveRuntimeInstalled = RecommendedLiveTranscription.isAvailable
        let offlineFallbackInstalled = ParakeetCppTranscriber.isInstalled(variant: .recommended06B)
        return ParakeetLiveSafetyPolicy.shouldSelectByDefault(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            liveRuntimeInstalled: liveRuntimeInstalled,
            offlineFallbackInstalled: offlineFallbackInstalled
        ) ? .localParakeetStreaming : .localParakeetCppRecommended
    }

    private enum Keys {
        static let autoImproveMode = "autoImproveMode"
        static let recordingTriggerMode = "recordingTriggerMode"
        static let recordingHotKey = "recordingHotKey"
        static let transcriptionMode = "transcriptionMode"
        static let improvementMode = "improvementMode"
        static let thresholdWords = "thresholdWords"
        static let modificationStrength = "modificationStrength"
        static let outputMode = "outputMode"
        static let ollamaBaseURL = "ollamaBaseURL"
        static let ollamaModel = "ollamaModel"
        static let preferredMicrophoneID = "preferredMicrophoneID"
        static let copyFinishedTextToClipboard = "copyFinishedTextToClipboard"
        static let autoSubmitDetectedTextFields = "autoSubmitDetectedTextFields"
        static let appDeliveryRules = "appDeliveryRules.v1"
    }
}
