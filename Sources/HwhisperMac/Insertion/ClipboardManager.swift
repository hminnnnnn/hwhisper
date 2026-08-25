import AppKit

/// Writes dictation output to the general pasteboard — C1's paste source and
/// the transcript-preservation fallback on any insertion outcome (§3.1).
///
/// The old save/restore snapshot machinery (capture every type of every
/// pasteboard item, restore after paste) was deleted in the 2026-08 audit:
/// the refined text deliberately stays on the clipboard after insertion, so
/// the restore was dead work that also copied arbitrarily large pasteboard
/// contents (screenshots!) over IPC on the main thread.
struct ClipboardManager {
    private let pasteboard = NSPasteboard.general

    /// Writes `text` as the sole pasteboard content.
    func setText(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
