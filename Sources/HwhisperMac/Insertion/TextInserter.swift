import Foundation

enum InsertionResult: Equatable {
    case inserted(strategy: String)
    case abortedContextMismatch
    case abortedSecureField
    case failed(transcriptPreservedToClipboard: Bool)
}

/// Orchestrates insertion end-to-end (§3 Decision c, §3.1
/// refining→inserting→restoring): revalidates the target context (AC8),
/// re-checks secure input immediately before writing (TOCTOU, AC6), walks
/// the strategy registry, and on any failure preserves the transcript to
/// the clipboard + notifies — insertion never dead-ends silently.
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
        guard originalSnapshot.matchesCurrent() else {
            preserveToClipboard(text)
            notifier.notifyInsertionFailed(
                reason: "focus changed before insertion",
                transcriptPreservedToClipboard: true
            )
            return .abortedContextMismatch
        }

        guard !SecureInputGuard.isSecureInputActive() else {
            // Do NOT preserve to clipboard here: a secure field implies the
            // user is in e.g. a password prompt, and writing the
            // transcript to the shared clipboard would itself be a leak.
            notifier.notifyInsertionFailed(
                reason: "refused: secure input field is active",
                transcriptPreservedToClipboard: false
            )
            return .abortedSecureField
        }

        for strategy in registry.strategies(for: originalSnapshot) {
            let strategyName = String(describing: type(of: strategy))
            let outcome = await strategy.insert(text, snapshot: originalSnapshot)
            HwhisperLog.log("insertion strategy \(strategyName): \(outcome)")
            switch outcome {
            case .inserted:
                return .inserted(strategy: strategyName)
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

    private func preserveToClipboard(_ text: String) {
        clipboard.setText(text)
    }
}
