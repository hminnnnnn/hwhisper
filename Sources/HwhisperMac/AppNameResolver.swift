import AppKit

/// Cached bundle-ID → display-name resolution, shared by the home tab's
/// app-usage card and the history rows. `NSWorkspace.urlForApplication` +
/// `FileManager.displayName` is LaunchServices IPC plus a localized-name
/// filesystem lookup — measured at 0.7–10ms per call and it does not
/// reliably warm up, yet both views used to call it inside SwiftUI `body`
/// (per visible history row, per home-card render), which was the history
/// tab's scroll jank (2026-08 audit). Bundle-ID → name is stable for a
/// process lifetime, so a plain grow-only cache is correct; the entry count
/// is bounded by the number of distinct apps the user dictates into.
@MainActor
enum AppNameResolver {
    private static var cache: [String: String] = [:]

    /// Human-readable app name; falls back to the bundle ID's last dotted
    /// component for apps no longer installed.
    static func name(for bundleID: String) -> String {
        if let cached = cache[bundleID] { return cached }
        let resolved: String
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            resolved = FileManager.default.displayName(atPath: url.path)
        } else {
            resolved = bundleID.components(separatedBy: ".").last ?? bundleID
        }
        cache[bundleID] = resolved
        return resolved
    }
}
