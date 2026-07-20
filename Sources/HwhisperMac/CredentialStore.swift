import Foundation

/// File-based storage for refinement provider API keys, replacing the
/// legacy Keychain (`KeychainHelper`) store.
///
/// Why not the Keychain: a Keychain item's "Always Allow" grant is recorded
/// against the requesting app's code-signing identity. hwhisper is signed
/// with a self-signed development certificate (`hwhisper-dev`), and
/// `securityd` cannot durably verify a self-signed identity's ACL entry —
/// the grant doesn't stick, so every dictation (and every rebuild) reopens
/// the "hwhisper wants to access key..." access prompt even after the user
/// clicks "Always Allow" (reported bug: repeated Keychain prompts).
///
/// Instead, keys live in a single JSON file under this user's Application
/// Support directory, created with owner-only POSIX permissions (`0700` on
/// the directory, `0600` on the file) so only this user account can read
/// it — the same approach the `gh`, `aws`, and `gcloud` CLIs use for their
/// own credential files. The file itself is protected by normal Unix
/// permissions and (at rest) by FileVault disk encryption; it never
/// triggers an OS-level access prompt, so there's nothing to re-prompt.
enum CredentialStore {
    private static let directoryURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("Hwhisper", isDirectory: true)
    }()
    private static let fileURL = directoryURL.appendingPathComponent("credentials.json")

    /// Creates the storage directory (owner-only `0700`) if it doesn't
    /// exist yet, and re-asserts that permission if it somehow drifted.
    private static func ensureDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directoryURL.path) {
            do {
                try fm.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                HwhisperLog.log("CredentialStore: failed to create \(directoryURL.path): \(error)")
            }
        } else {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
        }
    }

    private static func readAll() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    /// Atomic write: encode to a temp file created with `0600` from the
    /// start (so the secret is never briefly world/group-readable), then
    /// rename it over the real path — a rename is a single filesystem
    /// operation, so a reader never observes a partially-written file.
    private static func writeAll(_ dict: [String: String]) {
        ensureDirectory()
        guard let data = try? JSONEncoder().encode(dict) else {
            HwhisperLog.log("CredentialStore: failed to encode credentials")
            return
        }
        let fm = FileManager.default
        let tempURL = directoryURL.appendingPathComponent(".credentials-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tempURL.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            HwhisperLog.log("CredentialStore: failed to write temp file at \(tempURL.path)")
            return
        }
        do {
            _ = try fm.replaceItemAt(fileURL, withItemAt: tempURL)
        } catch {
            // `replaceItemAt` can fail if `fileURL` doesn't exist yet
            // (first-ever save) on some OS versions — fall back to a plain
            // move, then re-assert the permission on the final path.
            do {
                try fm.moveItem(at: tempURL, to: fileURL)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
            } catch {
                HwhisperLog.log("CredentialStore: failed to finalize \(fileURL.path): \(error)")
                try? fm.removeItem(at: tempURL)
            }
        }
    }

    static func read(account: String) -> String? {
        let value = readAll()[account]
        return (value?.isEmpty == false) ? value : nil
    }

    /// Writes `value` for `account`, replacing any existing entry. Passing
    /// an empty string deletes the stored key instead of storing an empty
    /// secret (mirrors `KeychainHelper.save`'s contract).
    static func save(_ value: String, account: String) {
        guard !value.isEmpty else {
            delete(account: account)
            return
        }
        var all = readAll()
        all[account] = value
        writeAll(all)
    }

    @discardableResult
    static func delete(account: String) -> Bool {
        var all = readAll()
        guard all.removeValue(forKey: account) != nil else { return true }
        writeAll(all)
        return true
    }
}
