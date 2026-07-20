import AppKit
import SwiftUI
import KeyboardShortcuts
import HwhisperCore

/// Settings window content. M1 added the hotkey recorder; M2 (§4) adds the
/// "텍스트 정제" (text refinement) and "인식 언어" (recognition language)
/// sections. `KeyboardShortcuts.Recorder` persists the chosen shortcut to
/// `UserDefaults` itself; refinement/language settings persist via
/// `RefinementSettings` (API keys go to the Keychain, never UserDefaults).
struct SettingsView: View {
    /// True when hosted inside the main window's detail pane (which scrolls
    /// and sizes itself) rather than the fixed-size standalone window.
    var embedded = false

    @State private var hotkeyMode: HotkeyMode = .current
    @State private var languageMode: RecognitionLanguageMode = .current
    @State private var soundFeedbackEnabled = SoundFeedbackSettings.isEnabled
    @State private var historyEnabled = HistorySettings.isEnabled

    @State private var refinementEnabled = RefinementSettings.isEnabled
    @State private var provider = RefinementSettings.provider
    @State private var model = RefinementSettings.model
    @State private var customEndpoint = RefinementSettings.customEndpoint
    @State private var apiKey = ""
    @State private var timeoutText = String(format: "%.0f", RefinementSettings.timeout)
    @State private var refinementStyle = RefinementSettings.refinementStyle

    var body: some View {
        Form {
            Section {
                Picker("단축키 방식:", selection: $hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: hotkeyMode) { _, newValue in
                    HotkeyMode.current = newValue
                }

                if hotkeyMode == .combination {
                    // Custom recorder instead of `KeyboardShortcuts.Recorder`:
                    // that view's `RecorderCocoa.init` calls the library's
                    // `Bundle.module`, which `fatalError`s in our hand-
                    // assembled (non-Xcode) .app because it can't locate the
                    // KeyboardShortcuts resource bundle — crashing the app the
                    // moment this Form row lays out (confirmed via a user
                    // crash report). This captures the combo ourselves and
                    // stores it through the non-UI `setShortcut` API, which
                    // never touches `Bundle.module`.
                    ShortcutRecorderRow()
                }

                if hotkeyMode == .singleKeyCustom {
                    SingleKeyRecorderRow()
                }
            } footer: {
                Group {
                    switch hotkeyMode {
                    case .combination:
                        Text("단축키를 한 번 누르면 녹음이 시작되고, 다시 누르면 녹음이 끝나며 바로 받아쓰기와 삽입이 진행됩니다(토글 방식). 누르고 있을 필요는 없습니다.")
                    case .singleKeyFn:
                        Text("fn 키를 짧게 한 번 탭하면 녹음이 시작/종료됩니다. 다른 키와 함께 누르면(조합) 무시됩니다. macOS의 기본 fn 동작과 겹치지 않도록 시스템 설정 > 키보드 > 🌐 키 누르면 실행에서 '아무 동작 안 함'으로 바꿔 주세요. 최초 사용 시 '입력 모니터링' 권한 요청이 뜰 수 있습니다.")
                    case .singleKeyRightCommand, .singleKeyRightOption:
                        Text("선택한 키를 짧게 한 번 탭하면 녹음이 시작/종료됩니다. 다른 키와 함께 누르면(조합, 예: 우측⌘+C) 무시되어 원래 동작을 방해하지 않습니다. 최초 사용 시 '입력 모니터링' 권한 요청이 뜰 수 있습니다.")
                    case .singleKeyCustom:
                        Text("원하는 키를 직접 지정합니다 — 보조키(⌘/⌥/⌃/⇧ 좌·우, fn)와 함수키(F1~F20, 외장 키보드의 F13~F19 포함)를 쓸 수 있습니다. 일반 문자·숫자·방향키·Return 등은 타이핑/이동과 충돌해 지원하지 않습니다(선택 시 안내가 표시됩니다). 지정한 키를 짧게 탭하면 녹음이 시작/종료됩니다.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Section {
                Toggle("사운드 피드백", isOn: $soundFeedbackEnabled)
                    .onChange(of: soundFeedbackEnabled) { _, newValue in
                        SoundFeedbackSettings.isEnabled = newValue
                    }
            } footer: {
                Text("녹음 시작/종료 시 짧은 소리로 알려줍니다. 화면을 보지 않아도 인지할 수 있습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("히스토리 저장", isOn: $historyEnabled)
                    .onChange(of: historyEnabled) { _, newValue in
                        HistorySettings.isEnabled = newValue
                    }
            } footer: {
                Text("딕테이션 결과(원본/정제본)를 이 Mac에만 저장합니다. 메뉴 막대 > hwhisper 열기 > 히스토리에서 검색·복사할 수 있고, 외부로 전송되지 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("인식 언어:", selection: $languageMode) {
                    ForEach(RecognitionLanguageMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .onChange(of: languageMode) { _, newValue in
                    RecognitionLanguageMode.current = newValue
                }
            } footer: {
                Text("영어로 말했는데 한국어로 잘못 인식된다면 '영어'를 선택하세요. '자동'은 현재 한국어를 우선 인식합니다 — 완전한 자동 언어 감지는 아직 지원되지 않습니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("정제 사용", isOn: $refinementEnabled)
                    .onChange(of: refinementEnabled) { _, newValue in
                        RefinementSettings.isEnabled = newValue
                    }

                if refinementEnabled {
                    Picker("정제 강도:", selection: $refinementStyle) {
                        ForEach(RefinementStyle.allCases, id: \.self) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .onChange(of: refinementStyle) { _, newValue in
                        RefinementSettings.refinementStyle = newValue
                    }

                    Text("구조화: 나열은 목록으로, 주제는 단락으로 재구성합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Picker("프로바이더:", selection: $provider) {
                        ForEach(RefinerProvider.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .onChange(of: provider) { _, newValue in
                        RefinementSettings.provider = newValue
                        model = RefinementSettings.model
                        apiKey = RefinementSettings.apiKey(for: newValue) ?? ""
                    }

                    TextField("모델명:", text: $model)
                        .onChange(of: model) { _, newValue in
                            RefinementSettings.model = newValue
                        }

                    if provider == .custom {
                        TextField("엔드포인트 URL:", text: $customEndpoint, prompt: Text("https://…/chat/completions"))
                            .onChange(of: customEndpoint) { _, newValue in
                                RefinementSettings.customEndpoint = newValue
                            }
                    }

                    if provider.requiresAPIKey {
                        SecureField("API 키:", text: $apiKey)
                            .onChange(of: apiKey) { _, newValue in
                                RefinementSettings.setAPIKey(newValue, for: provider)
                            }
                    } else {
                        Text("Ollama 로컬 서버는 API 키가 필요 없습니다 (localhost에서 직접 실행 중이어야 합니다).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    TextField("타임아웃(초):", text: $timeoutText)
                        .onChange(of: timeoutText) { _, newValue in
                            if let seconds = Double(newValue), seconds > 0 {
                                RefinementSettings.timeout = seconds
                            }
                        }
                }
            } header: {
                Text("텍스트 정제")
            } footer: {
                Text("정제를 켜면 받아쓰기 결과에서 필러 워드 제거, 문장부호/띄어쓰기 교정을 거친 \"정제된 텍스트만\" 선택한 프로바이더로 전송됩니다. 음성(오디오)은 어떤 경우에도 외부로 전송되지 않습니다. 정제가 실패하거나 시간 초과되면 원본 받아쓰기 텍스트가 그대로 삽입됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // 메인 창(먹 그라운드)에 임베드될 때는 Form의 시스템 배경을 걷어
        // 잉크가 비치게 하고, 섹션 카드만 떠 있게 둔다.
        .scrollContentBackground(embedded ? .hidden : .automatic)
        .tint(Brand.accent)
        .frame(
            width: embedded ? nil : 460,
            height: embedded ? nil : (hotkeyMode == .combination ? 700 : 680)
        )
        .onAppear {
            apiKey = RefinementSettings.apiKey(for: provider) ?? ""
        }
    }
}

/// A self-contained keyboard-shortcut recorder that replaces
/// `KeyboardShortcuts.Recorder` (which `fatalError`s via `Bundle.module` in
/// our non-Xcode .app — see the call site). It captures the next key combo
/// through a local `NSEvent` monitor and persists it with the library's
/// non-UI `setShortcut(_:for:)`, so the actual global-hotkey registration
/// (`GlobalHotkey`/`onKeyDown`) is unchanged.
private struct ShortcutRecorderRow: View {
    @State private var isRecording = false
    @State private var display: String = ShortcutRecorderRow.currentDescription()
    @State private var hasShortcut: Bool = KeyboardShortcuts.getShortcut(for: .toggleDictation) != nil
    @State private var monitor: Any?

    private static func currentDescription() -> String {
        KeyboardShortcuts.getShortcut(for: .toggleDictation)?.description ?? "지정되지 않음"
    }

    var body: some View {
        HStack {
            Text("딕테이션 단축키:")
            Spacer()
            if !isRecording && hasShortcut {
                Button("지우기") { clear() }
                    .buttonStyle(.borderless)
            }
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(isRecording ? "키 조합을 누르세요… (Esc 취소)" : display)
                    .monospacedDigit()
                    .frame(minWidth: 150)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isRecording ? Brand.accent : Color.secondary.opacity(0.4))
                    )
                    .foregroundStyle(isRecording ? Brand.accent : .primary)
            }
            .buttonStyle(.plain)
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        isRecording = true
        // Local monitor fires on the main thread; assumeIsolated lets us touch
        // @State/KeyboardShortcuts (main-actor) without a Sendable violation.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil // swallow the keystroke while recording
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == 53 { stopRecording(); return } // Esc cancels
        // Require ⌘/⌥/⌃ so we never bind a bare letter (or Shift+letter) as a
        // system-wide hotkey and clobber normal typing.
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        guard !mods.isEmpty, let shortcut = KeyboardShortcuts.Shortcut(event: event) else {
            NSSound.beep()
            return
        }
        KeyboardShortcuts.setShortcut(shortcut, for: .toggleDictation)
        display = shortcut.description
        hasShortcut = true
        stopRecording()
    }

    private func clear() {
        KeyboardShortcuts.setShortcut(nil, for: .toggleDictation)
        display = "지정되지 않음"
        hasShortcut = false
    }
}

/// Records a single modifier key for `.singleKeyCustom`. Captures the next
/// modifier key-down via a local `flagsChanged` monitor and stores its
/// key code in `HotkeyMode.customKeyCode` (which re-applies the monitor).
/// Only modifier keys `HotkeyMode.modifierInfo` knows are accepted.
private struct SingleKeyRecorderRow: View {
    @State private var isRecording = false
    @State private var display: String = SingleKeyRecorderRow.currentName()
    @State private var errorMessage: String?
    @State private var monitor: Any?

    private static func currentName() -> String {
        if let code = HotkeyMode.customKeyCode { return HotkeyMode.keyDisplayName(for: code) }
        return "지정되지 않음"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("단일 키:")
                Spacer()
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Text(isRecording ? "키를 누르세요… (Esc 취소)" : display)
                        .frame(minWidth: 150)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(isRecording ? Brand.accent : Color.secondary.opacity(0.4))
                        )
                        .foregroundStyle(isRecording ? Brand.accent : .primary)
                }
                .buttonStyle(.plain)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        errorMessage = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func assign(_ code: CGKeyCode) {
        HotkeyMode.customKeyCode = code
        display = HotkeyMode.keyDisplayName(for: code)
        errorMessage = nil
        stopRecording()
    }

    private func handle(_ event: NSEvent) {
        if event.type == .flagsChanged {
            // Modifier key: accept on press (its flag bit set), ignore release.
            let code = CGKeyCode(event.keyCode)
            guard let info = HotkeyMode.modifierInfo(for: code) else { return }
            guard event.modifierFlags.contains(info.flag) else { return }
            assign(code)
            return
        }

        // keyDown (non-modifier)
        if event.keyCode == 53 { stopRecording(); return } // Esc cancels
        if HotkeyMode.isAssignableKeyDown(event) {
            assign(CGKeyCode(event.keyCode))
        } else {
            // Regular letter/number, or a navigation/edit key — can't be a
            // global single-key toggle. Stay in recording mode so the user
            // can try another key; show the red one-line notice.
            errorMessage = "해당 키는 설정이 불가능합니다."
            NSSound.beep()
        }
    }
}

/// Owns the settings `NSWindow` so `AppDelegate` (an `.accessory` app with no
/// Dock icon or main menu) can present a normal SwiftUI window on demand.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: SettingsView())
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "hwhisper 설정"
        newWindow.contentView = hostingView
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        window = newWindow

        NSApp.activate(ignoringOtherApps: true)
        newWindow.makeKeyAndOrderFront(nil)
    }
}
