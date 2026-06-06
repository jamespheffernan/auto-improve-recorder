import AVFoundation
import Foundation

#if os(macOS)
import CoreAudio
#endif

enum AudioInputDeviceDiscovery {
    static func inputDevices() -> [AudioInputDevice] {
        #if os(macOS)
        let devices = coreAudioInputDevices()
        return [.systemDefault] + devices.sorted {
            if $0.isSystemDefault != $1.isSystemDefault {
                return $0.isSystemDefault
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        #else
        var devices = [AudioInputDevice.systemDefault]

        let captureDevices: [AVCaptureDevice]
        if #available(macOS 14.0, *) {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            )
            captureDevices = discovery.devices
        } else {
            captureDevices = AVCaptureDevice.devices(for: .audio)
        }
        devices.append(contentsOf: captureDevices.map {
            AudioInputDevice(
                id: $0.uniqueID,
                name: $0.localizedName,
                coreAudioDeviceID: nil,
                transportType: nil,
                isConnected: true,
                isInputCapable: true,
                isSystemDefault: false
            )
        })

        return devices
        #endif
    }
}

#if os(macOS)
extension AudioInputDeviceDiscovery {
    static func defaultInputDeviceID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        ) == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else {
            return nil
        }

        return deviceID
    }
}

private extension AudioInputDeviceDiscovery {
    static func coreAudioInputDevices() -> [AudioInputDevice] {
        let defaultInputDeviceID = defaultInputDeviceID()
        let captureDeviceNames = captureDeviceNamesByUniqueID()

        return audioDeviceIDs().compactMap { deviceID in
            guard inputChannelCount(for: deviceID) > 0 else { return nil }

            let uid = stringProperty(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal
            ) ?? "\(deviceID)"
            let coreAudioName = stringProperty(
                objectID: deviceID,
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal
            )
            let name = captureDeviceNames[uid] ?? coreAudioName ?? uid

            return AudioInputDevice(
                id: uid,
                name: name,
                coreAudioDeviceID: deviceID,
                transportType: transportTypeName(for: deviceID),
                isConnected: true,
                isInputCapable: true,
                isSystemDefault: defaultInputDeviceID == deviceID
            )
        }
    }

    static func audioDeviceIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var deviceIDs = Array(repeating: AudioObjectID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return []
        }
        return deviceIDs
    }

    static func inputChannelCount(for deviceID: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return 0
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            bufferListPointer
        ) == noErr else {
            return 0
        }

        let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(audioBufferList)
            .reduce(UInt32(0)) { $0 + $1.mNumberChannels }
    }

    static func stringProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)

        guard AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }

        let string = value as String
        return string.isEmpty ? nil : string
    }

    static func transportTypeName(for deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &transportType
        ) == noErr else {
            return nil
        }

        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn:
            return "built-in"
        case kAudioDeviceTransportTypeUSB:
            return "usb"
        case kAudioDeviceTransportTypeBluetooth:
            return "bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE:
            return "bluetooth-le"
        case kAudioDeviceTransportTypeVirtual:
            return "virtual"
        case kAudioDeviceTransportTypeAggregate:
            return "aggregate"
        default:
            return "\(transportType)"
        }
    }

    static func captureDeviceNamesByUniqueID() -> [String: String] {
        let captureDevices: [AVCaptureDevice]
        if #available(macOS 14.0, *) {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone],
                mediaType: .audio,
                position: .unspecified
            )
            captureDevices = discovery.devices
        } else {
            captureDevices = AVCaptureDevice.devices(for: .audio)
        }

        return Dictionary(uniqueKeysWithValues: captureDevices.map {
            ($0.uniqueID, $0.localizedName)
        })
    }
}
#endif
