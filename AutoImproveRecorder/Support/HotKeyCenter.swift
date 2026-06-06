import Carbon
import Foundation
import OSLog

private let recordingHotKeyLogger = Logger(
    subsystem: "com.fieldtheory.autoimproverecorder",
    category: "HotKeyCapture"
)

final class HotKeyCenter {
    enum Event {
        case recordingPressed(receivedAt: Date, eventID: UInt64, isRepeat: Bool)
        case recordingReleased(receivedAt: Date, eventID: UInt64)
        case cancelPressed(receivedAt: Date)
        case latchPressed(receivedAt: Date)
    }

    private var hotKeyRef: EventHotKeyRef?
    private var cancelHotKeyRef: EventHotKeyRef?
    private var walkieTalkieLatchHotKeyRef: EventHotKeyRef?
    private var walkieTalkieModifiedLatchHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var nextEventID: UInt64 = 1
    private let hotKeyID = EventHotKeyID(signature: HotKeyCenter.fourCharCode("AIRH"), id: 1)
    private let cancelHotKeyID = EventHotKeyID(signature: HotKeyCenter.fourCharCode("AIRC"), id: 2)
    private let walkieTalkieLatchHotKeyID = EventHotKeyID(signature: HotKeyCenter.fourCharCode("AIRL"), id: 3)
    private let walkieTalkieModifiedLatchHotKeyID = EventHotKeyID(signature: HotKeyCenter.fourCharCode("AIRM"), id: 4)
    var eventHandler: ((Event) -> Void)?
    var handler: ((Date) -> Void)?
    var releaseHandler: (() -> Void)?
    var cancelHandler: (() -> Void)?
    var walkieTalkieLatchHandler: (() -> Void)?

    func registerRecordingHotKey(_ hotKey: RecordingHotKey) -> Bool {
        guard hotKey.isValidForGlobalRegistration else { return false }
        installEventHandlerIfNeeded()
        unregisterRecordingHotKey()

        return RegisterEventHotKey(
            hotKey.keyCode,
            hotKey.modifiers,
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
                RecordingHotKey.hyperModifiers,
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
                    let eventID = center.takeNextEventID()
                    recordingHotKeyLogger.info("recording hotkey pressed.")
                    DispatchQueue.main.async {
                        center.eventHandler?(.recordingPressed(receivedAt: receivedAt, eventID: eventID, isRepeat: false))
                        center.handler?(receivedAt)
                    }
                } else if eventKind == UInt32(kEventHotKeyReleased) {
                    let receivedAt = Date()
                    let eventID = center.takeNextEventID()
                    DispatchQueue.main.async {
                        center.eventHandler?(.recordingReleased(receivedAt: receivedAt, eventID: eventID))
                        center.releaseHandler?()
                    }
                }
            } else if status == noErr && receivedID.signature == center.cancelHotKeyID.signature && receivedID.id == center.cancelHotKeyID.id {
                if eventKind == UInt32(kEventHotKeyPressed) {
                    let receivedAt = Date()
                    DispatchQueue.main.async {
                        center.eventHandler?(.cancelPressed(receivedAt: receivedAt))
                        center.cancelHandler?()
                    }
                }
            } else if status == noErr && center.isWalkieTalkieLatchHotKey(receivedID) {
                if eventKind == UInt32(kEventHotKeyPressed) {
                    let receivedAt = Date()
                    DispatchQueue.main.async {
                        center.eventHandler?(.latchPressed(receivedAt: receivedAt))
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

    func unregisterRecordingHotKey() {
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

    private func isWalkieTalkieLatchHotKey(_ id: EventHotKeyID) -> Bool {
        (id.signature == walkieTalkieLatchHotKeyID.signature && id.id == walkieTalkieLatchHotKeyID.id) ||
            (id.signature == walkieTalkieModifiedLatchHotKeyID.signature && id.id == walkieTalkieModifiedLatchHotKeyID.id)
    }

    private func takeNextEventID() -> UInt64 {
        let eventID = nextEventID
        nextEventID &+= 1
        return eventID
    }
}
