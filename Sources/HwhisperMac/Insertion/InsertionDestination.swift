import AppKit
import ApplicationServices

/// Where the text will actually go, resolved at insertion time rather than at
/// hotkey-down.
///
/// Replaces the old AC8 all-or-nothing gate. That gate demanded the frontmost
/// app AND its focused element be byte-identical to the capture-time snapshot,
/// and aborted to the clipboard otherwise — which meant a live, perfectly
/// writable caret got skipped just because focus had moved. Measured on this
/// app's own history: 9 of 121 dictations (7.4%, all in VS Code) degraded to
/// "go paste it yourself" that way.
///
/// The new rule is about capability, not sameness: insert wherever the caret
/// is now, as long as something there can accept text.
struct InsertionDestination {
    let bundleIdentifier: String?
    let processIdentifier: pid_t
    let applicationName: String?
    /// `true` when the focused element positively accepts text, `false` when it
    /// positively does not, `nil` when it could not be determined.
    ///
    /// The nil case matters: some apps expose no focused element over AX at
    /// all, and refusing those would be a regression against today's behavior
    /// (which happily pastes into them). Only a positive `false` — we found an
    /// element and it is not a text entry point — routes to clipboard-only, so
    /// the app never silently reports success for text that went nowhere.
    let acceptsText: Bool?

    /// Roles that take typed text even when they advertise neither a settable
    /// value nor a selection range.
    private static let textEntryRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField",
    ]

    @MainActor
    static func resolveCurrent() -> InsertionDestination? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = frontmost.processIdentifier
        return InsertionDestination(
            bundleIdentifier: frontmost.bundleIdentifier,
            processIdentifier: pid,
            applicationName: frontmost.localizedName,
            acceptsText: focusedElementAcceptsText(pid: pid)
        )
    }

    /// True when this is the same app the dictation started in. Used only for
    /// wording the confirmation — insertion itself no longer depends on it.
    func isSameApplication(as snapshot: TargetContextSnapshot) -> Bool {
        snapshot.processIdentifier == processIdentifier && snapshot.bundleIdentifier == bundleIdentifier
    }

    private static func focusedElementAcceptsText(pid: pid_t) -> Bool? {
        let appElement = AXUIElementCreateApplication(pid)
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef,
              CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            // No focused element exposed (or AX unavailable) — undecidable.
            return nil
        }
        let element = focusedRef as! AXUIElement

        // 1. A writable value is the strongest signal, and covers both native
        //    AppKit fields and Electron (verified: VS Code's input reports
        //    role=AXTextField valueSettable=true).
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }

        // 2. A selected-text range means there is a caret, which is enough —
        //    true of text views whose value itself is read-only over AX
        //    (web contenteditable, several editors).
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success {
            return true
        }

        // 3. Role fallback for elements that advertise neither.
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else {
            return nil
        }
        return textEntryRoles.contains(role)
    }
}
