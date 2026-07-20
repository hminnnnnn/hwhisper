import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI
import KeyboardShortcuts

/// First-launch (and re-open) welcome window (§4 M1 UX fix). hwhisper is an
/// `.accessory` (LSUIElement) menu-bar-only app: launching it never shows a
/// window or Dock icon, and in full-screen apps the menu bar itself is
/// hidden, so users who expect ordinary app-launch feedback conclude
/// "nothing happened" and assume it crashed. This window is the fix — it
/// explains the menu-bar UX, surfaces mic/Accessibility permission status
/// and the current shortcut so users can self-diagnose, and is shown again
/// whenever the (already-running) app is reopened from Finder/Dock (see
/// `AppDelegate.applicationShouldHandleReopen`).
struct WelcomeView: View {
    static let hideOnLaunchDefaultsKey = "hideWelcomeOnLaunch"

    let onOpenSettings: () -> Void
    let onClose: () -> Void

    @State private var microphonePermission = AVAudioApplication.shared.recordPermission
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var hideOnLaunch = UserDefaults.standard.bool(forKey: WelcomeView.hideOnLaunchDefaultsKey)

    private var shortcutDescription: String {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) else {
            return "미지정, 설정에서 지정하세요"
        }
        return shortcut.description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Hwhisper가 실행 중입니다 🎙")
                .font(.title2)
                .bold()

            Text("이 앱은 메뉴바 오른쪽의 🎙 아이콘으로 동작합니다. 전체화면에서는 마우스를 화면 맨 위로 가져가면 메뉴바가 나타납니다. 아이콘이 안 보이면 노치에 가려졌을 수 있으니 메뉴바 아이콘을 ⌘드래그로 정리해 보세요.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            permissionRow(
                title: "마이크",
                status: microphonePermissionText,
                granted: microphonePermission == .granted,
                settingsURLSuffix: "Privacy_Microphone"
            )

            permissionRow(
                title: "손쉬운 사용",
                status: accessibilityTrusted ? "허용됨" : "허용 필요",
                granted: accessibilityTrusted,
                settingsURLSuffix: "Privacy_Accessibility"
            )

            Divider()

            HStack {
                Text("딕테이션 단축키: \(shortcutDescription)")
                Spacer()
                Button("설정 열기", action: onOpenSettings)
            }

            Toggle("시작할 때 이 창 표시하지 않기", isOn: $hideOnLaunch)
                .onChange(of: hideOnLaunch) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: WelcomeView.hideOnLaunchDefaultsKey)
                }

            HStack {
                Spacer()
                Button("닫기", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .tint(Brand.accent)
        .onAppear(perform: refreshPermissionStatus)
    }

    private var microphonePermissionText: String {
        switch microphonePermission {
        case .granted: return "허용됨"
        case .denied: return "거부됨"
        case .undetermined: return "미결정"
        @unknown default: return "알 수 없음"
        }
    }

    private func refreshPermissionStatus() {
        microphonePermission = AVAudioApplication.shared.recordPermission
        accessibilityTrusted = AXIsProcessTrusted()
    }

    @ViewBuilder
    private func permissionRow(title: String, status: String, granted: Bool, settingsURLSuffix: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            Text("\(title): \(status)")
            Spacer()
            Button("시스템 설정 열기") {
                openSystemSettings(suffix: settingsURLSuffix)
            }
        }
    }

    private func openSystemSettings(suffix: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(suffix)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Owns the welcome `NSWindow` so `AppDelegate` (an `.accessory` app with no
/// Dock icon or main menu) can present it on launch and again on reopen.
/// Mirrors `SettingsWindowController`'s lazy-create-then-reuse shape.
@MainActor
final class WelcomeWindowController {
    private var window: NSWindow?
    private let settingsWindowController: SettingsWindowController

    init(settingsWindowController: SettingsWindowController) {
        self.settingsWindowController = settingsWindowController
    }

    func show() {
        // Rebuild the hosted `WelcomeView` on every call, even when reusing
        // an existing `NSWindow`. `WelcomeView`'s permission/shortcut
        // `@State` is only captured once at view creation, and merely
        // re-fronting an already-attached SwiftUI view does not refire
        // `onAppear` — without this, a user who reopens the app (the
        // primary way this window is meant to be re-consulted, see
        // `AppDelegate.applicationShouldHandleReopen`) after granting a
        // permission would still see the stale pre-grant status.
        let hostingView = NSHostingView(rootView: WelcomeView(
            onOpenSettings: { [weak self] in self?.settingsWindowController.show() },
            onClose: { [weak self] in self?.window?.close() }
        ))

        if let window {
            window.contentView = hostingView
            present(window)
            return
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Hwhisper"
        newWindow.contentView = hostingView
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        window = newWindow

        present(newWindow)
    }

    /// `.accessory` apps have no Dock icon to click back to, and a plain
    /// window sits behind whatever Space/full-screen app currently has
    /// focus — which is exactly the "launched it, nothing happened" bug
    /// this window exists to prevent. `.floating` plus `.canJoinAllSpaces`
    /// keeps it visible even while another app occupies a full-screen Space.
    private func present(_ window: NSWindow) {
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
