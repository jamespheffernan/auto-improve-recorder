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

    static func paste(text: String) throws {
        guard isTrusted(prompt: true) else {
            throw AccessibilityPasteError.notTrusted
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        else {
            throw AccessibilityPasteError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
