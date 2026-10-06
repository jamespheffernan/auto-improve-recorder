import AppKit
import Foundation

struct AppEnvironment {
    var delivery: any DeliveryService
    var settings: any SettingsStore
    var secrets: any SecretsStore
    var archive: any TranscriptArchiveClient
    var diagnostics: any DiagnosticsStore
    var permissions: any PermissionsClient
    var recording: any RecordingClient
    var transcription: any TranscriptionService
    var improvement: any ImprovementService
    var dictionaryStore: UserDictionaryStore
    /// Read only for the OpenAI realtime diagnostics saved by versions that predate `DiagnosticsStore`.
    var legacyDefaults: UserDefaults
    var microphoneDevices: any MicrophoneDeviceClient
    var microphoneUseLock: any MicrophoneUseLockClient
    var enginePrewarm: any EnginePrewarmClient
    /// Regular running apps that have a bundle identifier.
    var runningApps: () -> [FocusedApp]

    @MainActor
    static var live: AppEnvironment {
        AppEnvironment(
            delivery: ClosureDeliveryService(
                contextProvider: { promptForPermission in
                    AccessibilityPasteController.currentDeliveryContext(promptForPermission: promptForPermission)
                },
                pasteAction: { request in
                    try await AccessibilityPasteController.paste(request)
                },
                copyAction: { text in
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                },
                productDisplayName: "Auto Improve Recorder"
            ),
            settings: UserDefaultsSettingsStore(),
            secrets: KeychainSecretsStore(),
            archive: LiveTranscriptArchiveClient(),
            diagnostics: UserDefaultsDiagnosticsStore(),
            permissions: LivePermissionsClient(),
            recording: AudioRecorderClient(),
            transcription: LiveTranscriptionService(),
            improvement: LiveImprovementService(),
            dictionaryStore: UserDictionaryStore(lexiconReader: LexiconReader()),
            legacyDefaults: .standard,
            microphoneDevices: LiveMicrophoneDeviceClient(),
            microphoneUseLock: FileMicrophoneUseLockClient(),
            enginePrewarm: LiveEnginePrewarmClient(),
            runningApps: {
                NSWorkspace.shared.runningApplications.compactMap { app in
                    guard app.activationPolicy == .regular,
                          let bundleIdentifier = app.bundleIdentifier,
                          !bundleIdentifier.isEmpty else {
                        return nil
                    }

                    return FocusedApp(
                        bundleIdentifier: bundleIdentifier,
                        displayName: app.localizedName,
                        processIdentifier: app.processIdentifier
                    )
                }
            }
        )
    }
}
