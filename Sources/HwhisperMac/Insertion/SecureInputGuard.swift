import Carbon

/// TOCTOU guard for secure-input fields (password / secure keyboard entry,
/// R4). Insertion strategies MUST re-check this immediately before writing
/// text (§3 Decision c, AC6) — a check performed only at hotkey-down is
/// stale by the time insertion actually happens.
enum SecureInputGuard {
    /// True when the system is in secure keyboard entry mode (e.g. the
    /// focused field is a password field). Insertion must be refused.
    static func isSecureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }
}
