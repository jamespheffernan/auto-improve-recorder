import ApplicationServices
import AppKit

enum AccessibilityPasteError: LocalizedError {
    case notTrusted
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .notTrusted:
            return "Accessibility permission is not enabled."
        case .eventCreationFailed:
            return "Could not create paste keyboard events."
        }
    }
}

enum AccessibilityPasteController {
    static func isTrusted(prompt: Bool) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func focusedElementAcceptsText(promptForPermission: Bool = false) -> Bool {
        currentDeliveryContext(promptForPermission: promptForPermission).focusedTarget?.acceptsText == true
    }

    static func focusedTextTargetFrame(promptForPermission: Bool = false) -> CGRect? {
        currentDeliveryContext(promptForPermission: promptForPermission).focusedTarget?.frame
    }

    static func currentFocusedApp() -> FocusedApp? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return nil
        }

        return FocusedApp(bundleIdentifier: bundleIdentifier, displayName: app.localizedName)
    }

    static func focusedTextTarget(promptForPermission: Bool = false) -> FocusedTextTarget? {
        currentDeliveryContext(promptForPermission: promptForPermission).focusedTarget
    }

    static func currentDeliveryContext(promptForPermission: Bool = false) -> DeliveryContext {
        let frontmostApp = currentFocusedApp()
        let trusted = isTrusted(prompt: promptForPermission)

        guard trusted, let element = focusedElement() else {
            return DeliveryContext(focusedApp: frontmostApp, focusedTarget: nil, accessibilityTrusted: trusted)
        }

        let acceptsText = elementAcceptsText(element)
        let target = FocusedTextTarget(
            acceptsText: acceptsText,
            frame: acceptsText ? elementFrame(element) : nil
        )

        return DeliveryContext(focusedApp: frontmostApp, focusedTarget: target, accessibilityTrusted: trusted)
    }

    static func paste(
        text: String,
        leaveClipboardChanged: Bool = true,
        submitAfterPaste: Bool = false
    ) throws {
        guard isTrusted(prompt: true) else {
            throw AccessibilityPasteError.notTrusted
        }

        let pasteboard = NSPasteboard.general
        let snapshot = leaveClipboardChanged ? nil : PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            throw AccessibilityPasteError.eventCreationFailed
        }

        let submitKeyDown: CGEvent?
        let submitKeyUp: CGEvent?
        if submitAfterPaste {
            guard
                let returnDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true),
                let returnUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
            else {
                throw AccessibilityPasteError.eventCreationFailed
            }
            submitKeyDown = returnDown
            submitKeyUp = returnUp
        } else {
            submitKeyDown = nil
            submitKeyUp = nil
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        if let submitKeyDown, let submitKeyUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                submitKeyDown.post(tap: .cghidEventTap)
                submitKeyUp.post(tap: .cghidEventTap)
            }
        }

        if let snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                snapshot.restore(to: pasteboard)
            }
        }
    }

    private static func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        if result == .success,
           let value,
           CFGetTypeID(value) == AXUIElementGetTypeID() {
            return (value as! AXUIElement)
        }

        return frontmostApplicationFocusedElement()
    }

    private static func frontmostApplicationFocusedElement() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard result == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func elementAcceptsText(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element)
        let subrole = stringAttribute(kAXSubroleAttribute, from: element)

        if subrole == "AXSecureTextField" {
            return false
        }

        if let editable = boolAttribute("AXEditable", from: element), !editable {
            return false
        }

        guard role != kAXButtonRole as String &&
            role != kAXMenuItemRole as String &&
            role != kAXCheckBoxRole as String &&
            role != kAXRadioButtonRole as String &&
            role != kAXSliderRole as String
        else {
            return false
        }

        if role == kAXTextFieldRole as String ||
            role == kAXTextAreaRole as String ||
            role == kAXComboBoxRole as String {
            return true
        }

        guard hasTextEditingAttribute(element) else {
            return false
        }

        var settable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        return result != .success || settable.boolValue || role == "AXWebArea"
    }

    private static func hasTextEditingAttribute(_ element: AXUIElement) -> Bool {
        var names: CFArray?
        let result = AXUIElementCopyAttributeNames(element, &names)
        guard result == .success, let names = names as? [String] else {
            return false
        }

        let textEditingAttributes: Set<String> = [
            kAXSelectedTextRangeAttribute,
            kAXVisibleCharacterRangeAttribute,
            "AXSelectedTextMarkerRange",
            "AXInsertionPointLineNumber",
            "AXNumberOfCharacters",
            "AXPlaceholderValue"
        ]

        return names.contains { textEditingAttributes.contains($0) }
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element),
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }

        return value as? String
    }

    private static func boolAttribute(_ attribute: String, from element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else {
            return nil
        }

        return value as? Bool
    }

    private static func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint else {
            return nil
        }

        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgSize else {
            return nil
        }

        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else {
            return nil
        }
        return size
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                result[type] = item.data(forType: type)
            }
        } ?? []

        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let pasteboardItems = items.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }

        if !pasteboardItems.isEmpty {
            pasteboard.writeObjects(pasteboardItems)
        }
    }
}
