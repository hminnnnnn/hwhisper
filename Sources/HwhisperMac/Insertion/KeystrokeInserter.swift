import CoreGraphics

/// C3 (§3 Decision c): last-resort keystroke synthesis via CGEvent's
/// Unicode-string override. Deliberately restricted to ASCII text — Hangul
/// composition over synthesized CGEvent keystrokes is unreliable (R8), so
/// this strategy reports `.notApplicable` for any non-ASCII text rather
/// than risk mangled Korean output; the registry then has nothing left to
/// try and surfaces a failure (clipboard-preserve + notify).
struct KeystrokeInserter: InsertionStrategy {
    func insert(_ text: String, snapshot: TargetContextSnapshot) async -> InsertionOutcome {
        guard text.unicodeScalars.allSatisfy({ $0.isASCII }) else {
            return .notApplicable
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return .failed("could not create CGEventSource")
        }

        for scalar in text.unicodeScalars {
            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return .failed("could not create keyboard event")
            }
            var utf16 = Array(String(scalar).utf16)
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
        return .inserted
    }
}
