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
/// secure-input check (`SecureInputGuard`) and the AC8 context-integrity
/// revalidation immediately before calling `insert` — strategies do not
/// repeat those checks themselves.
///
/// Pinned to `@MainActor`: every conformer drives AX/clipboard/CGEvent,
/// which §3.1 assigns to the `@MainActor InsertionCoordinator` boundary.
/// This also keeps `TargetContextSnapshot` (not `Sendable` — it wraps an
/// `AXUIElement` identity marker) and strategy values on a single isolation
/// domain end-to-end, so `TextInserter` never needs to "send" them across
/// actors (Swift 6 region isolation).
protocol InsertionStrategy {
    @MainActor
    func insert(_ text: String, snapshot: TargetContextSnapshot) async -> InsertionOutcome
}
