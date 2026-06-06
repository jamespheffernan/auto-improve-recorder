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

    static var live: AppEnvironment {
        AppEnvironment(
            delivery: ClosureDeliveryService(
                contextProvider: { promptForPermission in
                    AccessibilityPasteController.currentDeliveryContext(promptForPermission: promptForPermission)
                },
                pasteAction: { text, leaveClipboardChanged, submitAfterPaste in
                    try AccessibilityPasteController.paste(
                        text: text,
                        leaveClipboardChanged: leaveClipboardChanged,
                        submitAfterPaste: submitAfterPaste
                    )
                },
                copyAction: { text in
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(text, forType: .string)
                }
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
