import Foundation

/// Result of a single insertion-strategy attempt.
enum InsertionOutcome: Equatable {
    case inserted
    /// This strategy cannot act on the current target (e.g. no settable AX
    /// attribute); the registry should fall through to the next strategy.
    case notApplicable
    /// This strategy attempted and failed; the registry stops and surfaces
    /// the failure (clipboard-preserve + notify, §3.1).
    case failed(String)
}

/// One of C1 (clipboard+⌘V), C2 (AX direct set), C3 (CGEvent keystrokes)
/// from the per-app strategy registry (§3 Decision c).
///
/// Implementations assume the caller has already performed the TOCTOU
/// secure-input check (`SecureInputGuard`) and resolved the destination —
/// strategies do not repeat those checks themselves.
///
/// Takes the `InsertionDestination` resolved at insertion time, NOT the
/// hotkey-down snapshot. That distinction is load-bearing for
/// `AccessibilityInserter`, which addresses the target app by pid: handing it
/// the stale snapshot would make it write into the app the user just left,
/// invisibly, whenever focus had moved.
///
/// Pinned to `@MainActor`: every conformer drives AX/clipboard/CGEvent,
/// which §3.1 assigns to the `@MainActor InsertionCoordinator` boundary.
protocol InsertionStrategy {
    @MainActor
    func insert(_ text: String, destination: InsertionDestination) async -> InsertionOutcome
}
