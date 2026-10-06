import Combine
import Foundation

enum AutoSendTranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    case phonon2
    case parakeet

    var id: String { rawValue }
    var label: String {
        switch self {
        case .phonon2: return "Phonon-2 · Neural Engine (Default)"
        case .parakeet: return "Parakeet"
        }
    }
}

struct AutoSendShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: UInt8

    static let control = Self(rawValue: 1 << 0)
    static let option = Self(rawValue: 1 << 1)
    static let shift = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)

    static let hyper: Self = [.control, .option, .shift, .command]
    static let requiredForGlobalShortcut: Self = [.control, .option, .command]
}

struct AutoSendKeyboardShortcut: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let keyLabel: String
    let modifiers: AutoSendShortcutModifiers

    static let defaultRecording = Self(keyCode: 15, keyLabel: "R", modifiers: .hyper)
    static let defaultCancel = Self(keyCode: 53, keyLabel: "Esc", modifiers: .hyper)

    var isValidGlobalShortcut: Bool {
        !keyLabel.isEmpty && !modifiers.intersection(.requiredForGlobalShortcut).isEmpty
    }

    var displayName: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyLabel
    }
}

enum AutoSendAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case enter
    case commandEnter
    case doNotSend

    var id: String { rawValue }

    var label: String {
        switch self {
        case .enter:
            return "Enter"
        case .commandEnter:
            return "Command-Enter"
        case .doNotSend:
            return "Do not send"
        }
    }
}

enum AutoSendTriggerMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case walkieTalkie
    case toggle

    var id: String { rawValue }

    var label: String {
        switch self {
        case .walkieTalkie:
            return "Hold to talk"
        case .toggle:
            return "Press twice"
        }
    }
}

enum AutoSendMenuBarIconStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case white

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .white:
            return "White"
        }
    }
}

enum AutoSendMicrophoneSelection {
    static let boyaMicrophoneName = "BOYA mini 2"
    static let ankerMicrophoneName = "Anker PowerConf C200"
}

struct AutoSendAppRule: Codable, Equatable, Identifiable, Sendable {
    var id: String { bundleIdentifier }
    var appName: String
    var bundleIdentifier: String
    var action: AutoSendAction

    static let whatsApp = AutoSendAppRule(
        appName: "WhatsApp",
        bundleIdentifier: "net.whatsapp.WhatsApp",
        action: .doNotSend
    )
}

@MainActor
final class AutoSendSettingsStore: ObservableObject {
    nonisolated static let defaultsSuiteName = "com.turfterrace.autosendrecorder"
    private static let rulesKey = "deliveryRules"
    private static let triggerModeKey = "recordingTriggerMode"
    private static let menuBarIconStyleKey = "menuBarIconStyle"
    private static let preferredMicrophoneIDKey = "preferredMicrophoneID"
    private static let accessibilityPromptShownKey = "accessibilityPromptShown"
    private static let recordingShortcutKey = "recordingShortcut"
    private static let cancelShortcutKey = "cancelShortcut"
    private static let onboardingCompletedKey = "onboardingCompleted"
    private static let wirelessRecorderEnabledKey = "wirelessRecorderEnabled"
    private static let transcriptionModelKey = "transcriptionModel"
    @Published var transcriptionModel: AutoSendTranscriptionModel {
        didSet {
            defaults.set(transcriptionModel.rawValue, forKey: Self.transcriptionModelKey)
            transcriptionModelDidChange?(transcriptionModel)
        }
    }
    @Published var triggerMode: AutoSendTriggerMode {
        didSet { defaults.set(triggerMode.rawValue, forKey: Self.triggerModeKey) }
    }

    @Published var menuBarIconStyle: AutoSendMenuBarIconStyle {
        didSet {
            defaults.set(menuBarIconStyle.rawValue, forKey: Self.menuBarIconStyleKey)
            menuBarIconStyleDidChange?()
        }
    }

    @Published var preferredMicrophoneID: String {
        didSet {
            defaults.set(preferredMicrophoneID, forKey: Self.preferredMicrophoneIDKey)
            microphoneDidChange?(preferredMicrophoneID)
        }
    }

    @Published var wirelessRecorderEnabled: Bool {
        didSet {
            defaults.set(wirelessRecorderEnabled, forKey: Self.wirelessRecorderEnabledKey)
            wirelessRecorderDidChange?(wirelessRecorderEnabled)
        }
    }

    @Published var rules: [AutoSendAppRule] {
        didSet { saveRules() }
    }

    @Published private(set) var recordingShortcut: AutoSendKeyboardShortcut
    @Published private(set) var cancelShortcut: AutoSendKeyboardShortcut
    @Published private(set) var hasCompletedOnboarding: Bool

    var menuBarIconStyleDidChange: (() -> Void)?
    var microphoneDidChange: ((String) -> Void)?
    var shortcutsDidChange: (() -> Void)?
    var wirelessRecorderDidChange: ((Bool) -> Void)?
    var transcriptionModelDidChange: ((AutoSendTranscriptionModel) -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        // The app's own domain is already in .standard. Adding it as a suite
        // causes macOS to reject the duplicate domain. Tests use a named suite.
        self.defaults = defaults ?? Self.applicationDefaults
        transcriptionModel = self.defaults.string(forKey: Self.transcriptionModelKey)
            .flatMap(AutoSendTranscriptionModel.init(rawValue:)) ?? .phonon2
        triggerMode = self.defaults.string(forKey: Self.triggerModeKey)
            .flatMap(AutoSendTriggerMode.init(rawValue:)) ?? .walkieTalkie
        menuBarIconStyle = self.defaults.string(forKey: Self.menuBarIconStyleKey)
            .flatMap(AutoSendMenuBarIconStyle.init(rawValue:)) ?? .automatic
        preferredMicrophoneID = self.defaults.string(forKey: Self.preferredMicrophoneIDKey) ?? ""
        wirelessRecorderEnabled = self.defaults.bool(forKey: Self.wirelessRecorderEnabledKey)
        recordingShortcut = Self.shortcut(
            from: self.defaults,
            key: Self.recordingShortcutKey,
            fallback: .defaultRecording
        )
        cancelShortcut = Self.shortcut(
            from: self.defaults,
            key: Self.cancelShortcutKey,
            fallback: .defaultCancel
        )
        hasCompletedOnboarding = self.defaults.bool(forKey: Self.onboardingCompletedKey)
        guard let data = self.defaults.data(forKey: Self.rulesKey),
              let saved = try? JSONDecoder().decode([AutoSendAppRule].self, from: data) else {
            rules = [.whatsApp]
            return
        }
        rules = saved.contains(where: { $0.bundleIdentifier == AutoSendAppRule.whatsApp.bundleIdentifier })
            ? saved
            : [.whatsApp] + saved
    }

    var hasSavedMicrophonePreference: Bool {
        defaults.object(forKey: Self.preferredMicrophoneIDKey) != nil
    }

    private static var applicationDefaults: UserDefaults {
        if Bundle.main.bundleIdentifier == defaultsSuiteName { return .standard }
        return UserDefaults(suiteName: AutoSendSettingsStore.defaultsSuiteName) ?? .standard
    }

    func action(for bundleIdentifier: String) -> AutoSendAction {
        rules.first(where: { $0.bundleIdentifier == bundleIdentifier })?.action ?? .enter
    }

    func takeAccessibilityPromptOpportunity() -> Bool {
        guard !defaults.bool(forKey: Self.accessibilityPromptShownKey) else { return false }
        defaults.set(true, forKey: Self.accessibilityPromptShownKey)
        return true
    }

    func resetAccessibilityPromptOpportunity() {
        defaults.removeObject(forKey: Self.accessibilityPromptShownKey)
    }

    func updateRecordingShortcut(_ shortcut: AutoSendKeyboardShortcut) -> String? {
        updateShortcut(shortcut, other: cancelShortcut, key: Self.recordingShortcutKey) {
            recordingShortcut = shortcut
        }
    }

    func updateCancelShortcut(_ shortcut: AutoSendKeyboardShortcut) -> String? {
        updateShortcut(shortcut, other: recordingShortcut, key: Self.cancelShortcutKey) {
            cancelShortcut = shortcut
        }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        defaults.set(true, forKey: Self.onboardingCompletedKey)
    }

    func upsert(appName: String, bundleIdentifier: String, action: AutoSendAction) {
        if let index = rules.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier }) {
            rules[index].appName = appName
            rules[index].action = action
        } else {
            rules.append(AutoSendAppRule(
                appName: appName,
                bundleIdentifier: bundleIdentifier,
                action: action
            ))
            rules.sort { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
        }
    }

    func remove(at offsets: IndexSet) {
        let protected = AutoSendAppRule.whatsApp.bundleIdentifier
        for index in offsets.sorted(by: >) where rules[index].bundleIdentifier != protected {
            rules.remove(at: index)
        }
    }

    private func saveRules() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Self.rulesKey)
    }

    private func updateShortcut(
        _ shortcut: AutoSendKeyboardShortcut,
        other: AutoSendKeyboardShortcut,
        key: String,
        apply: () -> Void
    ) -> String? {
        guard shortcut.isValidGlobalShortcut else {
            return "Include Control, Option, or Command so normal typing stays available."
        }
        guard shortcut != other else {
            return "Choose a different shortcut for recording and cancelling."
        }
        guard let data = try? JSONEncoder().encode(shortcut) else {
            return "The shortcut could not be saved."
        }
        defaults.set(data, forKey: key)
        apply()
        shortcutsDidChange?()
        return nil
    }

    private static func shortcut(
        from defaults: UserDefaults,
        key: String,
        fallback: AutoSendKeyboardShortcut
    ) -> AutoSendKeyboardShortcut {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(AutoSendKeyboardShortcut.self, from: data),
              value.isValidGlobalShortcut else {
            return fallback
        }
        return value
    }
}
