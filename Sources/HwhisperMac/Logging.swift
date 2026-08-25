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

    /// Cached format style. `Date.ISO8601FormatStyle` is a `Sendable` value
    /// type, so this avoids the Swift 6 shared-mutable-state problem that a
    /// cached `ISO8601DateFormatter` (not `Sendable`) would pose — without
    /// paying that class's construction on every line. The old "fresh
    /// formatter per call" comment claimed the allocation was immaterial;
    /// measured, it was 0.7–4ms per call (150–1000× a cached formatter), and
    /// `SingleKeyHotkeyMonitor` logs on the hotkey tap path *before* the
    /// recording starts, so every tap paid it (2026-08 audit).
    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private static func timestamp(for date: Date) -> String {
        date.formatted(timestampStyle)
    }

    /// File writes happen here, off the caller's thread — `log()` is called
    /// from the hotkey handler and other latency-sensitive paths, which
    /// shouldn't block on disk I/O. Serial, so line order is preserved.
    private static let writeQueue = DispatchQueue(label: "hwhisper.log-write", qos: .utility)

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

    /// `--test-*` 훅으로 실행 중이면 true. 훅은 실제 코드 경로를 그대로 태우므로
    /// 로그도 똑같이 남는데, 그러면 운영 로그에 합성 기록이 섞여 **회귀 감지
    /// 신호 자체가 오염된다** — 실제로 `--test-hotkey-clock`의 "일부러 길게 누름"
    /// 시나리오가 `hotkey: ignored`를 12건 남겨, 실사용 기각처럼 보였다.
    /// 표식을 붙여 진단 grep이 걸러낼 수 있게 한다(함정 19: 합성 데이터를 실
    /// 버그로 오인 금지).
    nonisolated(unsafe) static var isTestRun = false

    /// Logs to both stderr (for terminal/Xcode-console use) and the
    /// persistent log file.
    static func log(_ message: String) {
        FileHandle.standardError.write(Data("hwhisper: \(message)\n".utf8))
        write(message)
    }

    private static func write(_ message: String) {
        // Timestamp and the test-run marker are captured at call time (so the
        // line reflects when it was logged, not when the queue drained), but
        // formatting and the file write happen on the serial queue.
        let date = Date()
        let testMarker = isTestRun ? "[test] " : ""
        let work: @Sendable () -> Void = {
            guard let fileHandle else { return }
            let line = "[\(timestamp(for: date))] \(testMarker)\(message)\n"
            fileHandle.write(Data(line.utf8))
        }
        if isTestRun {
            // Test hooks `exit()` right after logging and some (e.g.
            // `--test-home-period-cycle`) grep the file immediately — an
            // async write could be lost to the exit. Tests aren't
            // latency-sensitive, so write through.
            writeQueue.sync(execute: work)
        } else {
            writeQueue.async(execute: work)
        }
    }
}
