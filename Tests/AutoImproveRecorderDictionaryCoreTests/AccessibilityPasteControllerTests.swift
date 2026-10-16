import AppKit
import XCTest
@testable import AutoImproveRecorderCore

@MainActor
final class AccessibilityPasteControllerTests: XCTestCase {
    func testSDKEditableAttributeCanOnlyVetoTextAcceptance() {
        XCTAssertEqual(kAXIsEditableAttribute as String, "AXIsEditable")
        XCTAssertTrue(AccessibilityEditableGate.allowsText(isEditable: true))
        XCTAssertTrue(AccessibilityEditableGate.allowsText(isEditable: nil))
        XCTAssertFalse(AccessibilityEditableGate.allowsText(isEditable: false))
    }

    func testLegacyOnlyPostsOnePasteWaitsThenPostsEnter() async throws {
        let pasteboard = makePasteboard(initialText: "Original")
        let scheduler = RestorationScheduler()
        let context = deliveryContext()
        var postedDescriptors: [SendKeyEventDescriptor] = []
        var timingSamples: [DeliveryTimingSample] = []
        let dependencies = AccessibilityPasteDependencies(
            isTrusted: { _ in true },
            pasteboard: pasteboard,
            postKeyEventPair: {
                postedDescriptors.append($0)
                return true
            },
            scheduleRestoration: { operation in scheduler.append(operation) },
            currentContext: { context },
            recordTiming: { timingSamples.append($0) }
        )
        let start = DispatchTime.now().uptimeNanoseconds

        let result = try await AccessibilityPasteController.paste(
            PasteExecutionRequest(
                text: "Transcript",
                leaveClipboardChanged: true,
                sendCommand: .enter,
                expectedDestination: DeliveryDestination(context: context),
                unknownDestinationPolicy: .suppressSend,
                settlementDelayNanoseconds: 80_000_000
            ),
            dependencies: dependencies
        )
        let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - start

        XCTAssertEqual(result.sendExecution, .sent)
        XCTAssertEqual(result.strategy, .legacyClipboardPaste)
        XCTAssertEqual(result.fallback, .optimizationDisabled)
        XCTAssertGreaterThanOrEqual(wallNanoseconds, 80_000_000)
        XCTAssertEqual(postedDescriptors.count, 2)
        XCTAssertEqual(postedDescriptors[0], SendKeyEventDescriptor(virtualKey: 0x09, flags: .maskCommand))
        XCTAssertEqual(postedDescriptors[1], SendCommand.enter.keyEventDescriptor)
        XCTAssertEqual(timingSamples.map(\.phase), [.pasteEvent, .settlement, .finalGuard, .sendEvent, .total])
        XCTAssertGreaterThanOrEqual(result.timing.settlementNanoseconds, 80_000_000)
    }

    func testUnwiredQualifiedModeStillUsesSafeLegacyFallback() async throws {
        let pasteboard = makePasteboard(initialText: "Original")
        let scheduler = RestorationScheduler()
        var postCount = 0
        let dependencies = makeDependencies(
            pasteboard: pasteboard,
            scheduler: scheduler,
            onPost: { postCount += 1 }
        )

        let result = try await AccessibilityPasteController.paste(
            PasteExecutionRequest(
                text: "Transcript",
                leaveClipboardChanged: true,
                sendCommand: nil,
                expectedDestination: nil,
                unknownDestinationPolicy: .allowSend,
                settlementDelayNanoseconds: 0,
                optimizationMode: .qualifiedCapabilities
            ),
            dependencies: dependencies
        )

        XCTAssertEqual(result.strategy, .legacyClipboardPaste)
        XCTAssertEqual(result.fallback, .capabilityUnavailable)
        XCTAssertEqual(postCount, 1)
    }

    func testQualifiedModeSendsAsSoonAsPasteIsAcknowledged() async throws {
        let pasteboard = makePasteboard(initialText: "Original")
        let scheduler = RestorationScheduler()
        let context = deliveryContext()
        var postedDescriptors: [SendKeyEventDescriptor] = []
        var pastePosted = false
        let dependencies = AccessibilityPasteDependencies(
            isTrusted: { _ in true },
            pasteboard: pasteboard,
            postKeyEventPair: { descriptor in
                postedDescriptors.append(descriptor)
                if descriptor.virtualKey == 0x09 {
                    pastePosted = true
                }
                return true
            },
            scheduleRestoration: { operation in scheduler.append(operation) },
            currentContext: { context },
            recordTiming: { _ in },
            preparePasteAcknowledgement: { _ in
                PasteAcknowledgementProbe { pastePosted }
            }
        )
        let start = DispatchTime.now().uptimeNanoseconds

        let result = try await AccessibilityPasteController.paste(
            PasteExecutionRequest(
                text: "Transcript",
                leaveClipboardChanged: true,
                sendCommand: .enter,
                expectedDestination: DeliveryDestination(context: context),
                unknownDestinationPolicy: .suppressSend,
                settlementDelayNanoseconds: 80_000_000,
                optimizationMode: .qualifiedCapabilities
            ),
            dependencies: dependencies
        )
        let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - start

        XCTAssertEqual(result.sendExecution, .sent)
        XCTAssertEqual(result.strategy, .acknowledgedClipboardPaste)
        XCTAssertEqual(result.fallback, .notRequired)
        XCTAssertLessThan(wallNanoseconds, 40_000_000)
        XCTAssertEqual(postedDescriptors.count, 2)
    }

    func testLegacyAndQualifiedFallbackClampSendSettlementToEightyMilliseconds() async throws {
        for mode in [DeliveryOptimizationMode.legacyOnly, .qualifiedCapabilities] {
            let pasteboard = makePasteboard(initialText: "Original")
            let scheduler = RestorationScheduler()
            let context = deliveryContext()
            var postedDescriptors: [SendKeyEventDescriptor] = []
            let dependencies = AccessibilityPasteDependencies(
                isTrusted: { _ in true },
                pasteboard: pasteboard,
                postKeyEventPair: {
                    postedDescriptors.append($0)
                    return true
                },
                scheduleRestoration: { operation in scheduler.append(operation) },
                currentContext: { context },
                recordTiming: { _ in }
            )
            let start = DispatchTime.now().uptimeNanoseconds

            let result = try await AccessibilityPasteController.paste(
                PasteExecutionRequest(
                    text: "Transcript",
                    leaveClipboardChanged: true,
                    sendCommand: .enter,
                    expectedDestination: DeliveryDestination(context: context),
                    unknownDestinationPolicy: .suppressSend,
                    settlementDelayNanoseconds: 0,
                    optimizationMode: mode
                ),
                dependencies: dependencies
            )
            let wallNanoseconds = DispatchTime.now().uptimeNanoseconds - start

            XCTAssertEqual(result.sendExecution, .sent)
            XCTAssertGreaterThanOrEqual(wallNanoseconds, 80_000_000)
            XCTAssertGreaterThanOrEqual(result.timing.settlementNanoseconds, 80_000_000)
            XCTAssertEqual(postedDescriptors.count, 2)
        }
    }

    func testSendEventFailureAfterPasteReturnsPastedWithSendSuppressed() async throws {
        let pasteboard = makePasteboard(initialText: "Original")
        let scheduler = RestorationScheduler()
        let context = deliveryContext()
        var postedDescriptors: [SendKeyEventDescriptor] = []
        let dependencies = AccessibilityPasteDependencies(
            isTrusted: { _ in true },
            pasteboard: pasteboard,
            postKeyEventPair: {
                postedDescriptors.append($0)
                return postedDescriptors.count == 1
            },
            scheduleRestoration: { operation in scheduler.append(operation) },
            currentContext: { context },
            recordTiming: { _ in }
        )

        let result = try await AccessibilityPasteController.paste(
            PasteExecutionRequest(
                text: "Transcript",
                leaveClipboardChanged: true,
                sendCommand: .enter,
                expectedDestination: DeliveryDestination(context: context),
                unknownDestinationPolicy: .suppressSend,
                settlementDelayNanoseconds: 0
            ),
            dependencies: dependencies
        )

        XCTAssertEqual(result.sendExecution, .suppressed(.sendEventFailed))
        XCTAssertEqual(result.strategy, .legacyClipboardPaste)
        XCTAssertEqual(postedDescriptors.count, 2)
        XCTAssertEqual(postedDescriptors.first?.virtualKey, 0x09)
    }

    func testUserClipboardChangePreventsDelayedRestore() async throws {
        let pasteboard = makePasteboard(initialText: "Original")
        let scheduler = RestorationScheduler()
        let dependencies = makeDependencies(pasteboard: pasteboard, scheduler: scheduler)

        _ = try await paste(
            text: "Transcript",
            dependencies: dependencies
        )
        pasteboard.clearContents()
        pasteboard.setString("User copy", forType: .string)
        scheduler.runAll()

        XCTAssertEqual(pasteboard.string(forType: .string), "User copy")
    }

    func testEventCreationFailureStillSchedulesSafeClipboardRestore() async {
        let pasteboard = makePasteboard(initialText: "Original")
        let scheduler = RestorationScheduler()
        let dependencies = makeDependencies(
            pasteboard: pasteboard,
            scheduler: scheduler,
            canPostEvents: false
        )

        do {
            _ = try await paste(text: "Transcript", dependencies: dependencies)
            XCTFail("Expected event creation failure")
        } catch AccessibilityPasteError.eventCreationFailed {
            XCTAssertEqual(scheduler.pendingCount, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        scheduler.runAll()
        XCTAssertEqual(pasteboard.string(forType: .string), "Original")
    }

    func testOverlappingDeliveriesRestoreOriginalClipboardAfterBothCleanups() async throws {
        let pasteboard = makePasteboard(initialText: "Original")
        let scheduler = RestorationScheduler()
        let dependencies = makeDependencies(pasteboard: pasteboard, scheduler: scheduler)

        _ = try await paste(text: "First transcript", dependencies: dependencies)
        _ = try await paste(text: "Second transcript", dependencies: dependencies)

        scheduler.runAll()

        XCTAssertEqual(pasteboard.string(forType: .string), "Original")
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testCancellationDuringFinalContextCheckPreventsSendEvent() async throws {
        let pasteboard = makePasteboard(initialText: "Original")
        let scheduler = RestorationScheduler()
        let context = DeliveryContext(
            focusedApp: FocusedApp(
                bundleIdentifier: "com.example.editor",
                displayName: "Editor",
                processIdentifier: 91
            ),
            focusedTarget: FocusedTextTarget(
                acceptsText: true,
                frame: nil,
                identity: FocusedTextTargetIdentity(rawValue: "editor")
            ),
            accessibilityTrusted: true
        )
        var postedDescriptors: [SendKeyEventDescriptor] = []
        let dependencies = AccessibilityPasteDependencies(
            isTrusted: { _ in true },
            pasteboard: pasteboard,
            postKeyEventPair: {
                postedDescriptors.append($0)
                return true
            },
            scheduleRestoration: { operation in scheduler.append(operation) },
            currentContext: {
                withUnsafeCurrentTask { $0?.cancel() }
                return context
            },
            recordTiming: { _ in }
        )

        let result = try await AccessibilityPasteController.paste(
            PasteExecutionRequest(
                text: "Transcript",
                leaveClipboardChanged: true,
                sendCommand: .enter,
                expectedDestination: DeliveryDestination(context: context),
                unknownDestinationPolicy: .suppressSend,
                settlementDelayNanoseconds: 0
            ),
            dependencies: dependencies
        )

        XCTAssertEqual(result.sendExecution, .suppressed(.deliveryCancelled))
        XCTAssertEqual(postedDescriptors.count, 1)
        XCTAssertEqual(postedDescriptors.first?.virtualKey, 0x09)
    }

    private func paste(
        text: String,
        dependencies: AccessibilityPasteDependencies
    ) async throws -> PasteExecutionResult {
        try await AccessibilityPasteController.paste(
            PasteExecutionRequest(
                text: text,
                leaveClipboardChanged: false,
                sendCommand: nil,
                expectedDestination: nil,
                unknownDestinationPolicy: .allowSend,
                settlementDelayNanoseconds: 0
            ),
            dependencies: dependencies
        )
    }

    private func makePasteboard(initialText: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("air-tests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(initialText, forType: .string)
        return pasteboard
    }

    private func makeDependencies(
        pasteboard: NSPasteboard,
        scheduler: RestorationScheduler,
        canPostEvents: Bool = true,
        onPost: (() -> Void)? = nil
    ) -> AccessibilityPasteDependencies {
        AccessibilityPasteDependencies(
            isTrusted: { _ in true },
            pasteboard: pasteboard,
            postKeyEventPair: { _ in
                onPost?()
                return canPostEvents
            },
            scheduleRestoration: { operation in scheduler.append(operation) },
            currentContext: {
                DeliveryContext(
                    focusedApp: nil,
                    focusedTarget: nil,
                    accessibilityTrusted: true
                )
            },
            recordTiming: { _ in }
        )
    }

    private func deliveryContext() -> DeliveryContext {
        DeliveryContext(
            focusedApp: FocusedApp(
                bundleIdentifier: "com.example.editor",
                displayName: "Editor",
                processIdentifier: 91
            ),
            focusedTarget: FocusedTextTarget(
                acceptsText: true,
                frame: nil,
                identity: FocusedTextTargetIdentity(rawValue: "editor")
            ),
            accessibilityTrusted: true
        )
    }
}

@MainActor
private final class RestorationScheduler {
    private var operations: [AccessibilityPasteDependencies.RestorationOperation] = []

    var pendingCount: Int { operations.count }

    func append(_ operation: @escaping AccessibilityPasteDependencies.RestorationOperation) {
        operations.append(operation)
    }

    func runFirst() {
        guard !operations.isEmpty else { return }
        operations.removeFirst()()
    }

    func runAll() {
        while !operations.isEmpty {
            runFirst()
        }
    }
}
