import ApplicationServices
import CoreGraphics
import Foundation

struct FocusedApp: Equatable, Hashable, Identifiable {
    let bundleIdentifier: String
    let displayName: String
    let processIdentifier: Int32?

    var id: String { bundleIdentifier }

    init(bundleIdentifier: String, displayName: String?, processIdentifier: Int32? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        let trimmedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.displayName = trimmedName.isEmpty ? bundleIdentifier : trimmedName
    }
}

struct FocusedTextTargetIdentity: Equatable {
    let rawValue: String
    private let accessibilityElement: AXUIElement?
    private let allowsElementReplacement: Bool

    init(rawValue: String) {
        self.rawValue = rawValue
        accessibilityElement = nil
        allowsElementReplacement = false
    }

    init(
        rawValue: String,
        accessibilityElement: AXUIElement,
        allowsElementReplacement: Bool = false
    ) {
        self.rawValue = rawValue
        self.accessibilityElement = accessibilityElement
        self.allowsElementReplacement = allowsElementReplacement
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        if let lhsElement = lhs.accessibilityElement,
           let rhsElement = rhs.accessibilityElement {
            if CFEqual(lhsElement, rhsElement) {
                return true
            }
            return lhs.allowsElementReplacement &&
                rhs.allowsElementReplacement &&
                lhs.rawValue == rhs.rawValue
        }

        return lhs.rawValue == rhs.rawValue
    }
}

struct FocusedTextTarget: Equatable {
    let acceptsText: Bool
    let frame: CGRect?
    let identity: FocusedTextTargetIdentity?

    init(
        acceptsText: Bool,
        frame: CGRect?,
        identity: FocusedTextTargetIdentity? = nil
    ) {
        self.acceptsText = acceptsText
        self.frame = frame
        self.identity = identity
    }
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
    case commandEnter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followDefault:
            return "Default"
        case .never:
            return "Never"
        case .always:
            return "Enter"
        case .commandEnter:
            return "Command-Enter"
        }
    }

    var sendCommand: SendCommand? {
        switch self {
        case .followDefault, .never:
            return nil
        case .always:
            return .enter
        case .commandEnter:
            return .commandEnter
        }
    }
}

enum SendCommand: String, CaseIterable, Codable, Equatable, Identifiable {
    case enter
    case commandEnter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .enter:
            return "Enter"
        case .commandEnter:
            return "Command-Enter"
        }
    }

    var keyEventDescriptor: SendKeyEventDescriptor {
        switch self {
        case .enter:
            return SendKeyEventDescriptor(virtualKey: 0x24, flags: [])
        case .commandEnter:
            return SendKeyEventDescriptor(virtualKey: 0x24, flags: .maskCommand)
        }
    }
}

struct SendKeyEventDescriptor: Equatable {
    let virtualKey: CGKeyCode
    let flags: CGEventFlags
}

struct DeliveryDestination: Equatable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let focusedTargetIdentity: FocusedTextTargetIdentity

    init?(context: DeliveryContext) {
        guard let app = context.focusedApp,
              let processIdentifier = app.processIdentifier,
              let focusedTargetIdentity = context.focusedTarget?.identity else {
            return nil
        }

        self.bundleIdentifier = app.bundleIdentifier
        self.processIdentifier = processIdentifier
        self.focusedTargetIdentity = focusedTargetIdentity
    }
}

enum UnknownDestinationPolicy: Equatable {
    case allowSend
    case suppressSend
}

enum SendSuppressionReason: Equatable {
    case destinationUnavailable
    case destinationChanged
    case focusChanged
    case focusIsNotEditable
    case deliveryCancelled
    case sendEventFailed
}

enum SendCommandExecution: Equatable {
    case notRequested
    case sent
    case suppressed(SendSuppressionReason)
}

enum DeliverySendGuard {
    static func suppressionReason(
        expectedDestination: DeliveryDestination?,
        currentContext: DeliveryContext,
        unknownDestinationPolicy: UnknownDestinationPolicy
    ) -> SendSuppressionReason? {
        guard currentContext.focusedTarget?.acceptsText == true else {
            return .focusIsNotEditable
        }

        guard let expectedDestination else {
            return unknownDestinationPolicy == .suppressSend ? .destinationUnavailable : nil
        }

        guard let currentApp = currentContext.focusedApp,
              let currentProcessIdentifier = currentApp.processIdentifier else {
            return .destinationChanged
        }

        guard currentApp.bundleIdentifier == expectedDestination.bundleIdentifier,
              currentProcessIdentifier == expectedDestination.processIdentifier else {
            return .destinationChanged
        }

        guard currentContext.focusedTarget?.identity == expectedDestination.focusedTargetIdentity else {
            return .focusChanged
        }

        return nil
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
    let sendCommand: SendCommand?
    let sendWasSuppressedByRule: Bool

    var shouldSubmit: Bool { sendCommand != nil }
    var submitWasSuppressedByRule: Bool { sendWasSuppressedByRule }
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

        let sendCommand: SendCommand?
        switch matchedRule?.submitBehavior {
        case .always:
            sendCommand = .enter
        case .commandEnter:
            sendCommand = .commandEnter
        case .never:
            sendCommand = nil
        case .followDefault, .none:
            sendCommand = globalSettings.autoSubmitDetectedTextFields ? .enter : nil
        }

        return ResolvedDeliveryPolicy(
            matchedRule: matchedRule,
            shouldCopyToClipboard: shouldCopyToClipboard,
            wantsPaste: wantsPaste,
            shouldPaste: shouldPaste,
            sendCommand: shouldPaste ? sendCommand : nil,
            sendWasSuppressedByRule: matchedRule?.submitBehavior == .never &&
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
