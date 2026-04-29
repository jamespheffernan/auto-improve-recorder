import SwiftUI

struct RecorderPillView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.phase.label)
                    .font(.system(size: 13, weight: .semibold))
                if let message = state.statusMessage {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                state.toggleRecording()
            } label: {
                Image(systemName: state.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help(state.isRecording ? "Stop recording" : "Start recording")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 340)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.18))
        )
    }

    private var indicatorColor: Color {
        switch state.phase {
        case .recording:
            return .red
        case .transcribing, .improving:
            return .orange
        case .failed:
            return .yellow
        case .idle, .ready:
            return .green
        }
    }
}
