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
    private let model = EdgeGlowModel()
    private var panel: NSPanel?
    private var hideToken = UUID()
    private var currentTarget: TargetHighlightFrame?
    private var targetFrameProvider: (() -> CGRect?)?
    private var targetMonitor: Timer?

    func showProcessing(targetFrameProvider: (() -> CGRect?)? = nil) {
        hideToken = UUID()
        self.targetFrameProvider = targetFrameProvider
        startTargetMonitor()
        show(mode: .processing)
    }

    func flashReady() {
        let token = UUID()
        let readyTarget = currentTarget
        hideToken = token
        stopTargetMonitor()
        show(mode: .ready, target: readyTarget)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.hideToken == token else { return }
            self.hide()
        }
    }

    func hide() {
        hideToken = UUID()
        stopTargetMonitor()
        currentTarget = nil
        model.targetRect = nil
        panel?.orderOut(nil)
    }

    private func show(mode: EdgeGlowView.Mode, target: TargetHighlightFrame? = nil) {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.mode = mode
        if let target {
            currentTarget = target
        } else {
            currentTarget = resolvedTargetFrame(targetFrameProvider?())
        }
        model.targetRect = currentTarget?.localRect
        model.screenFrame = currentTarget?.screenFrame ?? NSScreen.main?.frame ?? .zero
        panel.contentViewController = panel.contentViewController ?? NSHostingController(rootView: EdgeGlowView(model: model))
        positionPanel(panel, on: currentTarget?.screenFrame)
        panel.orderFrontRegardless()
    }

    private func startTargetMonitor() {
        targetMonitor?.invalidate()
        refreshTargetFrame()
        guard targetFrameProvider != nil else { return }
        targetMonitor = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTargetFrame()
            }
        }
    }

    private func stopTargetMonitor() {
        targetMonitor?.invalidate()
        targetMonitor = nil
        targetFrameProvider = nil
    }

    private func refreshTargetFrame() {
        currentTarget = resolvedTargetFrame(targetFrameProvider?())
        model.targetRect = currentTarget?.localRect
        if let panel {
            positionPanel(panel, on: currentTarget?.screenFrame)
        }
    }

    private func resolvedTargetFrame(_ frame: CGRect?) -> TargetHighlightFrame? {
        guard let frame,
              let screen = screen(containingAXFrame: frame),
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width >= 24,
              frame.height >= 14,
              frame.width <= screen.frame.width * 0.98,
              frame.height <= min(screen.frame.height * 0.55, 520) else {
            return nil
        }

        let topOffset = globalTop - screen.frame.maxY
        let localRect = CGRect(
            x: frame.minX - screen.frame.minX,
            y: frame.minY - topOffset,
            width: frame.width,
            height: frame.height
        )
        return TargetHighlightFrame(localRect: localRect, screenFrame: screen.frame)
    }

    private func screen(containingAXFrame frame: CGRect) -> NSScreen? {
        let appKitFrame = CGRect(
            x: frame.minX,
            y: globalTop - frame.minY - frame.height,
            width: frame.width,
            height: frame.height
        )
        let center = CGPoint(x: appKitFrame.midX, y: appKitFrame.midY)

        if let containing = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return containing
        }

        return NSScreen.screens
            .map { screen in
                (screen, screen.frame.intersection(appKitFrame).width * screen.frame.intersection(appKitFrame).height)
            }
            .filter { !$0.1.isNaN && $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0 ?? NSScreen.main
    }

    private var globalTop: CGFloat {
        NSScreen.screens.map { $0.frame.maxY }.max() ?? 0
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

    private func positionPanel(_ panel: NSPanel, on screenFrame: CGRect? = nil) {
        guard let frame = screenFrame ?? NSScreen.main?.frame else { return }
        panel.setFrame(frame, display: true)
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

    @ObservedObject var model: EdgeGlowModel
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let mode = model.mode
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

                if let rect = targetRect(in: proxy) {
                    TargetFieldHighlight(
                        rect: rect,
                        color: color,
                        opacity: opacity,
                        pulse: pulse,
                        showSubmitIndicator: mode == .processing
                    )
                }
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

    private func targetRect(in proxy: GeometryProxy) -> CGRect? {
        guard var rect = model.targetRect else { return nil }
        rect = rect.insetBy(dx: -8, dy: -7)

        guard rect.width > 0,
              rect.height > 0,
              rect.width < proxy.size.width,
              rect.height < proxy.size.height else {
            return nil
        }

        rect.origin.x = min(max(rect.origin.x, 10), max(10, proxy.size.width - rect.width - 10))
        rect.origin.y = min(max(rect.origin.y, 10), max(10, proxy.size.height - rect.height - 10))
        return rect
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

private final class EdgeGlowModel: ObservableObject {
    @Published var mode: EdgeGlowView.Mode = .processing
    @Published var targetRect: CGRect?
    @Published var screenFrame: CGRect = NSScreen.main?.frame ?? .zero
}

private struct TargetHighlightFrame {
    let localRect: CGRect
    let screenFrame: CGRect
}

private struct TargetFieldHighlight: View {
    let rect: CGRect
    let color: Color
    let opacity: Double
    let pulse: Bool
    let showSubmitIndicator: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(color.opacity(opacity), lineWidth: pulse ? 4 : 3)
                .shadow(color: color.opacity(opacity * 0.92), radius: pulse ? 18 : 9)
                .shadow(color: color.opacity(opacity * 0.5), radius: pulse ? 30 : 16)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            if showSubmitIndicator {
                SubmitDots(color: color, opacity: opacity, pulse: pulse)
                    .frame(width: 44, height: 22)
                    .position(x: indicatorX, y: indicatorY)
            }
        }
    }

    private var cornerRadius: CGFloat {
        min(max(rect.height * 0.22, 7), 14)
    }

    private var indicatorX: CGFloat {
        rect.maxX - 24
    }

    private var indicatorY: CGFloat {
        rect.minY + 13
    }
}

private struct SubmitDots: View {
    let color: Color
    let opacity: Double
    let pulse: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(color.opacity(dotOpacity(index)))
                    .frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.58), in: Capsule())
        .overlay(
            Capsule()
                .stroke(color.opacity(opacity * 0.68), lineWidth: 1)
        )
    }

    private func dotOpacity(_ index: Int) -> Double {
        let activeIndex = pulse ? 2 : 0
        return index == activeIndex ? 1 : 0.42
    }
}
