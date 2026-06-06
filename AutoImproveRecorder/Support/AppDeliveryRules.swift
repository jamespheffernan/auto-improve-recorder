import CoreGraphics
import Foundation

struct FocusedApp: Equatable, Hashable, Identifiable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }

    init(bundleIdentifier: String, displayName: String?) {
        self.bundleIdentifier = bundleIdentifier
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = trimmedName.isEmpty ? bundleIdentifier : trimmedName
    }
}

struct FocusedTextTarget: Equatable {
    let acceptsText: Bool
    let frame: CGRect?
}

struct DeliveryContext: Equatable {
    let focusedApp: FocusedApp?
    let focusedTarget: FocusedTextTarget?
    let accessibilityTrusted: Bool
}

enum PasteBehavior: String, CaseIterable, Codable, Identifiable {
    case followDefault
    case pasteIfPossible
    case doNotPaste

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followDefault:
            return "Default"
        case .pasteIfPossible:
            return "Paste"
        case .doNotPaste:
            return "Do not paste"
        }
    }
}

enum SubmitBehavior: String, CaseIterable, Codable, Identifiable {
    case followDefault
    case never
    case always

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followDefault:
            return "Default"
        case .never:
            return "Never"
        case .always:
            return "Always"
        }
    }
}

enum ClipboardBehavior: String, CaseIterable, Codable, Identifiable {
    case followDefault
    case copy
    case doNotCopy

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followDefault:
            return "Default"
        case .copy:
            return "Copy"
        case .doNotCopy:
            return "Do not copy"
        }
    }
}

struct AppDeliveryRule: Identifiable, Codable, Equatable {
    var id: UUID
    var appName: String
    var bundleIdentifier: String
    var isEnabled: Bool
    var pasteBehavior: PasteBehavior
    var submitBehavior: SubmitBehavior
    var clipboardBehavior: ClipboardBehavior

    static let whatsAppDefault = AppDeliveryRule(
        id: UUID(uuidString: "5F40B5BB-38F8-4DF6-B54F-8581A9230F52")!,
        appName: "WhatsApp",
        bundleIdentifier: "net.whatsapp.WhatsApp",
        isEnabled: true,
        pasteBehavior: .followDefault,
        submitBehavior: .never,
        clipboardBehavior: .followDefault
    )

    static func defaultRule(for app: FocusedApp) -> AppDeliveryRule {
        AppDeliveryRule(
            id: UUID(),
            appName: app.displayName,
            bundleIdentifier: app.bundleIdentifier,
            isEnabled: true,
            pasteBehavior: .followDefault,
            submitBehavior: .followDefault,
            clipboardBehavior: .followDefault
        )
    }
}

struct GlobalCompletionSettings: Codable, Equatable {
    let copyFinishedTextToClipboard: Bool
    let autoSubmitDetectedTextFields: Bool
}

struct ResolvedDeliveryPolicy: Equatable {
    let matchedRule: AppDeliveryRule?
    let shouldCopyToClipboard: Bool
    let wantsPaste: Bool
    let shouldPaste: Bool
    let shouldSubmit: Bool
    let submitWasSuppressedByRule: Bool
}

enum DeliveryPolicyResolver {
    static func resolve(
        context: DeliveryContext,
        globalSettings: GlobalCompletionSettings,
        rules: [AppDeliveryRule]
    ) -> ResolvedDeliveryPolicy {
        let matchedRule = matchingRule(for: context.focusedApp, in: rules)

        let shouldCopyToClipboard: Bool
        switch matchedRule?.clipboardBehavior {
        case .copy:
            shouldCopyToClipboard = true
        case .doNotCopy:
            shouldCopyToClipboard = false
        case .followDefault, .none:
            shouldCopyToClipboard = globalSettings.copyFinishedTextToClipboard
        }

        let wantsPaste: Bool
        switch matchedRule?.pasteBehavior {
        case .doNotPaste:
            wantsPaste = false
        case .followDefault, .pasteIfPossible, .none:
            wantsPaste = true
        }

        let shouldPaste = wantsPaste && context.focusedTarget?.acceptsText == true

        let wantsSubmit: Bool
        switch matchedRule?.submitBehavior {
        case .always:
            wantsSubmit = true
        case .never:
            wantsSubmit = false
        case .followDefault, .none:
            wantsSubmit = globalSettings.autoSubmitDetectedTextFields
        }

        return ResolvedDeliveryPolicy(
            matchedRule: matchedRule,
            shouldCopyToClipboard: shouldCopyToClipboard,
            wantsPaste: wantsPaste,
            shouldPaste: shouldPaste,
            shouldSubmit: shouldPaste && wantsSubmit,
            submitWasSuppressedByRule: matchedRule?.submitBehavior == .never &&
                globalSettings.autoSubmitDetectedTextFields
        )
    }

    private static func matchingRule(for app: FocusedApp?, in rules: [AppDeliveryRule]) -> AppDeliveryRule? {
        guard let bundleIdentifier = app?.bundleIdentifier else {
            return nil
        }

        return rules.first { rule in
            rule.isEnabled && rule.bundleIdentifier == bundleIdentifier
        }
    }
}

enum AppDeliveryRuleStore {
    static let defaultRules: [AppDeliveryRule] = [.whatsAppDefault]

    static func load(from defaults: UserDefaults, key: String) -> [AppDeliveryRule] {
        guard defaults.object(forKey: key) != nil else {
            return defaultRules
        }

        guard let data = defaults.data(forKey: key),
              let rules = try? JSONDecoder().decode([AppDeliveryRule].self, from: data) else {
            return defaultRules
        }

        return rules
    }

    static func save(_ rules: [AppDeliveryRule], to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(rules) else {
            return
        }

        defaults.set(data, forKey: key)
    }
}
