import AppKit
import ApplicationServices
import AVFoundation
import Foundation
import HwhisperCore
import UserNotifications

/// Races `operation` against a hard deadline (§2 AC2: refinement is always
/// async + timeout-bounded, default 8s, falling back to raw text). This is
/// belt-and-suspenders on top of `OpenAICompatibleRefiner`'s own
/// `URLSessionConfiguration` timeout — a single source of truth the call
/// site can rely on regardless of how the underlying request hangs.
private func withTimeout<T: Sendable>(
    _ seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            throw TextRefinerError.timedOut
        }
        guard let result = try await group.next() else {
            throw TextRefinerError.timedOut
        }
        group.cancelAll()
        return result
    }
}

/// Menubar app shell (§4): wires the global hotkey, mic capture, the B1
/// (Apple SpeechTranscriber) engine, and `TextInserter` into the dictation
/// loop. State-machine ownership (§3.1: idle→listening→transcribing→
/// refining→inserting→restoring→idle, single-flight queueing, cancel path)
/// lives in `HwhisperCore.PipelineActor`; this delegate is the UI adapter —
/// it drives the actor and mirrors its transitions onto the menu bar
/// icon/indicator/log, but owns no pipeline state of its own beyond
/// "is the mic currently capturing" (`isCapturing`), which is inherently
/// platform-specific (AVAudioEngine lifecycle).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Menu-bar state icons (brand pass: SF Symbol template images instead
    /// of the original emoji text — emojis ignore the menu bar's light/dark
    /// tinting and read as unfinished next to system status items).
    private enum StatusIcon: Equatable {
        case idle, recording, success, failure

        var image: NSImage? {
            let (name, description): (String, String) = switch self {
            case .idle: ("waveform", "hwhisper 대기 중")
            case .recording: ("record.circle.fill", "hwhisper 녹음 중")
            case .success: ("checkmark.circle", "hwhisper 삽입 완료")
            case .failure: ("exclamationmark.triangle", "hwhisper 오류")
            }
            let config = NSImage.SymbolConfiguration(pointSize: 14.5, weight: .medium)
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
                .withSymbolConfiguration(config) else { return nil }
            if self == .recording {
                // Red is the one state that must pop regardless of menu bar
                // appearance — non-template with an explicit palette color.
                let red = image.withSymbolConfiguration(
                    config.applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
                )
                red?.isTemplate = false
                return red
            }
            image.isTemplate = true
            return image
        }
    }

    private static let idleIcon = StatusIcon.idle
    private static let recordingIcon = StatusIcon.recording
    private static let successIcon = StatusIcon.success
    private static let failureIcon = StatusIcon.failure
    /// §3.1 cancel path: a second hotkey tap this soon after the recording
    /// started is treated as "cancel", not "stop and process" — a
    /// deliberately simple gesture (no separate key binding) since a real
    /// utterance essentially never finishes inside this window.
    private static let cancelTapWindow: TimeInterval = 0.4
    /// Guided recording duration (Typeless-style). The user speaks FREELY for
    /// `recordingGracePeriod`; only if they're still going past that point does
    /// a `recordingFinalWindow` countdown begin with an on-pill notice ("N초 후
    /// 음성 입력이 종료됩니다"), then a hard stop. Audio up to the cutoff is
    /// still transcribed + refined — nothing is discarded, and the whole
    /// transcript stays within a single coherent refinement call (no
    /// context-splitting chunking).
    ///
    /// Sizing: measured refinement output for Korean is ~0.46 tokens/char
    /// (Gemini 3.1 real E2E, HwhisperEval --refine-test), so the 8192-token
    /// ceiling only bites around ~16,000 chars (~1 hour of speech) — tokens are
    /// NOT the real limit; latency, coherence, and editing risk are. So the cap
    /// is set for UX, generously: 180s free speech ≈ ~800 chars (a long memo),
    /// + a 60s final window ⇒ 240s / ~1,080 chars total → output only ~500
    /// tokens (~7% of the ceiling). A 1,600-char input refined coherently in
    /// 1.4s in testing, so there's ample headroom to raise these if wanted.
    private static let recordingGracePeriod: TimeInterval = 180
    private static let recordingFinalWindow: TimeInterval = 60
    private static var recordingMaxDuration: TimeInterval { recordingGracePeriod + recordingFinalWindow }
    private static let notificationAuthorizationRequestedKey = "notificationAuthorizationRequested"
    private static let keychainMigrationAttemptedKey = "keychainMigrationAttempted"

    private var statusItem: NSStatusItem?
    private var lastErrorMenuItem: NSMenuItem?
    private var iconResetWorkItem: DispatchWorkItem?
    private let audioCapture = AudioCapture()
    private let textInserter = TextInserter()
    private let recordingIndicator = RecordingIndicatorController()
    private let settingsWindowController = SettingsWindowController()
    private lazy var welcomeWindowController = WelcomeWindowController(settingsWindowController: settingsWindowController)
    private lazy var onboardingWindowController = OnboardingWindowController(onFinish: { [weak self] in
        self?.mainWindowController.show()
    })
    /// Dictation history, shared by the pipeline (writer) and the main
    /// window (reader). Same owner-only App Support directory as
    /// `CredentialStore`.
    private let historyStore = SQLiteHistoryStore(
        databaseURL: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hwhisper/history.sqlite3")
    )
    /// Personal dictionary (§3 N-3 triple defense) — read fresh from the
    /// shared actor at each dictation so UI edits apply to the very next
    /// utterance without any invalidation plumbing.
    private let personalDictionary = FilePersonalDictionary(
        fileURL: FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hwhisper/dictionary.json")
    )
    private lazy var mainWindowController = MainWindowController(
        historyStore: historyStore,
        personalDictionary: personalDictionary
    )
    private let pipelineActor = PipelineActor()
    /// B2 fallback engine for macOS < 26 (no Apple `SpeechTranscriber`).
    /// Persistent — its underlying WhisperKit model is ~600MB and takes
    /// seconds-to-minutes to load, so it must be created once and reused,
    /// never per-job (unlike the cheap `AppleSpeechRecognizer`).
    private let whisperKitRecognizer = WhisperKitRecognizer()
    /// Flips true after the first successful WhisperKit transcription, so the
    /// one-time "downloading model" notice only shows before the first use.
    private var hasUsedWhisperKit = false
    private var captureSnapshot: TargetContextSnapshot?
    private var isCapturing = false
    private var captureStartedAt: Date?
    /// Ticks once a second while recording to drive the countdown warning and
    /// the hard auto-stop (see `startRecordingLimitTimer`). Invalidated by
    /// every path that ends a recording.
    private var recordingLimitTimer: Timer?
    /// Set once notifications are confirmed denied, so `postNotification`
    /// logs the "skipping" fact exactly once instead of on every call.
    private var hasLoggedNotificationsDenied = false
    private lazy var singleKeyHotkeyMonitor = SingleKeyHotkeyMonitor { [weak self] in
        self?.handleHotkeyToggle()
    }
    private var hotkeyModeObserver: NSObjectProtocol?
    /// Provider rawValue → API key, populated after the first successful
    /// Keychain read so the (potentially prompt-blocking) read happens at
    /// most once per provider per run. Cleared when the key is re-saved.
    private var apiKeyCache: [String: String] = [:]
    /// Providers whose Keychain read is still blocked (typically on a
    /// macOS access-authorization prompt). While set, refinement falls back
    /// to raw instead of stacking more blocked reads.
    private var apiKeyReadsInFlight: Set<String> = []
    private var apiKeyObserver: NSObjectProtocol?

    /// Resolves the API key for `provider` without ever letting a blocked
    /// `SecItemCopyMatching` (keychain authorization prompt) stall the
    /// dictation pipeline: the read runs as an unstructured detached task
    /// (task-group timeouts can't help — the group would await the blocked
    /// child), we poll its cached result for up to 3s, and if it's still
    /// pending the caller inserts raw text while the read self-heals into
    /// the cache whenever the user answers the prompt.
    private func fetchAPIKey(for provider: RefinerProvider) async -> String? {
        guard provider.requiresAPIKey else { return "" }
        if let cached = apiKeyCache[provider.rawValue] { return cached }

        if !apiKeyReadsInFlight.contains(provider.rawValue) {
            apiKeyReadsInFlight.insert(provider.rawValue)
            let readTask = Task.detached(priority: .userInitiated) {
                RefinementSettings.apiKey(for: provider)
            }
            Task { [weak self] in
                let key = await readTask.value
                await MainActor.run {
                    guard let self else { return }
                    self.apiKeyReadsInFlight.remove(provider.rawValue)
                    if let key, !key.isEmpty { self.apiKeyCache[provider.rawValue] = key }
                }
            }
        }

        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if let cached = apiKeyCache[provider.rawValue] { return cached }
            if !apiKeyReadsInFlight.contains(provider.rawValue) {
                // Read finished but produced no usable key (missing/empty).
                return nil
            }
        }
        return nil
    }

    /// One-time startup migration off the Keychain (§ bugfix: repeated
    /// "Always Allow" prompts — see `KeychainHelper`'s and
    /// `CredentialStore`'s doc comments for the root cause). Runs at most
    /// once per install (`keychainMigrationAttemptedKey`); for each
    /// provider that needs a key and doesn't already have one in
    /// `CredentialStore`, tries a **non-blocking, no-prompt** Keychain read
    /// (`KeychainHelper.readWithoutPrompt`) and, if it succeeds, copies the
    /// key into `CredentialStore` and deletes the Keychain item so it can
    /// never trigger a prompt again.
    ///
    /// If the read is blocked (`errSecInteractionNotAllowed` — the very
    /// prompt this migration exists to avoid), migration is skipped for
    /// that provider without ever showing UI: refinement's existing
    /// "API key unavailable" raw-text fallback already covers the gap, and
    /// the log line below tells the user (or a developer reading the log)
    /// that re-entering the key once in Settings finishes the migration.
    private func migrateKeychainCredentialsIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.keychainMigrationAttemptedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.keychainMigrationAttemptedKey)

        for provider in RefinerProvider.allCases where provider.requiresAPIKey {
            guard CredentialStore.read(account: provider.rawValue) == nil else { continue }
            guard let key = KeychainHelper.readWithoutPrompt(account: provider.rawValue), !key.isEmpty else {
                HwhisperLog.log("keychain migration: no unprompted key available for provider \(provider.rawValue) — re-enter the API key in Settings if refinement was previously configured")
                continue
            }
            CredentialStore.save(key, account: provider.rawValue)
            KeychainHelper.delete(account: provider.rawValue)
            HwhisperLog.log("keychain migration: moved API key for provider \(provider.rawValue) from Keychain to CredentialStore")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        HwhisperLog.logLaunchHeader()
        migrateKeychainCredentialsIfNeeded()
        NSApp.setActivationPolicy(.accessory)
        installStandardMenu()
        setUpStatusItem()

        pipelineActor.onTransition = { old, new in
            HwhisperLog.log("state: \(old) → \(new)")
        }

        GlobalHotkey.registerDefaultIfUnset()
        GlobalHotkey.onToggle { [weak self] in
            self?.handleHotkeyToggle()
        }

        apiKeyObserver = NotificationCenter.default.addObserver(
            forName: .refinementAPIKeyDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.apiKeyCache.removeAll() }
        }

        applyHotkeyMode()
        hotkeyModeObserver = NotificationCenter.default.addObserver(
            forName: .hotkeyModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyHotkeyMode() }
        }

        audioCapture.onLevelUpdate = { [weak self] level in
            Task { @MainActor in
                self?.recordingIndicator.updateLevel(level)
            }
        }

        // Inline X on the indicator → cancel the in-progress recording
        // immediately (any time during listening, not just the double-tap
        // window). No transcription, no message — the clean cancel users
        // asked for.
        recordingIndicator.onCancel = { [weak self] in
            self?.cancelCapture()
        }

        let micGranted = AVAudioApplication.shared.recordPermission == .granted
        let accessibilityGranted = AXIsProcessTrusted()
        let allPermissionsGranted = micGranted && accessibilityGranted

        // §4 permission-awareness fix: only ask for microphone permission if
        // it isn't already granted — repeatedly invoking the request API
        // once granted is harmless to macOS itself, but skipping it entirely
        // makes the "no repeat requests once granted" contract explicit and
        // observable in the log.
        if !micGranted {
            Task {
                let granted = await AudioCapture.requestMicrophonePermission()
                if !granted {
                    HwhisperLog.log("microphone permission not granted; grant it in System Settings > Privacy & Security > Microphone, then relaunch.")
                }
            }
        }

        // Without requesting authorization, `UNUserNotificationCenter.add`
        // silently refuses every notification (confirmed via live
        // diagnosis) — so `postNotification` below, and `TextInserter`'s
        // own `SystemInsertionNotifier`, could never actually reach the
        // user even though the code calling them "succeeds". This request
        // is what makes those notifications real instead of no-ops.
        //
        // Only ever requested once per install (UserDefaults flag): once the
        // user has answered the system prompt (granted OR denied), asking
        // again on every launch just logs the same
        // "notification authorization request failed" line forever without
        // ever re-prompting the user (macOS never shows the dialog twice) —
        // the floating indicator already covers denied-state feedback, so
        // repeating the request buys nothing and only pollutes the log.
        // UserNotifications hard-crashes ("bundleProxyForCurrentProcess is
        // nil") when running as a bare SwiftPM binary outside an .app
        // bundle (dev loop) — guard every UNUserNotificationCenter touch.
        if Bundle.main.bundleIdentifier != nil {
            if !UserDefaults.standard.bool(forKey: Self.notificationAuthorizationRequestedKey) {
                Task {
                    do {
                        _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                    } catch {
                        HwhisperLog.log("notification authorization request failed: \(error)")
                    }
                    UserDefaults.standard.set(true, forKey: Self.notificationAuthorizationRequestedKey)
                }
            }
        } else {
            HwhisperLog.log("running unbundled (dev); notifications disabled")
        }

        // §D2: a stranger's very first launch gets the multi-step onboarding
        // wizard (value prop → permissions → hotkey → refinement choice →
        // done) instead of the permission-only welcome window. Once
        // onboarding has run (or been skipped) at least once, fall back to
        // the old "please grant permission" re-prompt so a later permission
        // regression is still surfaced — never both at once.
        let arguments = ProcessInfo.processInfo.arguments
        let forceOnboarding = arguments.contains("--open-onboarding")
        let activateOnboarding = !arguments.contains("--no-activate")
        let onboardingCompleted = UserDefaults.standard.bool(forKey: OnboardingView.completedDefaultsKey)

        if forceOnboarding {
            onboardingWindowController.show(activate: activateOnboarding)
        } else if !onboardingCompleted {
            onboardingWindowController.show()
        } else if !allPermissionsGranted && !UserDefaults.standard.bool(forKey: WelcomeView.hideOnLaunchDefaultsKey) {
            // §4 permission-awareness fix: a user who already granted Mic +
            // Accessibility must never see a "please grant permission"
            // welcome window again — that repeated-prompt UX was itself
            // part of the reported bug. Only auto-show when something is
            // actually missing (still respecting the user's explicit
            // "don't show" preference).
            welcomeWindowController.show()
        }

        // Test-only hook: lets an external harness drive the Settings window
        // (e.g. to verify ⌘V paste in its text fields) without a real click
        // on the (Dock-less, `.accessory`) status item menu.
        if arguments.contains("--open-settings") {
            settingsWindowController.show()
        }
        if arguments.contains("--open-main") {
            // Optional section: `--open-main --open-section dictionary`.
            // `--no-activate` keeps focus on the current frontmost app
            // (visual-verification hook — see MainWindowController.show).
            var section: String?
            if let flagIndex = arguments.firstIndex(of: "--open-section"), flagIndex + 1 < arguments.count {
                section = arguments[flagIndex + 1]
            }
            mainWindowController.show(section: section, activate: !arguments.contains("--no-activate"))
        }

        // Test-only hook: shows the recording indicator in its "listening"
        // state (with the inline X) WITHOUT starting a real capture, so the
        // cancel affordance can be verified visually without synthesizing a
        // global hotkey or playing audio (both unsafe when a messenger/
        // meeting is frontmost). Feeds a slow fake level so the waveform is
        // non-flat in the screenshot.
        if arguments.contains("--test-indicator") {
            recordingIndicator.showListening()
            recordingIndicator.updateLevel(0.6)
        }
        // Test-only: renders the soft no-speech warning pill (design check
        // without needing a real silent recording).
        if arguments.contains("--test-warning") {
            showNoSpeechWarning()
        }
        // Test-only: renders the listening pill in its guided-duration final
        // window (the "N초 후 음성 입력이 종료됩니다" countdown notice) so the
        // second-line layout/color can be checked without waiting 3 minutes.
        if arguments.contains("--test-countdown") {
            recordingIndicator.showListening()
            recordingIndicator.updateLevel(0.6)
            recordingIndicator.updateCountdown(remaining: 12)
        }
        // Test-only: reproduces the "indicator stops appearing after repeated
        // use" race — show success (auto-hides at 0.9s), then start a new
        // listening state DURING the 0.25s hide fade (~1.0s). If the pill is
        // invisible after this, the alpha-restore bug is present.
        if arguments.contains("--test-indicator-race") {
            recordingIndicator.showSuccess()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.recordingIndicator.showListening()
                self?.recordingIndicator.updateLevel(0.6)
            }
        }
    }

    /// As an `.accessory` (menu-bar-only, no Dock icon) app, this process
    /// never gets AppKit's automatic application menu, which is what
    /// normally wires up standard edit commands (Cut/Copy/Paste/Select
    /// All/Undo/Redo) to every `NSTextField`/`NSSecureField`'s field editor
    /// via the responder chain. Without *some* `NSMenu` installed as
    /// `NSApp.mainMenu`, those key equivalents (⌘V etc.) are never
    /// intercepted at all — they don't even reach the responder chain — so
    /// pasting into the Settings window's API key / model name fields
    /// silently does nothing (reported bug). Installing a menu with the
    /// standard selectors (`cut:`/`copy:`/`paste:`/`selectAll:`/`undo:`/
    /// `redo:`, `target: nil` so AppKit routes them down the responder
    /// chain) restores those shortcuts even though the menu itself is never
    /// visible (no menu bar title) for an accessory app.
    private func installStandardMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu
        appMenu.addItem(NSMenuItem(title: "Quit hwhisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu

        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(undoItem)
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    /// Fires when the user reopens the app (Dock/Finder double-click) while
    /// it's already running as a menu-bar-only process. Without this, that
    /// reopen is a total no-op — exactly the "I opened it again and still
    /// nothing happened" recurrence of the original bug report. Reopening
    /// is an explicit user action, so this always shows regardless of
    /// permission state or the "don't show on launch" preference.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening from Dock/Finder now lands on the main app window; the
        // welcome window still takes over when required permissions are
        // missing, since nothing in the main window can fix those.
        if AVAudioApplication.shared.recordPermission == .granted && AXIsProcessTrusted() {
            mainWindowController.show()
        } else {
            welcomeWindowController.show()
        }
        return true
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = StatusIcon.idle.image

        let menu = NSMenu()
        // 브랜드 헤더: 앱 아이콘(먹×청자 심벌) + 워드마크 — 메뉴바 클릭
        // 시점이 브랜드가 처음 보이는 접점이라는 피드백 반영.
        let headerItem = NSMenuItem(title: "hwhisper", action: nil, keyEquivalent: "")
        let appIcon = NSApp.applicationIconImage.copy() as? NSImage
        appIcon?.size = NSSize(width: 20, height: 20)
        headerItem.image = appIcon
        menu.addItem(headerItem)
        menu.addItem(.separator())

        func symbolImage(_ name: String) -> NSImage? {
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            image?.isTemplate = true
            return image
        }

        let openItem = NSMenuItem(title: "hwhisper 열기", action: #selector(openMainWindow), keyEquivalent: "o")
        openItem.keyEquivalentModifierMask = [.command]
        openItem.target = self
        openItem.image = symbolImage("macwindow")
        menu.addItem(openItem)
        let historyItem = NSMenuItem(title: "히스토리", action: #selector(openHistory), keyEquivalent: "y")
        historyItem.keyEquivalentModifierMask = [.command]
        historyItem.target = self
        historyItem.image = symbolImage("clock.arrow.circlepath")
        menu.addItem(historyItem)
        let dictionaryItem = NSMenuItem(title: "개인 사전", action: #selector(openDictionary), keyEquivalent: "d")
        dictionaryItem.keyEquivalentModifierMask = [.command]
        dictionaryItem.target = self
        dictionaryItem.image = symbolImage("character.book.closed")
        menu.addItem(dictionaryItem)
        let settingsItem = NSMenuItem(title: "설정…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        settingsItem.target = self
        settingsItem.image = symbolImage("gearshape")
        menu.addItem(settingsItem)

        // Hidden until `setLastError` has something to show — surfaces the
        // most recent capture/transcription/insertion failure so a user who
        // missed the flashed icon (or a notification, if unauthorized) can
        // still find out what went wrong via the menu (§4 M1 UX fix).
        let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        errorItem.isHidden = true
        lastErrorMenuItem = errorItem
        menu.addItem(errorItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit hwhisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    @objc private func openSettings() {
        // Settings now lives inside the main window (§BACKLOG v0.2-1); the
        // standalone `SettingsWindowController` remains only for the welcome
        // window's "설정 열기" path.
        mainWindowController.show(section: "settings")
    }

    @objc private func openMainWindow() {
        mainWindowController.show()
    }

    @objc private func openHistory() {
        mainWindowController.show(section: "history")
    }

    @objc private func openDictionary() {
        mainWindowController.show(section: "dictionary")
    }

    /// Sets the menu bar icon, optionally auto-reverting to the idle
    /// waveform after `interval` — used so success/failure states are
    /// visible but don't get stuck once the moment has passed.
    private func setStatusIcon(_ symbol: StatusIcon, autoRevertAfter interval: TimeInterval? = nil) {
        iconResetWorkItem?.cancel()
        statusItem?.button?.image = symbol.image
        guard let interval else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.statusItem?.button?.image = StatusIcon.idle.image
        }
        iconResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: workItem)
    }

    private func setLastError(_ message: String?) {
        guard let errorItem = lastErrorMenuItem else { return }
        if let message {
            errorItem.title = "최근 오류: \(message)"
            errorItem.isHidden = false
        } else {
            errorItem.isHidden = true
        }
    }

    /// Posts a system notification, but only after confirming authorization
    /// — a denied user was already told via the floating indicator, so this
    /// skips the (guaranteed-to-fail) `add` call silently rather than
    /// retrying and logging "failed" on every single dictation. The denial
    /// itself is logged exactly once (`hasLoggedNotificationsDenied`) so a
    /// developer can still discover *why* notifications are quiet without
    /// the log filling up with the same line on every recording.
    private func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else {
            HwhisperLog.log("notification suppressed (unbundled): \(title) — \(body)")
            return
        }
        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                if !hasLoggedNotificationsDenied {
                    hasLoggedNotificationsDenied = true
                    HwhisperLog.log("notifications not authorized (status=\(settings.authorizationStatus.rawValue)); skipping future notifications — indicator already shows status")
                }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                HwhisperLog.log("notification delivery failed (\(error))")
            }
        }
    }

    /// Shared "no speech" advisory for both no-speech paths (entirely-silent
    /// recording, or a recording that transcribes to nothing). Deliberately
    /// a soft warning, not a failure: the menu-bar icon returns straight to
    /// idle and nothing is written to the "최근 오류" item — there's nothing
    /// wrong to record, the user just needs to speak and retry.
    private func showNoSpeechWarning() {
        setStatusIcon(Self.idleIcon)
        recordingIndicator.showWarning(title: "들리지 않았어요", message: "다시 한 번 말씀해 주세요.")
    }

    private func describeCaptureError(_ error: Error) -> String {
        if let captureError = error as? AudioCaptureError {
            switch captureError {
            case .permissionDenied:
                return "마이크 권한이 없습니다. 메뉴의 설정에서 시스템 설정을 열어 허용해 주세요."
            case .engineStartFailed(let reason):
                return "오디오 엔진을 시작하지 못했습니다: \(reason)"
            }
        }
        return "\(error)"
    }

    /// Distinguishes the three failure classes the plan calls out (mic
    /// permission / Accessibility permission / engine error) so both the
    /// indicator and the menu's "최근 오류" item say something actionable
    /// instead of a generic failure string.
    private func describeTranscriptionError(_ error: Error) -> String {
        if let sttError = error as? SpeechRecognizerError {
            switch sttError {
            case .engineUnavailable:
                return "받아쓰기 엔진을 사용할 수 없습니다."
            case .assetsNotProvisioned:
                return "한국어/영어 음성 인식 데이터가 아직 준비되지 않았습니다. 시스템 설정 > 손쉬운 사용 > 받아쓰기(Dictation)에서 언어 자산을 내려받아 주세요."
            case .recognitionFailed(let message):
                return "받아쓰기 엔진 오류: \(message)"
            }
        }
        return "받아쓰기에 실패했습니다: \(error)"
    }

    /// Distinguishes insertion failure causes — in particular, a missing
    /// Accessibility grant (which breaks both the AX and CGEvent-based
    /// insertion strategies) from a generic insertion failure.
    private func describeInsertionFailure() -> String {
        AXIsProcessTrusted()
            ? "텍스트 삽입에 실패했습니다 (전사 결과가 클립보드에 보존되었을 수 있습니다)."
            : "손쉬운 사용 권한이 없어 텍스트를 삽입하지 못했습니다. 메뉴 > 설정에서 권한을 확인하세요 (전사 결과는 클립보드에 있습니다)."
    }

    /// (Re)starts the single-key monitor to match the current `HotkeyMode`
    /// selection (§4 user feedback #1); a no-op stop when `.combination` is
    /// selected. The combination `KeyboardShortcuts` hotkey registered above
    /// is left running regardless of mode — both can fire simultaneously.
    private func applyHotkeyMode() {
        let mode = HotkeyMode.current
        guard mode != .combination else {
            singleKeyHotkeyMonitor.stop()
            return
        }

        // Global key/flags monitoring can be gated by Input Monitoring, a
        // TCC category distinct from the Accessibility permission the rest
        // of this app relies on (AX reads, CGEvent posting). Request it
        // explicitly rather than silently registering a monitor that may
        // never see events.
        if !CGPreflightListenEventAccess() {
            HwhisperLog.log("Input Monitoring not yet granted; requesting (required for single-key hotkey mode: \(mode.displayName))")
            _ = CGRequestListenEventAccess()
        }

        singleKeyHotkeyMonitor.start(mode: mode)
        HwhisperLog.log("single-key hotkey mode active: \(mode.displayName)")
    }

    /// Toggle entry point (§3.1): while idle, starts a new recording
    /// regardless of whether an earlier job is still transcribing/refining/
    /// inserting in the background (overlap path — see `PipelineActor`).
    /// While capturing, either cancels (fast double-tap) or stops and
    /// enqueues the recorded buffer for processing.
    private func handleHotkeyToggle() {
        if isCapturing {
            if let startedAt = captureStartedAt, Date().timeIntervalSince(startedAt) <= Self.cancelTapWindow {
                cancelCapture()
            } else {
                stopCaptureAndEnqueue()
            }
        } else {
            startCapture()
        }
    }

    private func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        captureStartedAt = Date()
        captureSnapshot = TargetContextSnapshot.capture()

        do {
            try audioCapture.start()
            setStatusIcon(Self.recordingIcon)
            recordingIndicator.showListening()
            pipelineActor.transition(to: .listening)
            HwhisperLog.log("recording started")
            startRecordingLimitTimer()
        } catch {
            isCapturing = false
            captureStartedAt = nil
            captureSnapshot = nil
            let reason = describeCaptureError(error)
            HwhisperLog.log("failed to start audio capture: \(error)")
            setLastError(reason)
            setStatusIcon(Self.failureIcon, autoRevertAfter: 2.5)
            recordingIndicator.showFailure(reason)
            postNotification(title: "hwhisper: 녹음을 시작하지 못했습니다", body: reason)
        }
    }

    /// Drives the guided-duration UX (Typeless-style): ticks once a second
    /// while recording, shows a countdown in the pill during the final
    /// `recordingMaxDuration - recordingWarnAt` seconds, then hard-stops at
    /// `recordingMaxDuration` by routing through the normal stop path — so the
    /// captured audio is transcribed + refined, never dropped.
    private func startRecordingLimitTimer() {
        recordingLimitTimer?.invalidate()
        recordingLimitTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordingLimitTick() }
        }
    }

    private func stopRecordingLimitTimer() {
        recordingLimitTimer?.invalidate()
        recordingLimitTimer = nil
        recordingIndicator.updateCountdown(remaining: nil)
    }

    private func recordingLimitTick() {
        guard isCapturing, let startedAt = captureStartedAt else {
            stopRecordingLimitTimer()
            return
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= Self.recordingMaxDuration {
            HwhisperLog.log("recording auto-stopped at max duration (\(Int(Self.recordingMaxDuration))s)")
            stopCaptureAndEnqueue() // invalidates the timer via stopRecordingLimitTimer
        } else if elapsed >= Self.recordingGracePeriod {
            let remaining = max(0, Int(ceil(Self.recordingMaxDuration - elapsed)))
            recordingIndicator.updateCountdown(remaining: remaining)
        }
    }

    /// §3.1 cancel path: discards the in-flight recording outright — no
    /// transcription, no queueing, nothing preserved to the clipboard
    /// (there is no transcript yet to preserve). Triggered either by a
    /// second hotkey tap within `cancelTapWindow` of the recording's start,
    /// or by clicking the indicator's inline X at any point while listening.
    private func cancelCapture() {
        guard isCapturing else { return }
        stopRecordingLimitTimer()
        isCapturing = false
        captureStartedAt = nil
        captureSnapshot = nil
        _ = audioCapture.stop()

        HwhisperLog.log("recording cancelled")
        setStatusIcon(Self.idleIcon)
        recordingIndicator.showCancelled()
        pipelineActor.transition(to: .idle)
    }

    /// Stops capture and hands the recorded buffer off to `PipelineActor`
    /// as a queued job (§3.1 overlap path / N-2 backpressure) rather than
    /// processing it inline — this is what lets a brand-new recording start
    /// immediately afterward without waiting for this job's transcribe/
    /// refine/insert to finish.
    private func stopCaptureAndEnqueue() {
        guard isCapturing else { return }
        stopRecordingLimitTimer()
        isCapturing = false
        captureStartedAt = nil

        let buffer = audioCapture.stop()
        HwhisperLog.log("recording stopped (\(buffer.samples.count) samples @ \(buffer.sampleRate)Hz = \(String(format: "%.1f", Double(buffer.samples.count) / buffer.sampleRate))s)")

        guard let snapshot = captureSnapshot else {
            HwhisperLog.log("no capture snapshot; dropping buffer")
            setStatusIcon(Self.idleIcon)
            recordingIndicator.hide()
            pipelineActor.transition(to: .idle)
            return
        }
        captureSnapshot = nil

        // Engine selection happens in `processQueuedJob` (Apple on macOS 26+,
        // WhisperKit fallback below) — no OS gate here anymore, so older Macs
        // queue and transcribe instead of being rejected outright.
        let jobID = UUID()
        HwhisperLog.log("job \(jobID) queued")
        let job = PipelineJob(
            id: jobID,
            run: { [weak self] in
                await self?.processQueuedJob(buffer: buffer, snapshot: snapshot)
            },
            onDropped: { [weak self] in
                self?.handleJobDropped(jobID: jobID)
            }
        )
        pipelineActor.enqueue(job)
    }

    /// Runs one queued job's full transcribe→refine→insert pass. Only one
    /// job runs at a time (`PipelineActor`'s single-flight queue), so this
    /// method never overlaps with another call to itself — safe to freely
    /// mutate the shared icon/indicator/log state.
    private func processQueuedJob(buffer: PCMBuffer, snapshot: TargetContextSnapshot) async {
        pipelineActor.transition(to: .transcribing)
        recordingIndicator.showTranscribing()

        let trimResult = EnergyVAD().trim(buffer)
        if trimResult.leadingTrimmedSeconds > 0 || trimResult.trailingTrimmedSeconds > 0 {
            HwhisperLog.log("VAD: trimmed leading \(String(format: "%.2f", trimResult.leadingTrimmedSeconds))s / trailing \(String(format: "%.2f", trimResult.trailingTrimmedSeconds))s of silence")
        }
        if trimResult.isEntirelySilent {
            HwhisperLog.log("VAD: entire recording is silence; skipping STT")
            showNoSpeechWarning()
            pipelineActor.transition(to: .idle)
            return
        }

        do {
            let biasingPhrases = await personalDictionary.biasingPhrases()
            if !biasingPhrases.isEmpty {
                HwhisperLog.log("dictionary: biasing recognition with \(biasingPhrases.count) term(s)")
            }

            let result: TranscriptionResult
            if #available(macOS 26.0, *) {
                // B1: Apple SpeechTranscriber (on-device, macOS 26+). Cheap to
                // construct, so a fresh instance per job is fine.
                result = try await AppleSpeechRecognizer().transcribe(
                    [trimResult.buffer],
                    languageMode: RecognitionLanguageMode.current,
                    contextualStrings: biasingPhrases
                )
            } else {
                // B2: WhisperKit fallback (macOS < 26 — no Apple engine).
                // First use downloads/loads the ~600MB model (seconds to
                // minutes); surface that instead of looking hung.
                if !hasUsedWhisperKit {
                    HwhisperLog.log("WhisperKit: first use on this run — loading model (downloads ~600MB on first ever run)")
                    recordingIndicator.showPreparingModel("음성 모델 준비 중… 최초 1회 다운로드(수 분 걸릴 수 있음)")
                }
                result = try await whisperKitRecognizer.transcribe(
                    [trimResult.buffer],
                    languageMode: RecognitionLanguageMode.current,
                    contextualStrings: biasingPhrases
                )
                hasUsedWhisperKit = true
            }
            // Log the length/outcome only, never the transcript content:
            // the log is a plaintext file and the dictated text is exactly
            // the sensitive content the app otherwise keeps on-device
            // (security review #3).
            HwhisperLog.log("transcribed \(result.text.count) chars")

            // No-speech guard (user request): VAD only catches pure silence;
            // low background noise can clear the VAD threshold yet still
            // transcribe to nothing (empty/whitespace, or a lone "." the
            // engine emits for non-speech). Warn instead of inserting an
            // empty/garbage result.
            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasWords = trimmedText.contains { $0.isLetter || $0.isNumber }
            guard hasWords else {
                HwhisperLog.log("no-speech guard: transcript had no words (\(result.text.count) chars); skipping insertion")
                showNoSpeechWarning()
                pipelineActor.transition(to: .idle)
                return
            }

            // Trimmed speech length — recorded with the history row as the
            // basis for the home tab's 받아쓰기/절약 시간 stats.
            let speechSeconds = trimResult.buffer.sampleRate > 0
                ? Double(trimResult.buffer.samples.count) / trimResult.buffer.sampleRate
                : 0
            await runRefinementPipeline(rawText: result.text, snapshot: snapshot, speechSeconds: speechSeconds)
        } catch {
            HwhisperLog.log("transcription failed: \(error)")
            let reason = describeTranscriptionError(error)
            setLastError(reason)
            setStatusIcon(Self.failureIcon, autoRevertAfter: 2.5)
            recordingIndicator.showFailure(reason)
            postNotification(title: "hwhisper: 받아쓰기 실패", body: reason)
            pipelineActor.transition(to: .idle)
        }
    }

    /// N-2 backpressure: a queued job was dropped before it ever started
    /// running because the pending queue was already at
    /// `PipelineActor.maxQueueDepth`. There is no transcript to preserve
    /// yet at this point (the dropped job's audio was never even
    /// transcribed) — the user is notified that a recording was lost so
    /// they can redo it, rather than silently disappearing.
    private func handleJobDropped(jobID: UUID) {
        let reason = "처리 대기열이 가득 차 오래된 녹음이 삭제되었습니다."
        HwhisperLog.log("job \(jobID) dropped: pipeline backpressure exceeded depth \(PipelineActor.maxQueueDepth)")
        setLastError(reason)
        setStatusIcon(Self.failureIcon, autoRevertAfter: 2.5)
        postNotification(title: "hwhisper: 녹음이 삭제되었습니다", body: reason)
    }

    /// Refines `rawText` when refinement is enabled (§4 M2), always falling
    /// back to the raw transcript on any failure/timeout/misconfiguration —
    /// refinement must never be a dead end (AC2). Logs elapsed time,
    /// provider, and outcome to `HwhisperLog` either way.
    private func runRefinementPipeline(rawText: String, snapshot: TargetContextSnapshot, speechSeconds: Double = 0) async {
        guard RefinementSettings.isEnabled else {
            await insertAndReport(text: rawText, snapshot: snapshot, speechSeconds: speechSeconds)
            return
        }
        pipelineActor.transition(to: .refining)

        let provider = RefinementSettings.provider
        let endpointString = RefinementSettings.endpoint(for: provider)
        guard let endpointURL = URL(string: endpointString), !endpointString.isEmpty else {
            HwhisperLog.log("refinement skipped: no valid endpoint configured for provider \(provider.rawValue)")
            await insertAndReport(text: rawText, snapshot: snapshot, speechSeconds: speechSeconds)
            return
        }

        // Defense-in-depth (security review #4): refuse to send the
        // transcript over cleartext to a non-local host. App Transport
        // Security already blocks http:// by default, but this makes the
        // policy explicit and fails safe to raw insertion rather than
        // relying solely on ATS. http://localhost / 127.0.0.1 (Ollama) is
        // allowed; everything else must be https.
        let host = endpointURL.host ?? ""
        let isLocalHost = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if endpointURL.scheme != "https" && !isLocalHost {
            HwhisperLog.log("refinement skipped: endpoint for provider \(provider.rawValue) is not https and not localhost — inserting raw text (set an https:// endpoint to enable refinement)")
            await insertAndReport(text: rawText, snapshot: snapshot, speechSeconds: speechSeconds)
            return
        }

        recordingIndicator.showRefining()
        let timeout = RefinementSettings.timeout
        let model = RefinementSettings.model
        let style = RefinementSettings.refinementStyle
        // Only protect terms that actually appear in this transcript — a
        // term absent from the input, if listed as "keep this term", makes the
        // LLM inject it into the output as a salient entity (observed live:
        // "오웬" spliced onto a sentence that never contained it).
        let context = RefinementContext(
            frontmostBundleID: snapshot.bundleIdentifier,
            protectedTerms: await personalDictionary.protectedTerms(presentIn: rawText)
        )

        // The Keychain read must stay OUT of any structured-concurrency
        // timeout race: `SecItemCopyMatching` blocks its thread while macOS
        // shows an access-authorization prompt (observed live after a
        // re-sign — first the main thread froze, then a task-group timeout
        // hung anyway because the group must await its blocked child before
        // returning). So: fetch once via an unstructured detached task with
        // a deadline; while that read is still pending, later dictations
        // fall back to raw immediately instead of piling up blocked reads.
        guard let apiKey = await fetchAPIKey(for: provider) else {
            HwhisperLog.log("refinement skipped: API key unavailable (keychain read pending or empty) — inserting raw text")
            await insertAndReport(text: rawText, snapshot: snapshot, speechSeconds: speechSeconds)
            return
        }

        let start = Date()
        do {
            let config = OpenAICompatibleRefinerConfig(
                endpoint: endpointURL,
                model: model,
                apiKey: apiKey.isEmpty ? nil : apiKey,
                timeout: timeout,
                style: style
            )
            let refiner = OpenAICompatibleRefiner(config: config)
            // Long input is refined as ceil(chunks / concurrency) rounds of
            // parallel calls (see OpenAICompatibleRefiner.refineChunked). Give
            // the outer bound that many timeouts of room so it doesn't kill a
            // legitimately long refinement; wall-clock stays ≈ that many calls.
            let chunkCount = OpenAICompatibleRefiner.chunkCount(for: rawText)
            let rounds = max(1, Int(ceil(Double(chunkCount) / Double(OpenAICompatibleRefiner.chunkConcurrency))))
            let effectiveTimeout = min(45, timeout * Double(rounds))
            let refined = try await withTimeout(effectiveTimeout) {
                try await refiner.refine(rawText, context: context)
            }
            let elapsed = Date().timeIntervalSince(start)
            HwhisperLog.log("refinement succeeded (provider=\(provider.rawValue), model=\(model), elapsed=\(String(format: "%.2f", elapsed))s)")
            await insertAndReport(text: refined, snapshot: snapshot, rawText: rawText, speechSeconds: speechSeconds)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            HwhisperLog.log("refinement failed, falling back to raw text (provider=\(provider.rawValue), model=\(model), elapsed=\(String(format: "%.2f", elapsed))s): \(error)")
            await insertAndReport(text: rawText, snapshot: snapshot, speechSeconds: speechSeconds)
        }
    }

    /// Inserts `text` at `snapshot`'s target and mirrors the outcome on the
    /// menu bar icon, "최근 오류" menu item, and floating indicator. Shared
    /// by both the raw and refined paths so refinement never changes how
    /// insertion outcomes are reported.
    private func insertAndReport(text: String, snapshot: TargetContextSnapshot, rawText: String? = nil, speechSeconds: Double = 0) async {
        // N-3 last-mile pass: runs after refinement (and on the raw path)
        // so dictionary spellings survive no matter what STT/LLM produced.
        let substituted = await personalDictionary.applyLastMileSubstitution(to: text)
        if substituted != text {
            HwhisperLog.log("dictionary: last-mile substitution applied")
        }
        pipelineActor.transition(to: .inserting)
        let outcome = await textInserter.insert(substituted, originalSnapshot: snapshot)
        HwhisperLog.log("insertion outcome: \(outcome)")
        recordHistory(insertedText: substituted, rawText: rawText ?? text, snapshot: snapshot, outcome: outcome, durationSeconds: speechSeconds)
        // §3.1's "restoring" stage (clipboard restore, best-effort
        // verification) is carried out inside `TextInserter`/
        // `ClipboardPasteInserter` themselves; from here it covers the
        // post-insert icon/indicator/log bookkeeping shared by every
        // outcome before returning to idle.
        pipelineActor.transition(to: .restoring)
        switch outcome {
        case .inserted:
            setLastError(nil)
            setStatusIcon(Self.successIcon, autoRevertAfter: 1.5)
            recordingIndicator.showSuccess()
        case .abortedContextMismatch:
            // User-requested fallback: don't discard the transcript just
            // because focus moved — `TextInserter` already copied it to the
            // clipboard (see its `.abortedContextMismatch` case), so tell
            // the user where it is instead of treating this as a bare
            // failure.
            let reason = "포커스가 바뀌어 클립보드에 복사했습니다 — ⌘V로 붙여넣기"
            setLastError(nil)
            setStatusIcon(Self.successIcon, autoRevertAfter: 1.5)
            recordingIndicator.showCopiedToClipboard(reason)
        case .abortedSecureField:
            let reason = "보안 입력 필드로 판단되어 삽입을 건너뛰었습니다."
            setLastError(reason)
            setStatusIcon(Self.failureIcon, autoRevertAfter: 2.5)
            recordingIndicator.showFailure(reason)
        case .failed:
            // `TextInserter` already posted its own precisely-worded
            // notification (clipboard-preserved reason, etc.) via its
            // internal `SystemInsertionNotifier` — just mirror the failure
            // on the icon/menu/indicator, don't double-notify.
            let reason = describeInsertionFailure()
            setLastError(reason)
            setStatusIcon(Self.failureIcon, autoRevertAfter: 2.5)
            recordingIndicator.showFailure(reason)
        }
        pipelineActor.transition(to: .idle)
    }

    /// Fire-and-forget history write (§BACKLOG v0.2-2). Never blocks the
    /// pipeline: the save runs in its own task, and a failure only logs —
    /// dictation must not degrade because the history DB is unhappy.
    private func recordHistory(
        insertedText: String,
        rawText: String,
        snapshot: TargetContextSnapshot,
        outcome: InsertionResult,
        durationSeconds: Double = 0
    ) {
        guard HistorySettings.isEnabled, !rawText.isEmpty else { return }
        let outcomeLabel: String
        switch outcome {
        case .inserted: outcomeLabel = "inserted"
        case .abortedContextMismatch: outcomeLabel = "clipboard"
        case .abortedSecureField: outcomeLabel = "secureField"
        case .failed: outcomeLabel = "failed"
        }
        let item = HistoryItem(
            rawText: rawText,
            refinedText: insertedText == rawText ? nil : insertedText,
            targetBundleID: snapshot.bundleIdentifier,
            outcome: outcomeLabel,
            durationSeconds: durationSeconds
        )
        let store = historyStore
        Task {
            do {
                try await store.save(item)
                await MainActor.run {
                    NotificationCenter.default.post(name: .hwhisperHistoryDidRecord, object: nil)
                }
            } catch {
                HwhisperLog.log("history: save failed: \(error)")
            }
        }
    }
}
