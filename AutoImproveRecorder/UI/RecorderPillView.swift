import SwiftUI

struct RecorderPillView: View {
    @EnvironmentObject private var state: AppState
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 13) {
            statusGlyph

            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase.label)
                    .font(.system(size: 13, weight: .semibold))
                Text(secondaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if showsPipeline {
                    ProcessingRailView(visualState: state.processingVisualState)
                        .padding(.top, 5)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                state.toggleRecording()
            } label: {
                Image(systemName: actionSymbol)
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .disabled(actionDisabled)
            .opacity(actionDisabled ? 0.52 : 1)
            .help(actionHelp)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, showsPipeline ? 11 : 10)
        .frame(width: 390)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(indicatorColor.opacity(state.phase.isBusy ? 0.42 : 0.22), lineWidth: 1)
        )
        .shadow(color: indicatorColor.opacity(state.phase.isBusy ? 0.18 : 0.08), radius: 14, y: 4)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: state.phase)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: state.processingVisualState)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private var statusGlyph: some View {
        ZStack {
            Circle()
                .fill(indicatorColor.opacity(state.phase.isBusy ? 0.18 : 0.12))
                .frame(width: 30, height: 30)

            Circle()
                .stroke(indicatorColor.opacity(state.phase.isBusy ? 0.68 : 0.45), lineWidth: 1)
                .frame(width: state.phase.isBusy && pulse ? 30 : 25, height: state.phase.isBusy && pulse ? 30 : 25)

            Image(systemName: state.processingVisualState.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(indicatorColor)
        }
        .frame(width: 32, height: 32)
    }

    private var secondaryText: String {
        let transcriptText = state.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcriptText.isEmpty {
            return transcriptText
        }
        if let message = state.statusMessage, !message.isEmpty {
            return message
        }
        return state.processingVisualState.detail
    }

    private var showsPipeline: Bool {
        switch state.processingVisualState {
        case .transcribing, .improving, .delivering:
            return true
        case .idle, .starting, .recording, .pasted, .submitted, .copied, .ready, .failed:
            return false
        }
    }

    private var actionSymbol: String {
        if state.isRecording {
            return "stop.fill"
        }
        if state.phase.isBusy {
            return state.processingVisualState.symbolName
        }
        if state.processingVisualState.isSuccessfulDelivery {
            return "checkmark"
        }
        return "mic.fill"
    }

    private var actionDisabled: Bool {
        state.phase.isBusy && !state.isRecording
    }

    private var actionHelp: String {
        if state.isRecording {
            return "Stop recording"
        }
        if state.phase.isBusy {
            return state.processingVisualState.label
        }
        return "Start recording"
    }

    private var indicatorColor: Color {
        state.processingVisualState.pillColor
    }
}

private struct ProcessingRailView: View {
    let visualState: ProcessingVisualState

    private let steps: [ProcessingVisualState] = [.transcribing, .improving, .delivering]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                Capsule()
                    .fill(fill(for: step, index: index))
                    .frame(width: width(for: step), height: 4)
                    .overlay(alignment: .trailing) {
                        if visualState == step {
                            Circle()
                                .fill(Color.white.opacity(0.9))
                                .frame(width: 4, height: 4)
                        }
                    }
            }
        }
        .frame(width: 88, alignment: .leading)
        .accessibilityLabel(accessibilityLabel)
    }

    private func fill(for step: ProcessingVisualState, index: Int) -> Color {
        if visualState == step {
            return step.pillColor
        }
        if index < currentIndex || visualState.isSuccessfulDelivery {
            return step.pillColor.opacity(0.78)
        }
        return Color.secondary.opacity(0.24)
    }

    private func width(for step: ProcessingVisualState) -> CGFloat {
        visualState == step ? 34 : 18
    }

    private var currentIndex: Int {
        steps.firstIndex(of: visualState) ?? (visualState.isSuccessfulDelivery ? steps.count : -1)
    }

    private var accessibilityLabel: String {
        "Processing stage: \(visualState.label)"
    }
}

private extension ProcessingVisualState {
    var pillColor: Color {
        switch self {
        case .starting:
            return Color(nsColor: .secondaryLabelColor)
        case .recording:
            return .red
        case .transcribing:
            return .orange
        case .improving:
            return Color(red: 0.12, green: 0.62, blue: 0.57)
        case .delivering:
            return Color(red: 0.30, green: 0.56, blue: 0.95)
        case .pasted, .submitted, .copied, .ready:
            return .green
        case .failed:
            return .yellow
        case .idle:
            return .green
        }
    }
}
