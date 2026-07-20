import AppKit

/// Single-modifier-tap hotkey mode (§4 user feedback #1: "단축키가 불편하다,
/// 단일 키로 하고 싶다"). An alternative to the `KeyboardShortcuts`-based
/// combination shortcut (`GlobalHotkey`) — both can be active simultaneously
/// (`AppDelegate` wires both; whichever fires first toggles dictation).
enum HotkeyMode: String, CaseIterable {
    case combination
    case singleKeyRightCommand
    case singleKeyRightOption
    case singleKeyFn
    /// A single modifier key the user recorded themselves (any of the
    /// modifier keys `modifierName(for:)` knows) — stored in
    /// `customKeyCode`. Lets users pick a single key beyond the three
    /// presets above (user request), still limited to modifier keys because
    /// a plain letter/number can't be a global single-key toggle without
    /// clobbering normal typing.
    case singleKeyCustom

    private static let defaultsKey = "hotkeyMode"
    private static let customCodeKey = "singleKeyCustomCode"

    /// Key code for `.singleKeyCustom`, recorded via the settings UI.
    static var customKeyCode: CGKeyCode? {
        get {
            let stored = UserDefaults.standard.integer(forKey: customCodeKey)
            return stored > 0 ? CGKeyCode(stored) : nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(Int(newValue), forKey: customCodeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: customCodeKey)
            }
            // Re-apply the monitor so the new key takes effect immediately.
            NotificationCenter.default.post(name: .hotkeyModeDidChange, object: nil)
        }
    }

    /// Human-readable name + the modifier bit each recordable modifier key
    /// sets in `event.modifierFlags`. The single source of truth for which
    /// modifier keys `.singleKeyCustom` accepts and how the monitor tests
    /// down/up. (Non-modifier keys like function keys are handled by
    /// `functionKeyName`/`isAssignableKeyDown` and the monitor's keyDown path.)
    static func modifierInfo(for keyCode: CGKeyCode) -> (name: String, flag: NSEvent.ModifierFlags)? {
        switch keyCode {
        case 54: return ("우측 ⌘", .command)
        case 55: return ("좌측 ⌘", .command)
        case 61: return ("우측 ⌥", .option)
        case 58: return ("좌측 ⌥", .option)
        case 62: return ("우측 ⌃", .control)
        case 59: return ("좌측 ⌃", .control)
        case 60: return ("우측 ⇧", .shift)
        case 56: return ("좌측 ⇧", .shift)
        case 63: return ("fn (🌐)", .function)
        default: return nil
        }
    }

    /// Standard Mac key codes for F1–F20 → display name. These reach apps as
    /// `keyDown` (unlike modifiers) and produce no text, so they're safe as a
    /// single-key toggle — especially F13–F19 on external keyboards.
    static func functionKeyName(for keyCode: CGKeyCode) -> String? {
        let map: [CGKeyCode: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18",
            80: "F19", 90: "F20",
        ]
        return map[keyCode]
    }

    /// Display name for any assignable single key (modifier or function key).
    static func keyDisplayName(for keyCode: CGKeyCode) -> String {
        modifierInfo(for: keyCode)?.name ?? functionKeyName(for: keyCode) ?? "키 \(keyCode)"
    }

    /// Navigation/edit keys that reach apps via `keyDown` but must never be a
    /// global single-key toggle — using them would fire dictation AND their
    /// normal action (move cursor, delete, confirm…) everywhere.
    private static let disallowedKeyCodes: Set<CGKeyCode> = [
        36, 76,             // Return / Enter
        48,                 // Tab
        49,                 // Space
        51,                 // Delete (backspace)
        53,                 // Escape
        117,                // Forward Delete
        115, 119, 116, 121, // Home, End, Page Up, Page Down
        123, 124, 125, 126, // arrow keys
        114,                // Help / Insert
    ]

    /// Whether a non-modifier `keyDown` can be assigned as a single-key
    /// toggle: not a nav/edit key, and not a text-producing key. Text keys
    /// (letters/digits/punctuation/space and the control chars for
    /// Return/Tab/Esc/Delete) yield a scalar below the function-key private
    /// range (< 0xF700); function keys and other non-text keys are at or
    /// above it (or produce no character at all).
    static func isAssignableKeyDown(_ event: NSEvent) -> Bool {
        if disallowedKeyCodes.contains(CGKeyCode(event.keyCode)) { return false }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else {
            return true // no character (some special keys) → allow
        }
        return scalar.value >= 0xF700
    }

    /// Persisted selection, defaulting to the right-⌘ single-key tap (§4:
    /// fn conflicts with the system default 🌐 action — emoji picker / input
    /// source switch — unless the user reconfigures System Settings, so it
    /// is not the default even though it's offered as an option).
    static var current: HotkeyMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let mode = HotkeyMode(rawValue: raw) else {
                return .singleKeyRightCommand
            }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .hotkeyModeDidChange, object: nil)
        }
    }

    /// `nil` for `.combination` (no single-key monitor should run).
    var singleKeyCode: CGKeyCode? {
        switch self {
        case .combination: return nil
        case .singleKeyRightCommand: return 54
        case .singleKeyRightOption: return 61
        case .singleKeyFn: return 63
        case .singleKeyCustom: return HotkeyMode.customKeyCode
        }
    }

    var displayName: String {
        switch self {
        case .combination: return "조합 키"
        case .singleKeyRightCommand: return "단일 키: 우측 ⌘"
        case .singleKeyRightOption: return "단일 키: 우측 ⌥"
        case .singleKeyFn: return "단일 키: fn (🌐)"
        case .singleKeyCustom:
            if let code = HotkeyMode.customKeyCode {
                return "단일 키: \(HotkeyMode.keyDisplayName(for: code))"
            }
            return "단일 키: 직접 지정"
        }
    }
}

extension Notification.Name {
    static let hotkeyModeDidChange = Notification.Name("HwhisperHotkeyModeDidChange")
}

/// Detects a "tap" (down→up within `tapWindow`, with no other key/mouse
/// input in between) of a single modifier key and fires `onTap`. Deliberately
/// ignores the key entirely when it's held as part of a combination (e.g.
/// right-⌘+C) so this never interferes with the key's normal system role.
///
/// Global monitors only see events delivered to *other* processes —
/// `NSEvent.addGlobalMonitorForEvents` requires the host process to be
/// authorized for Input Monitoring (a distinct TCC category from
/// Accessibility, which governs AX reads/CGEvent posting elsewhere in this
/// app); `AppDelegate` checks/requests that via `CGPreflightListenEventAccess`
/// / `CGRequestListenEventAccess` before starting this monitor.
@MainActor
final class SingleKeyHotkeyMonitor {
    private static let tapWindow: TimeInterval = 0.5

    private let onTap: () -> Void
    private var flagsMonitor: Any?
    private var interruptMonitor: Any?
    private var keyDownAt: Date?
    private var interrupted = false
    private var targetKeyCode: CGKeyCode?

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    func start(mode: HotkeyMode) {
        stop()
        guard let keyCode = mode.singleKeyCode else { return }
        targetKeyCode = keyCode

        if HotkeyMode.modifierInfo(for: keyCode) != nil {
            // Modifier key: detect a clean solo tap via flagsChanged.
            flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                Task { @MainActor in self?.handleFlagsChanged(event) }
            }
            // Any other keyboard/mouse input between the target key's down
            // and up disqualifies the tap — this is what keeps e.g. right-⌘+C
            // (copy) from also triggering dictation.
            interruptMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            ) { [weak self] _ in
                Task { @MainActor in self?.interrupted = true }
            }
        } else {
            // Non-modifier key (function key): it arrives as `keyDown`, not
            // `flagsChanged`. Fire on its press, ignoring auto-repeat while
            // held. No tap-window/interrupt logic needed — a function key
            // isn't held as a modifier in a combination.
            flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let code = event.keyCode
                let isRepeat = event.isARepeat
                Task { @MainActor in
                    guard let self, code == self.targetKeyCode, !isRepeat else { return }
                    self.onTap()
                }
            }
        }
    }

    func stop() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        if let interruptMonitor { NSEvent.removeMonitor(interruptMonitor) }
        flagsMonitor = nil
        interruptMonitor = nil
        keyDownAt = nil
        interrupted = false
        targetKeyCode = nil
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard let targetKeyCode else { return }

        guard event.keyCode == targetKeyCode else {
            // A different modifier changed state while we're mid-tap —
            // that's a combination, not a solo tap.
            if keyDownAt != nil { interrupted = true }
            return
        }

        let isDown = event.modifierFlags.contains(Self.flag(for: targetKeyCode))
        if isDown {
            keyDownAt = Date()
            interrupted = false
            return
        }

        // Key-up: evaluate whether this was a clean, fast, uninterrupted tap.
        defer {
            keyDownAt = nil
            interrupted = false
        }
        guard let keyDownAt else { return }
        guard !interrupted else { return }
        guard Date().timeIntervalSince(keyDownAt) <= Self.tapWindow else { return }
        onTap()
    }

    /// Maps the physical key back to the modifier bit it sets in
    /// `event.modifierFlags` while held — `.command`/`.option`/etc. are
    /// shared with the left/right counterpart, but `keyCode` already
    /// disambiguates which physical key produced the event, so this is only
    /// used to test down (bit set) vs. up (bit cleared). Delegates to
    /// `HotkeyMode.modifierInfo` so preset and custom single keys share one
    /// source of truth; falls back to `.command` for any unknown code.
    private static func flag(for keyCode: CGKeyCode) -> NSEvent.ModifierFlags {
        HotkeyMode.modifierInfo(for: keyCode)?.flag ?? .command
    }
}
