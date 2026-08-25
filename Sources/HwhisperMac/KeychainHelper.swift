import Foundation
import Security

/// Legacy Keychain-backed store for refinement provider API keys —
/// **migration-only** as of the move to `CredentialStore`. A self-signed
/// dev-signed app's "Always Allow" grant on a Keychain item never sticks
/// (`securityd` can't durably verify a self-signed identity's ACL entry),
/// so every dictation reopened the access-authorization prompt even after
/// the user allowed it (reported bug). Live reads/writes now go through
/// `CredentialStore`; this type only still exists so
/// `AppDelegate`'s one-time startup migration can pull any key a previous
/// build already stored here into the new file-based store.
enum KeychainHelper {
    private static let service = "com.hminn.hwhisper.apikey"

    // `save`/`read` (the live-path, prompt-capable operations) were deleted
    // in the 2026-08 audit — nothing referenced them since the move to
    // `CredentialStore`. Only the migration pair below survives; if keychain
    // storage ever returns, it goes behind `CredentialStore`, not here.

    /// Migration-only read: `kSecUseAuthenticationUIFail` tells
    /// `SecItemCopyMatching` to fail immediately with
    /// `errSecInteractionNotAllowed` instead of blocking the thread on an
    /// access-authorization prompt. Used so the one-time startup migration
    /// (`AppDelegate`) can only ever pull a key that's already accessible
    /// without a prompt — it must never itself be the thing that triggers
    /// the exact prompt this migration exists to stop.
    static func readWithoutPrompt(account: String) -> String? {
        // `kSecUseAuthenticationUIFail` is deprecated in favor of
        // `kSecUseAuthenticationContext` + `LAContext.interactionNotAllowed`
        // — but that replacement governs LocalAuthentication (Touch ID/
        // passcode) prompts on `SecAccessControl`-protected items, not the
        // classic "<app> wants to use your confidential information stored
        // in..." ACL-trust dialog this plain `kSecClassGenericPassword`
        // item can show. `kSecUseAuthenticationUIFail` is still the
        // documented, working way to suppress that dialog (verified: it
        // returns `errSecInteractionNotAllowed` immediately instead of
        // blocking on it), so it's kept intentionally despite the warning.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status != errSecSuccess && status != errSecItemNotFound {
                HwhisperLog.log("keychain migration read for account \(account) declined without prompting: OSStatus \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
