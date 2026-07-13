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
                contentRect: NSRect(x: 0, y: 0, width: 344, height: 72),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentViewController = hosting
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
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
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Auto Improve Settings"
            window.contentViewController = hosting
            window.contentMinSize = NSSize(width: 820, height: 560)
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

    func showProcessing(_ visualState: ProcessingVisualState, targetFrameProvider: (() -> CGRect?)? = nil) {
        hideToken = UUID()
        self.targetFrameProvider = targetFrameProvider
        startTargetMonitor()
        show(visualState: visualState)
    }

    func flashReady(_ visualState: ProcessingVisualState) {
        let token = UUID()
        let readyTarget = currentTarget
        hideToken = token
        stopTargetMonitor()
        show(visualState: visualState, target: readyTarget)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
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

    private func show(visualState: ProcessingVisualState, target: TargetHighlightFrame? = nil) {
        let panel = panel ?? makePanel()
        self.panel = panel
        model.visualState = visualState
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
    @ObservedObject var model: EdgeGlowModel
    @ObservedObject private var appState = AppState.shared
    @State private var pulse = false

    var body: some View {
        GeometryReader { proxy in
            let visualState = model.visualState
            let color = visualState.glowColor
            let opacity = visualState.baseGlowOpacity * (pulse ? 1 : 0.68)
            let depth = min(max(proxy.size.width, proxy.size.height) * 0.045, 72)
            let target = targetRect(in: proxy)
            let readoutPosition = glowReadoutPosition(in: proxy.size)

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
                    .stroke(color.opacity(opacity), lineWidth: visualState.isSuccessfulDelivery ? 5 : 3)
                    .blur(radius: visualState.isSuccessfulDelivery ? 10 : 7)
                    .padding(visualState.isSuccessfulDelivery ? 0 : 2)

                if visualState.showsGlowReadout {
                    GlowReadoutView(
                        visualState: visualState,
                        color: color,
                        opacity: opacity,
                        statusMessage: appState.statusMessage,
                        recordingStartedAt: appState.recordingStartedAt,
                        isLatched: appState.walkieTalkieIsLatchedForDisplay,
                        commandHint: visualState == .recording ? recordingCommandHint : nil
                    )
                    .position(readoutPosition)
                }

                if let rect = target {
                    TargetFieldHighlight(
                        rect: rect,
                        color: color,
                        opacity: opacity,
                        pulse: pulse,
                        visualState: visualState
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

    private var recordingCommandHint: String {
        if appState.recordingTriggerMode == .walkieTalkie {
            if appState.walkieTalkieIsLatchedForDisplay {
                return "\(appState.recordingHotKey.label) sends · Esc cancels"
            }
            return "Release sends · double-press locks · Esc cancels"
        }

        return "\(appState.recordingHotKey.label) sends · Esc cancels"
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

    private func glowReadoutPosition(in size: CGSize) -> CGPoint {
        CGPoint(
            x: size.width / 2,
            y: max(96, size.height - 104)
        )
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
    @Published var visualState: ProcessingVisualState = .transcribing
    @Published var targetRect: CGRect?
    @Published var screenFrame: CGRect = NSScreen.main?.frame ?? .zero
}

private extension ProcessingVisualState {
    var glowColor: Color {
        switch self {
        case .starting:
            return Color(red: 0.72, green: 0.77, blue: 0.82)
        case .recording:
            return Color(red: 1.00, green: 0.24, blue: 0.24)
        case .transcribing:
            return Color(red: 0.98, green: 0.58, blue: 0.18)
        case .improving:
            return Color(red: 0.22, green: 0.74, blue: 0.70)
        case .delivering:
            return Color(red: 0.35, green: 0.62, blue: 1.00)
        case .pasted, .submitted, .copied, .ready:
            return Color(red: 0.38, green: 0.95, blue: 0.62)
        case .failed:
            return Color(red: 1.00, green: 0.36, blue: 0.28)
        case .idle:
            return Color(red: 0.58, green: 0.64, blue: 0.70)
        }
    }

    var showsGlowReadout: Bool {
        switch self {
        case .idle:
            return false
        case .starting, .recording, .transcribing, .improving, .delivering, .pasted, .submitted, .copied, .ready, .failed:
            return true
        }
    }

    var showsStageStrip: Bool {
        switch self {
        case .transcribing, .improving, .delivering, .pasted, .submitted, .copied, .ready:
            return true
        case .idle, .starting, .recording, .failed:
            return false
        }
    }

    var baseGlowOpacity: Double {
        switch self {
        case .pasted, .submitted, .copied, .ready:
            return 0.72
        case .failed:
            return 0.62
        case .idle:
            return 0.22
        case .starting, .recording, .transcribing, .improving, .delivering:
            return 0.34
        }
    }
}

private struct GlowReadoutView: View {
    let visualState: ProcessingVisualState
    let color: Color
    let opacity: Double
    let statusMessage: String?
    let recordingStartedAt: Date?
    let isLatched: Bool
    let commandHint: String?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 0.2)) { timeline in
            VStack(alignment: .center, spacing: 6) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(color.opacity(0.95))
                        .frame(width: 7, height: 7)
                        .shadow(color: color.opacity(opacity), radius: 10)

                    if visualState == .recording {
                        GlowWaveform(color: color)
                        Text(elapsedText(now: timeline.date))
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: visualState.symbolName)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                        Text(visualState.label)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(.black.opacity(0.54))
                        .background(.ultraThinMaterial, in: Capsule())
                )
                .overlay(
                    Capsule()
                        .stroke(color.opacity(opacity * 0.9), lineWidth: 1)
                )
                .shadow(color: color.opacity(opacity * 0.66), radius: 18)

                if visualState.showsStageStrip {
                    StageRailView(visualState: visualState, color: color, opacity: opacity)
                }

                VStack(alignment: .center, spacing: 2) {
                    Text(readoutTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                    Text(readoutDetail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300, alignment: .center)
                .shadow(color: .black.opacity(0.32), radius: 8, y: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(readoutTitle). \(readoutDetail)")
        }
    }

    private var readoutTitle: String {
        if visualState == .recording, isLatched {
            return "Recording locked"
        }
        return visualState.label
    }

    private var readoutDetail: String {
        if let commandHint {
            return commandHint
        }
        if let statusMessage, !statusMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return statusMessage
        }
        return visualState.detail
    }

    private func elapsedText(now: Date) -> String {
        guard let recordingStartedAt else { return "00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(recordingStartedAt)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
}

private struct GlowWaveform: View {
    let color: Color
    @State private var active = false

    private let heights: [CGFloat] = [7, 14, 20, 11, 18]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(color.opacity(0.92))
                    .frame(width: 3, height: active ? height : max(6, 22 - height))
                    .animation(
                        .easeInOut(duration: 0.58)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.08),
                        value: active
                    )
            }
        }
        .frame(width: 30, height: 22)
        .onAppear {
            active = true
        }
    }
}

private struct StageRailView: View {
    let visualState: ProcessingVisualState
    let color: Color
    let opacity: Double

    private let stages: [ProcessingVisualState] = [.transcribing, .improving, .delivering, .ready]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                Capsule()
                    .fill(fill(for: stage, index: index))
                    .frame(width: visualState == stage ? 34 : 24, height: 4)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.28), in: Capsule())
    }

    private func fill(for stage: ProcessingVisualState, index: Int) -> Color {
        if visualState == stage || (visualState.isSuccessfulDelivery && stage == .ready) {
            return color.opacity(0.96)
        }
        if index < currentIndex || visualState.isSuccessfulDelivery {
            return color.opacity(opacity * 0.64)
        }
        return .white.opacity(0.22)
    }

    private var currentIndex: Int {
        stages.firstIndex(of: visualState) ?? (visualState.isSuccessfulDelivery ? stages.count : -1)
    }
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
    let visualState: ProcessingVisualState

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(color.opacity(opacity), lineWidth: pulse ? 4 : 3)
                .shadow(color: color.opacity(opacity * 0.92), radius: pulse ? 18 : 9)
                .shadow(color: color.opacity(opacity * 0.5), radius: pulse ? 30 : 16)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            if visualState == .delivering {
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
