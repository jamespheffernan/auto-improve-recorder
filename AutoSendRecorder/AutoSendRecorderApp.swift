import SwiftUI

@main
struct AutoSendRecorderApp: App {
    @NSApplicationDelegateAdaptor(AutoSendAppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            AutoSendSettingsView(state: .shared)
        }
    }
}
