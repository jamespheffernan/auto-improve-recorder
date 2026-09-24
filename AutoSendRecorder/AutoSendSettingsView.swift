import AppKit
import AVFoundation
import SwiftUI

struct AutoSendSettingsView: View {
    @ObservedObject var state: AutoSendState
    @ObservedObject private var settings: AutoSendSettingsStore
    @State private var shortcutError: String?
    @State private var dictionaryRules: [DictionaryReplacementRule] = []

    init(state: AutoSendState) {
        self.state = state
        _settings = ObservedObject(wrappedValue: state.settings)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 42, height: 42)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto Send Recorder")
                            .font(.title2.bold())
                        Text("Local transcription, then immediate delivery.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    AutoSendSettingsStatus(state: state.experienceState)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(settings.recordingShortcut.displayName)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                    Text(state.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                GroupBox("Shortcuts") {
                    VStack(spacing: 12) {
                        AutoSendShortcutRow(
                            title: "Record and send",
                            help: "Works system-wide in either trigger mode.",
                            shortcut: settings.recordingShortcut
                        ) { shortcutError = settings.updateRecordingShortcut($0) }
                        Divider()
                        AutoSendShortcutRow(
                            title: "Cancel",
                            help: "Stops the active recording or delivery.",
                            shortcut: settings.cancelShortcut
                        ) { shortcutError = settings.updateCancelShortcut($0) }
                        if let shortcutError {
                            Label(shortcutError, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityLabel("Shortcut error: \(shortcutError)")
                        }
                        Text("Click a shortcut, then type a new combination. Include Control, Option, or Command.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Recording trigger")
                            .fontWeight(.medium)
                        Text(settings.triggerMode == .walkieTalkie
                             ? "Hold the shortcut and release to send. Press Space while recording to lock it hands-free."
                             : "Press once to start and again to send.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Recording trigger", selection: $settings.triggerMode) {
                        ForEach(AutoSendTriggerMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
                .padding(.horizontal, 4)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Microphone")
                            .fontWeight(.medium)
                        Text(microphoneHelpText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Picker("Microphone", selection: $settings.preferredMicrophoneID) {
                        Text("System default").tag("")
                        ForEach(state.availableMicrophones.filter { !$0.isSystemDefaultPlaceholder }) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                }
                .padding(.horizontal, 4)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wireless recorder")
                            .fontWeight(.medium)
                        Text("Optional. Turning this on asks for Bluetooth access and listens for the paired recorder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Toggle("Wireless recorder", isOn: $settings.wirelessRecorderEnabled)
                        .labelsHidden()
                }
                .padding(.horizontal, 4)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Menu bar icon")
                            .fontWeight(.medium)
                        Text(settings.menuBarIconStyle == .white
                             ? "Keep the icon white in every recorder state."
                             : "Use the macOS menu bar color and show recorder state colors.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Menu bar icon", selection: $settings.menuBarIconStyle) {
                        ForEach(AutoSendMenuBarIconStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityLabel("Menu bar icon color")
                }
                .padding(.horizontal, 4)

                GroupBox("Send action by app") {
                    VStack(spacing: 0) {
                        LazyVStack(spacing: 0) {
                            ForEach($settings.rules) { $rule in
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(rule.appName)
                                            .fontWeight(.medium)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        Text(rule.bundleIdentifier)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    Picker("Send action", selection: $rule.action) {
                                        ForEach(AutoSendAction.allCases) { action in
                                            Text(action.label).tag(action)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(width: 150)
                                    .accessibilityLabel("Send action for \(rule.appName)")
                                }
                                .padding(.vertical, 8)

                                if rule.id != settings.rules.last?.id {
                                    Divider()
                                }
                            }
                        }

                        Divider()
                        HStack(spacing: 8) {
                            Button("Add Current App") {
                                state.addFrontmostAppRule()
                            }
                            Spacer()
                        }
                        .padding(.top, 10)
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Label("Known apps without a rule use Enter.", systemImage: "return")
                    Label("WhatsApp is Do not send.", systemImage: "hand.raised.fill")
                    Label("Unknown destination never sends.", systemImage: "shield.fill")
                    Text("Auto Send sends only when it can verify a focused text field and confirm that it did not change during delivery.")
                        .padding(.leading, 21)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                GroupBox("Dictionary") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Replacement rules run on every recording before it is sent: \(dictionaryRules.count) now, from Auto Improve Recorder's Dictionary settings and the lexicon at ~/.config/lexicon/terms.json. Edit rules in Auto Improve Recorder.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Dictionary terms are not used here. Parakeet takes no vocabulary, and Auto Send has no cleanup pass, so a name is corrected only when a rule covers it.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
            }
            .padding(18)
        }
        .frame(width: 560)
        .onAppear {
            state.refreshMicrophones()
            dictionaryRules = state.replacementRules.currentRules()
        }
    }

    private var microphoneHelpText: String {
        guard !settings.preferredMicrophoneID.isEmpty else {
            return "Uses the current macOS input."
        }
        let selected = state.availableMicrophones.first {
            $0.id == settings.preferredMicrophoneID
        }
        guard selected?.name.compare(
            AutoSendMicrophoneSelection.boyaMicrophoneName,
            options: .caseInsensitive
        ) == .orderedSame else {
            return "Uses the selected microphone immediately."
        }
        return "BOYA is used when its lav is live. Anker is used when the BOYA receiver has digital silence. The route is ready before recording starts."
    }
}

private struct AutoSendSettingsStatus: View {
    let state: AutoSendExperienceState

    var body: some View {
        Label(state.title, systemImage: state.symbolName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tone.settingsColor)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                state.tone.settingsColor.opacity(0.1),
                in: Capsule(style: .continuous)
            )
            .accessibilityLabel("Recorder status: \(state.title)")
    }
}

private extension AutoSendExperienceTone {
    var settingsColor: Color {
        switch self {
        case .neutral: return .secondary
        case .recording, .failure: return .red
        case .success: return .green
        case .informational: return .blue
        case .warning: return .orange
        }
    }
}

private struct AutoSendShortcutRow: View {
    let title: String
    let help: String
    let shortcut: AutoSendKeyboardShortcut
    let onChange: (AutoSendKeyboardShortcut) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            AutoSendShortcutRecorder(shortcut: shortcut, onChange: onChange)
                .frame(width: 150)
        }
    }
}

private struct AutoSendShortcutRecorder: NSViewRepresentable {
    let shortcut: AutoSendKeyboardShortcut
    let onChange: (AutoSendKeyboardShortcut) -> Void

    func makeNSView(context: Context) -> AutoSendShortcutRecorderControl {
        AutoSendShortcutRecorderControl(shortcut: shortcut, onChange: onChange)
    }

    func updateNSView(_ control: AutoSendShortcutRecorderControl, context: Context) {
        control.shortcut = shortcut
        control.onChange = onChange
    }
}

private final class AutoSendShortcutRecorderControl: NSButton {
    var shortcut: AutoSendKeyboardShortcut {
        didSet {
            if !isRecordingShortcut {
                updateTitle()
            }
        }
    }
    var onChange: (AutoSendKeyboardShortcut) -> Void
    private var isRecordingShortcut = false

    init(shortcut: AutoSendKeyboardShortcut, onChange: @escaping (AutoSendKeyboardShortcut) -> Void) {
        self.shortcut = shortcut
        self.onChange = onChange
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecordingShortcut)
        focusRingType = .exterior
        toolTip = "Click, then type a new keyboard shortcut"
        updateTitle()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecordingShortcut() {
        isRecordingShortcut = true
        title = "Type shortcut…"
        setAccessibilityValue("Waiting for a shortcut")
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        isRecordingShortcut = false
        updateTitle()
        return result
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }

        let modifiers = Self.shortcutModifiers(from: event.modifierFlags)
        if event.keyCode == 53 && modifiers.isEmpty {
            isRecordingShortcut = false
            updateTitle()
            return
        }

        guard !modifiers.intersection(.requiredForGlobalShortcut).isEmpty else {
            NSSound.beep()
            title = "Add a modifier"
            return
        }

        let updated = AutoSendKeyboardShortcut(
            keyCode: UInt32(event.keyCode),
            keyLabel: Self.keyLabel(for: event),
            modifiers: modifiers
        )
        shortcut = updated
        isRecordingShortcut = false
        updateTitle()
        onChange(updated)
        window?.makeFirstResponder(nil)
    }

    private func updateTitle() {
        title = shortcut.displayName
        setAccessibilityLabel("Keyboard shortcut")
        setAccessibilityValue(shortcut.displayName)
    }

    private static func shortcutModifiers(from flags: NSEvent.ModifierFlags) -> AutoSendShortcutModifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: AutoSendShortcutModifiers = []
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.command) { result.insert(.command) }
        return result
    }

    private static func keyLabel(for event: NSEvent) -> String {
        switch event.keyCode {
        case 36: return "Return"
        case 48: return "Tab"
        case 49: return "Space"
        case 51: return "Delete"
        case 53: return "Esc"
        case 115: return "Home"
        case 116: return "Page Up"
        case 117: return "Forward Delete"
        case 119: return "End"
        case 121: return "Page Down"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let label = event.charactersIgnoringModifiers?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() ?? ""
            return label.isEmpty ? "Key \(event.keyCode)" : label
        }
    }
}

struct AutoSendOnboardingView: View {
    @ObservedObject var state: AutoSendState
    @ObservedObject private var settings: AutoSendSettingsStore
    let onFinish: () -> Void

    @State private var page = 0
    @State private var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityTrusted = AccessibilityPasteController.isTrusted(prompt: false)
    @State private var practiceText = ""
    @State private var installTask: Task<Void, Never>?
    @State private var installProgress = 0.0
    @State private var installMessage = ""
    @State private var installedRuntime = false

    init(state: AutoSendState, onFinish: @escaping () -> Void) {
        self.state = state
        _settings = ObservedObject(wrappedValue: state.settings)
        self.onFinish = onFinish
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto Send Recorder")
                        .font(.title2.bold())
                    Text("Install speech models, then allow microphone and paste access.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(page + 1) of 3")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            ProgressView(value: Double(page + 1), total: 3)
                .progressViewStyle(.linear)
                .padding(.horizontal, 28)
                .padding(.top, 18)

            Group {
                switch page {
                case 0:
                    welcomePage
                case 1:
                    permissionsPage
                default:
                    firstUsePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(28)

            Divider()

            HStack {
                if page > 0 {
                    Button("Back") {
                        page -= 1
                    }
                }
                Spacer()
                Button(page == 2 ? "Finish later" : "Skip setup") {
                    onFinish()
                }
                if page < 2 {
                    Button("Continue") {
                        page += 1
                        refreshPermissions()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(installTask != nil || installedRuntime || (page == 0 && !runtimeStatus.isReady))
                } else if !state.lastText.isEmpty || !practiceText.isEmpty {
                    Button("Finish Setup") {
                        onFinish()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(18)
        }
        .frame(width: 680, height: 700)
        .onAppear {
            refreshPermissions()
            state.refreshMicrophones()
        }
        .onChange(of: state.lastText) { text in
            guard !text.isEmpty else { return }
            practiceText = text
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text("Speak once. Your words appear where you were typing.")
                .font(.largeTitle.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("Pick a microphone, allow two macOS permissions, then make a real local dictation. Audio and transcription stay on this Mac; recordings are kept in Application Support.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(runtimeStatus.message, systemImage: runtimeStatus.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(runtimeStatus.isReady ? .green : .orange)
                .accessibilityLabel("Local transcription: \(runtimeStatus.message)")

            if installedRuntime {
                Text("Speech models are installed. Quit and reopen Auto Send Recorder to finish setup.")
                Button("Quit to finish setup") { NSApp.terminate(nil) }
            } else if !runtimeStatus.isReady {
                Text("Download 1.75 GB of speech models from Hugging Face. Setup needs 4 GB of free space. After setup, transcription works offline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if installTask != nil {
                    ProgressView(value: installProgress)
                    Button("Cancel download") { installTask?.cancel() }
                } else {
                    Button("Install speech models") { installSpeechModels() }
                }
                if !installMessage.isEmpty {
                    Text(installMessage).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func installSpeechModels() {
        guard let runtime = Bundle.main.resourceURL?.appendingPathComponent("SpeechRuntime"),
              FileManager.default.fileExists(atPath: runtime.path) else {
            installMessage = "The speech engine is missing from this app. Download the complete installer from asr.turfterrace.com."
            return
        }
        installTask = Task {
            do {
                try await AutoSendRuntimeInstaller.install(bundledRuntime: runtime) { message, fraction in
                    Task { @MainActor in
                        installMessage = message
                        installProgress = fraction
                    }
                }
                installedRuntime = true
            } catch {
                installMessage = error is CancellationError ? "Download cancelled. You can retry setup." : error.localizedDescription
            }
            installTask = nil
        }
    }

    private var permissionsPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Allow access deliberately")
                .font(.title.bold())
            Text("Microphone records your voice. Accessibility pastes the transcript into the field you selected. Without Accessibility, the transcript is copied to the clipboard instead.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AutoSendPermissionRow(
                title: "Microphone",
                detail: microphonePermissionDetail,
                isGranted: microphoneAuthorization == .authorized,
                buttonTitle: microphoneButtonTitle,
                action: requestMicrophonePermission
            )

            Divider()

            AutoSendPermissionRow(
                title: "Accessibility",
                detail: accessibilityTrusted
                    ? "Ready to paste into the focused text field."
                    : "Needed for automatic paste; clipboard fallback remains available.",
                isGranted: accessibilityTrusted,
                buttonTitle: accessibilityTrusted ? "Granted" : "Allow Accessibility",
                action: requestAccessibilityPermission
            )

            Divider()

            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(settings.wirelessRecorderEnabled ? .blue : .secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Wireless recorder (optional)")
                        .fontWeight(.semibold)
                    Text("Turn this on only if you use the paired recorder. macOS will then ask for Bluetooth access.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("Use wireless recorder", isOn: $settings.wirelessRecorderEnabled)
                    .labelsHidden()
            }

            Button("Refresh permission status") {
                refreshPermissions()
            }
        }
    }

    private var firstUsePage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make your first dictation")
                .font(.title.bold())
            Text("Click in the field below, then hold \(settings.recordingShortcut.displayName), speak one sentence, and release. This practice field never submits anything.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $practiceText)
                    .font(.body)
                    .frame(height: 150)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    }
                    .accessibilityLabel("Practice dictation")
                if practiceText.isEmpty {
                    Text("Your transcript will appear here.")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }

            Label(state.statusMessage, systemImage: state.experienceState.symbolName)
                .font(.caption)
                .foregroundStyle(state.experienceState.tone.settingsColor)
                .fixedSize(horizontal: false, vertical: true)

            Text("Cancel any time with \(settings.cancelShortcut.displayName). You can replay this guide from the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var microphonePermissionDetail: String {
        switch microphoneAuthorization {
        case .authorized:
            return "Ready to record using \(selectedMicrophoneName)."
        case .notDetermined:
            return "macOS has not asked yet."
        case .denied:
            return "Denied. Open System Settings to allow access."
        case .restricted:
            return "Restricted by this Mac's policy."
        @unknown default:
            return "Permission status is unavailable."
        }
    }

    private var microphoneButtonTitle: String {
        switch microphoneAuthorization {
        case .authorized: return "Granted"
        case .notDetermined: return "Allow Microphone"
        case .denied, .restricted: return "Open Settings"
        @unknown default: return "Open Settings"
        }
    }

    private var selectedMicrophoneName: String {
        guard !settings.preferredMicrophoneID.isEmpty,
              let selected = state.availableMicrophones.first(where: { $0.id == settings.preferredMicrophoneID }) else {
            return "the system default"
        }
        return selected.name
    }

    private var runtimeStatus: (isReady: Bool, message: String) {
        let baseURL = ParakeetCppTranscriber.installBaseURL
        let executable = baseURL.appendingPathComponent("bin/parakeet-cli")
        let model = baseURL.appendingPathComponent("models/tdt-0.6b-v2-q4_k.gguf")
        let ready = FileManager.default.isExecutableFile(atPath: executable.path) &&
            FileManager.default.fileExists(atPath: model.path)
        return ready
            ? (true, "Local transcription runtime is ready.")
            : (false, "Local transcription runtime is incomplete.")
    }

    private func refreshPermissions() {
        microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityTrusted = AccessibilityPasteController.isTrusted(prompt: false)
    }

    private func requestMicrophonePermission() {
        guard microphoneAuthorization == .notDetermined else {
            openPrivacySettings(anchor: "Privacy_Microphone")
            return
        }
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run {
                refreshPermissions()
            }
        }
    }

    private func requestAccessibilityPermission() {
        _ = AccessibilityPasteController.isTrusted(prompt: true)
        openPrivacySettings(anchor: "Privacy_Accessibility")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            refreshPermissions()
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}

private struct AutoSendPermissionRow: View {
    let title: String
    let detail: String
    let isGranted: Bool
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(isGranted ? .green : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(buttonTitle, action: action)
                .disabled(isGranted)
        }
        .accessibilityElement(children: .contain)
    }
}
