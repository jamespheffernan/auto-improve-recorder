import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState.shared
    private let hotKeyCenter = HotKeyCenter()
    private let pillController = FloatingPillWindowController()
    private let previewController = PreviewWindowController()
    private let settingsController = SettingsWindowController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        state.showPill = { [weak self] in self?.pillController.show() }
        state.hidePill = { [weak self] in self?.pillController.hide() }
        state.showPreview = { [weak self] in self?.previewController.show() }
        state.showSettings = { [weak self] in self?.settingsController.show() }
        state.menuNeedsUpdate = { [weak self] in self?.rebuildMenu() }
        state.registerCancelHotKey = { [weak self] in self?.hotKeyCenter.registerCancelHotKey() }
        state.unregisterCancelHotKey = { [weak self] in self?.hotKeyCenter.unregisterCancelHotKey() }

        setupStatusItem()
        hotKeyCenter.handler = { [weak self] in
            self?.state.toggleRecording()
        }
        hotKeyCenter.cancelHandler = { [weak self] in
            self?.state.cancelRecording()
        }
        hotKeyCenter.registerDefaultHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyCenter.unregister()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Auto Improve Recorder")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "Auto Improve Recorder"
        }
        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let recordTitle = state.isRecording ? "Stop Recording" : "Start Recording"
        let recordItem = NSMenuItem(title: recordTitle, action: #selector(toggleRecording), keyEquivalent: "")
        recordItem.target = self
        menu.addItem(recordItem)

        let previewItem = NSMenuItem(title: "Show Preview", action: #selector(showPreview), keyEquivalent: "")
        previewItem.target = self
        previewItem.isEnabled = !state.session.preferredText.isEmpty || state.phase == .failed
        menu.addItem(previewItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    @objc private func toggleRecording() {
        state.toggleRecording()
    }

    @objc private func showPreview() {
        previewController.show()
    }

    @objc private func showSettings() {
        settingsController.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
