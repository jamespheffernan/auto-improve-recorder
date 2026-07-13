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

    private var rawText: String {
        state.session.rawTranscript
    }

    private var rawTrimmedText: String {
        rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanedText: String {
        state.session.improvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ""
            : state.session.improvedText
    }

    private var cleanedTrimmedText: String {
        cleanedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanedTitle: String {
        cleanedText.isEmpty ? "Cleaned text" : "Cleaned"
    }

    private var hasRawText: Bool {
        !rawTrimmedText.isEmpty
    }

    private var hasCleanedText: Bool {
        !cleanedTrimmedText.isEmpty
    }

    private var selectedEditorTitle: String {
        state.showRawTranscript ? "Raw transcript" : "Cleaned result"
    }

    private var selectedWordCount: Int {
        wordCount(for: state.showRawTranscript ? rawText : cleanedText)
    }

    private var cleanedStatusLabel: String {
        if state.session.improveFailed {
            return "Failed"
        }
        if hasRawText && hasCleanedText && rawTrimmedText != cleanedTrimmedText {
            return "Changed"
        }
        if hasCleanedText {
            return "Same"
        }
        if hasRawText {
            return "Not run"
        }
        return "Empty"
    }

    private var latestMessage: String? {
        if let message = state.session.message?.nonEmptyTrimmed {
            return message
        }
        return state.statusMessage?.nonEmptyTrimmed
    }

    private var statusContent: PreviewStatusCard.Content {
        if state.phase == .failed {
            return PreviewStatusCard.Content(
                title: "Capture needs attention",
                detail: latestMessage ?? "Recording did not finish. Any recovered text appears below.",
                systemImage: "exclamationmark.triangle.fill",
                tint: .red
            )
        }

        if state.session.improveFailed {
            return PreviewStatusCard.Content(
                title: "Cleanup needs retry",
                detail: latestMessage ?? "Raw transcript is preserved. Re-run can retry cleanup.",
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }

        if state.phase.isBusy {
            return PreviewStatusCard.Content(
                title: state.processingVisualState.label,
                detail: latestMessage ?? state.processingVisualState.detail,
                systemImage: state.processingVisualState.symbolName,
                tint: .orange
            )
        }

        if let deliveryContent {
            return deliveryContent
        }

        if hasCleanedText {
            return PreviewStatusCard.Content(
                title: "Cleaned text ready",
                detail: latestMessage ?? comparisonDetail,
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        }

        if hasRawText {
            return PreviewStatusCard.Content(
                title: "Raw transcript ready",
                detail: latestMessage ?? "Cleaned text is not available yet.",
                systemImage: "text.bubble.fill",
                tint: .blue
            )
        }

        return PreviewStatusCard.Content(
            title: "No transcript captured",
            detail: latestMessage ?? "Preview will show the next capture here.",
            systemImage: "text.badge.xmark",
            tint: Color(nsColor: .secondaryLabelColor)
        )
    }

    private var deliveryContent: PreviewStatusCard.Content? {
        switch state.processingVisualState {
        case .delivering:
            return PreviewStatusCard.Content(
                title: "Delivering text",
                detail: latestMessage ?? "Sending text to the focused field.",
                systemImage: "arrow.down.doc.fill",
                tint: .blue
            )
        case .pasted:
            return PreviewStatusCard.Content(
                title: "Pasted",
                detail: latestMessage ?? "Text landed in the focused field.",
                systemImage: "checkmark.circle.fill",
                tint: .green
            )
        case .submitted:
            return PreviewStatusCard.Content(
                title: "Pasted and submitted",
                detail: latestMessage ?? "Text landed and Return was sent.",
                systemImage: "return",
                tint: .green
            )
        case .copied:
            return PreviewStatusCard.Content(
                title: "Copied",
                detail: latestMessage ?? "Text is on the clipboard.",
                systemImage: "doc.on.doc.fill",
                tint: .green
            )
        case .idle, .starting, .recording, .transcribing, .improving, .ready, .failed:
            break
        }

        if let statusMessage = state.statusMessage?.nonEmptyTrimmed {
            let normalized = statusMessage.lowercased()
            if normalized.hasPrefix("pasted") {
                return PreviewStatusCard.Content(
                    title: "Pasted",
                    detail: statusMessage,
                    systemImage: "checkmark.circle.fill",
                    tint: .green
                )
            }
            if normalized.hasPrefix("copied. enable accessibility") {
                return PreviewStatusCard.Content(
                    title: "Copied instead of pasted",
                    detail: statusMessage,
                    systemImage: "doc.on.doc.fill",
                    tint: .orange
                )
            }
            if normalized.hasPrefix("copied") {
                return PreviewStatusCard.Content(
                    title: "Copied",
                    detail: statusMessage,
                    systemImage: "doc.on.doc.fill",
                    tint: .green
                )
            }
        }

        if state.canCopyOrPaste && state.permissionStatus.accessibility != .authorized {
            return PreviewStatusCard.Content(
                title: "Copy ready",
                detail: "Accessibility is not enabled, so paste falls back to the clipboard.",
                systemImage: "hand.raised.fill",
                tint: .orange
            )
        }

        return nil
    }

    private var comparisonDetail: String {
        if hasRawText && hasCleanedText && rawTrimmedText != cleanedTrimmedText {
            return "Cleaned result differs from the raw capture."
        }
        if hasRawText && hasCleanedText {
            return "Cleaned result matches the raw capture."
        }
        return "Ready for review."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            PreviewStatusCard(content: statusContent)

            HStack(spacing: 10) {
                PreviewTextChoice(
                    title: "Cleaned",
                    detail: hasCleanedText ? "\(wordCount(for: cleanedText)) words" : "No cleaned text",
                    badge: cleanedStatusLabel,
                    systemImage: "sparkles",
                    isSelected: !state.showRawTranscript,
                    isEnabled: true
                ) {
                    state.showRawTranscript = false
                }

                PreviewTextChoice(
                    title: "Raw",
                    detail: hasRawText ? "\(wordCount(for: rawText)) words" : "No raw transcript",
                    badge: hasRawText ? "Captured" : "Empty",
                    systemImage: "waveform",
                    isSelected: state.showRawTranscript,
                    isEnabled: hasRawText
                ) {
                    state.showRawTranscript = true
                }
            }

            editorHeader

            TextEditor(text: previewBinding)
                .font(.system(size: 14, design: .default))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor))
                )
                .frame(minHeight: 190)

            actions
        }
        .padding(18)
        .frame(width: 620, height: 500)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Preview")
                    .font(.system(size: 18, weight: .semibold))
                Text("Verify the capture before sending or retrying cleanup.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $state.showRawTranscript) {
                Text(cleanedTitle).tag(false)
                Text("Raw transcript").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 250)
            .disabled(!hasRawText)
        }
    }

    private var editorHeader: some View {
        HStack {
            Label(selectedEditorTitle, systemImage: state.showRawTranscript ? "waveform" : "sparkles")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("\(selectedWordCount) words")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
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

    private func wordCount(for text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

private struct PreviewStatusCard: View {
    struct Content {
        var title: String
        var detail: String
        var systemImage: String
        var tint: Color
    }

    var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: content.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(content.tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(content.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(content.tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(content.tint.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct PreviewTextChoice: View {
    var title: String
    var detail: String
    var badge: String
    var systemImage: String
    var isSelected: Bool
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(badge)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill((isSelected ? Color.accentColor : Color.secondary).opacity(0.12))
                            )
                    }
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 6)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.58)
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
