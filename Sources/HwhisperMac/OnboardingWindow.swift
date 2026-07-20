import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import HwhisperCore

/// First-run onboarding wizard (§D2 v0.3-distribution plan): a paged
/// introduction that gets a stranger from "just installed" to a working
/// dictation setup — value prop, permissions, hotkey choice, and (the core
/// step) an explicit, guided choice between raw-first (no key), a free
/// cloud API key, or a local Ollama server. Supersedes `WelcomeWindow` on
/// first launch; `WelcomeWindow` remains for the "permission went missing
/// again" re-prompt after onboarding has already run once (see
/// `AppDelegate.applicationDidFinishLaunching`).
struct OnboardingView: View {
    static let completedDefaultsKey = "onboardingCompleted"

    /// Reached the last page and explicitly asked to open the app.
    let onFinish: () -> Void
    /// Dismissed early ("건너뛰기" or closing the window) — still marks
    /// onboarding complete (so it doesn't nag on every future launch) but
    /// does not also pop the main window open.
    let onSkip: () -> Void

    @State private var page = 0
    private let totalPages = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch page {
                case 0: OnboardingWelcomePage()
                case 1: OnboardingPermissionsPage()
                case 2: OnboardingHotkeyPage()
                case 3: OnboardingRefinementPage()
                default: OnboardingFinishPage(onOpenHome: onFinish)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.vertical, 20)

            footer
        }
        .frame(width: 560, height: 640)
        .background(Brand.inkDeep)
        .tint(Brand.accent)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                BrandGlyph(height: 16)
                Text("hwhisper 시작하기")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            if page < totalPages - 1 {
                Button("건너뛰기", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 4)
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(0..<totalPages, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Brand.accent : Brand.inkRaise)
                        .frame(width: index == page ? 18 : 6, height: 6)
                }
            }
            HStack {
                if page > 0 {
                    Button("이전") { page -= 1 }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if page < totalPages - 1 {
                    Button("다음") { page += 1 }
                        .buttonStyle(.borderedProminent)
                        .tint(Brand.accent)
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 20)
    }
}

// MARK: - Page 1: Welcome

private struct OnboardingWelcomePage: View {
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            BrandGlyph(height: 54)
            Text("hwhisper에 오신 것을\n환영합니다")
                .multilineTextAlignment(.center)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("말하면 커서에 바로 입력되고, 음성은 기기를 떠나지 않습니다.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Page 2: Permissions

/// Reuses `WelcomeView`'s permission-check calls (`AVAudioApplication.shared
/// .recordPermission`, `AXIsProcessTrusted()`) — same source of truth, just
/// restyled to match the wizard's ink-dark chrome.
private struct OnboardingPermissionsPage: View {
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("권한 허용")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("딕테이션에는 마이크와 손쉬운 사용 권한이 필요합니다. 지금 허용하지 않아도 나중에 설정에서 다시 할 수 있습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            permissionCard(
                title: "마이크",
                detail: "음성을 듣기 위해 필요합니다.",
                granted: microphonePermission == .granted,
                statusText: microphoneStatusText
            ) {
                if microphonePermission == .undetermined {
                    Task {
                        _ = await AudioCapture.requestMicrophonePermission()
                        microphonePermission = AVAudioApplication.shared.recordPermission
                    }
                } else {
                    openSystemSettings(suffix: "Privacy_Microphone")
                }
            }

            permissionCard(
                title: "손쉬운 사용",
                detail: "커서 위치에 텍스트를 입력하기 위해 필요합니다.",
                granted: accessibilityTrusted,
                statusText: accessibilityTrusted ? "허용됨" : "허용 필요"
            ) {
                openSystemSettings(suffix: "Privacy_Accessibility")
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private var microphoneStatusText: String {
        switch microphonePermission {
        case .granted: "허용됨"
        case .denied: "거부됨"
        case .undetermined: "미결정"
        @unknown default: "알 수 없음"
        }
    }

    private func refresh() {
        microphonePermission = AVAudioApplication.shared.recordPermission
        accessibilityTrusted = AXIsProcessTrusted()
    }

    @ViewBuilder
    private func permissionCard(title: String, detail: String, granted: Bool, statusText: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Brand.accent : .orange)
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title): \(statusText)")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(granted ? "확인됨" : "시스템 설정 열기", action: action)
                .buttonStyle(.bordered)
                .disabled(granted)
        }
        .padding(14)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: 12))
    }

    private func openSystemSettings(suffix: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(suffix)") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Page 3: Hotkey

private struct OnboardingHotkeyPage: View {
    @State private var selected = HotkeyMode.current

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("단축키 선택")
                .font(.title2.bold())
                .foregroundStyle(.white)
            Text("탭 한 번으로 녹음을 시작/종료합니다. 나중에 설정에서 언제든 바꿀 수 있습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                ForEach(HotkeyMode.allCases, id: \.self) { mode in
                    hotkeyRow(mode)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func hotkeyRow(_ mode: HotkeyMode) -> some View {
        let isSelected = selected == mode
        return Button {
            selected = mode
            HotkeyMode.current = mode
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Brand.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(hotkeyDetail(mode))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(isSelected ? Brand.accent.opacity(0.14) : Brand.ink, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(isSelected ? Brand.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func hotkeyDetail(_ mode: HotkeyMode) -> String {
        switch mode {
        case .combination: "직접 지정한 조합 키를 사용합니다 (설정에서 지정)."
        case .singleKeyRightCommand: "우측 ⌘ 키를 짧게 탭합니다. 조합키(예: 우측⌘+C)는 무시됩니다."
        case .singleKeyRightOption: "우측 ⌥ 키를 짧게 탭합니다."
        case .singleKeyFn: "fn(🌐) 키를 짧게 탭합니다. 시스템 설정에서 fn 키 기본 동작을 바꿔야 충돌하지 않습니다."
        case .singleKeyCustom: "원하는 보조키(⌘/⌥/⌃/⇧ 좌·우, fn)를 직접 지정합니다 (설정에서 지정)."
        }
    }
}

// MARK: - Page 4: Refinement (core step)

private enum OnboardingRefinementChoice: Equatable {
    case off
    case apiKey
    case ollama
}

private enum OnboardingConnectionTestState: Equatable {
    case idle
    case testing
    case success(String)
    case failure(String)
}

private struct OnboardingRefinementPage: View {
    @State private var choice: OnboardingRefinementChoice = RefinementSettings.isEnabled
        ? (RefinementSettings.provider == .ollama ? .ollama : .apiKey)
        : .off
    @State private var provider: RefinerProvider = RefinementSettings.provider == .groq ? .groq : .gemini
    @State private var apiKey = ""
    @State private var testState: OnboardingConnectionTestState = .idle
    @State private var ollamaDetected = false
    @State private var ollamaProbeDone = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("정제 설정")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("받아쓴 텍스트를 다듬을지 선택합니다. 음성은 어떤 경우에도 외부로 전송되지 않습니다 — 정제를 켜면 \"정제된 텍스트만\" 선택한 프로바이더로 전송됩니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                offCard
                apiKeyCard
                ollamaCard
            }
        }
        .task { await probeOllama() }
        .onAppear {
            apiKey = RefinementSettings.apiKey(for: provider) ?? ""
        }
    }

    // MARK: Cards

    private var offCard: some View {
        cardHeader(
            title: "정제 없이 바로 시작",
            subtitle: "추천 — 받아쓴 텍스트가 그대로 삽입됩니다. 키 설정이 필요 없습니다.",
            isSelected: choice == .off
        ) {
            choice = .off
            RefinementSettings.isEnabled = false
        }
        .padding(14)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(choice == .off ? Brand.accent : .clear, lineWidth: 1.5))
    }

    private var apiKeyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader(
                title: "무료 API 키로 정제 켜기",
                subtitle: "필러 제거, 문장부호 교정, 구조화까지 — 클라우드 LLM으로 다듬습니다.",
                isSelected: choice == .apiKey
            ) {
                choice = .apiKey
                RefinementSettings.isEnabled = true
                RefinementSettings.provider = provider
            }

            if choice == .apiKey {
                VStack(alignment: .leading, spacing: 12) {
                    exampleBeforeAfter

                    Picker("프로바이더:", selection: $provider) {
                        Text("Gemini (무료 티어)").tag(RefinerProvider.gemini)
                        Text("Groq (무료 티어)").tag(RefinerProvider.groq)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: provider) { _, newValue in
                        RefinementSettings.provider = newValue
                        apiKey = RefinementSettings.apiKey(for: newValue) ?? ""
                        testState = .idle
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(providerGuideSteps)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(providerLinkTitle) {
                            NSWorkspace.shared.open(providerKeyURL)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }

                    SecureField("API 키 붙여넣기", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { _, newValue in
                            RefinementSettings.setAPIKey(newValue, for: provider)
                            testState = .idle
                        }

                    HStack(spacing: 10) {
                        Button {
                            Task { await runConnectionTest() }
                        } label: {
                            if testState == .testing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("연결 테스트")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty || testState == .testing)

                        testResultView
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(choice == .apiKey ? Brand.accent : .clear, lineWidth: 1.5))
    }

    private var ollamaCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader(
                title: "로컬 Ollama 사용",
                subtitle: ollamaProbeDone
                    ? (ollamaDetected ? "감지됨 — 로컬 Ollama 서버가 실행 중입니다." : "감지되지 않음 — Ollama를 설치하고 실행한 뒤 다시 확인하세요.")
                    : "확인 중…",
                isSelected: choice == .ollama
            ) {
                choice = .ollama
                RefinementSettings.isEnabled = true
                RefinementSettings.provider = .ollama
            }
            if choice == .ollama {
                HStack {
                    Text("API 키가 필요 없습니다. localhost:11434에서 서버가 실행 중이어야 합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("다시 확인") { Task { await probeOllama() } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(choice == .ollama ? Brand.accent : .clear, lineWidth: 1.5))
    }

    private func cardHeader(title: String, subtitle: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Brand.accent : .secondary)
                    .font(.system(size: 16))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private var exampleBeforeAfter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("정제 전/후 예시")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Text("전").font(.caption2).foregroundStyle(.secondary).frame(width: 16, alignment: .leading)
                    Text("음 그러니까 어 오늘 회의는요 어 3시에 하고 그 자료는 제가 어 준비할게요")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 6) {
                    Text("후").font(.caption2).foregroundStyle(Brand.accentLight).frame(width: 16, alignment: .leading)
                    Text("오늘 회의는 3시에 하고, 자료는 제가 준비할게요.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .padding(10)
            .background(Brand.inkRaise, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var testResultView: some View {
        switch testState {
        case .idle:
            EmptyView()
        case .testing:
            Text("연결 확인 중…").font(.caption).foregroundStyle(.secondary)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Brand.accentLight)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
        }
    }

    private var providerKeyURL: URL {
        switch provider {
        case .groq: URL(string: "https://console.groq.com/keys")!
        default: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    private var providerLinkTitle: String {
        provider == .groq ? "Groq에서 무료 키 발급받기 →" : "Google AI Studio에서 무료 키 발급받기 →"
    }

    private var providerGuideSteps: String {
        provider == .groq
            ? "1) 위 링크에서 Groq 계정으로 로그인  2) API Keys에서 새 키 생성  3) 아래에 붙여넣기"
            : "1) 위 링크에서 Google 계정으로 로그인  2) \"Create API key\" 클릭  3) 생성된 키를 아래에 붙여넣기"
    }

    // MARK: Probes

    /// Auto-detects a locally running Ollama server (§D2: "설치되어 있으면
    /// 자동 감지"). Short timeout, never blocks the UI — a failed/refused
    /// connection just means "not running" rather than an error state.
    private func probeOllama() async {
        guard let url = URL(string: "http://localhost:11434") else { return }
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 1.5
        sessionConfig.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: sessionConfig)
        var detected = false
        if let (_, response) = try? await session.data(from: url), (response as? HTTPURLResponse) != nil {
            detected = true
        }
        ollamaDetected = detected
        ollamaProbeDone = true
        // Only auto-select if the user hasn't already made an explicit
        // choice on this page (still at the default "off").
        if detected && choice == .off {
            choice = .ollama
            RefinementSettings.isEnabled = true
            RefinementSettings.provider = .ollama
        }
    }

    /// Minimal real chat-completions call against the configured provider to
    /// validate the pasted key, mirroring `AppDelegate.runRefinementPipeline`
    /// / `withTimeout`'s pattern: always timeout-bounded, never lets a hung
    /// request block the UI indefinitely.
    private func runConnectionTest() async {
        testState = .testing
        let endpointString = RefinementSettings.endpoint(for: provider)
        guard let endpointURL = URL(string: endpointString), !endpointString.isEmpty else {
            testState = .failure("엔드포인트 설정 오류")
            return
        }
        let key = apiKey
        let model = provider.defaultModel
        do {
            let config = OpenAICompatibleRefinerConfig(
                endpoint: endpointURL,
                model: model,
                apiKey: key.isEmpty ? nil : key,
                timeout: 10,
                style: .polish
            )
            let refiner = OpenAICompatibleRefiner(config: config)
            _ = try await withOnboardingTimeout(10) {
                try await refiner.refine("연결 테스트입니다.", context: RefinementContext())
            }
            testState = .success("연결 성공")
        } catch {
            testState = .failure("연결 실패: \(describeTestError(error))")
        }
    }

    private func describeTestError(_ error: Error) -> String {
        if let refinerError = error as? TextRefinerError {
            switch refinerError {
            case .timedOut:
                return "시간 초과 — 네트워크 상태를 확인하세요."
            case .unavailable:
                return "정제 기능을 사용할 수 없습니다."
            case .requestFailed(let message):
                if message.contains("401") || message.contains("403") {
                    return "API 키가 올바르지 않습니다."
                }
                return String(message.prefix(120))
            }
        }
        return "\(error)"
    }
}

/// Races `operation` against a hard deadline — same shape as
/// `AppDelegate`'s private `withTimeout`, duplicated here (file-private, no
/// cross-file symbol) so the onboarding wizard's connection test never
/// blocks the UI if a provider hangs.
private func withOnboardingTimeout<T: Sendable>(
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

// MARK: - Page 5: Finish

private struct OnboardingFinishPage: View {
    let onOpenHome: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Brand.accent)
            Text("설정이 끝났습니다")
                .font(.title2.bold())
                .foregroundStyle(.white)
            VStack(spacing: 6) {
                Text("단축키: \(HotkeyMode.current.displayName)")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
                Text(refinementSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("탭 한 번으로 녹음을 시작/종료합니다. 나중에 설정에서 언제든 바꿀 수 있습니다.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Spacer()
            Button("홈 화면 열기", action: onOpenHome)
                .buttonStyle(.borderedProminent)
                .tint(Brand.accent)
                .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var refinementSummary: String {
        guard RefinementSettings.isEnabled else { return "정제: 사용 안 함 (원문 그대로 삽입)" }
        switch RefinementSettings.provider {
        case .ollama: return "정제: 로컬 Ollama"
        default: return "정제: \(RefinementSettings.provider.displayName) API"
        }
    }
}

// MARK: - Window controller

/// Owns the onboarding `NSWindow`, mirroring `WelcomeWindowController`'s
/// lazy-create-then-reuse shape and floating/all-spaces presentation (the
/// same "launched it, nothing happened" concern applies to a first-run
/// wizard as to the permission-nag window it supersedes).
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    /// `activate: false` shows the window without stealing focus — used by
    /// the `--no-activate` test hook (mirrors `MainWindowController.show`).
    func show(activate: Bool = true) {
        let hostingView = NSHostingView(rootView: OnboardingView(
            onFinish: { [weak self] in self?.complete(openHome: true) },
            onSkip: { [weak self] in self?.complete(openHome: false) }
        ))

        if let window {
            window.contentView = hostingView
            present(window, activate: activate)
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "hwhisper 시작하기"
        newWindow.appearance = NSAppearance(named: .darkAqua)
        newWindow.backgroundColor = Brand.inkDeepNSColor
        newWindow.contentView = hostingView
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()
        window = newWindow

        present(newWindow, activate: activate)
    }

    private func present(_ window: NSWindow, activate: Bool) {
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        if activate { NSApp.activate(ignoringOtherApps: true) }
        window.makeKeyAndOrderFront(nil)
        // 무음 실패 금지 + screencapture -l 검증 훅 (MainWindowController와
        // 동일 패턴): 창 표시 사실과 윈도우 번호를 로그에 남긴다.
        HwhisperLog.log("onboarding window shown: number=\(window.windowNumber)")
    }

    private func complete(openHome: Bool) {
        UserDefaults.standard.set(true, forKey: OnboardingView.completedDefaultsKey)
        window?.close()
        if openHome { onFinish() }
    }

    /// Closing the window any other way (titlebar close, ⌘W) still counts
    /// as "seen it" — otherwise the wizard would reappear on every future
    /// launch until the user happens to click through to the last page.
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: OnboardingView.completedDefaultsKey)
    }
}
