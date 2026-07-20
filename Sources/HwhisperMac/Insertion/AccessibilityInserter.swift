import ApplicationServices

/// C2 (§3 Decision c): direct `AXUIElementSetAttributeValue` on
/// `kAXSelectedTextAttribute` for AX-writable apps. Fastest and safest (no
/// clipboard round-trip) but only applicable where the focused element
/// exposes a settable AX selected-text/value attribute — reports
/// `.notApplicable` otherwise so the registry falls through to C1.
///
/// Re-queries the focused `AXUIElement` from `snapshot.processIdentifier`
/// rather than reusing any element captured earlier (TargetContextSnapshot
/// intentionally does not expose a live element reference — see its doc
/// comment on staleness).
///
/// User feedback #3 ("텍스트가 잘 안 들어가는 것 같다"): several real-world
/// apps (Electron, browsers, KakaoTalk) report `AXUIElementSetAttributeValue`
/// as `.success` (`kAXErrorSuccess`) without the text actually landing in
/// the field — the AX call succeeding is not proof of insertion. `insert`
/// now reads the field back after setting and only reports `.inserted` if
/// the text is actually visible in it; otherwise it reports `.notApplicable`
/// (not `.failed`) so the registry falls through to C1 instead of stopping.
struct AccessibilityInserter: InsertionStrategy {
    func insert(_ text: String, snapshot: TargetContextSnapshot) async -> InsertionOutcome {
        guard let pid = snapshot.processIdentifier else { return .notApplicable }

        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return .notApplicable
        }
        let focusedElement = focusedRef as! AXUIElement

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(focusedElement, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue else {
            return .notApplicable
        }

        let beforeValue = Self.stringAttribute(focusedElement, kAXValueAttribute as String)

        let result = AXUIElementSetAttributeValue(focusedElement, kAXSelectedTextAttribute as CFString, text as CFString)
        guard result == .success else {
            return .failed("AXUIElementSetAttributeValue failed (\(result.rawValue))")
        }

        guard Self.verifyLanded(text, beforeValue: beforeValue, element: focusedElement) else {
            return .notApplicable
        }
        return .inserted
    }

    /// Reads `kAXValueAttribute` back after the set and confirms `text`
    /// actually shows up in it. If the value can't be read back at all,
    /// there is no way to distinguish a real success from the AX-lies
    /// failure mode this exists to catch — treated conservatively as
    /// unverified.
    private static func verifyLanded(_ text: String, beforeValue: String?, element: AXUIElement) -> Bool {
        guard let afterValue = stringAttribute(element, kAXValueAttribute as String) else {
            return false
        }
        if afterValue.contains(text) {
            return true
        }
        // Some fields don't mirror the inserted text verbatim through
        // kAXValueAttribute (e.g. it reflects a transformed/trimmed value).
        // Weaker fallback: accept any observable growth relative to the
        // pre-insert snapshot as evidence something was actually written.
        if let beforeValue, afterValue != beforeValue, afterValue.count >= beforeValue.count {
            return true
        }
        return false
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }
}
