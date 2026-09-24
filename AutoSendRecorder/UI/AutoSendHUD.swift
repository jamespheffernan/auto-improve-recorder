import AppKit
import SwiftUI

@MainActor
final class AutoSendHUDPresenter {
    private let model = AutoSendHUDModel()
    private let panel: AutoSendHUDPanel
    private var hideTask: Task<Void, Never>?
    private var deferredDeliveringTask: Task<Void, Never>?

    init() {
        let hostingView = NSHostingView(rootView: AutoSendHUDView(model: model))
        hostingView.frame = NSRect(origin: .zero, size: AutoSendHUDMetrics.size(for: .idle))

        let panel = AutoSendHUDPanel(
            contentRect: hostingView.bounds,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.contentView?.wantsLayer = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        self.panel = panel
    }

    func update(_ state: AutoSendExperienceState) {
        hideTask?.cancel()
        deferredDeliveringTask?.cancel()

        guard state == .delivering else {
            present(state)
            return
        }

        deferredDeliveringTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.present(state)
        }
    }

    private func present(_ state: AutoSendExperienceState) {
        resizePanel(for: state)
        model.state = state

        guard state.shouldShowHUD else {
            panel.orderOut(nil)
            return
        }

        if !panel.isVisible {
            panel.setFrameOrigin(AutoSendHUDPositioner.origin(for: panel.frame.size))
        }
        panel.orderFrontRegardless()

        guard let lifetime = state.hudLifetime else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }

    private func resizePanel(for state: AutoSendExperienceState) {
        let targetSize = AutoSendHUDMetrics.size(for: state)
        guard panel.frame.size != targetSize else { return }
        let currentFrame = panel.frame
        let targetOrigin = NSPoint(
            x: currentFrame.midX - (targetSize.width / 2),
            y: currentFrame.minY
        )
        panel.setFrame(NSRect(origin: targetOrigin, size: targetSize), display: panel.isVisible)
    }

#if DEBUG
    func showPlaygroundSample(_ state: AutoSendExperienceState) {
        update(state)
    }
#endif
}

private final class AutoSendHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AutoSendHUDModel: ObservableObject {
    @Published var state: AutoSendExperienceState = .idle
}

struct AutoSendHUDView: View {
    @ObservedObject var model: AutoSendHUDModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AutoSendHUDContent(state: model.state, reduceMotion: reduceMotion)
            .frame(
                width: AutoSendHUDMetrics.size(for: model.state).width,
                height: AutoSendHUDMetrics.size(for: model.state).height
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(model.state.title)
            .accessibilityValue(model.state.detail ?? "")
    }
}

struct AutoSendHUDContent: View {
    let state: AutoSendExperienceState
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: AutoSendHUDMetrics.cornerRadius, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: AutoSendHUDMetrics.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }

            HStack(spacing: 10) {
                AutoSendHUDSymbol(state: state, reduceMotion: reduceMotion)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let detail = state.detail {
                        Text(detail)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .lineLimit(state.usesExpandedHUD ? 2 : 1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .id(state.id)
            .transition(reduceMotion ? .opacity : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.96)),
                removal: .opacity.combined(with: .scale(scale: 0.84))
            ))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: state.id)
    }
}

private struct AutoSendHUDSymbol: View {
    let state: AutoSendExperienceState
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if state == .recording {
                AutoSendRecordingPulse(reduceMotion: reduceMotion, color: state.tone.color)
            }

            Circle()
                .fill(state.tone.color.opacity(0.14))
                .frame(width: 28, height: 28)

            Image(systemName: state.symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state.tone.color)
        }
        .accessibilityHidden(true)
    }
}

private struct AutoSendRecordingPulse: View {
    let reduceMotion: Bool
    let color: Color
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color.opacity(expanded ? 0 : 0.42), lineWidth: 1.5)
            .frame(width: 28, height: 28)
            .scaleEffect(expanded ? 1.35 : 0.92)
            .onAppear {
                updatePulse(reduceMotion: reduceMotion)
            }
            .onChange(of: reduceMotion) { newValue in
                updatePulse(reduceMotion: newValue)
            }
            .onDisappear {
                expanded = false
            }
    }

    private func updatePulse(reduceMotion: Bool) {
        withAnimation(nil) {
            expanded = false
        }
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.9).repeatForever(autoreverses: false)) {
            expanded = true
        }
    }
}

enum AutoSendHUDMetrics {
    static func size(for state: AutoSendExperienceState) -> NSSize {
        state.usesExpandedHUD
            ? NSSize(width: 320, height: 68)
            : NSSize(width: 292, height: 52)
    }

    static let cornerRadius: CGFloat = 16
    static let screenMargin: CGFloat = 18
}

private enum AutoSendHUDPositioner {
    @MainActor
    static func origin(for panelSize: NSSize) -> NSPoint {
        let screen = preferredScreen()
        guard let screen else { return .zero }
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.midX - (panelSize.width / 2),
            y: visible.minY + AutoSendHUDMetrics.screenMargin
        )
    }

    @MainActor
    private static func preferredScreen() -> NSScreen? {
        if let focusedField = AccessibilityPasteController.focusedTextTargetFrame(promptForPermission: false),
           let screen = screen(forQuartzRect: focusedField) {
            return screen
        }

        if let app = NSWorkspace.shared.frontmostApplication,
           let appWindow = frontmostWindowFrame(processIdentifier: app.processIdentifier),
           let screen = screen(forQuartzRect: appWindow) {
            return screen
        }

        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func frontmostWindowFrame(processIdentifier: pid_t) -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows {
            guard window[kCGWindowOwnerPID as String] as? pid_t == processIdentifier,
                  window[kCGWindowLayer as String] as? Int == 0,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1,
                  frame.height > 1 else {
                continue
            }
            return frame
        }
        return nil
    }

    private static func screen(forQuartzRect quartzRect: CGRect) -> NSScreen? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let appKitRect = CGRect(
            x: quartzRect.minX,
            y: primaryScreen.frame.maxY - quartzRect.maxY,
            width: quartzRect.width,
            height: quartzRect.height
        )
        guard let screen = NSScreen.screens.max(by: { left, right in
            intersectionArea(left.frame, appKitRect) < intersectionArea(right.frame, appKitRect)
        }), intersectionArea(screen.frame, appKitRect) > 0 else {
            return nil
        }
        return screen
    }

    private static func intersectionArea(_ left: CGRect, _ right: CGRect) -> CGFloat {
        let intersection = left.intersection(right)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}

private extension AutoSendExperienceState {
    var usesExpandedHUD: Bool {
        switch self {
        case .noTarget, .failed, .permissionNeeded:
            return true
        case .idle, .starting, .recording, .finalizing, .delivering, .sent, .cancelled,
             .pastedWithoutSend, .suppressed, .hotKeyConflict:
            return false
        }
    }
}

private extension AutoSendExperienceTone {
    var color: Color {
        switch self {
        case .neutral: return .primary
        case .recording: return .red
        case .success: return .green
        case .informational: return .blue
        case .warning: return .orange
        case .failure: return .red
        }
    }
}
