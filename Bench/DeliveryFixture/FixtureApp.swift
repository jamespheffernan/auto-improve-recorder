import AppKit
import Foundation

private final class NDJSONLogger {
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private let lock = NSLock()

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        try Data().write(to: url, options: .atomic)
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        try? handle.close()
    }

    func write(_ fields: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([0x0A]))
        try? handle.synchronize()
    }
}

private final class FixtureDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate, NSTextFieldDelegate {
    private let log: NDJSONLogger
    private let readyPath: String
    private var eventMonitor: Any?
    private var window: NSWindow!
    private var textField: NSTextField!
    private var textView: NSTextView!
    private var focusFieldSignal: DispatchSourceSignal?
    private var focusTextViewSignal: DispatchSourceSignal?

    init(log: NDJSONLogger, readyPath: String) {
        self.log = log
        self.readyPath = readyPath
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        buildWindow()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 0x24 else { return event }
            let command = event.modifierFlags.contains(.command) ? "commandEnter" : "enter"
            self?.log.write([
                "kind": "sendKey",
                "command": command,
                "target": self?.focusedTargetName() ?? "unknown",
                "monotonicNanoseconds": DispatchTime.now().uptimeNanoseconds,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
            ])
            return event
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textField)
        installFocusSignals()
        writeState(kind: "ready")

        let fieldRect = window.convertToScreen(textField.convert(textField.bounds, to: nil))
        let textViewRect = window.convertToScreen(textView.convert(textView.bounds, to: nil))
        let screenTop = NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
        let ready: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier,
            "textFieldIdentifier": "delivery.textField",
            "textViewIdentifier": "delivery.textView",
            "textFieldX": fieldRect.midX,
            "textFieldY": screenTop - fieldRect.midY,
            "textViewX": textViewRect.midX,
            "textViewY": screenTop - textViewRect.midY,
        ]
        let data = try! JSONSerialization.data(withJSONObject: ready, options: [.sortedKeys])
        try! data.write(to: URL(fileURLWithPath: readyPath), options: .atomic)
    }

    /// The native product target has an Edit > Paste command. A programmatic
    /// AppKit fixture does not get that menu for free, so Command-V otherwise
    /// reaches the process without invoking the responder-chain paste action.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit DeliveryFixtureApp",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        writeState(kind: "valueChanged")
    }

    func textDidChange(_ notification: Notification) {
        writeState(kind: "valueChanged")
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 300, y: 300, width: 640, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Auto Send Delivery Fixture"
        window.isReleasedWhenClosed = false

        let content = NSView(frame: window.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        window.contentView = content

        let fieldLabel = NSTextField(labelWithString: "Plain field")
        fieldLabel.frame = NSRect(x: 24, y: 304, width: 160, height: 20)
        content.addSubview(fieldLabel)

        textField = NSTextField(string: "")
        textField.frame = NSRect(x: 24, y: 260, width: 592, height: 32)
        textField.delegate = self
        textField.setAccessibilityIdentifier("delivery.textField")
        textField.setAccessibilityLabel("Delivery fixture plain field")
        content.addSubview(textField)

        let viewLabel = NSTextField(labelWithString: "Multiline text view")
        viewLabel.frame = NSRect(x: 24, y: 222, width: 180, height: 20)
        content.addSubview(viewLabel)

        let scrollView = NSScrollView(frame: NSRect(x: 24, y: 24, width: 592, height: 188))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        textView = NSTextView(frame: scrollView.bounds)
        textView.delegate = self
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.setAccessibilityIdentifier("delivery.textView")
        textView.setAccessibilityLabel("Delivery fixture multiline text view")
        scrollView.documentView = textView
        content.addSubview(scrollView)
    }

    private func installFocusSignals() {
        signal(SIGUSR1, SIG_IGN)
        signal(SIGUSR2, SIG_IGN)
        let textViewSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        textViewSource.setEventHandler { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.textView)
            self.writeState(kind: "focusRequested")
        }
        textViewSource.resume()
        focusTextViewSignal = textViewSource

        let fieldSource = DispatchSource.makeSignalSource(signal: SIGUSR2, queue: .main)
        fieldSource.setEventHandler { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.textField)
            self.writeState(kind: "focusRequested")
        }
        fieldSource.resume()
        focusFieldSignal = fieldSource
    }

    private func focusedTargetName() -> String {
        if window.firstResponder === textField.currentEditor() || window.firstResponder === textField {
            return "textField"
        }
        if window.firstResponder === textView {
            return "textView"
        }
        return "other"
    }

    private func writeState(kind: String) {
        log.write([
            "kind": kind,
            "focusedTarget": focusedTargetName(),
            "textFieldValue": textField.stringValue,
            "textViewValue": textView.string,
            "monotonicNanoseconds": DispatchTime.now().uptimeNanoseconds,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ])
    }
}

private struct Arguments {
    let logPath: String
    let readyPath: String

    init?(_ values: [String]) {
        guard let logIndex = values.firstIndex(of: "--log"), values.indices.contains(logIndex + 1),
              let readyIndex = values.firstIndex(of: "--ready"), values.indices.contains(readyIndex + 1) else {
            return nil
        }
        logPath = values[logIndex + 1]
        readyPath = values[readyIndex + 1]
    }
}

guard let arguments = Arguments(CommandLine.arguments) else {
    FileHandle.standardError.write(Data("usage: DeliveryFixtureApp --log PATH --ready PATH\n".utf8))
    exit(64)
}

do {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = FixtureDelegate(log: try NDJSONLogger(path: arguments.logPath), readyPath: arguments.readyPath)
    app.delegate = delegate
    app.run()
} catch {
    FileHandle.standardError.write(Data("fixture failed: \(error)\n".utf8))
    exit(1)
}
