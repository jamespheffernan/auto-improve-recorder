import CoreGraphics
import Darwin
import XCTest
@testable import AutoImproveRecorderCore

@MainActor
final class DeliveryServiceTests: XCTestCase {
    func testLegacyDeliveryOutcomeGoldenMatrix() async {
        let service = makeService()
        let whatsAppService = makeService(
            context: Self.deliveryContext(bundleIdentifier: "net.whatsapp.WhatsApp")
        )
        let pasted = await service.deliver(request(autoSend: false))
        let submitted = await service.deliver(request(autoSend: true))
        let suppressed = await whatsAppService.deliver(
            request(autoSend: true, rules: [.whatsAppDefault])
        )

        let golden = [pasted, submitted, suppressed].map {
            "\($0.outcome)|\($0.statusMessage)|\($0.policy.sendCommand?.rawValue ?? "none")"
        }

        XCTAssertEqual(golden, [
            "pasted|Pasted and copied to clipboard.|none",
            "submitted|Pasted, submitted, and copied to clipboard.|enter",
            "pasted|Pasted and copied. Auto-submit is off for WhatsApp.|none"
        ])
    }

    func testWhatsAppRuleSuppressesSendButStillPastesAndCopies() async {
        var pasteCalls: [PasteCall] = []
        let service = makeService(
            context: Self.deliveryContext(bundleIdentifier: "net.whatsapp.WhatsApp"),
            pasteAction: { request in
                pasteCalls.append(PasteCall(
                    text: request.text,
                    leaveClipboardChanged: request.leaveClipboardChanged,
                    sendCommand: request.sendCommand,
                    destination: request.expectedDestination,
                    unknownDestinationPolicy: request.unknownDestinationPolicy,
                    settlementDelayNanoseconds: request.settlementDelayNanoseconds,
                    optimizationMode: request.optimizationMode
                ))
                return Self.pasteResult(.notRequested)
            }
        )

        let result = await service.deliver(request(text: "Hello WhatsApp.", rules: [.whatsAppDefault]))

        XCTAssertEqual(result.outcome, .pasted)
        XCTAssertNil(result.policy.sendCommand)
        XCTAssertTrue(result.policy.sendWasSuppressedByRule)
        XCTAssertEqual(result.statusMessage, "Pasted and copied. Auto-submit is off for WhatsApp.")
        XCTAssertEqual(pasteCalls.count, 1)
        XCTAssertNil(pasteCalls[0].sendCommand)
    }

    func testPasteFailureFallsBackToCopyWhenClipboardEnabled() async {
        var copiedText: [String] = []
        let service = makeService(
            context: Self.deliveryContext(accessibilityTrusted: false),
            pasteAction: { _ in throw DeliveryTestError.pasteFailed },
            copyAction: { copiedText.append($0) },
            productDisplayName: "Auto Send Recorder"
        )

        let result = await service.deliver(request(text: "Fallback text.", autoSend: false))

        XCTAssertEqual(result.outcome, .copied)
        XCTAssertEqual(
            result.statusMessage,
            "Copied. Enable Accessibility for Auto Send Recorder in System Settings to paste automatically."
        )
        XCTAssertEqual(result.errorSummary, "Paste failed")
        XCTAssertEqual(copiedText, ["Fallback text."])
    }

    func testDisabledRuleDoesNotOverrideGlobalEnterCommand() async {
        let disabledRule = rule(isEnabled: false, submitBehavior: .never)
        var receivedCommand: SendCommand?
        let service = makeService(pasteAction: { request in
            receivedCommand = request.sendCommand
            return Self.pasteResult(.sent)
        })

        let result = await service.deliver(request(rules: [disabledRule]))

        XCTAssertEqual(receivedCommand, .enter)
        XCTAssertEqual(result.outcome, .submitted)
    }

    func testDoNotPasteRuleCopiesWithoutPromptingForPermission() async {
        var prompts: [Bool] = []
        var copiedText: [String] = []
        let service = ClosureDeliveryService(
            contextProvider: { prompt in
                prompts.append(prompt)
                return Self.deliveryContext()
            },
            pasteAction: { _ in
                XCTFail("Paste must not run")
                return Self.pasteResult(.notRequested)
            },
            copyAction: { copiedText.append($0) }
        )
        let noPasteRule = rule(pasteBehavior: .doNotPaste)

        let result = await service.deliver(request(text: "Copy only.", rules: [noPasteRule]))

        XCTAssertEqual(prompts, [false])
        XCTAssertEqual(copiedText, ["Copy only."])
        XCTAssertEqual(result.outcome, .copied)
        XCTAssertEqual(result.statusMessage, "Copied to clipboard. Pasting is off for Notes.")
    }

    func testUnknownDestinationPolicyIsPassedToPasteAction() async {
        let unknownContext = DeliveryContext(
            focusedApp: FocusedApp(bundleIdentifier: "com.example.notes", displayName: "Notes"),
            focusedTarget: FocusedTextTarget(acceptsText: true, frame: nil),
            accessibilityTrusted: true
        )
        var receivedDestination: DeliveryDestination?
        var receivedPolicy: UnknownDestinationPolicy?
        let service = makeService(
            context: unknownContext,
            pasteAction: { request in
                receivedDestination = request.expectedDestination
                receivedPolicy = request.unknownDestinationPolicy
                return Self.pasteResult(.suppressed(.destinationUnavailable))
            }
        )

        let result = await service.deliver(
            request(unknownDestinationPolicy: .suppressSend)
        )

        XCTAssertNil(receivedDestination)
        XCTAssertEqual(receivedPolicy, .suppressSend)
        XCTAssertEqual(result.outcome, .pasted)
        XCTAssertEqual(
            result.statusMessage,
            "Pasted and copied. Send was suppressed because the destination could not be verified."
        )
    }

    func testSubmittedStatusWaitsForSendActionCompletion() async {
        let actionStarted = expectation(description: "Send action started")
        let allowCompletion = AsyncGate()
        let service = makeService(pasteAction: { _ in
            actionStarted.fulfill()
            await allowCompletion.wait()
            return Self.pasteResult(.sent)
        })
        let deliveryTask = Task { await service.deliver(request()) }

        await fulfillment(of: [actionStarted], timeout: 1)
        XCTAssertFalse(deliveryTask.isCancelled)
        await allowCompletion.open()
        let result = await deliveryTask.value

        XCTAssertEqual(result.outcome, .submitted)
        XCTAssertEqual(result.statusMessage, "Pasted, submitted, and copied to clipboard.")
    }

    func testCommandEnterRulePassesConfiguredCommandAndDelay() async {
        var call: PasteCall?
        let service = makeService(pasteAction: { request in
            call = PasteCall(
                text: request.text,
                leaveClipboardChanged: request.leaveClipboardChanged,
                sendCommand: request.sendCommand,
                destination: request.expectedDestination,
                unknownDestinationPolicy: request.unknownDestinationPolicy,
                settlementDelayNanoseconds: request.settlementDelayNanoseconds,
                optimizationMode: request.optimizationMode
            )
            return Self.pasteResult(.sent)
        })
        let commandRule = rule(submitBehavior: .commandEnter)

        _ = await service.deliver(
            request(rules: [commandRule], sendSettlementDelayNanoseconds: 12_000_000)
        )

        XCTAssertEqual(call?.sendCommand, .commandEnter)
        XCTAssertEqual(call?.settlementDelayNanoseconds, 12_000_000)
        XCTAssertEqual(call?.optimizationMode, .legacyOnly)
    }

    func testContextAndPasteActionsRunOnMainThread() async {
        var contextRanOnMainThread = false
        var pasteRanOnMainThread = false
        let service = ClosureDeliveryService(
            contextProvider: { _ in
                contextRanOnMainThread = pthread_main_np() == 1
                return Self.deliveryContext()
            },
            pasteAction: { request in
                pasteRanOnMainThread = pthread_main_np() == 1
                return Self.pasteResult(request.sendCommand == nil ? .notRequested : .sent)
            },
            copyAction: { _ in }
        )

        _ = await service.deliver(request())

        XCTAssertTrue(contextRanOnMainThread)
        XCTAssertTrue(pasteRanOnMainThread)
    }

    private func makeService(
        context: DeliveryContext? = nil,
        pasteAction: @escaping ClosureDeliveryService.PasteAction = { request in
            PasteExecutionResult(
                sendExecution: request.sendCommand == nil ? .notRequested : .sent,
                strategy: .legacyClipboardPaste,
                fallback: .optimizationDisabled,
                timing: .zero
            )
        },
        copyAction: @escaping ClosureDeliveryService.CopyAction = { _ in },
        productDisplayName: String = "AutoImproveRecorder"
    ) -> ClosureDeliveryService {
        ClosureDeliveryService(
            contextProvider: { _ in context ?? Self.deliveryContext() },
            pasteAction: pasteAction,
            copyAction: copyAction,
            productDisplayName: productDisplayName
        )
    }

    private func request(
        text: String = "Send this.",
        autoSend: Bool = true,
        rules: [AppDeliveryRule] = [],
        unknownDestinationPolicy: UnknownDestinationPolicy = .allowSend,
        sendSettlementDelayNanoseconds: UInt64 = 80_000_000
    ) -> DeliveryRequest {
        DeliveryRequest(
            text: text,
            globalSettings: GlobalCompletionSettings(
                copyFinishedTextToClipboard: true,
                autoSubmitDetectedTextFields: autoSend
            ),
            rules: rules,
            unknownDestinationPolicy: unknownDestinationPolicy,
            sendSettlementDelayNanoseconds: sendSettlementDelayNanoseconds
        )
    }

    private static func deliveryContext(
        bundleIdentifier: String = "com.example.notes",
        processIdentifier: Int32? = 101,
        targetIdentity: String? = "editor-1",
        accessibilityTrusted: Bool = true
    ) -> DeliveryContext {
        DeliveryContext(
            focusedApp: FocusedApp(
                bundleIdentifier: bundleIdentifier,
                displayName: bundleIdentifier == "net.whatsapp.WhatsApp" ? "WhatsApp" : "Notes",
                processIdentifier: processIdentifier
            ),
            focusedTarget: FocusedTextTarget(
                acceptsText: true,
                frame: CGRect(x: 10, y: 20, width: 300, height: 40),
                identity: targetIdentity.map(FocusedTextTargetIdentity.init(rawValue:))
            ),
            accessibilityTrusted: accessibilityTrusted
        )
    }

    private func rule(
        isEnabled: Bool = true,
        pasteBehavior: PasteBehavior = .followDefault,
        submitBehavior: SubmitBehavior = .followDefault
    ) -> AppDeliveryRule {
        AppDeliveryRule(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            appName: "Notes",
            bundleIdentifier: "com.example.notes",
            isEnabled: isEnabled,
            pasteBehavior: pasteBehavior,
            submitBehavior: submitBehavior,
            clipboardBehavior: .followDefault
        )
    }

    private struct PasteCall: Equatable {
        var text: String
        var leaveClipboardChanged: Bool
        var sendCommand: SendCommand?
        var destination: DeliveryDestination?
        var unknownDestinationPolicy: UnknownDestinationPolicy
        var settlementDelayNanoseconds: UInt64
        var optimizationMode: DeliveryOptimizationMode
    }

    private static func pasteResult(_ execution: SendCommandExecution) -> PasteExecutionResult {
        PasteExecutionResult(
            sendExecution: execution,
            strategy: .legacyClipboardPaste,
            fallback: .optimizationDisabled,
            timing: .zero
        )
    }

    private enum DeliveryTestError: LocalizedError {
        case pasteFailed

        var errorDescription: String? { "Paste failed" }
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
