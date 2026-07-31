import AppKit

/// Where dictation *started*, captured at hotkey-down (idle→listening, §3.1).
///
/// Advisory only. This used to gate insertion: `matchesCurrent()` demanded the
/// frontmost app and its focused `AXUIElement` be identical at insert time
/// (AC8, R5) and any difference aborted to the clipboard. Measured against this
/// app's own history that rejected 7.4% of dictations — all with a live,
/// writable caret sitting right there — so the gate was replaced by
/// `InsertionDestination`, which asks whether the *current* focus can accept
/// text rather than whether it is the same focus.
///
/// What remains is the origin, used for two things only: telling the user when
/// text landed somewhere other than where they started, and attributing the
/// history row when nothing was inserted.
struct TargetContextSnapshot: Equatable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t?

    private init(bundleIdentifier: String?, processIdentifier: pid_t?) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
    }

    /// Captures the frontmost app. Must be called on the main thread
    /// (AppKit convention); callers here are always `@MainActor`.
    @MainActor
    static func capture() -> TargetContextSnapshot {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return TargetContextSnapshot(bundleIdentifier: nil, processIdentifier: nil)
        }
        return TargetContextSnapshot(
            bundleIdentifier: frontmost.bundleIdentifier,
            processIdentifier: frontmost.processIdentifier
        )
    }
}
