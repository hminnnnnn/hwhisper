import AppKit
import ApplicationServices

/// Captured at hotkey-down (idle→listening, §3.1) and revalidated
/// immediately before insertion. Insertion aborts if the frontmost app or
/// focused element changes between capture and insert (AC8, R5).
///
/// Deliberately does NOT retain the `AXUIElement` it observed at capture
/// time — only an identity marker for equality comparison. Insertion
/// strategies that need a live `AXUIElement` (C2) must re-query it via
/// `processIdentifier` at insertion time rather than reuse a possibly-stale
/// reference from capture.
struct TargetContextSnapshot: Equatable {
    let bundleIdentifier: String?
    let processIdentifier: pid_t?
    private let focusedElementIdentity: FocusedElementIdentity?

    private init(
        bundleIdentifier: String?,
        processIdentifier: pid_t?,
        focusedElementIdentity: FocusedElementIdentity?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.focusedElementIdentity = focusedElementIdentity
    }

    /// Captures the current frontmost app + its focused UI element.
    /// Must be called on the main thread (AppKit/AX convention); callers in
    /// this module always invoke it from `@MainActor` contexts.
    @MainActor
    static func capture() -> TargetContextSnapshot {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            return TargetContextSnapshot(bundleIdentifier: nil, processIdentifier: nil, focusedElementIdentity: nil)
        }

        let pid = frontmost.processIdentifier
        let identity = Self.focusedElementIdentity(forProcessIdentifier: pid)

        return TargetContextSnapshot(
            bundleIdentifier: frontmost.bundleIdentifier,
            processIdentifier: pid,
            focusedElementIdentity: identity
        )
    }

    /// True if the frontmost app and its focused element are unchanged
    /// since this snapshot was captured (AC8 context-integrity check).
    @MainActor
    func matchesCurrent() -> Bool {
        guard let processIdentifier else {
            // No frontmost app was observed at capture time — nothing to
            // meaningfully compare against; treat as a mismatch so callers
            // don't insert into an unknown target.
            return false
        }
        let currentFrontmost = NSWorkspace.shared.frontmostApplication
        guard currentFrontmost?.processIdentifier == processIdentifier,
              currentFrontmost?.bundleIdentifier == bundleIdentifier else {
            return false
        }
        let currentIdentity = Self.focusedElementIdentity(forProcessIdentifier: processIdentifier)
        return currentIdentity == focusedElementIdentity
    }

    private static func focusedElementIdentity(forProcessIdentifier pid: pid_t) -> FocusedElementIdentity? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return nil
        }
        return FocusedElementIdentity(element: (focusedRef as! AXUIElement))
    }
}

/// Wraps an `AXUIElement` purely for `CFEqual`-based identity comparison —
/// never dereferenced for attribute access from here.
private struct FocusedElementIdentity: Equatable {
    let element: AXUIElement

    static func == (lhs: FocusedElementIdentity, rhs: FocusedElementIdentity) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}
