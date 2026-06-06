import AVFoundation
import Foundation

enum PermissionState: String, Codable, Equatable {
    case authorized
    case denied
    case notDetermined
    case restricted
    case unavailable
}

struct PermissionStatus: Codable, Equatable {
    var microphone: PermissionState
    var accessibility: PermissionState
}

protocol PermissionsClient {
    var hasMicrophonePermission: Bool { get }
    var cachedMicrophonePermissionWasGranted: Bool { get }
    func microphoneState() -> PermissionState
    func requestMicrophone() async throws
    func rememberMicrophonePermissionGranted()
    func accessibilityState(prompt: Bool) -> PermissionState
    func snapshot(promptForAccessibility: Bool) async -> PermissionStatus
}

struct LivePermissionsClient: PermissionsClient {
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "com.fieldtheory.air.permissions-client", qos: .utility)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasMicrophonePermission: Bool {
        AudioRecorder.hasMicrophonePermission
    }

    var cachedMicrophonePermissionWasGranted: Bool {
        defaults.bool(forKey: Keys.microphonePermissionWasGranted)
    }

    func microphoneState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .unavailable
        }
    }

    func requestMicrophone() async throws {
        try await AudioRecorder.requestMicrophonePermission()
    }

    func rememberMicrophonePermissionGranted() {
        queue.async {
            defaults.set(true, forKey: Keys.microphonePermissionWasGranted)
        }
    }

    func accessibilityState(prompt: Bool) -> PermissionState {
        AccessibilityPasteController.isTrusted(prompt: prompt) ? .authorized : .denied
    }

    func snapshot(promptForAccessibility: Bool) async -> PermissionStatus {
        PermissionStatus(
            microphone: microphoneState(),
            accessibility: accessibilityState(prompt: promptForAccessibility)
        )
    }

    private enum Keys {
        static let microphonePermissionWasGranted = "microphonePermissionWasGranted"
    }
}
