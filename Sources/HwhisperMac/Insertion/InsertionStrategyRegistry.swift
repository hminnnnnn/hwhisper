/// Per-app strategy registry (§3 Decision c, C1-first revision — user
/// feedback #3: AX "succeeds" against several real-world apps — Electron,
/// browsers, KakaoTalk — without the text actually landing). C1
/// (clipboard+⌘V) is now the general-purpose default; C2 (AX) is tried
/// *first* only for a small whitelist of bundle IDs where it's been
/// verified reliable (native AppKit text views), and kept as a fallback
/// after C1 everywhere else rather than removed outright. `TextInserter`
/// tries each in order until one reports `.inserted`; `.notApplicable`
/// falls through, `.failed` stops (R3 mitigation).
struct InsertionStrategyRegistry {
    /// Bundle IDs where `AccessibilityInserter`'s read-back verification has
    /// been confirmed reliable — native AppKit text views. Extend only after
    /// verifying against the AC4 app matrix; unverified apps use the C1
    /// default below.
    private static let axPreferredBundleIdentifiers: Set<String> = [
        "com.apple.TextEdit",
        "com.apple.Notes",
    ]

    private let accessibilityInserter = AccessibilityInserter()
    private let clipboardInserter: ClipboardPasteInserter
    private let keystrokeInserter = KeystrokeInserter()

    init(notifier: InsertionNotifier) {
        self.clipboardInserter = ClipboardPasteInserter(notifier: notifier)
    }

    func strategies(for snapshot: TargetContextSnapshot) -> [InsertionStrategy] {
        if let bundleIdentifier = snapshot.bundleIdentifier,
           Self.axPreferredBundleIdentifiers.contains(bundleIdentifier) {
            return [accessibilityInserter, clipboardInserter, keystrokeInserter]
        }
        return [clipboardInserter, accessibilityInserter, keystrokeInserter]
    }
}
