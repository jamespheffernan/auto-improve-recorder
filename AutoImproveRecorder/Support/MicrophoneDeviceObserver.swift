import Foundation

#if os(macOS)
import CoreAudio
#endif

final class MicrophoneDeviceObserver {
    private let onDevicesChanged: () -> Void

    #if os(macOS)
    private let queue = DispatchQueue(label: "com.fieldtheory.air.microphone-devices", qos: .utility)
    private let debounceInterval: TimeInterval
    private var isObserving = false
    private var pendingWorkItem: DispatchWorkItem?
    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.scheduleChangeNotification()
    }
    #endif

    init(
        debounceInterval: TimeInterval = 0.25,
        onDevicesChanged: @escaping () -> Void
    ) {
        self.onDevicesChanged = onDevicesChanged
        #if os(macOS)
        self.debounceInterval = debounceInterval
        #endif
    }

    deinit {
        stop()
    }

    func start() {
        #if os(macOS)
        guard !isObserving else { return }
        isObserving = true
        addListener(selector: kAudioHardwarePropertyDevices)
        addListener(selector: kAudioHardwarePropertyDefaultInputDevice)
        #endif
    }

    func stop() {
        #if os(macOS)
        guard isObserving else { return }
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        removeListener(selector: kAudioHardwarePropertyDevices)
        removeListener(selector: kAudioHardwarePropertyDefaultInputDevice)
        isObserving = false
        #endif
    }

    #if os(macOS)
    private func addListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listenerBlock
        )
    }

    private func removeListener(selector: AudioObjectPropertySelector) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listenerBlock
        )
    }

    private func scheduleChangeNotification() {
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [onDevicesChanged] in
            DispatchQueue.main.async {
                onDevicesChanged()
            }
        }
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }
    #endif
}
