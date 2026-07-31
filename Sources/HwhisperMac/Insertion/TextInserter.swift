import Foundation

enum InsertionResult: Equatable {
    case inserted(strategy: String, bundleIdentifier: String?)
    /// Nothing could accept the text, so it was left on the clipboard. Carries
    /// the user-facing reason so the indicator can say *why*.
    case copiedToClipboard(reason: String)
    case abortedSecureField
    case failed(transcriptPreservedToClipboard: Bool)
}

/// Orchestrates insertion end-to-end (§3 Decision c, §3.1
/// refining→inserting→restoring): refuses secure fields (AC6), resolves where
/// the caret actually is, walks the strategy registry, and always leaves the
/// transcript on the clipboard so insertion never dead-ends silently.
///
/// Context policy (revised): insertion used to require the frontmost app *and*
/// its focused element to be identical to the hotkey-down snapshot, and
/// aborted to the clipboard on any difference. That treated "focus moved" as
/// equivalent to "nowhere to type", which it is not — 7.4% of this app's real
/// dictations were downgraded to manual paste while a perfectly writable caret
/// was sitting right there. Now the snapshot is advisory (it only decides
/// strategy order and the wording of the confirmation); what gates insertion is
/// whether the *current* focus can accept text.
struct TextInserter {
    private let registry: InsertionStrategyRegistry
    private let notifier: InsertionNotifier
    private let clipboard = ClipboardManager()

    init(notifier: InsertionNotifier = SystemInsertionNotifier()) {
        self.notifier = notifier
        self.registry = InsertionStrategyRegistry(notifier: notifier)
    }

    /// - Parameter originalSnapshot: captured at hotkey-down
    ///   (idle→listening, §3.1) via `TargetContextSnapshot.capture()`.
    @MainActor
    func insert(_ text: String, originalSnapshot: TargetContextSnapshot) async -> InsertionResult {
        // Checked FIRST, before anything touches the pasteboard: if focus moved
        // into a password prompt, writing the transcript to the shared
        // clipboard would itself be the leak we're trying to avoid. (The old
        // ordering ran the context check first and copied to the clipboard on
        // mismatch, so a focus change *into* a secure field leaked.)
        guard !SecureInputGuard.isSecureInputActive() else {
            notifier.notifyInsertionFailed(
                reason: "refused: secure input field is active",
                transcriptPreservedToClipboard: false
            )
            return .abortedSecureField
        }

        guard let destination = InsertionDestination.resolveCurrent() else {
            return copyOnly(text, reason: "입력할 수 있는 곳이 없어 클립보드에 복사했습니다 — ⌘V로 붙여넣기")
        }

        HwhisperLog.log(
            "insertion target: app=\(destination.bundleIdentifier ?? "nil") acceptsText=\(destination.acceptsText.map(String.init) ?? "unknown") sameAsStart=\(destination.isSameApplication(as: originalSnapshot))"
        )

        // Only a positive "this cannot take text" routes to clipboard-only;
        // `nil` (undecidable) still attempts insertion, so apps that expose no
        // focused element over AX keep working as before.
        if destination.acceptsText == false {
            let where_ = destination.applicationName.map { "\($0)에는" } ?? "여기에는"
            return copyOnly(text, reason: "\(where_) 입력할 수 없어 클립보드에 복사했습니다 — ⌘V로 붙여넣기")
        }

        for strategy in registry.strategies(forBundleIdentifier: destination.bundleIdentifier) {
            let strategyName = String(describing: type(of: strategy))
            let outcome = await strategy.insert(text, destination: destination)
            HwhisperLog.log("insertion strategy \(strategyName): \(outcome)")
            switch outcome {
            case .inserted:
                // The transcript stays on the clipboard after a successful
                // insert too (user request): a paste that lands in the wrong
                // place, or an app that quietly swallows it, is then one ⌘V
                // away from recovery instead of lost.
                preserveToClipboard(text)
                return .inserted(strategy: strategyName, bundleIdentifier: destination.bundleIdentifier)
            case .notApplicable:
                continue
            case .failed(let reason):
                preserveToClipboard(text)
                notifier.notifyInsertionFailed(reason: reason, transcriptPreservedToClipboard: true)
                return .failed(transcriptPreservedToClipboard: true)
            }
        }

        preserveToClipboard(text)
        notifier.notifyInsertionFailed(
            reason: "no insertion strategy succeeded",
            transcriptPreservedToClipboard: true
        )
        return .failed(transcriptPreservedToClipboard: true)
    }

    private func copyOnly(_ text: String, reason: String) -> InsertionResult {
        preserveToClipboard(text)
        notifier.notifyInsertionFailed(reason: reason, transcriptPreservedToClipboard: true)
        return .copiedToClipboard(reason: reason)
    }

    private func preserveToClipboard(_ text: String) {
        clipboard.setText(text)
    }
}
