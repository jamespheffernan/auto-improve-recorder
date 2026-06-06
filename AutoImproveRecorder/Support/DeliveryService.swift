import Foundation

struct DeliveryRequest: Equatable {
    var text: String
    var globalSettings: GlobalCompletionSettings
    var rules: [AppDeliveryRule]
}

enum DeliveryOutcome: Equatable {
    case pasted
    case submitted
    case copied
    case ready
}

struct DeliveryResult: Equatable {
    var outcome: DeliveryOutcome
    var statusMessage: String
    var context: DeliveryContext
    var policy: ResolvedDeliveryPolicy
    var errorSummary: String?
}

protocol DeliveryService {
    func focusedContext(promptForPermission: Bool) -> DeliveryContext
    func copy(_ text: String)
    func pasteManually(_ text: String) throws
    func deliver(_ request: DeliveryRequest) -> DeliveryResult
}

struct ClosureDeliveryService: DeliveryService {
    typealias ContextProvider = (_ promptForPermission: Bool) -> DeliveryContext
    typealias PasteAction = (_ text: String, _ leaveClipboardChanged: Bool, _ submitAfterPaste: Bool) throws -> Void
    typealias CopyAction = (_ text: String) -> Void

    private let contextProvider: ContextProvider
    private let pasteAction: PasteAction
    private let copyAction: CopyAction

    init(
        contextProvider: @escaping ContextProvider,
        pasteAction: @escaping PasteAction,
        copyAction: @escaping CopyAction
    ) {
        self.contextProvider = contextProvider
        self.pasteAction = pasteAction
        self.copyAction = copyAction
    }

    func focusedContext(promptForPermission: Bool) -> DeliveryContext {
        contextProvider(promptForPermission)
    }

    func copy(_ text: String) {
        copyAction(text)
    }

    func pasteManually(_ text: String) throws {
        try pasteAction(text, true, false)
    }

    func deliver(_ request: DeliveryRequest) -> DeliveryResult {
        let initialContext = focusedContext(promptForPermission: false)
        let initialPolicy = DeliveryPolicyResolver.resolve(
            context: initialContext,
            globalSettings: request.globalSettings,
            rules: request.rules
        )
        let context: DeliveryContext
        let policy: ResolvedDeliveryPolicy

        if initialPolicy.wantsPaste {
            context = focusedContext(promptForPermission: true)
            policy = DeliveryPolicyResolver.resolve(
                context: context,
                globalSettings: request.globalSettings,
                rules: request.rules
            )
        } else {
            context = initialContext
            policy = initialPolicy
        }

        if policy.shouldPaste {
            do {
                try pasteAction(
                    request.text,
                    policy.shouldCopyToClipboard,
                    policy.shouldSubmit
                )
                return DeliveryResult(
                    outcome: policy.shouldSubmit ? .submitted : .pasted,
                    statusMessage: Self.deliveryStatusMessage(for: policy),
                    context: context,
                    policy: policy,
                    errorSummary: nil
                )
            } catch {
                if policy.shouldCopyToClipboard {
                    copyAction(request.text)
                    return DeliveryResult(
                        outcome: .copied,
                        statusMessage: Self.pasteFailureStatusMessage(
                            copied: true,
                            accessibilityTrusted: context.accessibilityTrusted
                        ),
                        context: context,
                        policy: policy,
                        errorSummary: error.localizedDescription
                    )
                }

                return DeliveryResult(
                    outcome: .ready,
                    statusMessage: Self.pasteFailureStatusMessage(
                        copied: false,
                        accessibilityTrusted: context.accessibilityTrusted
                    ),
                    context: context,
                    policy: policy,
                    errorSummary: error.localizedDescription
                )
            }
        }

        if policy.shouldCopyToClipboard {
            copyAction(request.text)
            return DeliveryResult(
                outcome: .copied,
                statusMessage: Self.copyOnlyStatusMessage(for: policy),
                context: context,
                policy: policy,
                errorSummary: nil
            )
        }

        return DeliveryResult(
            outcome: .ready,
            statusMessage: Self.readyOnlyStatusMessage(for: policy),
            context: context,
            policy: policy,
            errorSummary: nil
        )
    }

    private static func deliveryStatusMessage(for policy: ResolvedDeliveryPolicy) -> String {
        if policy.shouldSubmit {
            return policy.shouldCopyToClipboard
                ? "Pasted, submitted, and copied to clipboard."
                : "Pasted and submitted."
        }

        if policy.submitWasSuppressedByRule, let appName = policy.matchedRule?.appName {
            return policy.shouldCopyToClipboard
                ? "Pasted and copied. Auto-submit is off for \(appName)."
                : "Pasted. Auto-submit is off for \(appName)."
        }

        return policy.shouldCopyToClipboard
            ? "Pasted and copied to clipboard."
            : "Pasted."
    }

    private static func pasteFailureStatusMessage(copied: Bool, accessibilityTrusted: Bool) -> String {
        let prefix = copied ? "Copied." : "Text ready."
        if accessibilityTrusted {
            return "\(prefix) Could not paste automatically."
        }

        return "\(prefix) Enable Accessibility for AutoImproveRecorder in System Settings to paste automatically."
    }

    private static func copyOnlyStatusMessage(for policy: ResolvedDeliveryPolicy) -> String {
        if !policy.wantsPaste, let appName = policy.matchedRule?.appName {
            return "Copied to clipboard. Pasting is off for \(appName)."
        }

        return "Copied to clipboard."
    }

    private static func readyOnlyStatusMessage(for policy: ResolvedDeliveryPolicy) -> String {
        if !policy.wantsPaste, let appName = policy.matchedRule?.appName {
            return "Text ready. Pasting is off for \(appName)."
        }

        return "Text ready."
    }
}
