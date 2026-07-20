import Foundation
import UserNotifications

/// Surfaces insertion failures/fallbacks to the user (§3.1 failure
/// transitions: "preserve transcript to clipboard + notify"; AC6). A full
/// menubar status/toast UI is an M3 deliverable (§4); for now this posts a
/// system notification best-effort.
protocol InsertionNotifier {
    func notifyInsertionFailed(reason: String, transcriptPreservedToClipboard: Bool)
    func notifyClipboardRestoreFailed()
}

/// `UNUserNotificationCenter`-backed notifier. Delivery requires the host
/// process to be a signed, bundled app with notification authorization
/// granted — M0 runs as a bare SwiftPM executable, so delivery is not
/// guaranteed here; failures fall back to stderr logging so they stay
/// observable during development (verification note, not a silent no-op).
struct SystemInsertionNotifier: InsertionNotifier {
    func notifyInsertionFailed(reason: String, transcriptPreservedToClipboard: Bool) {
        let body = transcriptPreservedToClipboard
            ? "\(reason) — transcript copied to clipboard."
            : reason
        post(title: "hwhisper: insertion failed", body: body)
    }

    func notifyClipboardRestoreFailed() {
        post(title: "hwhisper: clipboard not restored", body: "Your previous clipboard contents could not be restored.")
    }

    private func post(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            HwhisperLog.log("notification suppressed (unbundled): \(title) — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                logFallback(title: title, body: body, error: error)
            }
        }
    }

    private func logFallback(title: String, body: String, error: Error) {
        HwhisperLog.log("notification delivery failed (\(error)); \(title) — \(body)")
    }
}
