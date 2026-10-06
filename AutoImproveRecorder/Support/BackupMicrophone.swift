import Foundation

/// Picks the second microphone that records alongside an external main microphone.
enum BackupMicrophoneChooser {
    static let preferredBackupName = "Anker PowerConf C200"
    /// The ESP32 board's USB audio. It is never a backup.
    static let excludedNames = ["TinyUSB UAC1"]
    static let builtInTransport = "built-in"
    static let usbTransport = "usb"

    /// The backup for a recording on `primary`, or nil when the recording gets none: the feature
    /// is off, the main microphone is built in or unknown, or no other device is eligible.
    /// Only built-in and USB devices are eligible. Order: `preferredName`, then a built-in
    /// microphone, then any other USB microphone.
    static func chooseBackup(
        primary: MicrophoneDevice,
        devices: [MicrophoneDevice],
        isEnabled: Bool,
        preferredName: String = preferredBackupName
    ) -> MicrophoneDevice? {
        guard isEnabled,
              let main = resolvedPrimary(primary, devices: devices),
              main.transportType != builtInTransport else {
            return nil
        }
        let candidates = devices.filter { device in
            !device.isSystemDefaultPlaceholder &&
                device.id != main.id &&
                !isSameCoreAudioDevice(device, main) &&
                device.isConnected &&
                device.isInputCapable &&
                (device.transportType == builtInTransport || device.transportType == usbTransport) &&
                !excludedNames.contains { hasName(device, $0) }
        }
        return candidates.first { hasName($0, preferredName) }
            ?? candidates.first { $0.transportType == builtInTransport }
            ?? candidates.first
    }

    /// The device a recording on `primary` reads from. The system-default placeholder becomes the
    /// device that is the system default now; nil when the list does not name one.
    static func resolvedPrimary(
        _ primary: MicrophoneDevice,
        devices: [MicrophoneDevice]
    ) -> MicrophoneDevice? {
        guard primary.isSystemDefaultPlaceholder else { return primary }
        return devices.first { !$0.isSystemDefaultPlaceholder && $0.isSystemDefault }
    }

    private static func hasName(_ device: MicrophoneDevice, _ name: String) -> Bool {
        device.name.compare(name, options: .caseInsensitive) == .orderedSame
    }

    private static func isSameCoreAudioDevice(_ left: MicrophoneDevice, _ right: MicrophoneDevice) -> Bool {
        guard let leftID = left.coreAudioDeviceID, let rightID = right.coreAudioDeviceID else {
            return false
        }
        return leftID == rightID
    }
}

/// Decides which of a recording's two transcripts to use.
enum BackupTranscriptChoice {
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// True when the backup's text has more words than the main text.
    static func prefersBackup(mainText: String, backupText: String) -> Bool {
        wordCount(backupText) > wordCount(mainText)
    }
}
