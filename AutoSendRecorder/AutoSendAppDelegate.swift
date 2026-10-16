import AppKit
import SwiftUI

@MainActor
final class AutoSendAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let state = AutoSendState.shared
    private let hotKeys = AutoSendHotKeyCenter()
    private let hud = AutoSendHUDPresenter()
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var recordMenuItem: NSMenuItem?
    private var statusMessageMenuItem: NSMenuItem?
    private var copyMenuItem: NSMenuItem?
    private var lastAnnouncementKey: String?
    private var settingsWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private var settingsShortcutMonitor: Any?
    private var wirelessBridgeStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        state.settings.menuBarIconStyleDidChange = { [weak self] in
            self?.updateStatusItemAppearance()
        }
        state.settings.shortcutsDidChange = { [weak self] in
            self?.registerConfiguredHotKeys()
        }
        state.settings.wirelessRecorderDidChange = { [weak self] enabled in
            self?.updateWirelessRecorder(enabled: enabled)
            self?.registerConfiguredHotKeys()
        }
        installSettingsShortcut()
        state.didChange = { [weak self] in
            guard let self else { return }
            self.hud.update(self.state.experienceState)
            self.updateMenu()
            self.announceImportantStateIfNeeded()
        }
        hotKeys.handler = { [weak self] event in
            switch event {
            case .recordingPressed:
                self?.state.recordingHotKeyPressed()
            case .recordingReleased:
                self?.state.recordingHotKeyReleased()
            case .esp32RecordingPressed:
                self?.state.esp32RecordingButtonPressed()
            case .esp32RecordingReleased:
                self?.state.esp32RecordingButtonReleased()
            case .spaceLatch:
                self?.state.recordingSpaceLatchPressed()
            case .cancel:
                self?.state.cancel()
            }
        }
        state.registerSpaceLatch = { [weak self] in self?.hotKeys.registerSpaceLatch() ?? false }
        state.unregisterSpaceLatch = { [weak self] in self?.hotKeys.unregisterSpaceLatch() }
        registerConfiguredHotKeys()
        updateWirelessRecorder(enabled: state.settings.wirelessRecorderEnabled)
        state.prewarm()
        if !state.settings.hasCompletedOnboarding {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboarding()
            }
        }

#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-settings") {
            showSettings()
        }
        if arguments.contains("--show-onboarding") {
            showOnboarding()
        }
        if arguments.contains("--state-playground") {
            AutoSendStatePlaygroundController.shared.show()
        }
        if let flagIndex = arguments.firstIndex(of: "--state-playground-snapshot"),
           arguments.indices.contains(flagIndex + 1) {
            let snapshotURL = URL(fileURLWithPath: arguments[flagIndex + 1])
            AutoSendStatePlaygroundController.shared.show()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                try? AutoSendStatePlaygroundController.shared.saveSnapshot(to: snapshotURL)
            }
        }
#endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys.unregister()
        if wirelessBridgeStarted {
            AutoSendWirelessBridge.shared.stop()
        }
        if let settingsShortcutMonitor {
            NSEvent.removeMonitor(settingsShortcutMonitor)
        }
        state.cancel()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateMenu()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = makeMenuBarIcon()
            button.setAccessibilityLabel("Auto Send Recorder")
            button.toolTip = "Auto Send Recorder"
        }
        statusItem = item
        buildMenu()
        updateMenu()
    }

    private func buildMenu() {
        menu.delegate = self
        let recordItem = NSMenuItem(
            title: "Start Recording",
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        recordItem.target = self
        menu.addItem(recordItem)
        recordMenuItem = recordItem

        let messageItem = NSMenuItem(title: state.statusMessage, action: nil, keyEquivalent: "")
        messageItem.isEnabled = false
        menu.addItem(messageItem)
        statusMessageMenuItem = messageItem

        let copyItem = NSMenuItem(title: "Copy Last Transcript", action: #selector(copyLastText), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)
        copyMenuItem = copyItem

        menu.addItem(.separator())
        let setupItem = NSMenuItem(title: "Setup Guide...", action: #selector(showOnboarding), keyEquivalent: "")
        setupItem.target = self
        menu.addItem(setupItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.keyEquivalentModifierMask = [.command]
        menu.addItem(settingsItem)

#if DEBUG
        let playgroundItem = NSMenuItem(
            title: "State Playground...",
            action: #selector(showStatePlayground),
            keyEquivalent: ""
        )
        playgroundItem.target = self
        menu.addItem(playgroundItem)
#endif

        let quitItem = NSMenuItem(title: "Quit Auto Send Recorder", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        self.statusItem?.menu = menu
    }

    private func updateMenu() {
        let recordTitle: String
        switch state.phase {
        case .recording:
            recordTitle = "Stop Recording"
        case .starting:
            recordTitle = "Starting Recording"
        case .transcribing:
            recordTitle = "Transcribing"
        case .delivering:
            recordTitle = "Pasting"
        case .idle, .ready, .failed:
            recordTitle = "Start Recording"
        }
        recordMenuItem?.title = recordTitle
        recordMenuItem?.isEnabled = state.phase == .recording || !state.phase.isBusy

        statusMessageMenuItem?.title = state.statusMessage
        statusMessageMenuItem?.image = NSImage(
            systemSymbolName: state.experienceState.symbolName,
            accessibilityDescription: state.experienceState.title
        )
        copyMenuItem?.isHidden = state.lastText.isEmpty
        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        guard state.settings.menuBarIconStyle != .white else {
            button.contentTintColor = .white
            button.toolTip = "Auto Send Recorder — \(state.experienceState.title)"
            return
        }
        switch state.experienceState.tone {
        case .recording:
            button.contentTintColor = .systemRed
        case .warning:
            button.contentTintColor = .systemOrange
        case .failure:
            button.contentTintColor = .systemRed
        case .neutral, .success, .informational:
            button.contentTintColor = nil
        }
        button.toolTip = "Auto Send Recorder — \(state.experienceState.title)"
    }

    private func makeMenuBarIcon() -> NSImage {
        let image = NSImage(named: "MenuBarIcon") ?? NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Auto Send Recorder"
        ) ?? NSImage(
            systemSymbolName: "paperplane.fill",
            accessibilityDescription: "Auto Send Recorder"
        ) ?? NSImage(size: NSSize(width: 18, height: 18))

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Auto Send Recorder"
        return image
    }

    private func announceImportantStateIfNeeded() {
        let announcement: (key: String, message: String)?
        switch state.experienceState {
        case .recording:
            announcement = ("recording", "Recording started.")
        case .recordingWarning(let message):
            announcement = ("recording-warning:\(message)", message)
        case .sent:
            announcement = ("sent", "Transcript sent.")
        case .cancelled:
            announcement = ("cancelled", "Recording cancelled. The saved recording was kept.")
        case .permissionNeeded(let message):
            announcement = ("permission:\(message)", "Permission needed. \(message)")
        case .failed(let message):
            announcement = ("failed:\(message)", "Auto Send Recorder failed. \(message)")
        case .idle, .starting, .finalizing, .delivering, .pastedWithoutSend, .suppressed,
             .noTarget, .hotKeyConflict:
            announcement = nil
        }

        guard let announcement, announcement.key != lastAnnouncementKey else { return }
        lastAnnouncementKey = announcement.key
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement.message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue
            ]
        )
    }

    private func registerConfiguredHotKeys() {
        state.reportHotKeyRegistration(hotKeys.register(
            recording: state.settings.recordingShortcut,
            cancel: state.settings.cancelShortcut,
            enableWirelessRecorder: state.settings.wirelessRecorderEnabled
        ))
    }

    private func updateWirelessRecorder(enabled: Bool) {
        if enabled {
            guard !wirelessBridgeStarted else { return }
            wirelessBridgeStarted = true
            AutoSendWirelessBridge.shared.start { [weak state] pressed in
                Task { @MainActor in
                    if pressed {
                        state?.esp32RecordingButtonPressed()
                    } else {
                        state?.esp32RecordingButtonReleased()
                    }
                }
            }
        } else if wirelessBridgeStarted {
            AutoSendWirelessBridge.shared.stop()
            wirelessBridgeStarted = false
        }
    }

    @objc private func toggleRecording() {
        state.toggleRecording()
    }

    @objc private func copyLastText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(state.lastText, forType: .string)
    }

    @objc private func showOnboarding() {
        let controller = onboardingWindowController ?? makeOnboardingWindowController()
        onboardingWindowController = controller
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() {
        state.rememberCurrentAppForSettings()
        let controller = settingsWindowController ?? makeSettingsWindowController()
        settingsWindowController = controller
        NSApplication.shared.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindowController() -> NSWindowController {
        let hostingController = NSHostingController(rootView: AutoSendSettingsView(state: state))
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        let contentSize = NSSize(
            width: 530,
            height: min(max(fittingSize.height, 420), 640)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Auto Send Recorder Settings"
        window.setAccessibilityTitle("Auto Send Recorder Settings")
        window.contentMinSize = NSSize(width: 530, height: 420)
        window.contentMaxSize = NSSize(width: 700, height: 700)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("AutoSendRecorderSettingsWindow")
        window.center()
        return NSWindowController(window: window)
    }

    private func makeOnboardingWindowController() -> NSWindowController {
        let hostingController = NSHostingController(rootView: AutoSendOnboardingView(
            state: state,
            onFinish: { [weak self] in
                self?.state.settings.completeOnboarding()
                self?.onboardingWindowController?.close()
            }
        ))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 620, height: 560)),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Welcome to Auto Send Recorder"
        window.setAccessibilityTitle("Auto Send Recorder Setup Guide")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.delegate = self
        window.center()
        return NSWindowController(window: window)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === onboardingWindowController?.window else { return }
        state.settings.completeOnboarding()
    }

    private func installSettingsShortcut() {
        settingsShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let relevantModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard relevantModifiers == .command,
                  event.charactersIgnoringModifiers == "," else {
                return event
            }
            self?.showSettings()
            return nil
        }
    }

#if DEBUG
    @objc private func showStatePlayground() {
        AutoSendStatePlaygroundController.shared.show()
    }
#endif

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
