import AppKit
import Foundation

@MainActor
final class AutoSendDeliveryAdapter: AutoSendDeliveryService, @unchecked Sendable {
    private let settings: AutoSendSettingsStore
    private let service: ClosureDeliveryService

    init(settings: AutoSendSettingsStore) {
        self.settings = settings
        service = ClosureDeliveryService(
            contextProvider: { prompt in
                let shouldPrompt = prompt && settings.takeAccessibilityPromptOpportunity()
                return AccessibilityPasteController.currentDeliveryContext(promptForPermission: shouldPrompt)
            },
            pasteAction: { request in
                try await AccessibilityPasteController.paste(request)
            },
            copyAction: { text in
                _ = Self.copyToPasteboard(text)
            },
            productDisplayName: "Auto Send Recorder"
        )
    }

    func deliver(text: String) async throws -> AutoSendDeliveryDisposition {
        // The shared delivery service captures the authoritative AX destination
        // immediately before paste, then checks it again before sending.
        let request = DeliveryRequest(
            text: text,
            globalSettings: GlobalCompletionSettings(
                copyFinishedTextToClipboard: false,
                autoSubmitDetectedTextFields: true
            ),
            rules: settings.rules.map(Self.sharedRule),
            unknownDestinationPolicy: .suppressSend,
            sendSettlementDelayNanoseconds: 80_000_000,
            optimizationMode: .qualifiedCapabilities
        )

        let result = await service.deliver(request)
        return AutoSendDeliveryDisposition.resolving(
            Self.report(result),
            copyToClipboard: { Self.copyToPasteboard(text) }
        )
    }

    private static func report(_ result: DeliveryResult) -> AutoSendDeliveryReport {
        let outcome: AutoSendDeliveryReport.Outcome
        switch result.outcome {
        case .submitted:
            outcome = .submitted
        case .pasted:
            outcome = .pasted
        case .copied:
            outcome = .copied
        case .ready:
            outcome = .ready
        }
        return AutoSendDeliveryReport(
            outcome: outcome,
            sendWasRequested: result.policy.sendCommand != nil,
            statusMessage: result.statusMessage,
            errorSummary: result.errorSummary,
            accessibilityTrusted: result.context.accessibilityTrusted
        )
    }

    private static func copyToPasteboard(_ text: String) -> Bool {
        AutoSendPasteboardWriter.write(text)
    }

    private static func sharedRule(_ rule: AutoSendAppRule) -> AppDeliveryRule {
        let submitBehavior: SubmitBehavior
        switch rule.action {
        case .enter:
            submitBehavior = .always
        case .commandEnter:
            submitBehavior = .commandEnter
        case .doNotSend:
            submitBehavior = .never
        }
        return AppDeliveryRule(
            id: UUID(),
            appName: rule.appName,
            bundleIdentifier: rule.bundleIdentifier,
            isEnabled: true,
            pasteBehavior: .followDefault,
            submitBehavior: submitBehavior,
            clipboardBehavior: .doNotCopy
        )
    }
}
