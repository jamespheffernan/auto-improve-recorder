import SwiftUI
import UIKit

// MARK: - Accent system (user-selectable)

enum SwissAccent: String, CaseIterable, Identifiable {
    case brandNew  // hot red
    case bauhaus   // cobalt
    case vignelli  // mustard
    case sequoia   // forest emerald
    case riot      // hot pink
    case sienna    // burnt orange

    var id: String { rawValue }

    var name: String {
        switch self {
        case .brandNew: return "Brand New"
        case .bauhaus:  return "Bauhaus"
        case .vignelli: return "Vignelli"
        case .sequoia:  return "Sequoia"
        case .riot:     return "Riot"
        case .sienna:   return "Sienna"
        }
    }

    var caption: String {
        switch self {
        case .brandNew: return "Hot red — confident, urgent"
        case .bauhaus:  return "Deep cobalt — design-textbook quiet"
        case .vignelli: return "Signal yellow — NYC subway warmth"
        case .sequoia:  return "Forest emerald — grounded, evergreen"
        case .riot:     return "Hot pink — slightly punk, undeniable"
        case .sienna:   return "Burnt orange — earth, warmth"
        }
    }

    var color: Color {
        switch self {
        case .brandNew: return Color(red: 0.886, green: 0.220, blue: 0.220)
        case .bauhaus:  return Color(red: 0.102, green: 0.243, blue: 0.667)
        case .vignelli: return Color(red: 0.824, green: 0.576, blue: 0.078)
        case .sequoia:  return Color(red: 0.118, green: 0.424, blue: 0.290)
        case .riot:     return Color(red: 0.914, green: 0.118, blue: 0.361)
        case .sienna:   return Color(red: 0.769, green: 0.353, blue: 0.165)
        }
    }

    /// Foreground used on top of the accent background.
    var foreground: Color {
        switch self {
        case .vignelli: return Color(red: 0.102, green: 0.067, blue: 0)
        default:        return SwissPalette.paper
        }
    }
}

// MARK: - Palette + type

enum SwissPalette {
    static let paper    = Color(red: 0.957, green: 0.945, blue: 0.922) // #F4F1EB
    static let ink      = Color(red: 0.039, green: 0.039, blue: 0.039) // #0A0A0A
    static let mute     = Color(red: 0.039, green: 0.039, blue: 0.039).opacity(0.55)
    static let hairline = Color(red: 0.039, green: 0.039, blue: 0.039).opacity(1)
    static let grid     = Color(red: 0.039, green: 0.039, blue: 0.039).opacity(0.04)
    static let muteSoft = Color(red: 0.039, green: 0.039, blue: 0.039).opacity(0.32)
}

// MARK: - Motion timings (mechanical, no springs)

enum Motion {
    static let toggleSlide   = Animation.timingCurve(0.85, 0, 0.15, 1, duration: 0.22)
    static let copiedSlide   = Animation.timingCurve(0.85, 0, 0.15, 1, duration: 0.24)
    static let phaseSwap     = Animation.linear(duration: 0.16)
    static let press         = Animation.linear(duration: 0.08)
    static let recordIgnite  = Animation.timingCurve(0.4, 0, 0.6, 1, duration: 0.18)
}

// MARK: - Type system (refined editorial body, condensed display)

enum SwissType {
    /// Editorial body — New York serif at a reading size with loose leading.
    /// Used for transcript and message body. Apple's modern serif, NOT the
    /// generic Times-like serif from the original screenshot.
    static let body: Font = .system(size: 22, weight: .regular, design: .serif)

    /// Italic emphasis for highlighted spans inside body text.
    static let bodyItalic: Font = .system(size: 22, weight: .regular, design: .serif).italic()

    /// Slightly smaller refined body for secondary content.
    static let bodySmall: Font = .system(size: 19, weight: .regular, design: .serif)
}

// MARK: - Main view

struct IOSRecorderView: View {
    @EnvironmentObject private var state: IOSAppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("swissAccent") private var accentRaw: String = SwissAccent.brandNew.rawValue

    @State private var showingSettings = false

    // Recording timer
    @State private var recordingStart: Date = .now
    @State private var displayedSeconds: Int = 0
    @State private var timerTask: Task<Void, Never>?

    // Index counter
    @State private var indexNumber: String = "00"

    // Improve scramble
    @State private var isScrambling = false
    @State private var scrambleStart: Date = .now
    @State private var scrambleTarget: String = ""
    @State private var scrambleTask: Task<Void, Never>?

    // Copied bar
    @State private var copyFeedback: Bool = false
    @State private var copyHideTask: Task<Void, Never>?
    @State private var primaryPressIsDown = false
    @State private var primaryPressHasFired = false

    // First-frame budget: skip decorative grid + ultraThinMaterial blur until
    // after the first interactive frame so SwiftUI has less to render on cold start.
    @State private var hasShownFirstFrame: Bool = false

    // Cached date string — computed once on appear, not per-render.
    @State private var currentDateString: String = Self.formattedToday()

    private var accent: SwissAccent {
        SwissAccent(rawValue: accentRaw) ?? .brandNew
    }
    private var accentColor: Color { accent.color }
    private var accentFG: Color { accent.foreground }

    var body: some View {
        ZStack(alignment: .bottom) {
            SwissPalette.paper.ignoresSafeArea()
            if hasShownFirstFrame {
                gridBackground
            }

            VStack(spacing: 0) {
                metaStrip
                headerRow
                toggleStrip
                bodySection
                if !state.history.isEmpty {
                    historyStrip
                }
                Spacer(minLength: 0)
            }

            if copyFeedback {
                copiedBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showingSettings) {
            SwissSettingsSheet(accentRaw: $accentRaw)
                .environmentObject(state)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            dock
        }
        .onAppear {
            AIRColdStartTracker.markFirstAppear()
            AIRColdStartTracker.markFirstInteractive()
            tickIndexNumber()
            // Reveal decorative grid + ultraThinMaterial after the first interactive frame.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000)
                hasShownFirstFrame = true
            }
            // Defer audio session warmup off the first frame.
            Task.detached(priority: .utility) {
                await MainActor.run { state.prepareForFastRecordingStart() }
            }
        }
        .onDisappear { cleanupTasks() }
        .onChange(of: state.phase) { oldPhase, newPhase in
            handlePhaseChange(from: oldPhase, to: newPhase)
        }
        .onChange(of: state.statusMessage) { _, msg in
            if let msg, msg.localizedCaseInsensitiveContains("copied") {
                triggerCopyFeedback()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                state.prepareForFastRecordingStart()
            case .background:
                state.releaseFastRecordingResourcesIfIdle()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }

    // MARK: - Background grid

    private var gridBackground: some View {
        GeometryReader { geo in
            let count = 6
            let step = geo.size.width / CGFloat(count)
            Canvas { ctx, size in
                for i in 1..<count {
                    let x = CGFloat(i) * step
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    ctx.stroke(path, with: .color(SwissPalette.grid), lineWidth: 1)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // MARK: - Meta strip (REC indicator + date + frame)

    private var metaStrip: some View {
        HStack {
            HStack(spacing: 6) {
                RecDot(isRecording: state.isRecording, accent: accentColor)
                Text(state.isRecording ? "REC \(timeString)" : "READY  00:00")
                    .monoSmall()
                    .foregroundStyle(state.isRecording ? accentColor : SwissPalette.ink)
                    .monospacedDigit()
            }
            Spacer()
            Text(currentDateString)
                .monoSmall()
                .foregroundStyle(SwissPalette.ink)
            Spacer()
            HStack(spacing: 0) {
                Text("F.")
                    .monoSmall()
                    .foregroundStyle(SwissPalette.ink.opacity(0.55))
                Text(indexNumber)
                    .monoSmall()
                    .foregroundStyle(SwissPalette.ink)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { hairline }
        .overlay(alignment: .bottom) { hairline }
        .padding(.top, 6)
    }

    // MARK: - Header (index block + DRAFT MODE.)

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                Text("N°")
                    .monoSmall()
                    .foregroundStyle(accentFG.opacity(0.85))
                Text(indexNumber)
                    .font(.system(size: 28, weight: .heavy))
                    .fontWidth(.compressed)
                    .monospacedDigit()
                    .foregroundStyle(accentFG)
                    .lineSpacing(-2)
            }
            .frame(width: 56)
            .padding(.vertical, 10)
            .background(state.isRecording || state.phase.isBusy ? SwissPalette.ink : accentColor)
            .animation(reduceMotion ? nil : Motion.phaseSwap, value: state.phase)

            VStack(alignment: .leading, spacing: 6) {
                Text("Voice / \(headerLabel)")
                    .monoTiny()
                    .foregroundStyle(SwissPalette.muteSoft)

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Draft")
                        .font(.system(size: 60, weight: .heavy))
                        .fontWidth(.compressed)
                        .foregroundStyle(SwissPalette.ink)
                    Text(" ")
                }
                Text(headerSecond)
                    .font(.system(size: 60, weight: .heavy))
                    .fontWidth(.compressed)
                    .foregroundStyle(accentColor)
                    .padding(.top, -22)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
    }

    private var headerLabel: String {
        switch state.phase {
        case .idle:         return "Standby"
        case .starting:     return "Opening"
        case .recording:    return "Live"
        case .transcribing: return "Transcribe"
        case .improving:    return "Polish"
        case .delivering:   return "Send"
        case .ready:        return state.showRawTranscript ? "Raw" : "Cleaned"
        case .failed:       return "Error"
        }
    }

    private var headerSecond: String {
        switch state.phase {
        case .idle:         return "Mode."
        case .starting:     return "Mic."
        case .recording:    return "Live."
        case .transcribing: return "Pull."
        case .improving:    return "Polish."
        case .delivering:   return "Send."
        case .ready:        return "Done."
        case .failed:       return "Halt."
        }
    }

    // MARK: - Toggle strip

    private var toggleStrip: some View {
        HStack(spacing: 0) {
            toggleOption(label: "Cleaned", active: !state.showRawTranscript) {
                Haptics.selection()
                state.showRawTranscript = false
            }
            divider
            toggleOption(label: "Raw", active: state.showRawTranscript) {
                Haptics.selection()
                state.showRawTranscript = true
            }
        }
        .background(SwissPalette.paper)
        .overlay(Rectangle().stroke(SwissPalette.hairline, lineWidth: 1))
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .opacity(state.session.rawTranscript.isEmpty ? 0.42 : 1)
        .disabled(state.session.rawTranscript.isEmpty)
    }

    private func toggleOption(label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .heavy))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(active ? SwissPalette.paper : SwissPalette.ink)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(active ? SwissPalette.ink : Color.clear)
                .animation(reduceMotion ? nil : Motion.toggleSlide, value: active)
        }
        .buttonStyle(SwissPressStyle())
    }

    private var divider: some View {
        Rectangle()
            .fill(SwissPalette.hairline)
            .frame(width: 1)
    }

    // MARK: - Body section

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("01")
                    .font(.system(size: 30, weight: .heavy))
                    .fontWidth(.compressed)
                    .monospacedDigit()
                    .foregroundStyle(SwissPalette.ink)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(footerStrong)
                        .monoTiny()
                        .foregroundStyle(SwissPalette.ink)
                    Text(footerDetail)
                        .monoTiny()
                        .foregroundStyle(SwissPalette.muteSoft)
                }
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) { hairline }

            phaseBody
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: phaseBodyHeight, alignment: .topLeading)

            Spacer(minLength: 0)

            HStack {
                Text(state.history.isEmpty ? "Start / 001" : "End / \(indexNumber)")
                    .monoTiny()
                    .foregroundStyle(SwissPalette.ink)
                Spacer()
                Text(footerEnd)
                    .monoTiny()
                    .foregroundStyle(state.phase == .failed ? accentColor : SwissPalette.ink)
            }
            .padding(.top, 8)
            .overlay(alignment: .top) { hairline }
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
    }

    @ViewBuilder
    private var phaseBody: some View {
        switch state.phase {
        case .idle:
            if state.session.preferredText.isEmpty {
                Text("Tap record. We'll polish what you said.")
                    .font(SwissType.body)
                    .foregroundStyle(SwissPalette.muteSoft)
                    .padding(.top, 4)
            } else {
                readyText
            }
        case .starting:
            AnimatedDotsLabel(text: "Opening microphone")
                .foregroundStyle(SwissPalette.ink)
        case .recording:
            SwissWaveform(accent: accentColor)
                .frame(height: 90)
                .transition(.opacity)
        case .transcribing, .improving:
            VStack(alignment: .leading, spacing: 14) {
                AnimatedDotsLabel(text: state.phase == .transcribing ? "Transcribing" : "Polishing")
                    .foregroundStyle(SwissPalette.ink)
                if state.phase == .improving, !state.session.rawTranscript.isEmpty {
                    TranscriptViewport {
                        Text(state.session.rawTranscript)
                            .font(SwissType.body)
                            .lineSpacing(4)
                            .foregroundStyle(SwissPalette.ink.opacity(0.55))
                            .modifier(ShimmerStep(active: !reduceMotion))
                    }
                }
            }
        case .delivering:
            AnimatedDotsLabel(text: "Sending")
                .foregroundStyle(SwissPalette.ink)
        case .ready:
            readyText
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Text("Recording didn't finish.")
                    .font(.system(size: 19, weight: .heavy))
                    .fontWidth(.compressed)
                    .foregroundStyle(accentColor)
                Text(state.session.message ?? state.statusMessage ?? "Try again.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SwissPalette.ink.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var readyText: some View {
        TranscriptViewport {
            if isScrambling, !state.showRawTranscript {
                ScrambleText(target: scrambleTarget, start: scrambleStart, duration: 1.1, accent: accentColor)
            } else {
                HighlightedTranscript(text: displayText, highlightAccent: accentColor)
            }
        }
    }

    private var displayText: String {
        let raw = state.showRawTranscript ? state.session.rawTranscript : state.session.preferredText
        return raw.isEmpty ? state.session.preferredText : raw
    }

    // MARK: - History strip (Swiss)

    private var historyStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Earlier / \(state.history.count)")
                    .monoTiny()
                    .foregroundStyle(SwissPalette.muteSoft)
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(state.history.prefix(10).enumerated()), id: \.element.id) { _, item in
                        HistoryChip(item: item, accent: accentColor) {
                            state.restoreHistoryItem(item, useRaw: false)
                        }
                    }
                }
                .padding(.horizontal, 28)
            }
            .padding(.bottom, 6)
        }
        .overlay(alignment: .top) { hairline.padding(.top, 0) }
    }

    // MARK: - Dock

    private var dock: some View {
        HStack(spacing: 10) {
            dockButton(label: "Settings", systemImage: "slider.horizontal.3") {
                Haptics.light()
                showingSettings = true
            }

            recordButton

            if state.canCopy {
                dockButton(label: "Copy", systemImage: "doc.on.doc") {
                    Haptics.success()
                    state.copyDisplayText()
                }
            }

            if state.canRerunImprove {
                dockButton(label: "Polish", systemImage: "wand.and.stars") {
                    Haptics.light()
                    state.rerunImprove()
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(hasShownFirstFrame ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(SwissPalette.paper))
        .overlay(alignment: .top) { hairline }
    }

    private func dockButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(SwissPalette.ink)
                .frame(width: 52, height: 52)
                .background(SwissPalette.paper)
                .overlay(Rectangle().stroke(SwissPalette.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(SwissPressStyle())
        .accessibilityLabel(label)
    }

    private var recordButton: some View {
        HStack(spacing: 10) {
            Image(systemName: state.isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 18, weight: .heavy))
            Text(primaryActionTitle)
                .font(.system(size: 12, weight: .heavy))
                .tracking(2.0)
                .textCase(.uppercase)
        }
        .foregroundStyle(state.isRecording ? accentFG : SwissPalette.paper)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(state.isRecording ? accentColor : SwissPalette.ink)
        .contentShape(Rectangle())
        .opacity(recordButtonOpacity)
        .scaleEffect(primaryPressIsDown ? 0.992 : 1)
        .animation(.linear(duration: 0.04), value: primaryPressIsDown)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    primaryPressIsDown = true
                    guard !primaryPressHasFired else { return }
                    primaryPressHasFired = true
                    triggerPrimaryAction()
                }
                .onEnded { _ in
                    primaryPressIsDown = false
                    primaryPressHasFired = false
                }
        )
        .accessibilityLabel(primaryActionTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            triggerPrimaryAction()
        }
    }

    private var recordButtonOpacity: Double {
        if state.phase.isBusy && !state.isRecording {
            return 0.46
        }
        return primaryPressIsDown ? 0.64 : 1
    }

    private func triggerPrimaryAction() {
        if state.isRecording {
            Haptics.stop()
            state.stopRecording()
        } else if !state.phase.isBusy {
            Haptics.recordStart()
            state.startRecording()
        }
    }

    // MARK: - Copied bar

    private var copiedBar: some View {
        HStack(spacing: 12) {
            Text("01")
                .font(.system(size: 26, weight: .heavy))
                .fontWidth(.compressed)
                .foregroundStyle(accentFG)
            Text("Copied to clipboard")
                .font(.system(size: 11, weight: .heavy))
                .tracking(2.2)
                .textCase(.uppercase)
                .foregroundStyle(accentFG)
            Spacer()
            Text("→")
                .font(.system(size: 14, weight: .heavy, design: .monospaced))
                .foregroundStyle(accentFG.opacity(0.7))
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(accentColor)
        .padding(.bottom, 88 + safeBottomInset)
    }

    // MARK: - Helpers

    private var hairline: some View {
        Rectangle()
            .fill(SwissPalette.hairline)
            .frame(height: 1)
    }

    private var safeBottomInset: CGFloat {
        UIApplication.shared.keyWindow?.safeAreaInsets.bottom ?? 0
    }

    private var phaseBodyHeight: CGFloat {
        switch state.phase {
        case .ready:
            return state.history.isEmpty ? 250 : 188
        case .improving:
            return 188
        case .failed:
            return 156
        default:
            return 130
        }
    }

    private var primaryActionTitle: String {
        if state.isRecording {
            return "Stop"
        }
        if case .failed = state.phase {
            return "Try Again"
        }
        return "Record"
    }

    private var timeString: String {
        formatSeconds(displayedSeconds)
    }

    private func formatSeconds(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%02d:%02d", m, s)
    }

    private static let _dateStringFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy—MM—dd"
        return f
    }()

    private static func formattedToday() -> String {
        return _dateStringFormatter.string(from: Date())
    }

    private var footerStrong: String {
        switch state.phase {
        case .idle:         return "Ready"
        case .starting:     return "Opening"
        case .recording:    return "Recording"
        case .transcribing: return "Working"
        case .improving:    return "Polishing"
        case .delivering:   return "Sending"
        case .ready:        return state.showRawTranscript ? "Raw" : "Polished"
        case .failed:       return "Halted"
        }
    }

    private var footerDetail: String {
        let words = wordCount(displayText)
        if words > 0 {
            return "\(words) W · \(timeString)"
        }
        return "00:00"
    }

    private var footerEnd: String {
        switch state.phase {
        case .ready:        return state.showRawTranscript ? "Raw ✕" : "Polished ✓"
        case .failed:       return "Try again"
        case .recording:    return "Live ●"
        case .starting:     return "Opening…"
        case .transcribing, .improving: return "Working…"
        case .delivering:   return "Sending…"
        case .idle:         return "Standby"
        }
    }

    // MARK: - Phase transitions

    private func handlePhaseChange(from old: RecorderPhase, to new: RecorderPhase) {
        switch new {
        case .starting:
            stopTimerTask()
        case .recording:
            recordingStart = .now
            displayedSeconds = 0
            startTimerTask()
        case .transcribing:
            stopTimerTask()
            // Soft tick — "we got the audio, working on it"
            Haptics.phaseTick()
        case .improving:
            stopTimerTask()
            // Soft tick — "moving from raw to polished"
            Haptics.phaseTick()
        case .ready:
            stopTimerTask()
            // If we just polished, scramble the text in (with layered haptics).
            if old == .improving, !state.session.improvedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                triggerScramble(target: state.session.improvedText)
            } else if case .transcribing = old, !state.session.preferredText.isEmpty {
                // Transcript landed without polishing — single success.
                Haptics.success()
            }
        case .failed:
            stopTimerTask()
            Haptics.warning()
        case .delivering:
            stopTimerTask()
        case .idle:
            stopTimerTask()
        }
    }

    private func startTimerTask() {
        timerTask?.cancel()
        timerTask = Task { @MainActor in
            while !Task.isCancelled, state.isRecording {
                let elapsed = Int(Date().timeIntervalSince(recordingStart))
                if displayedSeconds != elapsed {
                    displayedSeconds = elapsed
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private func stopTimerTask() {
        timerTask?.cancel()
        timerTask = nil
    }

    private func triggerScramble(target: String) {
        scrambleTask?.cancel()
        scrambleTarget = target
        scrambleStart = .now
        isScrambling = true
        Haptics.scrambleStart()
        scrambleTask = Task { @MainActor in
            // Layered haptic pattern across the 1.1s scramble: 4 soft ticks, then success.
            // This makes polishing feel like a tactile process, not a blank wait.
            for _ in 0..<4 {
                try? await Task.sleep(nanoseconds: 220_000_000)
                if Task.isCancelled { return }
                Haptics.scrambleTick()
            }
            try? await Task.sleep(nanoseconds: 220_000_000)
            if Task.isCancelled { return }
            Haptics.scrambleEnd()
            try? await Task.sleep(nanoseconds: 80_000_000)
            isScrambling = false
        }
    }

    private func triggerCopyFeedback() {
        withAnimation(reduceMotion ? nil : Motion.copiedSlide) {
            copyFeedback = true
        }
        copyHideTask?.cancel()
        copyHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_700_000_000)
            withAnimation(reduceMotion ? nil : Motion.copiedSlide) {
                copyFeedback = false
            }
        }
    }

    private func tickIndexNumber() {
        let target = max(state.history.count + 1, 14)
        let targetStr = String(format: "%03d", target)
        var current = 0
        let step = 0.06
        Task { @MainActor in
            while current < target {
                try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
                current += 1
                indexNumber = String(format: "%03d", current)
            }
            indexNumber = targetStr
        }
    }

    private func cleanupTasks() {
        timerTask?.cancel()
        copyHideTask?.cancel()
        scrambleTask?.cancel()
    }

    private func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }
}

// MARK: - REC dot pulse (mechanical, step-pulse)

private struct RecDot: View {
    let isRecording: Bool
    let accent: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation) { context in
            let phase = phaseStep(at: context.date)
            Circle()
                .fill(isRecording ? accent : SwissPalette.muteSoft)
                .frame(width: 8, height: 8)
                .opacity(isRecording && !reduceMotion ? phase : (isRecording ? 1 : 0.45))
        }
    }

    private func phaseStep(at date: Date) -> Double {
        // Hard step every 0.4s for that mechanical Tachograph feel.
        let interval = 0.4
        let step = floor(date.timeIntervalSinceReferenceDate / interval)
        return step.truncatingRemainder(dividingBy: 2) == 0 ? 1.0 : 0.25
    }
}

// MARK: - Animated mono dots ("Transcribing.../Polishing...")

private struct AnimatedDotsLabel: View {
    let text: String
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.18, paused: false)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let dots = Int(elapsed * 4) % 4
            let suffix = String(repeating: ".", count: dots) + String(repeating: " ", count: 3 - dots)
            HStack(spacing: 0) {
                Text(text.uppercased())
                Text(suffix)
            }
            .font(.system(size: 13, weight: .bold, design: .monospaced))
            .tracking(2.2)
        }
    }
}

// MARK: - Swiss waveform (vertical bars, instant updates)

private struct SwissWaveform: View {
    let accent: Color
    private let barCount = 18

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.09)) { context in
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<barCount, id: \.self) { i in
                    Rectangle()
                        .fill(SwissPalette.ink)
                        .frame(maxWidth: .infinity)
                        .frame(height: barHeight(index: i, at: context.date))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func barHeight(index: Int, at date: Date) -> CGFloat {
        // Pseudo-random per bar per frame, with center bias for broadcast feel.
        let seed = UInt64(date.timeIntervalSinceReferenceDate * 11.123) &+ UInt64(index * 7919)
        let raw = Double((seed &* 6364136223846793005 &+ 1442695040888963407) >> 33) / Double(UInt32.max / 2)
        let value = max(0.16, min(1.0, raw))
        let center = Double(barCount) / 2.0
        let dist = abs(Double(index) - center) / center
        let bias = 1.0 - dist * 0.32
        return CGFloat(8 + value * 78 * bias)
    }
}

// MARK: - Highlighted transcript (with accent on `stop` etc)

private struct TranscriptViewport<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content
                .padding(.bottom, 18)
        }
        .scrollBounceBehavior(.basedOnSize)
        .mask(alignment: .center) {
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.88),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .accessibilityElement(children: .contain)
    }
}

private struct HighlightedTranscript: View {
    let text: String
    let highlightAccent: Color

    var body: some View {
        Text(text)
            .font(SwissType.body)
            .lineSpacing(5)
            .kerning(0.1)
            .foregroundStyle(SwissPalette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Scramble effect

private struct ScrambleText: View {
    let target: String
    let start: Date
    let duration: Double
    let accent: Color

    private static let scrambleChars: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ!?.,;:0123456789")

    var body: some View {
        TimelineView(.animation) { context in
            Text(currentText(at: context.date))
                .font(SwissType.body)
                .lineSpacing(5)
                .kerning(0.1)
                .foregroundStyle(SwissPalette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func currentText(at date: Date) -> String {
        let elapsed = date.timeIntervalSince(start)
        let t = max(0, min(1, elapsed / duration))
        var result = ""
        let chars = Array(target)
        for i in 0..<chars.count {
            let charT = t * 1.4 - (Double(i) / Double(max(chars.count, 1))) * 0.4
            if charT >= 1.0 {
                result.append(chars[i])
            } else if chars[i].isWhitespace || chars[i].isNewline {
                result.append(chars[i])
            } else if !chars[i].isLetter && !chars[i].isNumber {
                result.append(chars[i])
            } else {
                let idx = Int.random(in: 0..<Self.scrambleChars.count)
                result.append(Self.scrambleChars[idx])
            }
        }
        return result
    }
}

// MARK: - Step shimmer modifier (for "polishing" text)

private struct ShimmerStep: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if !active {
            content
        } else {
            TimelineView(.animation) { context in
                let step = floor(context.date.timeIntervalSinceReferenceDate * 6).truncatingRemainder(dividingBy: 2)
                content.opacity(step == 0 ? 1.0 : 0.55)
            }
        }
    }
}

// MARK: - History chip (Swiss)

private struct HistoryChip: View {
    let item: IOSTranscriptHistoryItem
    let accent: Color
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(item.createdAt.formatted(.dateTime.hour().minute()))
                        .monoTiny()
                        .foregroundStyle(SwissPalette.muteSoft)
                    Spacer()
                    if item.improveFailed {
                        Text("RAW")
                            .monoTiny()
                            .foregroundStyle(accent)
                    }
                }
                Text(item.preferredText.prefix(140) + (item.preferredText.count > 140 ? "…" : ""))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SwissPalette.ink)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: 220, alignment: .leading)
            }
            .padding(12)
            .frame(width: 240, alignment: .leading)
            .background(SwissPalette.paper)
            .overlay(Rectangle().stroke(SwissPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(SwissPressStyle())
    }
}

// MARK: - Press style (opacity flash, mechanical timing)

private struct SwissPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.linear(duration: 0.06), value: configuration.isPressed)
    }
}

// MARK: - Type extensions

private extension View {
    func monoSmall() -> some View {
        self.font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(2.0)
            .textCase(.uppercase)
    }

    func monoTiny() -> some View {
        self.font(.system(size: 9, weight: .semibold, design: .monospaced))
            .tracking(1.8)
            .textCase(.uppercase)
    }
}

// MARK: - Haptics (pre-warmed, layered)

/// All generators pre-warmed at launch. After every fire we re-prepare so the
/// next tap is fast. Intensity tweaks give each lifecycle moment its own feel.
enum Haptics {
    private static let lightGen: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .light); g.prepare(); return g
    }()
    private static let softGen: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .soft); g.prepare(); return g
    }()
    private static let mediumGen: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .medium); g.prepare(); return g
    }()
    private static let rigidGen: UIImpactFeedbackGenerator = {
        let g = UIImpactFeedbackGenerator(style: .rigid); g.prepare(); return g
    }()
    private static let notificationGen: UINotificationFeedbackGenerator = {
        let g = UINotificationFeedbackGenerator(); g.prepare(); return g
    }()
    private static let selectionGen: UISelectionFeedbackGenerator = {
        let g = UISelectionFeedbackGenerator(); g.prepare(); return g
    }()

    /// Tap an icon button or open a menu — light, neutral.
    static func light()       { lightGen.impactOccurred(intensity: 0.7); lightGen.prepare() }

    /// Toggle Cleaned/Raw — selection feel.
    static func selection()   { selectionGen.selectionChanged(); selectionGen.prepare() }

    /// "Ignition" — recording is starting. Slightly hard medium thump.
    /// Layered: medium impact + a tiny rigid follow-up 35ms later for ignition feel.
    static func recordStart() {
        mediumGen.impactOccurred(intensity: 1.0)
        mediumGen.prepare()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
            rigidGen.impactOccurred(intensity: 0.55)
            rigidGen.prepare()
        }
    }

    /// Hard stop — "click" of a transport button.
    static func stop()        { rigidGen.impactOccurred(intensity: 0.92); rigidGen.prepare() }

    /// A subtle "phase moved forward" tick (transcribing → improving → ready).
    static func phaseTick()   { softGen.impactOccurred(intensity: 0.6); softGen.prepare() }

    /// Polishing scramble starts.
    static func scrambleStart() { lightGen.impactOccurred(intensity: 0.5); lightGen.prepare() }

    /// One of N taps fired during the scramble — very subtle.
    static func scrambleTick() { softGen.impactOccurred(intensity: 0.45); softGen.prepare() }

    /// Polish settled — success.
    static func scrambleEnd()  { notificationGen.notificationOccurred(.success); notificationGen.prepare() }

    /// Copied to clipboard.
    static func success()      { notificationGen.notificationOccurred(.success); notificationGen.prepare() }

    /// Recording failed / something needs attention.
    static func warning()      { notificationGen.notificationOccurred(.warning); notificationGen.prepare() }
}

// MARK: - Settings sheet (Swiss-styled)

struct SwissSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: IOSAppState
    @Binding var accentRaw: String

    private var accent: SwissAccent {
        SwissAccent(rawValue: accentRaw) ?? .brandNew
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SwissPalette.paper.ignoresSafeArea()
                Form {
                    Section {
                        ForEach(SwissAccent.allCases) { option in
                            Button {
                                accentRaw = option.rawValue
                                Haptics.light()
                            } label: {
                                HStack(spacing: 14) {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(option.color)
                                        .frame(width: 36, height: 36)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.name)
                                            .font(.system(size: 15, weight: .heavy))
                                            .fontWidth(.compressed)
                                            .textCase(.uppercase)
                                            .tracking(1.2)
                                            .foregroundStyle(SwissPalette.ink)
                                        Text(option.caption)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(SwissPalette.muteSoft)
                                    }
                                    Spacer()
                                    if accent == option {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .heavy))
                                            .foregroundStyle(option.color)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Accent")
                    }

                    Section {
                        Picker("Capture engine", selection: $state.processingMode) {
                            ForEach(IOSProcessingMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                    } header: {
                        Text("Capture")
                    }

                    Section {
                        Picker("Cleanup provider", selection: $state.improvementMode) {
                            ForEach(ImprovementMode.allCases.filter { $0 != .ollamaLocal }) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        Picker("Cleanup", selection: $state.outputMode) {
                            ForEach(OutputMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        Picker("Auto-improve", selection: $state.autoImproveMode) {
                            ForEach(AutoImproveMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                    } header: {
                        Text("Draft")
                    }

                    Section {
                        Toggle("Copy finished text", isOn: $state.copyFinishedTextToClipboard)
                        Stepper("Threshold: \(state.thresholdWords) words", value: $state.thresholdWords, in: 1...500)
                    } header: {
                        Text("Behavior")
                    }

                    Section {
                        SecureField("OpenAI API key", text: $state.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Gemini API key", text: $state.geminiAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Anthropic API key", text: $state.anthropicAPIKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Providers")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Bridge for accessing safe area inset

private extension UIApplication {
    var keyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }
}

#Preview {
    IOSRecorderView()
        .environmentObject(IOSAppState())
}
