#if DEBUG
import AppKit
import SwiftUI

@MainActor
final class AutoSendStatePlaygroundController {
    static let shared = AutoSendStatePlaygroundController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = AutoSendStatePlaygroundView()
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.title = "Auto Send State Playground"
        window.styleMask = [.titled, .closable, .resizable]
        window.contentMinSize = NSSize(width: 620, height: 440)
        window.contentMaxSize = NSSize(width: 900, height: 620)
        window.setContentSize(NSSize(width: 680, height: 520))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 680, height: 520))
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func saveSnapshot(to url: URL) throws {
        guard let contentView = window?.contentView,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            throw SnapshotError.unavailable
        }
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw SnapshotError.unavailable
        }
        try data.write(to: url, options: .atomic)
    }

    private enum SnapshotError: Error {
        case unavailable
    }
}

private struct AutoSendStatePlaygroundView: View {
    @State private var selected: AutoSendExperienceState = .recording
    @State private var reduceMotion = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(AutoSendExperienceState.playgroundStates) { state in
                        Button {
                            selected = state
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: state.symbolName)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(state.title)
                                        .fontWeight(.medium)
                                    Text(state.id)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            selected.id == state.id ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                }
                .padding(12)
            }
            .frame(width: 250)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.56))

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("State playground")
                        .font(.title2.bold())
                    Text("Select each production state. Motion here never controls delivery timing.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("HUD preview") {
                    VStack(alignment: .leading, spacing: 16) {
                        AutoSendHUDContent(state: selected, reduceMotion: reduceMotion)
                            .frame(
                                width: AutoSendHUDMetrics.size(for: selected).width,
                                height: AutoSendHUDMetrics.size(for: selected).height
                            )
                            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(selected.title)
                                .font(.headline)
                            Text(selected.detail ?? "No detail")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(8)
                }
                .frame(height: 210)

                Spacer()

                Toggle("Simulate Reduce Motion", isOn: $reduceMotion)
                    .toggleStyle(.switch)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(minWidth: 620, idealWidth: 680, maxWidth: 900)
        .frame(minHeight: 440, idealHeight: 520, maxHeight: 620)
    }
}
#endif
