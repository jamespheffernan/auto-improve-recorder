import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @State private var selectedSection: SettingsSection = .recording

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SettingsSidebar(selection: $selectedSection)
                    .frame(width: 188)

                Divider()

                ScrollView {
                    SettingsPaneContent(section: selectedSection)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 24)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }

            ReadinessFooter()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(
            minWidth: 820,
            idealWidth: 900,
            maxWidth: .infinity,
            minHeight: 560,
            idealHeight: 680,
            maxHeight: .infinity
        )
        .onAppear {
            state.refreshMicrophones()
            state.refreshDeliveryRuleCandidateApps()
            state.refreshLocalModelStatuses()
            Task { await state.refreshReadiness() }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case recording
    case processing
    case output
    case providers
    case dictionary
    case readiness

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recording:
            return "Recording"
        case .processing:
            return "Processing"
        case .output:
            return "Output"
        case .providers:
            return "Providers"
        case .dictionary:
            return "Dictionary"
        case .readiness:
            return "Readiness"
        }
    }

    var subtitle: String {
        switch self {
        case .recording:
            return "Hotkey, trigger, and microphone input."
        case .processing:
            return "Transcription, cleanup, and local runtime choices."
        case .output:
            return "Cleanup style, clipboard, paste, and app rules."
        case .providers:
            return "Cloud keys and local Ollama settings."
        case .dictionary:
            return "Terms, replacement rules and the generated lexicon."
        case .readiness:
            return "Permissions, diagnostics, and current app status."
        }
    }

    var systemImage: String {
        switch self {
        case .recording:
            return "mic"
        case .processing:
            return "cpu"
        case .output:
            return "arrow.down.doc"
        case .providers:
            return "key"
        case .dictionary:
            return "character.book.closed"
        case .readiness:
            return "checkmark.shield"
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selection: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto Improve")
                    .font(.system(size: 16, weight: .semibold))
                Text("Settings")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 18)

            VStack(spacing: 4) {
                ForEach(SettingsSection.allCases) { section in
                    SettingsSidebarRow(
                        section: section,
                        isSelected: selection == section
                    ) {
                        selection = section
                    }
                }
            }
            .padding(.horizontal, 8)

            Spacer(minLength: 0)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.44))
    }
}

private struct SettingsSidebarRow: View {
    var section: SettingsSection
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 17)
                Text(section.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.accentColor.opacity(0.14))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsPaneContent: View {
    @EnvironmentObject private var state: AppState
    var section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsPaneHeader(section: section)

            switch section {
            case .recording:
                RecordingSettingsPane()
            case .processing:
                ProcessingSettingsPane()
            case .output:
                OutputSettingsPane()
            case .providers:
                ProvidersSettingsPane()
            case .dictionary:
                DictionarySettingsSection(store: state.dictionaryStore)
            case .readiness:
                ReadinessSettingsPane()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct SettingsPaneHeader: View {
    var section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(section.title)
                    .font(.system(size: 24, weight: .semibold))
            } icon: {
                Image(systemName: section.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Text(section.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }
}

private struct SettingsGroup<Content: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 145, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 12) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.vertical, 17)

            Divider()
        }
    }
}

private struct SettingRow<Control: View>: View {
    var title: String
    var detail: String?
    var controlWidth: CGFloat
    @ViewBuilder var control: () -> Control

    init(
        _ title: String,
        detail: String? = nil,
        controlWidth: CGFloat = 300,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.title = title
        self.detail = detail
        self.controlWidth = controlWidth
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            control()
                .frame(width: controlWidth, alignment: .trailing)
        }
    }
}

private struct SettingsInlineNote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RecordingSettingsPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup(
                title: "Capture",
                subtitle: "Set how dictation starts, stops, and cancels."
            ) {
                SettingRow("Trigger", detail: recordingTriggerNote, controlWidth: 240) {
                    Picker("", selection: $state.recordingTriggerMode) {
                        ForEach(RecordingTriggerMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                SettingRow("Hotkey", detail: "Click the key field, then press the shortcut.", controlWidth: 180) {
                    HotKeyRecorder(
                        hotKey: $state.recordingHotKey,
                        onCaptureChange: { isCapturing in
                            if isCapturing {
                                state.beginRecordingHotKeyCapture()
                            } else {
                                state.endRecordingHotKeyCapture()
                            }
                        }
                    )
                    .frame(width: 180, height: 28)
                }
            }

            SettingsGroup(
                title: "Microphone",
                subtitle: "Choose the input AIR should use and refresh available devices."
            ) {
                SettingRow("Input device", detail: state.resolvedMicrophoneSummary, controlWidth: 320) {
                    HStack(spacing: 8) {
                        Picker("", selection: $state.preferredMicrophoneID) {
                            ForEach(state.availableMicrophones) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 274)

                        Button {
                            state.refreshMicrophones()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh microphones")
                    }
                }
            }
        }
    }

    private var recordingTriggerNote: String {
        switch state.recordingTriggerMode {
        case .walkieTalkie:
            return "Hold to talk, release to send, or double-press to latch hands-free."
        case .toggle:
            return "Press once to start, press again to send. Esc cancels."
        }
    }
}

private struct ProcessingSettingsPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup(
                title: "Choose a preset",
                subtitle: "Start with a tested pipeline. Manual engine pairing is advanced."
            ) {
                ProcessingPresetSummary()

                LocalModelSettingsSection()

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingRow("Transcription", detail: transcriptionDetail, controlWidth: 280) {
                            Picker("", selection: $state.transcriptionMode) {
                                ForEach(TranscriptionMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                        }

                        SettingRow("Cleanup", detail: state.improvementMode.detailLabel, controlWidth: 280) {
                            Picker("", selection: $state.improvementMode) {
                                ForEach(ImprovementMode.allCases) { mode in
                                    Text(mode.label).tag(mode)
                                }
                            }
                            .labelsHidden()
                        }

                        SettingsInlineNote(text: processingNote)
                    }
                    .padding(.top, 8)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advanced engine pairing")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Manually choose transcription and cleanup only when a preset does not fit.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                }

            }

            SettingsGroup(
                title: "Auto-improve",
                subtitle: "Control when the cleanup pass runs."
            ) {
                SettingRow("Mode", detail: autoImproveDetail, controlWidth: 240) {
                    Picker("", selection: $state.autoImproveMode) {
                        ForEach(AutoImproveMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                SettingRow("Threshold", detail: "Automatic cleanup starts once the transcript reaches this length.", controlWidth: 200) {
                    Stepper("\(state.thresholdWords) words", value: $state.thresholdWords, in: 1...500)
                }
            }
        }
    }

    private var transcriptionDetail: String {
        switch state.transcriptionMode {
        case .localWhisper, .localParakeetCppFast, .localParakeetCppRecommended, .localParakeetCppResident, .localParakeetStreaming, .appleLocal:
            return "Audio stays on this Mac."
        case .openAIAPI, .fastest:
            return "Audio may be sent to OpenAI."
        }
    }

    private var autoImproveDetail: String {
        switch state.autoImproveMode {
        case .off:
            return "Always keep the raw transcript."
        case .manual:
            return "Clean only when you click Re-run."
        case .automatic:
            return "Clean automatically above the threshold."
        }
    }

    private var processingNote: String {
        if state.transcriptionMode == .localWhisper && state.improvementMode == .ollamaLocal {
            return "LAIR local mode uses whisper.cpp for transcription and Ollama qwen3.5:0.8b-mlx for cleanup."
        }

        if state.transcriptionMode == .localParakeetCppFast && state.improvementMode == .ollamaLocal {
            return "All-local mode uses Parakeet.cpp 110M Fast for transcription and Ollama qwen3.5:0.8b-mlx for cleanup."
        }

        if state.transcriptionMode == .localParakeetCppRecommended && state.improvementMode == .ollamaLocal {
            return "All-local mode uses Parakeet.cpp 0.6B Recommended for transcription and Ollama qwen3.5:0.8b-mlx for cleanup."
        }

        if state.transcriptionMode == .localParakeetCppResident && state.improvementMode == .ollamaLocal {
            return "All-local mode uses resident Parakeet.cpp 0.6B for transcription and Ollama qwen3.5:0.8b-mlx for cleanup."
        }

        if state.transcriptionMode == .localParakeetStreaming && state.improvementMode == .ollamaLocal {
            return "All-local mode uses resident Parakeet Live transcription and Ollama qwen3.5:0.8b-mlx for cleanup."
        }

        if state.transcriptionMode == .appleLocal && state.improvementMode == .appleLocal {
            return "All-local mode uses Apple Speech for transcription and Apple Intelligence for cleanup when available on this Mac."
        }

        if state.improvementMode == .appleLocal {
            return "Apple local improvement uses the on-device Apple Intelligence model when available on this Mac."
        }

        if state.improvementMode == .geminiFlash {
            return "Gemini Flash cleanup sends transcript text to Google. Local transcription can still stay on this Mac."
        }

        if state.improvementMode == .claudeHaiku {
            return "Claude Haiku cleanup sends transcript text to Anthropic. Local transcription can still stay on this Mac."
        }

        if state.improvementMode == .ollamaLocal {
            return "Ollama local cleanup sends transcript text to the local Ollama server. Paired with Local Whisper, Parakeet, or Parakeet.cpp, the full flow stays on this Mac."
        }

        if state.transcriptionMode == .appleLocal {
            return "Apple Speech keeps transcription local, then sends text to OpenAI for cleanup when auto-improve runs."
        }

        return "OpenAI cleanup uses the API key in Providers. Local Whisper, Parakeet, and Apple Speech transcription stay on this Mac."
    }
}

private struct ProcessingPresetSummary: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(currentPathTitle, systemImage: currentPathSymbol)
                    .font(.system(size: 14, weight: .semibold))

                Text("Current path")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())

                Spacer()

                Button {
                    state.refreshLocalModelStatuses()
                } label: {
                    Label("Check presets", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }

            Text(currentPathDetail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
    }

    private var currentPathTitle: String {
        if state.transcriptionMode == .localParakeetCppRecommended && state.improvementMode == .ollamaLocal {
            return "All Local"
        }

        switch state.transcriptionMode {
        case .localParakeetCppRecommended:
            return "Recommended local"
        case .localParakeetCppResident:
            return "Resident local"
        case .localParakeetStreaming:
            return "Parakeet Live"
        case .localParakeetCppFast:
            return "Fast local"
        case .appleLocal:
            return "Apple Speech"
        case .fastest:
            return "Cloud Realtime"
        case .localWhisper, .openAIAPI:
            return "Custom pairing"
        }
    }

    private var currentPathSymbol: String {
        switch state.transcriptionMode {
        case .fastest, .openAIAPI:
            return "cloud"
        case .localParakeetCppResident, .localParakeetStreaming:
            return "bolt.horizontal"
        case .localWhisper, .localParakeetCppFast, .localParakeetCppRecommended, .appleLocal:
            return "cpu"
        }
    }

    private var currentPathDetail: String {
        "Transcription: \(state.transcriptionMode.label). Cleanup: \(state.improvementMode.label). Pick a preset below to switch paths without manually pairing engines."
    }
}

private struct OutputSettingsPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup(
                title: "Cleanup style",
                subtitle: "Choose how strongly AIR rewrites dictation."
            ) {
                SettingRow("Style", detail: state.outputMode.promptIntensity, controlWidth: 320) {
                    Picker("", selection: $state.outputMode) {
                        ForEach(OutputMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            SettingsGroup(
                title: "Delivery",
                subtitle: "Default behavior after the final text is ready."
            ) {
                Toggle("Copy finished text to clipboard", isOn: $state.copyFinishedTextToClipboard)
                    .toggleStyle(.checkbox)
                Toggle("Auto-submit in detected text fields", isOn: $state.autoSubmitDetectedTextFields)
                    .toggleStyle(.checkbox)
            }

            SettingsGroup(
                title: "App rules",
                subtitle: "Override paste, clipboard, and Return behavior per app."
            ) {
                AppRulesEditor()
            }
        }
    }
}

private struct AppRulesEditor: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Menu {
                    if state.deliveryRuleCandidateApps.isEmpty {
                        Text("No available running apps")
                    } else {
                        ForEach(state.deliveryRuleCandidateApps) { app in
                            Button(app.displayName) {
                                state.addAppDeliveryRule(for: app)
                            }
                        }
                    }
                } label: {
                    Label("Add running app", systemImage: "plus")
                }

                Button {
                    state.refreshDeliveryRuleCandidateApps()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button("Restore defaults") {
                    state.resetAppDeliveryRulesToDefaults()
                }

                Spacer()
            }

            if state.appDeliveryRules.isEmpty {
                SettingsInlineNote(text: "No app rules configured.")
            } else {
                VStack(spacing: 8) {
                    ForEach($state.appDeliveryRules) { $rule in
                        AppDeliveryRuleRow(rule: $rule) {
                            state.removeAppDeliveryRule(id: rule.id)
                        }
                    }
                }
            }
        }
    }
}

private struct ProvidersSettingsPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup(
                title: "Cloud keys",
                subtitle: "Only used when a matching cloud engine is selected."
            ) {
                SettingRow("OpenAI", detail: "Used by OpenAI cleanup and Cloud Realtime.", controlWidth: 320) {
                    SecureField("sk-...", text: $state.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                SettingRow("Gemini", detail: "Used by Gemini Flash cleanup.", controlWidth: 320) {
                    SecureField("AIza...", text: $state.geminiAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                SettingRow("Anthropic", detail: "Used by Claude Haiku cleanup.", controlWidth: 320) {
                    SecureField("sk-ant-...", text: $state.anthropicAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
            }

            SettingsGroup(
                title: "Ollama",
                subtitle: "Local cleanup server and model."
            ) {
                SettingRow("Base URL", detail: "Default local Ollama endpoint.", controlWidth: 320) {
                    TextField("Base URL", text: $state.ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)
                }
                SettingRow("Model", detail: "AIR expects the qwen3.5 local cleanup model by default.", controlWidth: 320) {
                    TextField("Model", text: $state.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                }
                SettingsInlineNote(text: "Start Ollama locally and pull the selected model before choosing Ollama local cleanup.")
            }
        }
    }
}

private struct ReadinessSettingsPane: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup(
                title: "Permissions",
                subtitle: "Recording and automatic paste depend on these macOS permissions."
            ) {
                PermissionStatusRow(
                    title: "Microphone",
                    systemImage: "mic",
                    state: state.permissionStatus.microphone,
                    detail: microphonePermissionDetail,
                    actionTitle: "Refresh",
                    action: refreshReadiness
                )
                PermissionStatusRow(
                    title: "Accessibility",
                    systemImage: "keyboard",
                    state: state.permissionStatus.accessibility,
                    detail: accessibilityPermissionDetail,
                    actionTitle: "Prompt Accessibility",
                    action: { state.promptForAccessibilityPermission() },
                    secondaryTitle: "Refresh",
                    secondaryAction: refreshReadiness
                )
            }

            SettingsGroup(
                title: "Diagnostics",
                subtitle: "The latest saved issue and copyable technical details."
            ) {
                DiagnosticsStatusRow(event: state.diagnosticEvents.first)
            }
        }
    }

    private func refreshReadiness() {
        Task { await state.refreshReadiness() }
    }

    private var microphonePermissionDetail: String {
        switch state.permissionStatus.microphone {
        case .authorized:
            return "Ready: recording can use the microphone."
        case .notDetermined:
            return "Next: start a recording and grant microphone access when macOS asks."
        case .denied:
            return "Blocked: enable Microphone access for AutoImproveRecorder in System Settings, then refresh."
        case .restricted:
            return "Blocked by macOS policy. Check Screen Time, device management, or System Settings."
        case .unavailable:
            return "Unavailable: AIR cannot read microphone permission on this Mac."
        }
    }

    private var accessibilityPermissionDetail: String {
        switch state.permissionStatus.accessibility {
        case .authorized:
            return "Ready: AIR can paste finished text into the focused app."
        case .notDetermined:
            return "Next: prompt macOS for Accessibility access so AIR can paste automatically."
        case .denied:
            return "Next: open the macOS Accessibility prompt, approve AutoImproveRecorder, then refresh."
        case .restricted:
            return "Blocked by macOS policy. Check System Settings or device management before automatic paste will work."
        case .unavailable:
            return "Unavailable: AIR cannot check Accessibility trust on this Mac."
        }
    }
}

private struct ReadinessFooter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
                if hasPermissionAction {
                    Label(footerActionMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)

                    if state.permissionStatus.accessibility != .authorized {
                        Button("Prompt Accessibility") {
                            state.promptForAccessibilityPermission()
                        }
                        .controlSize(.small)
                    }

                    Button("Refresh") {
                        Task { await state.refreshReadiness() }
                    }
                    .controlSize(.small)
                } else {
                    FooterPermissionBadge(
                        title: "Mic",
                        systemImage: "mic",
                        state: state.permissionStatus.microphone
                    )
                    FooterPermissionBadge(
                        title: "Accessibility",
                        systemImage: "keyboard",
                        state: state.permissionStatus.accessibility
                    )
                }

                Spacer(minLength: 12)

                if let message = state.statusMessage,
                   !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    private var hasPermissionAction: Bool {
        state.permissionStatus.microphone != .authorized || state.permissionStatus.accessibility != .authorized
    }

    private var footerActionMessage: String {
        let microphoneNeedsAction = state.permissionStatus.microphone != .authorized
        let accessibilityNeedsAction = state.permissionStatus.accessibility != .authorized

        if microphoneNeedsAction && accessibilityNeedsAction {
            return "Microphone and Accessibility need attention."
        }

        if microphoneNeedsAction {
            return "Microphone permission needs attention."
        }

        return "Accessibility is needed for automatic paste."
    }
}

private struct FooterPermissionBadge: View {
    var title: String
    var systemImage: String
    var state: PermissionState

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Circle()
                .fill(state.readinessDotColor)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .help("\(title): \(state.readinessLabel)")
    }
}

private struct PermissionStatusRow: View {
    var title: String
    var systemImage: String
    var state: PermissionState
    var detail: String
    var actionTitle: String?
    var action: (() -> Void)?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        ActionableStatusRow(
            title: title,
            subtitle: nil,
            detail: detail,
            statusLabel: state.readinessLabel,
            systemImage: systemImage,
            tint: state.readinessTint,
            actionTitle: actionTitle,
            action: action,
            secondaryTitle: secondaryTitle,
            secondaryAction: secondaryAction
        )
    }
}

private struct DiagnosticsStatusRow: View {
    @EnvironmentObject private var state: AppState
    var event: DiagnosticEvent?

    var body: some View {
        if let event {
            ActionableStatusRow(
                title: event.summary,
                subtitle: event.subsystem.label,
                detail: "Next: copy details if you need to troubleshoot this issue. \(event.diagnosticsSubtitle)",
                statusLabel: event.severity.label,
                systemImage: event.subsystem.systemImage,
                tint: event.severity.statusTint,
                actionTitle: "Copy details",
                action: { state.copyLatestDiagnostics() },
                secondaryTitle: "Refresh",
                secondaryAction: { state.refreshDiagnostics() }
            )
        } else {
            ActionableStatusRow(
                title: "No recent diagnostics",
                subtitle: nil,
                detail: "If recording, provider, runtime, or delivery fails, the latest issue will appear here.",
                statusLabel: "Clear",
                systemImage: "checkmark.circle.fill",
                tint: .green,
                actionTitle: "Refresh",
                action: { state.refreshDiagnostics() }
            )
        }
    }
}

private struct ActionableStatusRow: View {
    var title: String
    var subtitle: String? = nil
    var detail: String
    var statusLabel: String
    var systemImage: String
    var tint: Color
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 6) {
                Text(statusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.14))
                    .clipShape(Capsule())

                if hasActions {
                    HStack(spacing: 6) {
                        if let actionTitle, let action {
                            Button(actionTitle, action: action)
                                .controlSize(.small)
                        }

                        if let secondaryTitle, let secondaryAction {
                            Button(secondaryTitle, action: secondaryAction)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 10)
    }

    private var hasActions: Bool {
        (actionTitle != nil && action != nil) || (secondaryTitle != nil && secondaryAction != nil)
    }
}

private struct LocalModelSettingsSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            recommendedRow
            Divider()
            allLocalRow
            Divider()
            cloudRealtimeRow
            Divider()
            residentRow
            Divider()
            fastRow
            Divider()
            appleSpeechRow
        }
    }

    private var recommendedRow: some View {
        LocalModelStatusRow(
            status: status(for: .parakeetCppRecommended),
            fallbackDescriptor: LocalModelInventory.descriptor(for: .parakeetCppRecommended),
            actionTitle: "Use Recommended",
            action: { state.useRecommendedLocalTranscription() },
            secondaryTitle: "Check",
            secondaryAction: { state.refreshLocalModelStatuses() }
        )
    }

    private var residentRow: some View {
        LocalModelStatusRow(
            status: status(for: .parakeetCppResident),
            fallbackDescriptor: LocalModelInventory.descriptor(for: .parakeetCppResident),
            actionTitle: "Use Resident",
            action: { state.useResidentLocalTranscription() },
            secondaryTitle: "Check",
            secondaryAction: { state.refreshLocalModelStatuses() }
        )
    }

    private var fastRow: some View {
        LocalModelStatusRow(
            status: status(for: .parakeetCppFast),
            fallbackDescriptor: LocalModelInventory.descriptor(for: .parakeetCppFast),
            actionTitle: "Use Fast",
            action: { state.useFastLocalTranscription() },
            secondaryTitle: "Check",
            secondaryAction: { state.refreshLocalModelStatuses() }
        )
    }

    private var allLocalRow: some View {
        LocalModelStatusRow(
            status: status(for: .allLocal),
            fallbackDescriptor: LocalModelInventory.descriptor(for: .allLocal),
            actionTitle: "Use All Local",
            action: { state.useAllLocalPreset() },
            secondaryTitle: "Check all",
            secondaryAction: { state.refreshLocalModelStatuses() }
        )
    }

    private var appleSpeechRow: some View {
        LocalModelStatusRow(
            status: status(for: .appleSpeech),
            fallbackDescriptor: LocalModelInventory.descriptor(for: .appleSpeech),
            actionTitle: "Use Apple Speech",
            action: { state.useAppleSpeechPreset() },
            secondaryTitle: "Check",
            secondaryAction: { state.refreshLocalModelStatuses() }
        )
    }

    private var cloudRealtimeRow: some View {
        LocalModelStatusRow(
            status: status(for: .cloudRealtime),
            fallbackDescriptor: LocalModelInventory.descriptor(for: .cloudRealtime),
            actionTitle: "Use Cloud Realtime",
            action: { state.useCloudRealtimePreset() },
            secondaryTitle: cloudDiagnosticsTitle,
            secondaryAction: cloudDiagnosticsAction
        )
    }

    private var cloudDiagnosticsTitle: String? {
        state.lastOpenAIRealtimeDiagnostics == nil ? nil : "Copy diagnostics"
    }

    private var cloudDiagnosticsAction: (() -> Void)? {
        guard state.lastOpenAIRealtimeDiagnostics != nil else { return nil }
        return { state.copyOpenAIRealtimeDiagnostics() }
    }

    private func status(for id: LocalModelID) -> LocalModelStatus? {
        state.localModelStatus(for: id)
    }
}

private struct LocalModelStatusRow: View {
    var status: LocalModelStatus?
    var fallbackDescriptor: LocalModelDescriptor
    var actionTitle: String
    var action: () -> Void
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?

    private var descriptor: LocalModelDescriptor {
        status?.descriptor ?? fallbackDescriptor
    }

    private var state: LocalModelState {
        status?.state ?? .checking
    }

    private var detail: String {
        status?.primaryIssueText ?? status?.detail ?? "Checking local status..."
    }

    var body: some View {
        ActionableStatusRow(
            title: descriptor.title,
            subtitle: descriptor.subtitle,
            detail: "\(nextStep) \(detail)",
            statusLabel: state.label,
            systemImage: statusSymbol,
            tint: statusTint,
            actionTitle: actionTitle.isEmpty ? nil : actionTitle,
            action: actionTitle.isEmpty ? nil : action,
            secondaryTitle: secondaryTitle,
            secondaryAction: secondaryAction
        )
    }

    private var nextStep: String {
        switch state {
        case .ready, .installed:
            return "Ready: choose this preset when you want this processing path."
        case .checking:
            return "Checking: AIR is reading the current local runtime state."
        case .loading:
            return "Loading: wait for the runtime check to finish."
        case .downloading:
            return "Downloading: keep Settings open until the model download completes."
        case .needsModel:
            if descriptor.id == .allLocal {
                return "Next: install the missing Parakeet model or pull the Ollama cleanup model, then check again."
            }
            return "Next: install the missing model file, then check again."
        case .needsRuntime:
            if descriptor.id == .cloudRealtime {
                return "Next: add an OpenAI API key in Providers, then check again."
            }
            if descriptor.id == .parakeetCppResident {
                return "Next: install the optional resident runtime, or use Recommended local instead."
            }
            return "Next: install the required local runtime, then check again."
        case .externalAppRequired:
            if descriptor.id == .allLocal {
                return "Next: start Ollama locally and pull qwen3.5:0.8b-mlx, then check again."
            }
            return "Next: open the required local app or service, then check again."
        case .unavailable:
            if descriptor.id == .parakeetCppRecommended {
                return "This Mac will use one-shot Parakeet.cpp Recommended instead."
            }
            return "No AIR action is available for this Mac right now."
        case .failed:
            return "Next: check again or copy diagnostics if this keeps failing."
        }
    }

    private var statusSymbol: String {
        switch state {
        case .ready, .installed:
            return "checkmark.circle.fill"
        case .checking, .loading:
            return "arrow.clockwise.circle.fill"
        case .downloading:
            return "arrow.down.circle.fill"
        case .needsModel, .needsRuntime, .externalAppRequired, .unavailable:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }

    private var statusTint: Color {
        switch state {
        case .ready, .installed:
            return .green
        case .checking, .loading, .downloading:
            return .blue
        case .needsModel, .needsRuntime, .externalAppRequired, .unavailable:
            return .orange
        case .failed:
            return .red
        }
    }
}

private struct DictionarySettingsSection: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject var store: UserDictionaryStore
    @State private var newEntryText = ""
    @State private var newRulePhrase = ""
    @State private var newRuleReplacement = ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsGroup(
                title: "In the current mode",
                subtitle: "What the dictionary does with your settings as they are now."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(currentModeLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            SettingsGroup(
                title: "Terms",
                subtitle: "Names and phrases AIR should recognize and preserve."
            ) {
                HStack(spacing: 8) {
                    TextField("Word or phrase", text: $newEntryText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addEntry)
                    Button {
                        addEntry()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }

                if store.entries.isEmpty {
                    Text("No dictionary entries yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(store.entries) { entry in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.text)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1)
                                    Text(entry.source)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    state.deleteDictionaryEntry(id: entry.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete dictionary entry")
                            }
                        }
                    }
                }

            }

            SettingsGroup(
                title: "Replacements",
                subtitle: "Rewrite a dictated phrase into the exact text you want."
            ) {
                HStack(spacing: 8) {
                    TextField("Phrase", text: $newRulePhrase)
                        .textFieldStyle(.roundedBorder)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("Replacement", text: $newRuleReplacement)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addReplacementRule)
                    Button {
                        addReplacementRule()
                    } label: {
                        Label("Rule", systemImage: "plus")
                    }
                }

                if store.replacementRules.isEmpty {
                    Text("No replacement rules yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(store.replacementRules) { rule in
                            HStack(spacing: 8) {
                                Text(rule.phrase)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(.secondary)
                                Text(rule.replacement)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    state.deleteReplacementRule(id: rule.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete replacement rule")
                            }
                        }
                    }
                }
            }

            SettingsGroup(
                title: "Lexicon",
                subtitle: "Generated from your work in ~/.config/lexicon/terms.json. Read only here; your own terms and rules above take precedence."
            ) {
                Text("\(store.lexicon.terms.count) terms, \(store.lexicon.rules.count) rules")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                ForEach(store.lexicon.rules) { rule in
                    HStack(spacing: 8) {
                        Text(rule.phrase)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.secondary)
                        Text(rule.replacement)
                            .font(.system(size: 13))
                            .lineLimit(1)
                        Spacer()
                    }
                }
                if !store.lexicon.terms.isEmpty {
                    Text("Top terms: " + store.lexicon.terms.prefix(12).joined(separator: ", "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let lexiconError = store.lexiconLoadError {
                    Text(lexiconError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsGroup(
                title: "Import",
                subtitle: "Bring in terms and rules from Superwhisper."
            ) {
                HStack {
                    Button {
                        state.importSuperwhisperDictionary()
                    } label: {
                        Label("Import Superwhisper", systemImage: "square.and.arrow.down")
                    }
                    Spacer()
                    Text("\(store.entries.count) terms, \(store.replacementRules.count) rules")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if let loadError = store.lastLoadError {
                    Text(loadError)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { store.reloadLexicon() }
    }

    private var currentModeLines: [String] {
        let mode = state.transcriptionMode
        let rules = "Replacement rules run on every recording, before anything else reads the text: \(store.replacementRules.count) of yours and \(store.lexicon.rules.count) from the lexicon."
        let recogniser = mode.takesVocabulary
            ? "\(mode.label) receives up to 20 terms as a spelling hint."
            : "\(mode.label) takes no vocabulary, so terms do not reach the recogniser."
        let cleanup: String
        switch state.autoImproveMode {
        case .off:
            cleanup = "Auto Improve is off, so the cleanup prompt, and the terms in it, run only when you choose Improve."
        case .manual:
            cleanup = "Terms reach the cleanup prompt only when you choose Improve."
        case .automatic:
            cleanup = "Terms reach the cleanup prompt for recordings of \(state.thresholdWords) words or more; shorter recordings get the rules only."
        }
        return [rules, recogniser, cleanup]
    }

    private func addEntry() {
        let text = newEntryText
        state.addDictionaryEntry(text)
        if !UserDictionaryStore.normalizedText(text).isEmpty {
            newEntryText = ""
        }
    }

    private func addReplacementRule() {
        let phrase = newRulePhrase
        let replacement = newRuleReplacement
        state.addReplacementRule(phrase: phrase, replacement: replacement)
        if !UserDictionaryStore.normalizedText(phrase).isEmpty,
           !UserDictionaryStore.normalizedText(replacement).isEmpty {
            newRulePhrase = ""
            newRuleReplacement = ""
        }
    }
}

private struct AppDeliveryRuleRow: View {
    @Binding var rule: AppDeliveryRule
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Toggle("", isOn: $rule.isEnabled)
                    .toggleStyle(.checkbox)
                    .labelsHidden()

                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.appName)
                        .font(.system(size: 13, weight: .medium))
                    Text(rule.bundleIdentifier)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove app rule")
            }

            HStack(spacing: 8) {
                Picker("Paste", selection: $rule.pasteBehavior) {
                    ForEach(PasteBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                .pickerStyle(.menu)

                Picker("Submit", selection: $rule.submitBehavior) {
                    ForEach(SubmitBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                .pickerStyle(.menu)

                Picker("Clipboard", selection: $rule.clipboardBehavior) {
                    ForEach(ClipboardBehavior.allCases) { behavior in
                        Text(behavior.label).tag(behavior)
                    }
                }
                .pickerStyle(.menu)
            }
            .disabled(!rule.isEnabled)
            .opacity(rule.isEnabled ? 1.0 : 0.55)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
    }
}

private extension PermissionState {
    var readinessLabel: String {
        switch self {
        case .authorized:
            return "Ready"
        case .denied:
            return "Denied"
        case .notDetermined:
            return "Not requested"
        case .restricted:
            return "Restricted"
        case .unavailable:
            return "Unavailable"
        }
    }

    var readinessBadgeColor: Color {
        switch self {
        case .authorized:
            return Color.green.opacity(0.16)
        case .notDetermined:
            return Color.blue.opacity(0.14)
        case .denied, .restricted, .unavailable:
            return Color.orange.opacity(0.16)
        }
    }

    var readinessTint: Color {
        switch self {
        case .authorized:
            return .green
        case .notDetermined:
            return .blue
        case .denied, .restricted, .unavailable:
            return .orange
        }
    }

    var readinessDotColor: Color {
        switch self {
        case .authorized:
            return .green
        case .notDetermined:
            return .blue
        case .denied, .restricted, .unavailable:
            return .orange
        }
    }
}

private extension DiagnosticEvent {
    var diagnosticsSubtitle: String {
        let provider = relatedProvider.map { " - \($0)" } ?? ""
        let details = self.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if details.isEmpty {
            return "\(subsystem.label) - \(severity.label)\(provider)"
        }
        return "\(subsystem.label) - \(severity.label)\(provider): \(details)"
    }
}

private extension DiagnosticSubsystem {
    var label: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .accessibility:
            return "Accessibility"
        case .hotKey:
            return "Hot key"
        case .openAIRealtime:
            return "OpenAI realtime"
        case .transcription:
            return "Transcription"
        case .improvement:
            return "Improvement"
        case .localRuntime:
            return "Local runtime"
        case .archive:
            return "Archive"
        }
    }

    var systemImage: String {
        switch self {
        case .microphone:
            return "mic"
        case .accessibility:
            return "keyboard"
        case .hotKey:
            return "command"
        case .openAIRealtime:
            return "waveform"
        case .transcription:
            return "text.bubble"
        case .improvement:
            return "wand.and.stars"
        case .localRuntime:
            return "cpu"
        case .archive:
            return "archivebox"
        }
    }
}

private extension DiagnosticSeverity {
    var label: String {
        switch self {
        case .info:
            return "Info"
        case .warning:
            return "Warning"
        case .error:
            return "Error"
        }
    }

    var statusTint: Color {
        switch self {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

private struct HotKeyRecorder: NSViewRepresentable {
    @Binding var hotKey: RecordingHotKey
    var onCaptureChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(hotKey: $hotKey, onCaptureChange: onCaptureChange)
    }

    func makeNSView(context: Context) -> HotKeyRecorderButton {
        let button = HotKeyRecorderButton()
        button.onChange = { newHotKey in
            context.coordinator.hotKey.wrappedValue = newHotKey
        }
        button.onCaptureChange = { isCapturing in
            context.coordinator.onCaptureChange(isCapturing)
        }
        return button
    }

    func updateNSView(_ button: HotKeyRecorderButton, context: Context) {
        context.coordinator.hotKey = $hotKey
        context.coordinator.onCaptureChange = onCaptureChange
        button.hotKey = hotKey
        button.onChange = { newHotKey in
            context.coordinator.hotKey.wrappedValue = newHotKey
        }
        button.onCaptureChange = { isCapturing in
            context.coordinator.onCaptureChange(isCapturing)
        }
    }

    final class Coordinator {
        var hotKey: Binding<RecordingHotKey>
        var onCaptureChange: (Bool) -> Void

        init(hotKey: Binding<RecordingHotKey>, onCaptureChange: @escaping (Bool) -> Void) {
            self.hotKey = hotKey
            self.onCaptureChange = onCaptureChange
        }
    }
}

private final class HotKeyRecorderButton: NSButton {
    var hotKey: RecordingHotKey = .defaultValue {
        didSet {
            if !isCapturing {
                updateAppearance()
            }
        }
    }

    var onChange: ((RecordingHotKey) -> Void)?
    var onCaptureChange: ((Bool) -> Void)?

    private var isCapturing = false
    private var pendingModifiers: UInt32 = 0
    private var captureMessage: String?

    override var acceptsFirstResponder: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 180, height: 28)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else {
            super.keyDown(with: event)
            return
        }

        guard !event.isARepeat else { return }

        let keyCode = UInt32(event.keyCode)
        if keyCode == UInt32(kVK_Escape) {
            finishCapture(commit: nil)
            return
        }

        if keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete) {
            finishCapture(commit: .defaultValue)
            return
        }

        let candidate = RecordingHotKey(
            keyCode: keyCode,
            modifiers: Self.carbonModifiers(from: event.modifierFlags)
        )

        guard candidate.isValidForGlobalRegistration else {
            captureMessage = validationMessage(for: candidate)
            NSSound.beep()
            updateAppearance()
            return
        }

        finishCapture(commit: candidate)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isCapturing, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        keyDown(with: event)
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        guard isCapturing else {
            super.flagsChanged(with: event)
            return
        }

        pendingModifiers = Self.carbonModifiers(from: event.modifierFlags)
        captureMessage = nil
        updateAppearance()
    }

    override func resignFirstResponder() -> Bool {
        if isCapturing {
            setCapturing(false)
            pendingModifiers = 0
            captureMessage = nil
            updateAppearance()
        }
        return super.resignFirstResponder()
    }

    private func configure() {
        bezelStyle = .rounded
        controlSize = .regular
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        focusRingType = .default
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginCapture)
        updateAppearance()
    }

    @objc private func beginCapture() {
        setCapturing(true)
        pendingModifiers = 0
        captureMessage = nil
        _ = window?.makeFirstResponder(self)
        updateAppearance()
    }

    private func finishCapture(commit newHotKey: RecordingHotKey?) {
        setCapturing(false)
        pendingModifiers = 0
        captureMessage = nil
        if let newHotKey {
            hotKey = newHotKey
            onChange?(newHotKey)
        } else {
            updateAppearance()
        }
        _ = window?.makeFirstResponder(nil)
    }

    private func setCapturing(_ newValue: Bool) {
        guard isCapturing != newValue else { return }
        isCapturing = newValue
        onCaptureChange?(newValue)
    }

    private func updateAppearance() {
        if isCapturing {
            if let captureMessage {
                title = captureMessage
            } else if pendingModifiers != 0 {
                title = RecordingHotKey.modifierLabel(for: pendingModifiers) + "..."
            } else {
                title = "Press shortcut"
            }
            toolTip = "Press a shortcut"
        } else {
            title = hotKey.label
            toolTip = "Recording hotkey"
        }
    }

    private func validationMessage(for hotKey: RecordingHotKey) -> String {
        if !RecordingHotKey.supportsKeyCode(hotKey.keyCode) {
            return "Unsupported key"
        }
        if hotKey.keyCode == UInt32(kVK_Space) {
            return "Space is reserved"
        }
        if hotKey.keyCode == UInt32(kVK_Delete) || hotKey.keyCode == UInt32(kVK_ForwardDelete) {
            return "Delete resets"
        }
        return "Add ⌘, ⌥, or ⌃"
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.command) {
            modifiers |= UInt32(cmdKey)
        }
        if flags.contains(.option) {
            modifiers |= UInt32(optionKey)
        }
        if flags.contains(.control) {
            modifiers |= UInt32(controlKey)
        }
        if flags.contains(.shift) {
            modifiers |= UInt32(shiftKey)
        }
        return modifiers
    }
}
