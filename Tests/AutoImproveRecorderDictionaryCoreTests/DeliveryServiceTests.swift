import CoreGraphics
import XCTest
@testable import AutoImproveRecorderDictionaryCore

final class DeliveryServiceTests: XCTestCase {
    func testWhatsAppRuleSuppressesSubmitButStillPastesAndCopies() {
        var pasteCalls: [PasteCall] = []
        var copiedText: [String] = []
        let service = makeService(
            context: DeliveryContext(
                focusedApp: FocusedApp(bundleIdentifier: "net.whatsapp.WhatsApp", displayName: "WhatsApp"),
                focusedTarget: FocusedTextTarget(
                    acceptsText: true,
                    frame: CGRect(x: 10, y: 20, width: 300, height: 40)
                ),
                accessibilityTrusted: true
            ),
            pasteAction: { text, leaveClipboardChanged, submitAfterPaste in
                pasteCalls.append(PasteCall(
                    text: text,
                    leaveClipboardChanged: leaveClipboardChanged,
                    submitAfterPaste: submitAfterPaste
                ))
            },
            copyAction: { copiedText.append($0) }
        )

        let result = service.deliver(
            DeliveryRequest(
                text: "Hello WhatsApp.",
                globalSettings: GlobalCompletionSettings(
                    copyFinishedTextToClipboard: true,
                    autoSubmitDetectedTextFields: true
                ),
                rules: [.whatsAppDefault]
            )
        )

        XCTAssertEqual(result.outcome, DeliveryOutcome.pasted)
        XCTAssertEqual(result.policy.shouldSubmit, false)
        XCTAssertEqual(result.policy.submitWasSuppressedByRule, true)
        XCTAssertEqual(result.statusMessage, "Pasted and copied. Auto-submit is off for WhatsApp.")
        XCTAssertEqual(pasteCalls, [
            PasteCall(text: "Hello WhatsApp.", leaveClipboardChanged: true, submitAfterPaste: false)
        ])
        XCTAssertTrue(copiedText.isEmpty)
    }

    func testPasteFailureFallsBackToCopyWhenClipboardEnabled() {
        var copiedText: [String] = []
        let service = makeService(
            context: Self.deliveryContext(accessibilityTrusted: false),
            pasteAction: { _, _, _ in throw DeliveryTestError.pasteFailed },
            copyAction: { copiedText.append($0) }
        )

        let result = service.deliver(
            DeliveryRequest(
                text: "Fallback text.",
                globalSettings: GlobalCompletionSettings(
                    copyFinishedTextToClipboard: true,
                    autoSubmitDetectedTextFields: false
                ),
                rules: []
            )
        )

        XCTAssertEqual(result.outcome, DeliveryOutcome.copied)
        XCTAssertEqual(result.statusMessage, "Copied. Enable Accessibility for AutoImproveRecorder in System Settings to paste automatically.")
        XCTAssertEqual(result.errorSummary, DeliveryTestError.pasteFailed.localizedDescription)
        XCTAssertEqual(copiedText, ["Fallback text."])
    }

    func testDoNotPasteRuleCopiesWithAppSpecificMessage() {
        var copiedText: [String] = []
        let service = makeService(copyAction: { copiedText.append($0) })
        let rule = AppDeliveryRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            appName: "Notes",
            bundleIdentifier: "com.example.notes",
            isEnabled: true,
            pasteBehavior: .doNotPaste,
            submitBehavior: .followDefault,
            clipboardBehavior: .followDefault
        )

        let result = service.deliver(
            DeliveryRequest(
                text: "Copy only.",
                globalSettings: GlobalCompletionSettings(
                    copyFinishedTextToClipboard: true,
                    autoSubmitDetectedTextFields: true
                ),
                rules: [rule]
            )
        )

        XCTAssertEqual(result.outcome, DeliveryOutcome.copied)
        XCTAssertEqual(result.policy.wantsPaste, false)
        XCTAssertEqual(result.statusMessage, "Copied to clipboard. Pasting is off for Notes.")
        XCTAssertEqual(copiedText, ["Copy only."])
    }

    func testDoNotPasteRuleDoesNotPromptForAccessibility() {
        var promptRequests: [Bool] = []
        let service = ClosureDeliveryService(
            contextProvider: { promptForPermission in
                promptRequests.append(promptForPermission)
                return Self.deliveryContext(accessibilityTrusted: false)
            },
            pasteAction: { _, _, _ in XCTFail("Paste should not be attempted") },
            copyAction: { _ in }
        )
        let rule = AppDeliveryRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            appName: "Notes",
            bundleIdentifier: "com.example.notes",
            isEnabled: true,
            pasteBehavior: .doNotPaste,
            submitBehavior: .followDefault,
            clipboardBehavior: .followDefault
        )

        _ = service.deliver(
            DeliveryRequest(
                text: "Copy only.",
                globalSettings: GlobalCompletionSettings(
                    copyFinishedTextToClipboard: true,
                    autoSubmitDetectedTextFields: true
                ),
                rules: [rule]
            )
        )

        XCTAssertEqual(promptRequests, [false])
    }

    func testDoNotPasteAndDoNotCopyLeavesTextReady() {
        let service = makeService()
        let rule = AppDeliveryRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            appName: "Private App",
            bundleIdentifier: "com.example.notes",
            isEnabled: true,
            pasteBehavior: .doNotPaste,
            submitBehavior: .followDefault,
            clipboardBehavior: .doNotCopy
        )

        let result = service.deliver(
            DeliveryRequest(
                text: "Ready only.",
                globalSettings: GlobalCompletionSettings(
                    copyFinishedTextToClipboard: true,
                    autoSubmitDetectedTextFields: false
                ),
                rules: [rule]
            )
        )

        XCTAssertEqual(result.outcome, DeliveryOutcome.ready)
        XCTAssertEqual(result.policy.shouldCopyToClipboard, false)
        XCTAssertEqual(result.statusMessage, "Text ready. Pasting is off for Private App.")
    }

    private func makeService(
        context: DeliveryContext? = nil,
        pasteAction: @escaping ClosureDeliveryService.PasteAction = { _, _, _ in },
        copyAction: @escaping ClosureDeliveryService.CopyAction = { _ in }
    ) -> ClosureDeliveryService {
        let resolvedContext = context ?? Self.deliveryContext(accessibilityTrusted: true)
        return ClosureDeliveryService(
            contextProvider: { _ in resolvedContext },
            pasteAction: pasteAction,
            copyAction: copyAction
        )
    }

    private static func deliveryContext(accessibilityTrusted: Bool) -> DeliveryContext {
        DeliveryContext(
            focusedApp: FocusedApp(bundleIdentifier: "com.example.notes", displayName: "Notes"),
            focusedTarget: FocusedTextTarget(
                acceptsText: true,
                frame: CGRect(x: 10, y: 20, width: 300, height: 40)
            ),
            accessibilityTrusted: accessibilityTrusted
        )
    }

    private struct PasteCall: Equatable {
        var text: String
        var leaveClipboardChanged: Bool
        var submitAfterPaste: Bool
    }

    private enum DeliveryTestError: LocalizedError {
        case pasteFailed

        var errorDescription: String? {
            "Paste failed"
        }
    }
}
