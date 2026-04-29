import AVFoundation
import Foundation

struct AudioInputDevice: Identifiable, Hashable {
    var id: String
    var name: String
}

enum AudioInputDeviceDiscovery {
    static func inputDevices() -> [AudioInputDevice] {
        var devices = [
            AudioInputDevice(id: "", name: "System default")
        ]

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
            AudioInputDevice(id: $0.uniqueID, name: $0.localizedName)
        })

        return devices
    }
}
