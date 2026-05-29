import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("Processing") {
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
                Picker("Auto-improve", selection: $state.autoImproveMode) {
                    ForEach(AutoImproveMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("Cleanup", selection: $state.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Stepper("Threshold: \(state.thresholdWords) words", value: $state.thresholdWords, in: 1...500)
                Text(processingNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("OpenAI") {
                SecureField("API key", text: $state.apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Gemini") {
                SecureField("API key", text: $state.geminiAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Anthropic") {
                SecureField("API key", text: $state.anthropicAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Ollama") {
                TextField("Base URL", text: $state.ollamaBaseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $state.ollamaModel)
                    .textFieldStyle(.roundedBorder)
                Text("Start Ollama locally and run `ollama pull qwen3.5:0.8b-mlx` before using Ollama local improvement.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let diagnostics = state.lastOpenAIRealtimeDiagnostics {
                Section("OpenAI diagnostics") {
                    Text("Last realtime error: \(diagnostics.summary)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        state.copyOpenAIRealtimeDiagnostics()
                    } label: {
                        Label("Copy details", systemImage: "doc.on.doc")
                    }
                }
            }

            Section("Recording") {
                Picker("Trigger", selection: $state.recordingTriggerMode) {
                    ForEach(RecordingTriggerMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("Hotkey", selection: $state.recordingHotKey) {
                    ForEach(RecordingHotKey.allCases) { hotKey in
                        Text(hotKey.label).tag(hotKey)
                    }
                }
                Picker("Microphone", selection: $state.preferredMicrophoneID) {
                    ForEach(state.availableMicrophones) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                Button {
                    state.refreshMicrophones()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }

            Section("Completion") {
                Toggle("Copy finished text to clipboard", isOn: $state.copyFinishedTextToClipboard)
                    .toggleStyle(.checkbox)
                Toggle("Auto-submit in detected text fields", isOn: $state.autoSubmitDetectedTextFields)
                    .toggleStyle(.checkbox)
            }

            Section("Parakeet") {
                TextField("Runtime path", text: $state.parakeetRuntimePath)
                    .textFieldStyle(.roundedBorder)
                TextField("Script path", text: $state.parakeetScriptPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Cache path", text: $state.parakeetCachePath)
                    .textFieldStyle(.roundedBorder)
                Button {
                    state.autodetectParakeetRuntime()
                } label: {
                    Label("Auto-detect", systemImage: "magnifyingglass")
                }
            }

            if let message = state.statusMessage {
                Section {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private var processingNote: String {
        if state.transcriptionMode == .localWhisper && state.improvementMode == .ollamaLocal {
            return "LAIR local mode uses whisper.cpp for transcription and Ollama qwen3.5:0.8b-mlx for cleanup."
        }

        if state.transcriptionMode == .localParakeet && state.improvementMode == .ollamaLocal {
            return "All-local mode uses Parakeet for transcription and Ollama qwen3.5:0.8b-mlx for cleanup."
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
            return "Ollama local cleanup sends transcript text to the local Ollama server. Paired with Local Whisper or Local Parakeet, the full flow stays on this Mac."
        }

        if state.transcriptionMode == .appleLocal {
            return "Apple Speech keeps transcription local, then sends text to OpenAI for cleanup when auto-improve runs."
        }

        return "OpenAI cleanup uses the API key below. Local Whisper, Parakeet, and Apple Speech transcription stay on this Mac."
    }
}
