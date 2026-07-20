import Foundation
import HwhisperCore

/// Persisted "텍스트 정제" settings (§4 M2). Mirrors `HotkeyMode`'s
/// UserDefaults-backed pattern (see `SingleKeyHotkey.swift`). The API key
/// itself is never stored here — it lives in `CredentialStore` (an
/// owner-only-permissioned file, not the Keychain — see that type's doc
/// comment for why), keyed per provider so switching providers doesn't
/// clobber a previously saved key.
enum RefinementSettings {
    private static let enabledKey = "refinementEnabled"
    private static let providerKey = "refinementProvider"
    private static let modelKey = "refinementModel"
    private static let customEndpointKey = "refinementCustomEndpoint"
    private static let timeoutKey = "refinementTimeout"
    private static let styleKey = "refinementStyle"
    static let defaultTimeout: TimeInterval = 8

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static var provider: RefinerProvider {
        get {
            guard let raw = UserDefaults.standard.string(forKey: providerKey),
                  let provider = RefinerProvider(rawValue: raw) else {
                return .gemini
            }
            return provider
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    /// Model name for the current provider; falls back to that provider's
    /// preset default until the user explicitly edits the field.
    static var model: String {
        get {
            let stored = UserDefaults.standard.string(forKey: modelKey)
            return (stored?.isEmpty == false) ? stored! : provider.defaultModel
        }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    /// Only consulted when `provider == .custom`.
    static var customEndpoint: String {
        get { UserDefaults.standard.string(forKey: customEndpointKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: customEndpointKey) }
    }

    /// Refinement timeout in seconds; falls back to `defaultTimeout` (AC2:
    /// timeout → raw fallback, default 8s).
    static var timeout: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: timeoutKey)
            return stored > 0 ? stored : defaultTimeout
        }
        set { UserDefaults.standard.set(newValue, forKey: timeoutKey) }
    }

    /// 정제 강도: 기본 다듬기(필러 제거/문장부호) 대비, 구조화는 나열·화제
    /// 전환을 목록/단락으로 재구성한다. 기본값은 `.polish` (기존 동작 유지).
    static var refinementStyle: RefinementStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: styleKey),
                  let style = RefinementStyle(rawValue: raw) else {
                return .polish
            }
            return style
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: styleKey) }
    }

    /// Resolved chat-completions endpoint for `provider` (custom providers
    /// use the user-entered `customEndpoint`).
    static func endpoint(for provider: RefinerProvider) -> String {
        provider == .custom ? customEndpoint : provider.defaultEndpoint
    }

    /// API key access, delegated to `CredentialStore` (never UserDefaults,
    /// never the Keychain), scoped per provider.
    static func apiKey(for provider: RefinerProvider) -> String? {
        CredentialStore.read(account: provider.rawValue)
    }

    static func setAPIKey(_ value: String, for provider: RefinerProvider) {
        CredentialStore.save(value, account: provider.rawValue)
        NotificationCenter.default.post(name: .refinementAPIKeyDidChange, object: nil)
    }
}

extension Notification.Name {
    /// Posted after an API key is (re)saved so `AppDelegate` can drop its
    /// in-memory key cache and pick up the new value on the next refinement.
    static let refinementAPIKeyDidChange = Notification.Name("refinementAPIKeyDidChange")
}

/// "인식 언어" setting (§4 M2 — English-utterance breakage pain point).
/// `RecognitionLanguageMode` itself lives in `HwhisperCore` (platform
/// agnostic); this Mac-only extension adds UserDefaults persistence and
/// display strings for the Settings picker.
extension RecognitionLanguageMode: CaseIterable {
    public static var allCases: [RecognitionLanguageMode] { [.korean, .english, .auto] }

    private static let defaultsKey = "recognitionLanguageMode"

    /// Persisted selection, defaulting to Korean (§4: matches the app's
    /// primary audience and the engine's current locale-scoped behavior).
    static var current: RecognitionLanguageMode {
        get {
            switch UserDefaults.standard.string(forKey: defaultsKey) {
            case "english": .english
            case "auto": .auto
            default: .korean
            }
        }
        set {
            let raw: String
            switch newValue {
            case .korean: raw = "korean"
            case .english: raw = "english"
            case .auto: raw = "auto"
            }
            UserDefaults.standard.set(raw, forKey: defaultsKey)
        }
    }

    var displayName: String {
        switch self {
        case .korean: "한국어"
        case .english: "영어"
        case .auto: "자동 (현재 한국어 우선)"
        }
    }
}
