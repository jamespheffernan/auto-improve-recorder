import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let state = AppState.shared
    private let hotKeyCenter = HotKeyCenter()
    private let pillController = FloatingPillWindowController()
    private let previewController = PreviewWindowController()
    private let settingsController = SettingsWindowController()
    private let edgeGlowController = EdgeGlowWindowController()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        state.showPill = { [weak self] in self?.pillController.show() }
        state.hidePill = { [weak self] in self?.pillController.hide() }
        state.showPreview = { [weak self] in self?.previewController.show() }
        state.showSettings = { [weak self] in self?.settingsController.show() }
        state.menuNeedsUpdate = { [weak self] in self?.rebuildMenu() }
        state.registerRecordingHotKey = { [weak self] hotKey in
            self?.hotKeyCenter.registerRecordingHotKey(hotKey) ?? false
        }
        state.registerCancelHotKey = { [weak self] in self?.hotKeyCenter.registerCancelHotKey() }
        state.unregisterCancelHotKey = { [weak self] in self?.hotKeyCenter.unregisterCancelHotKey() }
        state.registerWalkieTalkieLatchHotKey = { [weak self] in self?.hotKeyCenter.registerWalkieTalkieLatchHotKey() }
        state.unregisterWalkieTalkieLatchHotKey = { [weak self] in self?.hotKeyCenter.unregisterWalkieTalkieLatchHotKey() }
        state.showProcessingSignal = { [weak self, weak state] in
            self?.edgeGlowController.showProcessing {
                guard state?.autoSubmitDetectedTextFields == true else { return nil }
                return AccessibilityPasteController.focusedTextTargetFrame(promptForPermission: false)
            }
        }
        state.flashReadySignal = { [weak self] in self?.edgeGlowController.flashReady() }
        state.hideProcessingSignal = { [weak self] in self?.edgeGlowController.hide() }

        setupStatusItem()
        hotKeyCenter.handler = { [weak self] receivedAt in
            self?.state.recordingHotKeyPressed(requestedAt: receivedAt)
        }
        hotKeyCenter.releaseHandler = { [weak self] in
            self?.state.recordingHotKeyReleased()
        }
        hotKeyCenter.cancelHandler = { [weak self] in
            self?.state.cancelRecording()
        }
        hotKeyCenter.walkieTalkieLatchHandler = { [weak self] in
            self?.state.latchCurrentWalkieTalkieRecording()
        }
        state.refreshRecordingHotKeyRegistration()
        state.prewarmLocalModels()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyCenter.unregister()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = makeMenuBarWaveformIcon()
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

        if let diagnostics = state.lastOpenAIRealtimeDiagnostics, !diagnostics.summary.isEmpty {
            let errorItem = NSMenuItem(title: "Last OpenAI error: \(shortMenuText(diagnostics.summary))", action: #selector(showSettings), keyEquivalent: "")
            errorItem.target = self
            menu.addItem(errorItem)
        }

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

    private func shortMenuText(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
        guard cleaned.count > 80 else { return cleaned }
        let index = cleaned.index(cleaned.startIndex, offsetBy: 80)
        return String(cleaned[..<index]) + "..."
    }

    private func makeMenuBarWaveformIcon() -> NSImage {
        // Brand mark: the "AIR" A-wave monogram, rendered as a template so the
        // system tints it for light/dark menu bars. Falls back to SF Symbols if
        // the asset is somehow unavailable.
        let image = NSImage(named: "MenuBarIcon") ?? NSImage(
            systemSymbolName: "waveform",
            accessibilityDescription: "Auto Improve Recorder"
        ) ?? NSImage(
            systemSymbolName: "waveform.path.ecg",
            accessibilityDescription: "Auto Improve Recorder"
        ) ?? NSImage(
            systemSymbolName: "mic",
            accessibilityDescription: "Auto Improve Recorder"
        ) ?? NSImage(size: NSSize(width: 18, height: 18))

        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        image.accessibilityDescription = "Auto Improve Recorder"
        return image
    }
}
