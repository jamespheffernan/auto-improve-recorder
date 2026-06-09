import Foundation

#if os(macOS)
import CoreAudio
#endif

#if os(macOS)
typealias AIRAudioObjectID = AudioObjectID
#else
typealias AIRAudioObjectID = UInt32
#endif

struct MicrophoneDevice: Identifiable, Hashable, Codable {
    var id: String
    var name: String
    var coreAudioDeviceID: AIRAudioObjectID?
    var transportType: String?
    var isConnected: Bool
    var isInputCapable: Bool
    var isSystemDefault: Bool

    static let systemDefault = MicrophoneDevice(
        id: "",
        name: "System default",
        coreAudioDeviceID: nil,
        transportType: nil,
        isConnected: true,
        isInputCapable: true,
        isSystemDefault: true
    )

    var isSystemDefaultPlaceholder: Bool {
        id.isEmpty && coreAudioDeviceID == nil
    }
}

typealias AudioInputDevice = MicrophoneDevice

struct MicrophonePreferences: Codable, Equatable {
    enum Mode: String, Codable {
        case systemDefault
        case preferred
    }

    var mode: Mode
    var preferredIDs: [String]

    static let systemDefault = MicrophonePreferences(mode: .systemDefault, preferredIDs: [])

    static func fromPreferredMicrophoneID(_ id: String) -> MicrophonePreferences {
        let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else { return .systemDefault }
        return MicrophonePreferences(mode: .preferred, preferredIDs: [trimmedID])
    }
}

enum MicrophoneResolutionReason: String, Codable, Equatable {
    case systemDefault
    case preferredAvailable
    case preferredMissing
    case preferredDisconnected
    case preferredNotInputCapable
    case preferredQuarantined
}

struct MicrophoneResolution: Equatable {
    var requestedID: String?
    var device: MicrophoneDevice
    var usedFallback: Bool
    var reason: MicrophoneResolutionReason
}

enum MicrophoneResolverError: LocalizedError, Equatable {
    case noUsableMicrophone

    var errorDescription: String? {
        switch self {
        case .noUsableMicrophone:
            return "No usable microphone is available."
        }
    }
}

enum MicrophoneResolver {
    static func resolve(
        preferences: MicrophonePreferences,
        devices: [MicrophoneDevice],
        quarantinedUntil: [String: Date],
        now: Date
    ) throws -> MicrophoneResolution {
        switch preferences.mode {
        case .systemDefault:
            return MicrophoneResolution(
                requestedID: nil,
                device: systemDefaultDevice(from: devices),
                usedFallback: false,
                reason: .systemDefault
            )

        case .preferred:
            return try resolvePreferred(
                preferences: preferences,
                devices: devices,
                quarantinedUntil: quarantinedUntil,
                now: now
            )
        }
    }

    private static func resolvePreferred(
        preferences: MicrophonePreferences,
        devices: [MicrophoneDevice],
        quarantinedUntil: [String: Date],
        now: Date
    ) throws -> MicrophoneResolution {
        let requestedIDs = preferences.preferredIDs.filter { !$0.isEmpty }
        let requestedID = requestedIDs.first

        for id in requestedIDs {
            guard let device = devices.first(where: { $0.id == id }) else {
                continue
            }

            if let quarantinedUntil = quarantinedUntil[id], quarantinedUntil > now {
                return try fallbackResolution(
                    requestedID: id,
                    reason: .preferredQuarantined,
                    devices: devices
                )
            }

            guard device.isConnected else {
                return try fallbackResolution(
                    requestedID: id,
                    reason: .preferredDisconnected,
                    devices: devices
                )
            }

            guard device.isInputCapable else {
                return try fallbackResolution(
                    requestedID: id,
                    reason: .preferredNotInputCapable,
                    devices: devices
                )
            }

            return MicrophoneResolution(
                requestedID: id,
                device: device,
                usedFallback: false,
                reason: .preferredAvailable
            )
        }

        return try fallbackResolution(
            requestedID: requestedID,
            reason: .preferredMissing,
            devices: devices
        )
    }

    private static func fallbackResolution(
        requestedID: String?,
        reason: MicrophoneResolutionReason,
        devices: [MicrophoneDevice]
    ) throws -> MicrophoneResolution {
        guard let device = fallbackDevice(from: devices, excluding: Set([requestedID].compactMap { $0 })) else {
            throw MicrophoneResolverError.noUsableMicrophone
        }

        return MicrophoneResolution(
            requestedID: requestedID,
            device: device,
            usedFallback: true,
            reason: reason
        )
    }

    private static func fallbackDevice(
        from devices: [MicrophoneDevice],
        excluding excludedIDs: Set<String>
    ) -> MicrophoneDevice? {
        let usableConcreteDevices = devices.filter {
            !$0.isSystemDefaultPlaceholder &&
            !excludedIDs.contains($0.id) &&
            $0.isConnected &&
            $0.isInputCapable
        }
        let placeholderAliasesExcludedDefault = excludedIDsAliasCurrentSystemDefault(
            in: devices,
            excludedIDs: excludedIDs
        )
        let usableSystemDefaultPlaceholder = devices.first {
            $0.isSystemDefaultPlaceholder &&
            !excludedIDs.contains($0.id) &&
            $0.isConnected &&
            $0.isInputCapable &&
            !placeholderAliasesExcludedDefault
        }

        return usableConcreteDevices.first(where: \.isSystemDefault) ??
            usableSystemDefaultPlaceholder ??
            usableConcreteDevices.first
    }

    private static func excludedIDsAliasCurrentSystemDefault(
        in devices: [MicrophoneDevice],
        excludedIDs: Set<String>
    ) -> Bool {
        devices.contains {
            !$0.isSystemDefaultPlaceholder &&
            excludedIDs.contains($0.id) &&
            $0.isSystemDefault
        }
    }

    private static func systemDefaultDevice(from devices: [MicrophoneDevice]) -> MicrophoneDevice {
        devices.first(where: \.isSystemDefaultPlaceholder) ?? .systemDefault
    }
}

enum MicrophoneDefaultInputPinningPolicy {
    static func targetDeviceToPin(
        preferences: MicrophonePreferences,
        devices: [MicrophoneDevice],
        quarantinedUntil: [String: Date],
        now: Date
    ) -> MicrophoneDevice? {
        guard preferences.mode == .preferred,
              let resolution = try? MicrophoneResolver.resolve(
                preferences: preferences,
                devices: devices,
                quarantinedUntil: quarantinedUntil,
                now: now
              ),
              !resolution.usedFallback,
              !resolution.device.isSystemDefaultPlaceholder,
              resolution.device.coreAudioDeviceID != nil,
              !resolution.device.isSystemDefault else {
            return nil
        }

        return resolution.device
    }
}
