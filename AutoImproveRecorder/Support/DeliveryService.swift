import Foundation

struct DeliveryRequest: Equatable {
    var text: String
    var globalSettings: GlobalCompletionSettings
    var rules: [AppDeliveryRule]
    var unknownDestinationPolicy: UnknownDestinationPolicy
    var sendSettlementDelayNanoseconds: UInt64
    var optimizationMode: DeliveryOptimizationMode

    init(
        text: String,
        globalSettings: GlobalCompletionSettings,
        rules: [AppDeliveryRule],
        unknownDestinationPolicy: UnknownDestinationPolicy = .allowSend,
        sendSettlementDelayNanoseconds: UInt64 = 80_000_000,
        optimizationMode: DeliveryOptimizationMode = .legacyOnly
    ) {
        self.text = text
        self.globalSettings = globalSettings
        self.rules = rules
        self.unknownDestinationPolicy = unknownDestinationPolicy
        self.sendSettlementDelayNanoseconds = sendSettlementDelayNanoseconds
        self.optimizationMode = optimizationMode
    }
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

@MainActor
protocol DeliveryService {
    func focusedContext(promptForPermission: Bool) -> DeliveryContext
    func copy(_ text: String)
    func pasteManually(_ text: String) async throws
    func deliver(_ request: DeliveryRequest) async -> DeliveryResult
}

@MainActor
struct ClosureDeliveryService: DeliveryService {
    typealias ContextProvider = (_ promptForPermission: Bool) -> DeliveryContext
    typealias PasteAction = (PasteExecutionRequest) async throws -> PasteExecutionResult
    typealias CopyAction = (_ text: String) -> Void

    private let contextProvider: ContextProvider
    private let pasteAction: PasteAction
    private let copyAction: CopyAction
    private let productDisplayName: String

    init(
        contextProvider: @escaping ContextProvider,
        pasteAction: @escaping PasteAction,
        copyAction: @escaping CopyAction,
        productDisplayName: String = "AutoImproveRecorder"
    ) {
        self.contextProvider = contextProvider
        self.pasteAction = pasteAction
        self.copyAction = copyAction
        self.productDisplayName = productDisplayName
    }

    func focusedContext(promptForPermission: Bool) -> DeliveryContext {
        contextProvider(promptForPermission)
    }

    func copy(_ text: String) {
        copyAction(text)
    }

    func pasteManually(_ text: String) async throws {
        _ = try await pasteAction(
            PasteExecutionRequest(
                text: text,
                leaveClipboardChanged: true,
                sendCommand: nil,
                expectedDestination: nil,
                unknownDestinationPolicy: .allowSend,
                settlementDelayNanoseconds: 0
            )
        )
    }

    func deliver(_ request: DeliveryRequest) async -> DeliveryResult {
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
                let pasteResult = try await pasteAction(
                    PasteExecutionRequest(
                        text: request.text,
                        leaveClipboardChanged: policy.shouldCopyToClipboard,
                        sendCommand: policy.sendCommand,
                        expectedDestination: DeliveryDestination(context: context),
                        unknownDestinationPolicy: request.unknownDestinationPolicy,
                        settlementDelayNanoseconds: request.sendSettlementDelayNanoseconds,
                        optimizationMode: request.optimizationMode
                    )
                )
                return DeliveryResult(
                    outcome: pasteResult.sendExecution == .sent ? .submitted : .pasted,
                    statusMessage: Self.deliveryStatusMessage(
                        for: policy,
                        sendExecution: pasteResult.sendExecution
                    ),
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
                            accessibilityTrusted: context.accessibilityTrusted,
                            productDisplayName: productDisplayName
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
                        accessibilityTrusted: context.accessibilityTrusted,
                        productDisplayName: productDisplayName
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

    private static func deliveryStatusMessage(
        for policy: ResolvedDeliveryPolicy,
        sendExecution: SendCommandExecution
    ) -> String {
        if sendExecution == .sent {
            return policy.shouldCopyToClipboard
                ? "Pasted, submitted, and copied to clipboard."
                : "Pasted and submitted."
        }

        if case let .suppressed(reason) = sendExecution {
            let reasonText: String
            switch reason {
            case .destinationUnavailable:
                reasonText = "the destination could not be verified"
            case .destinationChanged, .focusChanged, .focusIsNotEditable:
                reasonText = "the destination changed"
            case .deliveryCancelled:
                reasonText = "delivery was cancelled"
            case .sendEventFailed:
                reasonText = "the send key could not be posted"
            }
            return policy.shouldCopyToClipboard
                ? "Pasted and copied. Send was suppressed because \(reasonText)."
                : "Pasted. Send was suppressed because \(reasonText)."
        }

        if policy.sendWasSuppressedByRule, let appName = policy.matchedRule?.appName {
            return policy.shouldCopyToClipboard
                ? "Pasted and copied. Auto-submit is off for \(appName)."
                : "Pasted. Auto-submit is off for \(appName)."
        }

        return policy.shouldCopyToClipboard
            ? "Pasted and copied to clipboard."
            : "Pasted."
    }

    private static func pasteFailureStatusMessage(
        copied: Bool,
        accessibilityTrusted: Bool,
        productDisplayName: String
    ) -> String {
        let prefix = copied ? "Copied." : "Text ready."
        if accessibilityTrusted {
            return "\(prefix) Could not paste automatically."
        }

        return "\(prefix) Enable Accessibility for \(productDisplayName) in System Settings to paste automatically."
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
