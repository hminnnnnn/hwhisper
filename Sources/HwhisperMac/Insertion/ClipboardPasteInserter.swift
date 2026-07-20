import CoreGraphics

/// C1 (§3 Decision c): clipboard + synthesized ⌘V, with save/restore. The
/// general-purpose default insertion path — works in effectively any app
/// that accepts paste, at the cost of a clipboard round-trip.
///
/// Verification note: synthesizing ⌘V via `CGEvent.post` requires
/// Accessibility (and on some configurations, Input Monitoring) permission
/// for the host process. `CGEvent` creation succeeding does not guarantee
/// the target app actually received the keystrokes if that permission is
/// missing — this cannot be exercised end-to-end without granting
/// Accessibility to this executable, which is out of scope for this pass.
struct ClipboardPasteInserter: InsertionStrategy {
    private let clipboard = ClipboardManager()
    private let notifier: InsertionNotifier
    /// Time to let the target app process the synthesized paste before
    /// restoring the clipboard — too short risks racing the paste and
    /// restoring the clipboard before the target app has actually read from
    /// it (user feedback #3: paste sometimes silently "doesn't take" in
    /// real-world apps). 150ms proved too tight in practice; 0.3s is the
    /// floor the plan calls for.
    private let pasteSettleNanoseconds: UInt64

    init(notifier: InsertionNotifier, pasteSettleNanoseconds: UInt64 = 350_000_000) {
        self.notifier = notifier
        self.pasteSettleNanoseconds = pasteSettleNanoseconds
    }

    func insert(_ text: String, snapshot: TargetContextSnapshot) async -> InsertionOutcome {
        let saved = clipboard.save()
        clipboard.setText(text)

        guard Self.synthesizePaste() else {
            clipboard.restore(saved)
            return .failed("could not synthesize ⌘V (Accessibility permission missing?)")
        }

        try? await Task.sleep(nanoseconds: pasteSettleNanoseconds)

        if clipboard.restore(saved) == .failed {
            notifier.notifyClipboardRestoreFailed()
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
