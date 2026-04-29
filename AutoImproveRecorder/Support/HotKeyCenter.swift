import Carbon
import Foundation

final class HotKeyCenter {
    private var hotKeyRef: EventHotKeyRef?
    private var cancelHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: HotKeyCenter.fourCharCode("AIRH"), id: 1)
    private let cancelHotKeyID = EventHotKeyID(signature: HotKeyCenter.fourCharCode("AIRC"), id: 2)
    var handler: (() -> Void)?
    var cancelHandler: (() -> Void)?

    func registerDefaultHotKey() {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return noErr
            }

            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            var receivedID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &receivedID
            )

            if status == noErr && receivedID.signature == center.hotKeyID.signature && receivedID.id == center.hotKeyID.id {
                DispatchQueue.main.async {
                    center.handler?()
                }
            } else if status == noErr && receivedID.signature == center.cancelHotKeyID.signature && receivedID.id == center.cancelHotKeyID.id {
                DispatchQueue.main.async {
                    center.cancelHandler?()
                }
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        RegisterEventHotKey(
            UInt32(kVK_ANSI_R),
            UInt32(cmdKey | optionKey | controlKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func registerCancelHotKey() {
        guard cancelHotKeyRef == nil else { return }
        RegisterEventHotKey(
            UInt32(kVK_Escape),
            0,
            cancelHotKeyID,
            GetApplicationEventTarget(),
            0,
            &cancelHotKeyRef
        )
    }

    func unregisterCancelHotKey() {
        if let cancelHotKeyRef {
            UnregisterEventHotKey(cancelHotKeyRef)
            self.cancelHotKeyRef = nil
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        unregisterCancelHotKey()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }

    private static func fourCharCode(_ string: String) -> OSType {
        var result: UInt32 = 0
        for scalar in string.unicodeScalars.prefix(4) {
            result = (result << 8) + UInt32(scalar.value)
        }
        return result
    }
}
