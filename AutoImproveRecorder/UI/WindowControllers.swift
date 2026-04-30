import AppKit
import SwiftUI

@MainActor
final class FloatingPillWindowController {
    private var panel: NSPanel?

    func show() {
        if panel == nil {
            let hosting = NSHostingController(
                rootView: RecorderPillView()
                    .environmentObject(AppState.shared)
            )
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 360, height: 64),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hosting
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            self.panel = panel
        }

        positionPanel()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func positionPanel() {
        guard let panel, let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - 18
        )
        panel.setFrameOrigin(origin)
    }
}

@MainActor
final class PreviewWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: PreviewView()
                    .environmentObject(AppState.shared)
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Auto Improve"
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsView()
                    .environmentObject(AppState.shared)
            )
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Auto Improve Settings"
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class EdgeGlowWindowController {
    private var panel: NSPanel?
    private var hideToken = UUID()

    func showProcessing() {
        hideToken = UUID()
        show(mode: .processing)
    }

    func flashReady() {
        let token = UUID()
        hideToken = token
        show(mode: .ready)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.hide()
        }
    }

    func hide() {
        hideToken = UUID()
        panel?.orderOut(nil)
    }

    private func show(mode: EdgeGlowView.Mode) {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.contentViewController = NSHostingController(rootView: EdgeGlowView(mode: mode))
        positionPanel(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSScreen.main?.frame ?? .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        panel.setFrame(screen.frame, display: true)
    }
}

private struct EdgeGlowView: View {
    enum Mode {
        case processing
        case ready

        var color: Color {
            switch self {
            case .processing:
                return Color(red: 0.98, green: 0.58, blue: 0.18)
            case .ready:
                return Color(red: 0.38, green: 0.95, blue: 0.62)
            }
        }

        var baseOpacity: Double {
            switch self {
            case .processing:
                return 0.34
            case .ready:
                return 0.72
            }
        }
    }

    let mode: Mode
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let color = mode.color
            let opacity = mode.baseOpacity * (pulse ? 1 : 0.68)
            let depth = min(max(proxy.size.width, proxy.size.height) * 0.045, 72)

            ZStack {
                edgeBand(color: color, opacity: opacity, start: .top, end: .bottom)
                    .frame(height: depth)
                    .frame(maxHeight: .infinity, alignment: .top)

                edgeBand(color: color, opacity: opacity, start: .bottom, end: .top)
                    .frame(height: depth)
                    .frame(maxHeight: .infinity, alignment: .bottom)

                edgeBand(color: color, opacity: opacity, start: .leading, end: .trailing)
                    .frame(width: depth)
                    .frame(maxWidth: .infinity, alignment: .leading)

                edgeBand(color: color, opacity: opacity, start: .trailing, end: .leading)
                    .frame(width: depth)
                    .frame(maxWidth: .infinity, alignment: .trailing)

                Rectangle()
                    .stroke(color.opacity(opacity), lineWidth: mode == .processing ? 3 : 5)
                    .blur(radius: mode == .processing ? 7 : 10)
                    .padding(mode == .processing ? 2 : 0)
            }
            .compositingGroup()
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
        }
        .ignoresSafeArea()
        .background(Color.clear)
    }

    private func edgeBand(
        color: Color,
        opacity: Double,
        start: UnitPoint,
        end: UnitPoint
    ) -> some View {
        LinearGradient(
            colors: [
                color.opacity(opacity),
                color.opacity(opacity * 0.38),
                color.opacity(0)
            ],
            startPoint: start,
            endPoint: end
        )
        .blur(radius: 2)
    }
}
