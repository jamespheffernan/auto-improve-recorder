import Carbon
import Foundation

enum AutoSendHotKeyRegistration: Equatable {
    case registered
    case deviceConflict
    case deviceFailed(OSStatus)
    case conflict
    case failed(OSStatus)
}

final class AutoSendHotKeyCenter {
    enum Event {
        case recordingPressed
        case recordingReleased
        case esp32RecordingPressed
        case esp32RecordingReleased
        case spaceLatch
        case cancel
    }

    var handler: ((Event) -> Void)?

    private let toggleID = EventHotKeyID(signature: AutoSendHotKeyCenter.fourCharCode("ASRH"), id: 1)
    private let cancelID = EventHotKeyID(signature: AutoSendHotKeyCenter.fourCharCode("ASRC"), id: 2)
    private let esp32ID = EventHotKeyID(signature: AutoSendHotKeyCenter.fourCharCode("ASRE"), id: 3)
    private let spaceLatchID = EventHotKeyID(signature: AutoSendHotKeyCenter.fourCharCode("ASRL"), id: 4)
    private let modifiedSpaceLatchID = EventHotKeyID(signature: AutoSendHotKeyCenter.fourCharCode("ASRM"), id: 5)
    private var toggleRef: EventHotKeyRef?
    private var cancelRef: EventHotKeyRef?
    private var esp32Ref: EventHotKeyRef?
    private var spaceLatchRef: EventHotKeyRef?
    private var modifiedSpaceLatchRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    /// The shortcuts last passed to `register`. The Space latch reads them.
    private var recordingShortcut = AutoSendKeyboardShortcut.defaultRecording
    private var cancelShortcut = AutoSendKeyboardShortcut.defaultCancel

    func register(
        recording: AutoSendKeyboardShortcut = .defaultRecording,
        cancel: AutoSendKeyboardShortcut = .defaultCancel,
        enableWirelessRecorder: Bool = true
    ) -> AutoSendHotKeyRegistration {
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { return .failed(handlerStatus) }
        unregisterHotKeys()
        recordingShortcut = recording
        cancelShortcut = cancel

        let status = RegisterEventHotKey(
            recording.keyCode,
            Self.carbonModifiers(for: recording.modifiers),
            toggleID,
            GetApplicationEventTarget(),
            0,
            &toggleRef
        )
        guard status == noErr else {
            return status == eventHotKeyExistsErr ? .conflict : .failed(status)
        }

        let cancelStatus = RegisterEventHotKey(
            cancel.keyCode,
            Self.carbonModifiers(for: cancel.modifiers),
            cancelID,
            GetApplicationEventTarget(),
            0,
            &cancelRef
        )
        guard cancelStatus == noErr else {
            unregisterHotKeys()
            return cancelStatus == eventHotKeyExistsErr ? .conflict : .failed(cancelStatus)
        }

        guard enableWirelessRecorder else { return .registered }

        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let esp32Status = RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            modifiers,
            esp32ID,
            GetApplicationEventTarget(),
            0,
            &esp32Ref
        )
        guard esp32Status == noErr else {
            return esp32Status == eventHotKeyExistsErr
                ? .deviceConflict
                : .deviceFailed(esp32Status)
        }
        return .registered
    }

    func unregister() {
        unregisterHotKeys()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    /// Arms Space only while a hold-to-talk recording is active. The modified
    /// registration uses the recording shortcut's modifiers, so Space latches a
    /// recording before the main shortcut is released.
    @discardableResult
    func registerSpaceLatch() -> Bool {
        let handlerStatus = installHandlerIfNeeded()
        guard handlerStatus == noErr else { return false }

        let heldModifiers = AutoSendSpaceLatch.modifierSets(
            recording: recordingShortcut,
            cancel: cancelShortcut
        ).first { !$0.isEmpty }
        if spaceLatchRef == nil {
            guard RegisterEventHotKey(
                AutoSendSpaceLatch.spaceKeyCode, 0, spaceLatchID, GetApplicationEventTarget(), 0,
                &spaceLatchRef
            ) == noErr else { return false }
        }
        if modifiedSpaceLatchRef == nil, let heldModifiers {
            guard RegisterEventHotKey(
                AutoSendSpaceLatch.spaceKeyCode, Self.carbonModifiers(for: heldModifiers),
                modifiedSpaceLatchID, GetApplicationEventTarget(), 0,
                &modifiedSpaceLatchRef
            ) == noErr else {
                unregisterSpaceLatch()
                return false
            }
        }
        return true
    }

    func unregisterSpaceLatch() {
        if let spaceLatchRef {
            UnregisterEventHotKey(spaceLatchRef)
            self.spaceLatchRef = nil
        }
        if let modifiedSpaceLatchRef {
            UnregisterEventHotKey(modifiedSpaceLatchRef)
            self.modifiedSpaceLatchRef = nil
        }
    }

    private func unregisterHotKeys() {
        if let toggleRef {
            UnregisterEventHotKey(toggleRef)
            self.toggleRef = nil
        }
        if let cancelRef {
            UnregisterEventHotKey(cancelRef)
            self.cancelRef = nil
        }
        if let esp32Ref {
            UnregisterEventHotKey(esp32Ref)
            self.esp32Ref = nil
        }
        unregisterSpaceLatch()
    }

    private func installHandlerIfNeeded() -> OSStatus {
        guard eventHandlerRef == nil else { return noErr }
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let center = Unmanaged<AutoSendHotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr else { return status }
            let delivered: Event?
            if hotKeyID.signature == center.toggleID.signature && hotKeyID.id == center.toggleID.id {
                delivered = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                    ? .recordingReleased
                    : .recordingPressed
            } else if hotKeyID.signature == center.esp32ID.signature && hotKeyID.id == center.esp32ID.id {
                delivered = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                    ? .esp32RecordingReleased
                    : .esp32RecordingPressed
            } else if (hotKeyID.signature == center.spaceLatchID.signature && hotKeyID.id == center.spaceLatchID.id) ||
                        (hotKeyID.signature == center.modifiedSpaceLatchID.signature && hotKeyID.id == center.modifiedSpaceLatchID.id) {
                delivered = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .spaceLatch : nil
            } else if hotKeyID.signature == center.cancelID.signature && hotKeyID.id == center.cancelID.id {
                delivered = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .cancel : nil
            } else {
                delivered = nil
            }
            if let delivered {
                DispatchQueue.main.async { center.handler?(delivered) }
            }
            return noErr
        }
        return eventTypes.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                buffer.count,
                buffer.baseAddress,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerRef
            )
        }
    }

    private static func carbonModifiers(for modifiers: AutoSendShortcutModifiers) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private static func fourCharCode(_ text: String) -> OSType {
        text.unicodeScalars.prefix(4).reduce(0) { ($0 << 8) + UInt32($1.value) }
    }

    deinit {
        unregister()
    }
}
