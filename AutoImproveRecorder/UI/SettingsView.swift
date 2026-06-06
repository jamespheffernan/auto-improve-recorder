import AppKit
import Carbon
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettingsTab()
                    .tabItem { Label("General", systemImage: "gearshape") }

                EngineSettingsTab()
                    .tabItem { Label("Engine", systemImage: "cpu") }

                OutputSettingsTab()
                    .tabItem { Label("Output", systemImage: "text.alignleft") }

                ProvidersSettingsTab()
                    .tabItem { Label("Providers", systemImage: "key") }

                DictionarySettingsTab(store: state.dictionaryStore)
                    .tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            }

            ReadinessFooter()
        }
        .frame(
            minWidth: 560,
            idealWidth: 620,
            maxWidth: .infinity,
            minHeight: 460,
            idealHeight: 580,
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

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Recording") {
                Picker("Trigger", selection: $state.recordingTriggerMode) {
                    ForEach(RecordingTriggerMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Text(recordingTriggerNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Hotkey")
                    Spacer()
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
                Picker("Microphone", selection: $state.preferredMicrophoneID) {
                    ForEach(state.availableMicrophones) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                Text(state.resolvedMicrophoneSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    state.refreshMicrophones()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            Section("Improvement") {
                Picker("Auto-improve", selection: $state.autoImproveMode) {
                    ForEach(AutoImproveMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Stepper("Threshold: \(state.thresholdWords) words", value: $state.thresholdWords, in: 1...500)
                Text("Auto-improve runs cleanup automatically once a transcript passes the word threshold.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ReadinessSettingsSection()
        }
        .formStyle(.grouped)
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

private struct EngineSettingsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            LocalModelSettingsSection()

            Section("How this engine runs") {
                Text(processingNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                DisclosureGroup("Custom engine (advanced)") {
                    Picker("Transcription", selection: $state.transcriptionMode) {
                        ForEach(TranscriptionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker("Improvement", selection: $state.improvementMode) {
                        ForEach(ImprovementMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Text("Mix any transcription and cleanup engine. The presets above set these for you.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
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

        return "OpenAI cleanup uses the API key in the Providers tab. Local Whisper, Parakeet, and Apple Speech transcription stay on this Mac."
    }
}

private struct OutputSettingsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Cleanup style") {
                Picker("Style", selection: $state.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(state.outputMode.promptIntensity)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Delivery") {
                Toggle("Copy finished text to clipboard", isOn: $state.copyFinishedTextToClipboard)
                    .toggleStyle(.checkbox)
                Toggle("Auto-submit in detected text fields", isOn: $state.autoSubmitDetectedTextFields)
                    .toggleStyle(.checkbox)
            }

            Section("App rules") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Per-app overrides")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Override paste, clipboard, and Return behavior for specific apps.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            state.refreshDeliveryRuleCandidateApps()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh running apps")
                    }

                    if state.appDeliveryRules.isEmpty {
                        Text("No app rules configured.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach($state.appDeliveryRules) { $rule in
                                AppDeliveryRuleRow(rule: $rule) {
                                    state.removeAppDeliveryRule(id: rule.id)
                                }
                            }
                        }
                    }

                    HStack {
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
                            Label("Add Running App", systemImage: "plus")
                        }

                        Button("Restore Defaults") {
                            state.resetAppDeliveryRulesToDefaults()
                        }

                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ProvidersSettingsTab: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Cloud API keys") {
                LabeledContent("OpenAI") {
                    SecureField("sk-…", text: $state.apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Gemini") {
                    SecureField("AIza…", text: $state.geminiAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Anthropic") {
                    SecureField("sk-ant-…", text: $state.anthropicAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                Text("Keys stay on this Mac and are only sent when you pick a matching cloud engine.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Ollama (local cleanup)") {
                TextField("Base URL", text: $state.ollamaBaseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $state.ollamaModel)
                    .textFieldStyle(.roundedBorder)
                Text("Start Ollama locally and run `ollama pull qwen3.5:0.8b-mlx` before using Ollama local improvement.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DictionarySettingsTab: View {
    @ObservedObject var store: UserDictionaryStore

    var body: some View {
        Form {
            DictionarySettingsSection(store: store)
        }
        .formStyle(.grouped)
    }
}

private struct ReadinessFooter: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 14) {
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

private struct ReadinessSettingsSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Section("Readiness") {
            PermissionStatusRow(
                title: "Microphone",
                systemImage: "mic",
                state: state.permissionStatus.microphone
            )
            PermissionStatusRow(
                title: "Accessibility",
                systemImage: "keyboard",
                state: state.permissionStatus.accessibility
            )

            HStack(spacing: 8) {
                Button {
                    Task { await state.refreshReadiness() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    state.promptForAccessibilityPermission()
                } label: {
                    Label("Prompt Accessibility", systemImage: "hand.raised")
                }
            }

            if let latest = state.diagnosticEvents.first {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last issue: \(latest.summary)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(latest.diagnosticsSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        state.copyLatestDiagnostics()
                    } label: {
                        Label("Copy details", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }
}

private struct PermissionStatusRow: View {
    var title: String
    var systemImage: String
    var state: PermissionState

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(state.readinessLabel)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(state.readinessBadgeColor)
                .clipShape(Capsule())
        }
    }
}

private struct LocalModelSettingsSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Section("Choose an engine") {
            recommendedRow
            fastRow
            allLocalRow
            appleSpeechRow
            cloudRealtimeRow
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(descriptor.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Text(state.label)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(badgeBackground)
                    .clipShape(Capsule())
            }

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if !actionTitle.isEmpty {
                    Button(actionTitle, action: action)
                }

                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var badgeBackground: Color {
        switch state {
        case .ready, .installed:
            return Color.green.opacity(0.16)
        case .checking, .loading, .downloading:
            return Color.blue.opacity(0.14)
        case .needsModel, .needsRuntime, .externalAppRequired, .unavailable:
            return Color.orange.opacity(0.16)
        case .failed:
            return Color.red.opacity(0.16)
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
        Section("Dictionary") {
            VStack(alignment: .leading, spacing: 10) {
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

                Divider()

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
