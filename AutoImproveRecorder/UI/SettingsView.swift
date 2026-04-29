import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        Form {
            Section("OpenAI") {
                SecureField("API key", text: $state.apiKey)
                    .textFieldStyle(.roundedBorder)
                Picker("Auto-improve", selection: $state.autoImproveMode) {
                    ForEach(AutoImproveMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Picker("Output", selection: $state.outputMode) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                Stepper("Threshold: \(state.thresholdWords) words", value: $state.thresholdWords, in: 1...500)
                Stepper("Strength: \(state.modificationStrength)", value: $state.modificationStrength, in: 1...5)
            }

            Section("Recording") {
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
}
