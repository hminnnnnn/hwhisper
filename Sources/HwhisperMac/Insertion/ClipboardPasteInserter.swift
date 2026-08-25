import CoreGraphics

/// C1 (§3 Decision c): clipboard + synthesized ⌘V. The general-purpose
/// default insertion path — works in effectively any app that accepts paste.
///
/// No save/restore of the previous clipboard happens here: the refined text
/// deliberately STAYS on the clipboard after insertion (`TextInserter.
/// preserveToClipboard`, user request), so the old snapshot→paste→350ms
/// settle→restore dance restored contents that the very next call clobbered
/// again. That dead work cost 350ms of pipeline latency per dictation plus a
/// full multi-type pasteboard copy on the main thread (large with an image
/// copied) — removed in the 2026-08 audit.
///
/// Verification note: synthesizing ⌘V via `CGEvent.post` requires
/// Accessibility (and on some configurations, Input Monitoring) permission
/// for the host process. `CGEvent` creation succeeding does not guarantee
/// the target app actually received the keystrokes if that permission is
/// missing.
struct ClipboardPasteInserter: InsertionStrategy {
    private let clipboard = ClipboardManager()

    func insert(_ text: String, destination: InsertionDestination) async -> InsertionOutcome {
        // TOCTOU re-check (SecureInputGuard's stated contract): the
        // coordinator's check is already tens of milliseconds stale after AX
        // destination resolution, and writing the transcript to the shared
        // pasteboard is itself the leak being refused. The read is a cheap
        // process-global flag — re-checking costs nothing.
        guard !SecureInputGuard.isSecureInputActive() else {
            return .failed("refused: secure input became active before paste")
        }
        clipboard.setText(text)

        guard Self.synthesizePaste() else {
            return .failed("could not synthesize ⌘V (Accessibility permission missing?)")
        }
        return .inserted
    }

    private static func synthesizePaste() -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        let vKeyCode: CGKeyCode = 9 // ANSI 'v'
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
