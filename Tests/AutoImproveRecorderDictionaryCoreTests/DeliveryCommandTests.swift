import CoreGraphics
import XCTest
@testable import AutoImproveRecorderDictionaryCore

final class DeliveryCommandTests: XCTestCase {
    func testEnterDescriptorHasNoModifierFlags() {
        let descriptor = SendCommand.enter.keyEventDescriptor

        XCTAssertEqual(descriptor.virtualKey, 0x24)
        XCTAssertEqual(descriptor.flags, [])
    }

    func testCommandEnterDescriptorHasCommandFlag() {
        let descriptor = SendCommand.commandEnter.keyEventDescriptor

        XCTAssertEqual(descriptor.virtualKey, 0x24)
        XCTAssertEqual(descriptor.flags, .maskCommand)
    }

    func testLegacyAlwaysJSONStillDecodesAsEnter() throws {
        let data = Data("\"always\"".utf8)

        let behavior = try JSONDecoder().decode(SubmitBehavior.self, from: data)

        XCTAssertEqual(behavior, .always)
        XCTAssertEqual(behavior.sendCommand, .enter)
    }

    func testUnknownDestinationCanBeSuppressed() {
        XCTAssertEqual(
            DeliverySendGuard.suppressionReason(
                expectedDestination: nil,
                currentContext: context(),
                unknownDestinationPolicy: .suppressSend
            ),
            .destinationUnavailable
        )
    }

    func testUnknownDestinationCanUseCompatibleGlobalBehavior() {
        XCTAssertNil(
            DeliverySendGuard.suppressionReason(
                expectedDestination: nil,
                currentContext: context(),
                unknownDestinationPolicy: .allowSend
            )
        )
    }

    func testChangedProcessSuppressesSend() {
        let expected = DeliveryDestination(context: context(processIdentifier: 101))

        XCTAssertEqual(
            DeliverySendGuard.suppressionReason(
                expectedDestination: expected,
                currentContext: context(processIdentifier: 202),
                unknownDestinationPolicy: .allowSend
            ),
            .destinationChanged
        )
    }

    func testChangedFocusSuppressesSend() {
        let expected = DeliveryDestination(context: context(
            targetIdentity: FocusedTextTargetIdentity(rawValue: "editor-1")
        ))

        XCTAssertEqual(
            DeliverySendGuard.suppressionReason(
                expectedDestination: expected,
                currentContext: context(
                    targetIdentity: FocusedTextTargetIdentity(rawValue: "editor-2")
                ),
                unknownDestinationPolicy: .allowSend
            ),
            .focusChanged
        )
    }

    func testRecreatedFieldWithSameStableIdentifierDoesNotSuppressSend() {
        let rawValue = "101:identifier:message-composer"
        let before = FocusedTextTargetIdentity(
            rawValue: rawValue,
            accessibilityElement: AXUIElementCreateApplication(201),
            allowsElementReplacement: true
        )
        let after = FocusedTextTargetIdentity(
            rawValue: rawValue,
            accessibilityElement: AXUIElementCreateApplication(202),
            allowsElementReplacement: true
        )
        let expected = DeliveryDestination(context: context(targetIdentity: before))

        XCTAssertNil(
            DeliverySendGuard.suppressionReason(
                expectedDestination: expected,
                currentContext: context(targetIdentity: after),
                unknownDestinationPolicy: .suppressSend
            )
        )
    }

    func testRecreatedFieldWithoutStableIdentifierStillSuppressesSend() {
        let before = FocusedTextTargetIdentity(
            rawValue: "101:element:message-composer",
            accessibilityElement: AXUIElementCreateApplication(201)
        )
        let after = FocusedTextTargetIdentity(
            rawValue: "101:element:message-composer",
            accessibilityElement: AXUIElementCreateApplication(202)
        )
        let expected = DeliveryDestination(context: context(targetIdentity: before))

        XCTAssertEqual(
            DeliverySendGuard.suppressionReason(
                expectedDestination: expected,
                currentContext: context(targetIdentity: after),
                unknownDestinationPolicy: .suppressSend
            ),
            .focusChanged
        )
    }

    func testNonEditableFocusSuppressesSend() {
        let expected = DeliveryDestination(context: context())

        XCTAssertEqual(
            DeliverySendGuard.suppressionReason(
                expectedDestination: expected,
                currentContext: context(acceptsText: false),
                unknownDestinationPolicy: .allowSend
            ),
            .focusIsNotEditable
        )
    }

    private func context(
        processIdentifier: Int32 = 101,
        targetIdentity: FocusedTextTargetIdentity = FocusedTextTargetIdentity(rawValue: "editor-1"),
        acceptsText: Bool = true
    ) -> DeliveryContext {
        DeliveryContext(
            focusedApp: FocusedApp(
                bundleIdentifier: "com.example.notes",
                displayName: "Notes",
                processIdentifier: processIdentifier
            ),
            focusedTarget: FocusedTextTarget(
                acceptsText: acceptsText,
                frame: nil,
                identity: targetIdentity
            ),
            accessibilityTrusted: true
        )
    }
}
