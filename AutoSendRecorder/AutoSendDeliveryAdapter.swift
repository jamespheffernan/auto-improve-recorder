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
        switch result.outcome {
        case .submitted:
            return .sent
        case .pasted:
            return result.policy.sendCommand == nil
                ? .pastedWithoutSending
                : .sendSuppressed(result.statusMessage)
        case .copied:
            if let error = result.errorSummary {
                return result.context.accessibilityTrusted
                    ? .pasteFailed(error)
                    : .permissionRequired(result.statusMessage)
            }
            return .copied(result.statusMessage)
        case .ready:
            let clipboardWriteSucceeded = Self.copyToPasteboard(text)
            if let error = result.errorSummary {
                guard clipboardWriteSucceeded else {
                    return .pasteFailed("Could not paste or copy the transcript. \(error)")
                }
                return result.context.accessibilityTrusted
                    ? .pasteFailed("Copied to clipboard. \(error)")
                    : .permissionRequired("Copied to clipboard. \(result.statusMessage)")
            }
            return AutoSendClipboardFallback.disposition(
                accessibilityTrusted: result.context.accessibilityTrusted,
                clipboardWriteSucceeded: clipboardWriteSucceeded,
                statusMessage: result.statusMessage
            )
        }
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
