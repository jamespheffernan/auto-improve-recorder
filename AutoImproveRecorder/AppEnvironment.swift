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
            improvement: LiveImprovementService()
        )
    }
}
