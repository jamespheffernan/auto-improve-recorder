import SwiftUI

struct PreviewView: View {
    @EnvironmentObject private var state: AppState

    private var previewBinding: Binding<String> {
        Binding(
            get: { state.showRawTranscript ? state.session.rawTranscript : cleanedText },
            set: { newValue in
                state.updateDisplayText(newValue)
            }
        )
    }

    private var cleanedText: String {
        state.session.improvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : state.session.improvedText
    }

    private var cleanedTitle: String {
        cleanedText.isEmpty ? "Cleaned text" : "Cleaned"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Preview")
                    .font(.system(size: 18, weight: .semibold))
                Spacer()
                Picker("", selection: $state.showRawTranscript) {
                    Text(cleanedTitle).tag(false)
                    Text("Raw transcript").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 250)
                    .disabled(state.session.rawTranscript.isEmpty)
            }

            if let message = state.session.message ?? state.statusMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(state.phase == .failed ? .red : .secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !state.showRawTranscript && cleanedText.isEmpty && !state.session.rawTranscript.isEmpty {
                Text("No cleaned version yet. Switch to Raw transcript to inspect the unedited capture, or run cleanup.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextEditor(text: previewBinding)
                .font(.system(size: 14, design: .default))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .frame(minHeight: 220)

            HStack(spacing: 10) {
                Button {
                    state.copyDisplayText()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(!state.canCopyOrPaste)

                Button {
                    state.pasteDisplayText()
                } label: {
                    Label("Paste", systemImage: "arrow.down.doc")
                }
                .disabled(!state.canCopyOrPaste)

                Spacer()

                Button {
                    state.rerunImprove()
                } label: {
                    Label("Re-run", systemImage: "arrow.clockwise")
                }
                .disabled(!state.canRerunImprove)
            }
        }
        .padding(18)
        .frame(width: 560, height: 420)
    }
}
