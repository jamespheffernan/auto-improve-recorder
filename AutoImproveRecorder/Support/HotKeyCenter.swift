import Carbon
import Foundation

final class HotKeyCenter {
    private var hotKeyRef: EventHotKeyRef?
    private var cancelHotKeyRef: EventHotKeyRef?
    private var walkieTalkieLatchHotKeyRef: EventHotKeyRef?
    private var walkieTalkieModifiedLatchHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let hotKeyID = EventHotKeyID(signature: HotKeyCenter.fourCharCode("AIRH"), id: 1)
    private let cancelHotKeyID = EventHotKeyID(signature: HotKeyCenter.fourCharCode("AIRC"), id: 2)
    private let walkieTalkieLatchHotKeyID = EventHotKeyID(signature: HotKeyCenter.fourCharCode("AIRL"), id: 3)
    private let walkieTalkieModifiedLatchHotKeyID = EventHotKeyID(signature: HotKeyCenter.fourCharCode("AIRM"), id: 4)
    var handler: ((Date) -> Void)?
    var releaseHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?
    var walkieTalkieLatchHandler: (() -> Void)?

    func registerRecordingHotKey(_ hotKey: RecordingHotKey) -> Bool {
        installEventHandlerIfNeeded()
        unregisterRecordingHotKey()

        return RegisterEventHotKey(
            hotKey.keyCode,
            Self.hyperModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        ) == noErr
    }

    func registerCancelHotKey() {
        installEventHandlerIfNeeded()
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

    func registerWalkieTalkieLatchHotKey() {
        installEventHandlerIfNeeded()
        if walkieTalkieLatchHotKeyRef == nil {
            RegisterEventHotKey(
                UInt32(kVK_Space),
                0,
                walkieTalkieLatchHotKeyID,
                GetApplicationEventTarget(),
                0,
                &walkieTalkieLatchHotKeyRef
            )
        }
        if walkieTalkieModifiedLatchHotKeyRef == nil {
            RegisterEventHotKey(
                UInt32(kVK_Space),
                Self.hyperModifiers,
                walkieTalkieModifiedLatchHotKeyID,
                GetApplicationEventTarget(),
                0,
                &walkieTalkieModifiedLatchHotKeyRef
            )
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

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
            guard let event, let userData else {
                return noErr
            }

            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let eventKind = GetEventKind(event)
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
                if eventKind == UInt32(kEventHotKeyPressed) {
                    let receivedAt = Date()
                    NSLog("Recording startup: global hotkey delivered.")
                    DispatchQueue.main.async {
                        center.handler?(receivedAt)
                    }
                } else if eventKind == UInt32(kEventHotKeyReleased) {
                    DispatchQueue.main.async {
                        center.releaseHandler?()
                    }
                }
            } else if status == noErr && receivedID.signature == center.cancelHotKeyID.signature && receivedID.id == center.cancelHotKeyID.id {
                if eventKind == UInt32(kEventHotKeyPressed) {
                    DispatchQueue.main.async {
                        center.cancelHandler?()
                    }
                }
            } else if status == noErr && center.isWalkieTalkieLatchHotKey(receivedID) {
                if eventKind == UInt32(kEventHotKeyPressed) {
                    DispatchQueue.main.async {
                        center.walkieTalkieLatchHandler?()
                    }
                }
            }
            return noErr
        }

        _ = eventTypes.withUnsafeMutableBufferPointer { buffer in
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

    func unregisterWalkieTalkieLatchHotKey() {
        if let walkieTalkieLatchHotKeyRef {
            UnregisterEventHotKey(walkieTalkieLatchHotKeyRef)
            self.walkieTalkieLatchHotKeyRef = nil
        }
        if let walkieTalkieModifiedLatchHotKeyRef {
            UnregisterEventHotKey(walkieTalkieModifiedLatchHotKeyRef)
            self.walkieTalkieModifiedLatchHotKeyRef = nil
        }
    }

    func unregister() {
        unregisterRecordingHotKey()
        unregisterCancelHotKey()
        unregisterWalkieTalkieLatchHotKey()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    private func unregisterRecordingHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
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

    private static var hyperModifiers: UInt32 {
        UInt32(cmdKey | optionKey | controlKey | shiftKey)
    }

    private func isWalkieTalkieLatchHotKey(_ id: EventHotKeyID) -> Bool {
        (id.signature == walkieTalkieLatchHotKeyID.signature && id.id == walkieTalkieLatchHotKeyID.id) ||
            (id.signature == walkieTalkieModifiedLatchHotKeyID.signature && id.id == walkieTalkieModifiedLatchHotKeyID.id)
    }
}
