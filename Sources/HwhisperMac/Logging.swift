import Foundation

/// Minimal file-backed logger (§4 M1 observability fix). hwhisper runs as an
/// `.accessory` menu-bar app with no attached console when launched via
/// Finder/`open` (the normal way a user runs it), so `stderr`-only logging
/// was invisible for any post-hoc diagnosis of "I pressed the hotkey and
/// nothing happened" reports. This appends the same messages to
/// `~/Library/Logs/Hwhisper.log` so a user (or a developer working from a
/// bug report) can inspect what happened without reproducing inside a
/// terminal session.
enum HwhisperLog {
    private static let fileHandle: FileHandle? = {
        let fm = FileManager.default
        guard let logsDir = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true) else { return nil }
        do {
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("hwhisper: could not create log directory: \(error)\n".utf8))
            return nil
        }
        let logURL = logsDir.appendingPathComponent("Hwhisper.log")
        if !fm.fileExists(atPath: logURL.path) {
            // Owner-only (0600): the log records dictation lengths, state
            // transitions, and app paths — not world-readable content
            // (security review #3). Existing logs are also tightened below.
            fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        } else {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }()

    /// A fresh formatter per call rather than a cached static — avoids a
    /// shared-mutable-state Sendable violation under Swift 6 strict
    /// concurrency (`ISO8601DateFormatter` is not `Sendable`), and log calls
    /// are infrequent enough that the extra allocation is immaterial.
    private static func timestamp(for date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Best-effort version/build-time pair for the launch header. Uses the
    /// bundle's `CFBundleShortVersionString` when running from an .app
    /// bundle (falls back to "dev" for a bare SwiftPM executable), and the
    /// executable's file modification date as a practical stand-in for a
    /// true build timestamp (no separate build-info generation step exists
    /// in this project yet).
    static func launchHeaderInfo() -> (version: String, buildTime: String) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        var buildTime = "unknown"
        if let exePath = Bundle.main.executableURL?.path,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exePath),
           let modDate = attrs[.modificationDate] as? Date {
            buildTime = timestamp(for: modDate)
        }
        return (version, buildTime)
    }

    /// Call once at launch, before any other log call, so each run is
    /// clearly delimited in the persistent log file.
    static func logLaunchHeader() {
        let info = launchHeaderInfo()
        write("=== launch (version \(info.version), built \(info.buildTime)) ===")
    }

    /// Logs to both stderr (for terminal/Xcode-console use) and the
    /// persistent log file.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("hwhisper: \(message)\n".utf8))
        write(message)
    }

    private static func write(_ message: String) {
        guard let fileHandle else { return }
        let line = "[\(timestamp(for: Date()))] \(message)\n"
        fileHandle.write(Data(line.utf8))
    }
}
