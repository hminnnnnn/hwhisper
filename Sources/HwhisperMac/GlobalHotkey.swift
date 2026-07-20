import KeyboardShortcuts

// KeyboardShortcuts is an SPM dependency (MIT, github.com/sindresorhus/
// KeyboardShortcuts, pinned to 1.15.0 — 1.16.0+ requires an unavailable
// #Preview macro toolchain feature on this host). This file isolates that
// dependency to a single thin wrapper (§4 constraint). Now compiled and
// verified via a real `swift build` (host SwiftPM recovered) rather than
// the standalone `swiftc -typecheck` pass used for the rest of HwhisperMac.
//
// `KeyboardShortcuts.Name` is not `Sendable` (upstream, .build/checkouts/
// KeyboardShortcuts/Sources/KeyboardShortcuts/Name.swift). Rather than
// `@preconcurrency import` (which would silently downgrade ALL
// Sendable-related diagnostics from this module to warnings, including ones
// we might actually want to see later), `.toggleDictation` and the wrapper
// below are pinned to `@MainActor` — KeyboardShortcuts' own registration
// APIs are documented as main-thread-only anyway (it's AppKit-event-loop
// backed), and every call site in HwhisperMac (`AppDelegate`) already runs
// on `@MainActor`, so this matches both the library's real constraint and
// this app's architecture (§3.1: hotkey/AX/clipboard/CGEvent stay on the
// main-actor UI-facing boundary).
extension KeyboardShortcuts.Name {
    /// Single global hotkey: toggle-only (§4 M1 UX fix). A single tap starts
    /// recording; the next tap stops it and runs transcription+insertion.
    /// Hold-to-talk (onKeyUp-based) was removed — on real hardware a single
    /// quick tap-and-release was frequently indistinguishable from a hold,
    /// producing an immediate start→stop with near-empty audio and a
    /// transcription failure. Toggle removes that ambiguity entirely.
    @MainActor
    static let toggleDictation = Self("toggleDictation")
}

/// Thin wrapper isolating the KeyboardShortcuts dependency from the rest of
/// HwhisperMac (§4 environment constraint). Deliberately minimal — no
/// business logic here, only registration plumbing.
@MainActor
enum GlobalHotkey {
    /// Fires once per key-down press. The caller (`AppDelegate`) is
    /// responsible for toggling between start/stop itself, since only
    /// key-down is wired up now (no onKeyUp handler — see
    /// `.toggleDictation`'s doc comment for why hold semantics were
    /// removed).
    static func onToggle(_ handler: @escaping () -> Void) {
        KeyboardShortcuts.onKeyDown(for: .toggleDictation, action: handler)
    }

    /// Seeds the default shortcut (⌃⌥⌘Space) so dictation works before the
    /// user has configured Settings. Three modifiers on purpose: the old
    /// ⌃⌥Space default was one modifier away from the Korean/English
    /// input-source switch (⌃Space) and caused frequent accidental
    /// activations (user-reported). Also migrates the old seeded default;
    /// any other user-recorded shortcut is left untouched.
    static func registerDefaultIfUnset() {
        let newDefault = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .option, .command])
        let legacyDefault = KeyboardShortcuts.Shortcut(.space, modifiers: [.control, .option])
        let current = KeyboardShortcuts.getShortcut(for: .toggleDictation)
        guard current == nil || current == legacyDefault else { return }
        KeyboardShortcuts.setShortcut(newDefault, for: .toggleDictation)
    }
}
