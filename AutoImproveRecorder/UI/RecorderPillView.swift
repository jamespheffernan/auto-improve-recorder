import SwiftUI

struct RecorderPillView: View {
    @EnvironmentObject private var state: AppState
    @State private var pulse = false

    var body: some View {
        let presentation = PillPresentation(
            visualState: state.processingVisualState,
            phase: state.phase
        )

        HStack(spacing: 10) {
            statusGlyph(presentation)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(presentation.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Text(presentation.badge)
                        .font(.system(size: 9, weight: .bold))
                        .textCase(.uppercase)
                        .foregroundStyle(presentation.color)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(presentation.color.opacity(0.11), in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(presentation.color.opacity(0.24), lineWidth: 1)
                        )
                        .fixedSize()
                }

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
            .frame(minWidth: 0)

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
            .accessibilityLabel(actionHelp)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, showsPipeline ? 10 : 9)
        .frame(width: 320)
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(presentation.color.opacity(presentation.borderOpacity), lineWidth: 1)
        )
        .shadow(color: presentation.color.opacity(presentation.shadowOpacity), radius: 8, y: 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.title). \(presentation.badge). \(secondaryText)")
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: state.phase)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: state.processingVisualState)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.72).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    private func statusGlyph(_ presentation: PillPresentation) -> some View {
        ZStack {
            glyphBackground(
                shape: presentation.shape,
                color: presentation.color,
                fillOpacity: state.phase.isBusy ? 0.16 : 0.10
            )

            glyphStroke(
                shape: presentation.shape,
                color: presentation.color,
                strokeOpacity: state.phase.isBusy ? 0.64 : 0.40,
                size: state.phase.isBusy && pulse ? 30 : 25
            )

            Image(systemName: presentation.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(presentation.color)
        }
        .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private func glyphBackground(
        shape: PillGlyphShape,
        color: Color,
        fillOpacity: Double
    ) -> some View {
        switch shape {
        case .circle:
            Circle()
                .fill(color.opacity(fillOpacity))
                .frame(width: 30, height: 30)
        case .capsule:
            Capsule()
                .fill(color.opacity(fillOpacity))
                .frame(width: 31, height: 22)
        case .roundedSquare:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(fillOpacity))
                .frame(width: 28, height: 28)
        case .diamond:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(fillOpacity))
                .frame(width: 24, height: 24)
                .rotationEffect(.degrees(45))
        }
    }

    @ViewBuilder
    private func glyphStroke(
        shape: PillGlyphShape,
        color: Color,
        strokeOpacity: Double,
        size: CGFloat
    ) -> some View {
        switch shape {
        case .circle:
            Circle()
                .stroke(color.opacity(strokeOpacity), lineWidth: 1)
                .frame(width: size, height: size)
        case .capsule:
            Capsule()
                .stroke(color.opacity(strokeOpacity), lineWidth: 1)
                .frame(width: size + 2, height: 22)
        case .roundedSquare:
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(color.opacity(strokeOpacity), lineWidth: 1)
                .frame(width: size - 2, height: size - 2)
        case .diamond:
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(color.opacity(strokeOpacity), lineWidth: 1)
                .frame(width: size - 6, height: size - 6)
                .rotationEffect(.degrees(45))
        }
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
}

private struct PillPresentation {
    let title: String
    let badge: String
    let symbolName: String
    let color: Color
    let shape: PillGlyphShape
    let borderOpacity: Double
    let shadowOpacity: Double

    init(visualState: ProcessingVisualState, phase: RecorderPhase) {
        symbolName = visualState.symbolName
        color = visualState.pillColor

        switch visualState {
        case .idle:
            title = phase == .failed ? "Needs attention" : "Ready"
            badge = phase == .failed ? "Fix" : "Idle"
            shape = phase == .failed ? .diamond : .roundedSquare
            borderOpacity = phase == .failed ? 0.38 : 0.16
            shadowOpacity = phase == .failed ? 0.08 : 0.04
        case .starting:
            title = "Opening mic"
            badge = "Start"
            shape = .capsule
            borderOpacity = 0.24
            shadowOpacity = 0.06
        case .recording:
            title = "Listening"
            badge = "Rec"
            shape = .circle
            borderOpacity = 0.32
            shadowOpacity = 0.10
        case .transcribing:
            title = "Transcribing"
            badge = "Step 1"
            shape = .capsule
            borderOpacity = 0.26
            shadowOpacity = 0.07
        case .improving:
            title = "Cleaning"
            badge = "Step 2"
            shape = .capsule
            borderOpacity = 0.26
            shadowOpacity = 0.07
        case .delivering:
            title = "Pasting"
            badge = "Step 3"
            shape = .capsule
            borderOpacity = 0.26
            shadowOpacity = 0.07
        case .pasted:
            title = "Text pasted"
            badge = "Done"
            shape = .circle
            borderOpacity = 0.22
            shadowOpacity = 0.06
        case .submitted:
            title = "Text submitted"
            badge = "Done"
            shape = .circle
            borderOpacity = 0.22
            shadowOpacity = 0.06
        case .copied:
            title = "Copied"
            badge = "Saved"
            shape = .roundedSquare
            borderOpacity = 0.22
            shadowOpacity = 0.06
        case .ready:
            title = "Text ready"
            badge = "Done"
            shape = .roundedSquare
            borderOpacity = 0.20
            shadowOpacity = 0.05
        case .failed:
            title = "Needs attention"
            badge = "Fix"
            shape = .diamond
            borderOpacity = 0.38
            shadowOpacity = 0.08
        }
    }
}

private enum PillGlyphShape {
    case circle
    case capsule
    case roundedSquare
    case diamond
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
