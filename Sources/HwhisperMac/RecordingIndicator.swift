import AppKit
import SwiftUI

/// What the floating recording indicator (below) is currently showing.
enum RecordingIndicatorState: Equatable {
    case listening
    case transcribing
    /// LLM text-refinement pass in flight (§4 M2) — distinct from
    /// `.transcribing` so the user can tell STT and refinement apart.
    case refining
    /// One-time heavy setup in flight (WhisperKit model download/load on
    /// macOS < 26) — a spinner plus an explanatory line so a multi-minute
    /// first-run load doesn't look like a hang.
    case preparing(String)
    case success
    case failure(String)
    /// A soft advisory (e.g. no speech detected) — a deliberate, low-stakes
    /// outcome that must NOT read as a hard error. Carries an optional title
    /// + a message; styled amber/circle rather than the failure red/triangle.
    case warning(title: String, message: String)
    /// Focus changed before insertion — the transcript was copied to the
    /// clipboard instead of being discarded (user-requested fallback,
    /// distinct from `.failure` so it doesn't read as an error).
    case copiedToClipboard(String)
    /// The user cancelled the in-progress recording (double-tap the hotkey
    /// within the cancel window) — distinct from `.failure` since this is a
    /// deliberate action, not an error.
    case cancelled
}

/// Wraps an `NSVisualEffectView` so SwiftUI content can sit on real macOS
/// window-blur ("glass") instead of a flat translucent color fill. `.hudWindow`
/// gives the dark frosted material Wispr Flow's Flow Bar uses; `.behindWindow`
/// blending samples whatever is on-screen behind the panel so the blur
/// actually reacts to the desktop under it. `state = .active` is load-bearing:
/// this panel is `.nonactivatingPanel` and never becomes key, and a vibrancy
/// view left at the default `.followsWindowActiveState` renders as a dim,
/// washed-out "inactive" material forever since the window can never become
/// active — pinning `.active` keeps the glass looking alive regardless.
private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// SwiftUI content for the floating indicator panel. Wispr-Flow-style: a
/// single-row compact pill — status icon, status text, and (while listening)
/// a live waveform meter — that hugs its content instead of sitting in a
/// fixed box. A first pass tried a larger fixed-size panel with a bright
/// colored border for visibility; a real-device screenshot showed that read
/// as an error/warning box and clipped the helper line at the fixed frame's
/// edge. This version drops the border, lets the panel auto-size to content
/// (see `RecordingIndicatorController.resizePanelToFitContent`), and reserves
/// the red accent for the pulsing "recording" dot only — the rest of the
/// pill stays a neutral glass fill so it doesn't read as a warning while
/// listening is the normal, expected state.
///
/// A second pass (this one) replaced the flat black fill with real
/// `NSVisualEffectView` glass, turned the level meter into a
/// center-anchored scrolling waveform, and added motion to every state
/// change — a flat capsule that snaps between states read as "cheap" even
/// though the layout was already right.
private struct RecordingIndicatorView: View {
    let state: RecordingIndicatorState
    let level: Float
    /// Tapped by the inline X button while listening — cancels the
    /// in-progress recording immediately (no transcription, no message),
    /// the click-to-cancel affordance users asked for instead of the
    /// fiddly double-tap-within-0.4s gesture.
    var onCancel: (() -> Void)? = nil

    @State private var isPulsing = false
    @State private var successScale: CGFloat = 0.5

    /// Exponentially-smoothed level (`displayed = displayed*0.7 + new*0.3`)
    /// so a single loud transient doesn't make a bar jump its full height in
    /// one frame — the smoothing itself is what removes the "jittery, cheap"
    /// look from the old raw-threshold bars.
    @State private var smoothedLevel: Float = 0
    /// Rolling window of the last `barCount` smoothed levels. Each new
    /// sample is pushed on the end and the oldest drops off the front, so
    /// the whole bar row reads left-to-right as a few hundred milliseconds
    /// of recent history scrolling past — the same trick a scope/DAW
    /// waveform uses to look alive instead of just "12 independent meters".
    @State private var levelHistory: [Float] = Array(repeating: 0, count: 13)

    private let barCount = 13

    var body: some View {
        HStack(alignment: reason == nil ? .center : .top, spacing: 11) {
            statusIcon
                .frame(width: 17, height: 17)
                // Nudge the icon to sit on the title's optical baseline when
                // there's a second line below.
                .padding(.top, reason == nil ? 0 : 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .center, spacing: 10) {
                    Text(statusText)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(.white.opacity(0.95))
                        .fixedSize()
                    if state == .listening {
                        waveformMeter
                        if let onCancel {
                            Button(action: onCancel) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                            .help("입력 취소")
                            .accessibilityLabel("입력 취소")
                        }
                    }
                }
                if let reason {
                    Text(reason)
                        .font(.system(size: 12.5, weight: .regular))
                        .tracking(-0.1)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineSpacing(2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 300, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, reason == nil ? 13 : 15)
        .background(
            GlassBackground()
                .clipShape(Capsule(style: .continuous))
        )
        .overlay(
            // Sub-1px hairline "edge catching light" highlight — the detail
            // that reads as glass rather than a dark plastic pill.
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.75)
        )
        .fixedSize()
        .onChange(of: level) { _, newValue in
            smoothedLevel = smoothedLevel * 0.7 + newValue * 0.3
            levelHistory.removeFirst()
            levelHistory.append(smoothedLevel)
        }
    }

    /// Failure/clipboard-copy/warning states carry an explanatory second
    /// line — everything else stays a single-row pill.
    private var reason: String? {
        switch state {
        case .failure(let reason), .copiedToClipboard(let reason): reason
        case .warning(_, let message): message
        case .preparing(let message): message
        default: nil
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .listening:
            Circle()
                .fill(Color(nsColor: .systemRed))
                .frame(width: 11, height: 11)
                .shadow(color: .red.opacity(0.6), radius: 5)
                .opacity(isPulsing ? 0.75 : 1)
                .scaleEffect(isPulsing ? 0.85 : 1.0)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                }
        case .transcribing, .refining, .preparing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.green)
                .scaleEffect(successScale)
                .onAppear {
                    successScale = 0.5
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                        successScale = 1.0
                    }
                }
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)
        case .warning:
            // Circle (not triangle) + amber (not red-orange) so a soft
            // advisory like "no speech" doesn't read as a hard error.
            Image(systemName: "waveform.slash")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.35))
        case .copiedToClipboard:
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 16))
                .foregroundStyle(.blue)
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var statusText: String {
        switch state {
        case .listening: "듣는 중…"
        case .transcribing: "변환 중…"
        case .refining: "다듬는 중…"
        case .success: "완료"
        case .failure: "실패"
        case .preparing: "준비 중…"
        case .warning(let title, _): title
        case .copiedToClipboard: "클립보드에 복사됨"
        case .cancelled: "취소됨"
        }
    }

    /// Center-anchored scrolling waveform (replaces the old bottom-anchored
    /// bar-graph meter). Bars grow symmetrically up/down from the row's
    /// vertical center, each showing one sample of `levelHistory`, and get
    /// brighter (not just taller) as they get louder. The container's
    /// width/height are fixed regardless of bar height — level changes must
    /// never resize the panel (see
    /// `RecordingIndicatorController.updateLevel`), only redraw within this
    /// box.
    private var waveformMeter: some View {
        HStack(spacing: 3) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white.opacity(barBrightness(for: index)))
                    .frame(width: 3, height: barHeight(for: index))
                    .shadow(color: .white.opacity(barGlow(for: index)), radius: 2.5)
            }
        }
        .frame(width: CGFloat(barCount) * 3 + CGFloat(barCount - 1) * 3, height: 20, alignment: .center)
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: levelHistory)
    }

    private func sample(at index: Int) -> Float {
        guard levelHistory.indices.contains(index) else { return 0 }
        return min(max(levelHistory[index], 0), 1)
    }

    private func barHeight(for index: Int) -> CGFloat {
        3 + 16 * CGFloat(sample(at: index))
    }

    private func barBrightness(for index: Int) -> Double {
        0.32 + 0.68 * Double(sample(at: index))
    }

    private func barGlow(for index: Int) -> Double {
        let value = Double(sample(at: index))
        return value > 0.55 ? (value - 0.55) * 0.9 : 0
    }
}

/// Persisted "사운드 피드백"설정 (녹음 시작/종료를 짧은 시스템 사운드로
/// 알림) — real-device check found the visual indicator alone easy to miss
/// (small, low-contrast, bottom of screen, no entrance cue); a sound the
/// user can hear without looking at the screen closes that gap (Wispr
/// Flow/Typeless both do this). Defaults to ON; UserDefaults has no
/// built-in "default true" bool, so an unset key reads as enabled.
enum SoundFeedbackSettings {
    private static let enabledKey = "soundFeedbackEnabled"

    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

/// Owns the always-on-top floating recording indicator (§4 M1 UX fix).
///
/// `.nonactivatingPanel` is load-bearing, not cosmetic: this panel must
/// NEVER take keyboard focus or become the frontmost app, because doing so
/// would change `NSWorkspace.shared.frontmostApplication` out from under the
/// `TargetContextSnapshot` captured at hotkey-down and silently break
/// insertion targeting (AC8) — the whole point of dictation is to insert
/// into whatever app the user was just in, not into this indicator.
@MainActor
final class RecordingIndicatorController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<RecordingIndicatorView>?
    private var state: RecordingIndicatorState = .listening
    private var level: Float = 0
    private var autoHideWorkItem: DispatchWorkItem?
    /// True while a `hide()` fade is in flight. `present()` clears it so the
    /// fade's completion no longer `orderOut`s the (now re-shown) panel.
    private var hidePending = false
    /// Set by `AppDelegate`; invoked when the user clicks the inline X while
    /// listening. Cancels the recording regardless of how long it's been
    /// running (unlike the double-tap gesture, which only cancels within
    /// `cancelTapWindow`).
    var onCancel: (() -> Void)?

    /// Single place the SwiftUI root view is built so every construction
    /// site (present/updateLevel/panel creation) carries the cancel handler.
    private func makeRootView() -> RecordingIndicatorView {
        RecordingIndicatorView(state: state, level: level, onCancel: onCancel)
    }

    func showListening() {
        level = 0
        present(.listening)
        playSound(named: "Tink")
    }

    /// `level` arrives from `AudioCapture.onLevelUpdate`, fired on the
    /// real-time audio tap thread; callers must already have hopped to the
    /// main actor before calling this (see `AppDelegate`). This intentionally
    /// does NOT go through `resizePanelToFitContent` — the waveform lives in
    /// a fixed-size box (see `RecordingIndicatorView.waveformMeter`), so a
    /// level tick can only ever change bar heights inside that box, never
    /// the panel's fitting size. Re-measuring/resizing the window on every
    /// tick (the old behavior) was pure wasted work at audio-tap rate.
    func updateLevel(_ newLevel: Float) {
        level = newLevel
        guard state == .listening else { return }
        hostingView?.rootView = makeRootView()
    }

    /// Called right as recording ends and transcription begins — the
    /// "종료" cue in the start/end sound pair, distinct from the start
    /// sound so the user can tell the two apart without looking.
    func showTranscribing() {
        present(.transcribing)
        playSound(named: "Bottle")
    }

    /// Shown while an LLM refinement pass is in flight (§4 M2), distinct
    /// from `.transcribing` so "받아쓰기 중" and "다듬는 중" read as
    /// different stages of the pipeline.
    func showRefining() {
        present(.refining)
    }

    /// One-time heavy setup (WhisperKit model download/load). No auto-hide —
    /// it stays until the transcription that follows swaps the state.
    func showPreparingModel(_ message: String) {
        present(.preparing(message))
    }

    func showSuccess() {
        present(.success)
        scheduleAutoHide(after: 0.9)
    }

    /// Shows the failure reason directly on the indicator rather than
    /// relying solely on a system notification, which the user may not have
    /// authorized (§4 requirement: don't depend on notifications alone).
    func showFailure(_ message: String) {
        present(.failure(message))
        scheduleAutoHide(after: 3.5)
    }

    /// A soft advisory (e.g. no speech detected) — deliberately gentler than
    /// `showFailure`: amber, not red, and a shorter dwell since there's
    /// nothing for the user to fix beyond trying again.
    func showWarning(title: String, message: String) {
        present(.warning(title: title, message: message))
        scheduleAutoHide(after: 2.6)
    }

    /// Focus changed before insertion — the transcript landed on the
    /// clipboard instead (user-requested fallback). Shown longer than
    /// `.success` since the user still has to act (⌘V).
    func showCopiedToClipboard(_ message: String) {
        present(.copiedToClipboard(message))
        scheduleAutoHide(after: 3.5)
    }

    /// The user cancelled the in-progress recording (double-tap the hotkey
    /// within the cancel window, §3.1 cancel path). Auto-hides quickly since
    /// this is a deliberate, low-stakes action — no clipboard/transcript to
    /// act on.
    func showCancelled() {
        present(.cancelled)
        scheduleAutoHide(after: 1.2)
    }

    /// Fade + slight downward settle (0.25s) rather than an instant
    /// `orderOut` — an indicator that's suddenly just gone reads as a glitch
    /// as much as one that suddenly just appears does.
    func hide() {
        autoHideWorkItem?.cancel()
        guard let panel, panel.isVisible else { return }
        hidePending = true
        var frame = panel.frame
        frame.origin.y -= 8
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor in
                // If a `present()` ran during the fade it cleared `hidePending`
                // and re-showed the panel — don't order it out from under the
                // new state.
                guard let self, self.hidePending else { return }
                self.hidePending = false
                self.panel?.orderOut(nil)
            }
        }
    }

    private func present(_ newState: RecordingIndicatorState) {
        autoHideWorkItem?.cancel()
        hidePending = false // cancel any in-flight hide's pending orderOut
        state = newState
        let panel = makePanelIfNeeded()
        let wasVisible = panel.isVisible

        // Only intercept mouse events while listening (so the inline X is
        // clickable). In every other state the pill is purely informational
        // and must let clicks pass through to the app behind it. The panel
        // is `.nonactivatingPanel`, so even an intercepted click never
        // changes the frontmost app / insertion target.
        panel.ignoresMouseEvents = (newState != .listening)

        if wasVisible {
            // Crossfade the content (icon/text swap) and ease the pill's
            // frame to its new fitting size in the same 0.25s transaction,
            // instead of the old instant swap + instant resize — this is
            // the single change that made state transitions (listening →
            // transcribing → ✅) stop feeling like a slideshow.
            withAnimation(.easeInOut(duration: 0.25)) {
                hostingView?.rootView = makeRootView()
            }
            resizePanelToFitContent(animated: true)
            // Restore opacity: a new recording can begin during the 0.25s hide
            // fade, when the panel is still `isVisible` but its alpha is being
            // animated toward 0. Without this the pill orders front at alpha 0
            // (invisible) and stays stuck there across later state changes —
            // "the indicator stopped appearing after repeated use".
            panel.animator().alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            hostingView?.rootView = makeRootView()
            resizePanelToFitContent(animated: false)
            animateIn(panel, to: panel.frame.origin)
        }
    }

    /// Fade-in + slight rise (0.2s) on first appearance only, so the
    /// indicator's arrival is itself a noticeable event rather than an
    /// object that's suddenly just there (real-device check: silent
    /// appearance with no motion was easy to miss).
    private func animateIn(_ panel: NSPanel, to targetOrigin: NSPoint) {
        let size = panel.frame.size
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: targetOrigin.x, y: targetOrigin.y - 10))
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrame(NSRect(origin: targetOrigin, size: size), display: true)
        }
    }

    /// The pill auto-sizes to its content (no fixed frame — a fixed frame
    /// is what clipped the helper text in a previous design). Re-measures
    /// the hosting view's ideal size and resizes/repositions the panel to
    /// match, keeping the bottom edge pinned at the same anchor so the pill
    /// grows upward (not off-screen) when a state needs a second line
    /// (failure/clipboard reason). Only called on state/text changes (see
    /// `updateLevel`, which deliberately skips this) — animated when the
    /// panel is already visible so the resize reads as a smooth reflow
    /// instead of a snap.
    private func resizePanelToFitContent(animated: Bool) {
        guard let panel, let hostingView else { return }
        let fitting = hostingView.fittingSize
        let size = NSSize(width: max(fitting.width, 120), height: max(fitting.height, 40))
        let origin = bottomCenterOrigin(for: size)
        let newFrame = NSRect(origin: origin, size: size)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                hostingView.animator().setFrameSize(size)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            hostingView.frame = NSRect(origin: .zero, size: size)
            panel.setFrame(newFrame, display: panel.isVisible)
        }
    }

    /// Plays a short, quiet system sound so the user gets a non-visual cue
    /// they don't need to look at the screen to notice (respects the
    /// "사운드 피드백" setting, default ON).
    private func playSound(named name: NSSound.Name) {
        guard SoundFeedbackSettings.isEnabled else { return }
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0.35
        sound.play()
    }

    private func scheduleAutoHide(after interval: TimeInterval) {
        autoHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.hide() }
        autoHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let frame = NSRect(x: 0, y: 0, width: 200, height: 48)
        let hosting = NSHostingView(rootView: makeRootView())
        hosting.frame = frame
        self.hostingView = hosting

        let newPanel = NSPanel(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        newPanel.isFloatingPanel = true
        // .statusBar keeps this visible above fullscreen apps' windows
        // without joining the menu bar/Dock auto-hide dance.
        newPanel.level = .statusBar
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The window server draws this shadow outside the content view's
        // bounds, so unlike a SwiftUI `.shadow()` (which would get clipped
        // by the tightly-fitted hosting view) it's free to be large and
        // soft without needing extra padding reserved around the capsule.
        newPanel.hasShadow = true
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        // Default to click-through; `present(_:)` flips this to interactive
        // only while listening so the inline X is clickable. The panel is
        // `.nonactivatingPanel`, so even an intercepted click can't steal
        // focus from the insertion target.
        newPanel.ignoresMouseEvents = true
        newPanel.hidesOnDeactivate = false
        newPanel.contentView = hosting

        self.panel = newPanel
        return newPanel
    }

    /// Target origin for a pill of `size`, centered horizontally and raised
    /// well above the screen bottom (real-device check: the old 56pt offset
    /// sat right on top of the Dock and app input fields/composer bars,
    /// which is exactly where the user's attention already is — 140pt
    /// clears that zone). The bottom edge stays pinned at this y regardless
    /// of content height, so taller states (failure reason) grow upward.
    private func bottomCenterOrigin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main else { return .zero }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - size.width / 2
        let y = screenFrame.minY + 140
        return NSPoint(x: x, y: y)
    }
}
