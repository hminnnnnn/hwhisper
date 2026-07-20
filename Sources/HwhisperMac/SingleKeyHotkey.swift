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

    private static let defaultsKey = "hotkeyMode"

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
        }
    }

    var displayName: String {
        switch self {
        case .combination: return "조합 키"
        case .singleKeyRightCommand: return "단일 키: 우측 ⌘"
        case .singleKeyRightOption: return "단일 키: 우측 ⌥"
        case .singleKeyFn: return "단일 키: fn (🌐)"
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

        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handleFlagsChanged(event) }
        }
        // Any other keyboard/mouse input between the target key's down and
        // up disqualifies the tap — this is what keeps e.g. right-⌘+C
        // (copy) from also triggering dictation.
        interruptMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { [weak self] _ in
            Task { @MainActor in self?.interrupted = true }
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
    /// `event.modifierFlags` while held — `.command`/`.option` are shared
    /// with their left-hand counterpart, but `keyCode` already disambiguates
    /// which physical key produced the event, so this is only used to test
    /// down (bit set) vs. up (bit cleared).
    private static func flag(for keyCode: CGKeyCode) -> NSEvent.ModifierFlags {
        switch keyCode {
        case 63: return .function
        case 61: return .option
        default: return .command // 54 (right ⌘)
        }
    }
}
