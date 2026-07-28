import SwiftUI

/// hwhisper 브랜드 상수 — 「먹(ink) × 청자(celadon)」.
///
/// 컨셉: 속삭임(whisper)은 낮고 조용하지만 정확히 전달되고, 남에게 들리지
/// 않는다(음성이 기기를 떠나지 않는 프라이버시). 경쟁(Wispr Flow)의 따뜻한
/// 크림 톤과 반대편에서, 깊은 잉크 네이비 + 청자빛 민트로 "조용한 신뢰"를
/// 표현한다. 앱 아이콘(`scripts/render-app-icon.swift`)과 동일 팔레트 —
/// 값을 바꾸면 두 곳을 함께 갱신할 것.
enum Brand {
    /// 청자(celadon) 악센트 — #46B99C 계열. 토글/버튼/선택 강조에 쓰는
    /// 시스템 tint. 라이트·다크 모두에서 통하는 중간톤이라 테마 무관 고정.
    static let accent = Color(red: 0.275, green: 0.725, blue: 0.612)
    /// 밝은 청자 — 그라데이션 상단(#A5EEDC), 웨이브폼 하이라이트용.
    static let accentLight = Color(red: 0.647, green: 0.933, blue: 0.863)

    // MARK: - 적응형 그라운드 (다크: 먹 세계 / 라이트: 청자 종이)
    //
    // 상수 하나만 동적으로 바꾸면 `.background(Brand.ink)` 등 호출처를
    // 손대지 않고 라이트/다크가 함께 전환된다. 값을 바꾸면 앱 아이콘
    // (`scripts/render-app-icon.swift`)의 다크 팔레트와도 정합을 유지할 것.

    /// 먹(ink) 사이드바/카드 그라운드 — 다크 #131B2E / 라이트 #FAFCFB(청자빛 흰 카드).
    static let ink = dynamic(dark: (0.075, 0.106, 0.180), light: (0.980, 0.988, 0.984))
    /// 심연(ink deep) 메인 캔버스 — 다크 #0A0F1A / 라이트 #EDF2F0(청자 종이).
    static let inkDeep = dynamic(dark: (0.039, 0.059, 0.102), light: (0.929, 0.949, 0.941))
    /// 살짝 떠 있는 표면/트랙/칩 — 다크 #1B2740 / 라이트 #DCE6E2(연청자 회색).
    static let inkRaise = dynamic(dark: (0.106, 0.153, 0.251), light: (0.863, 0.902, 0.886))

    /// 주 텍스트 — 다크: 흰색 / 라이트: 먹색(#10161F, near-black). 하드코딩
    /// `.white` 텍스트를 대체해 라이트 모드에서 글씨가 배경에 묻히지 않게 한다.
    static let inkText = dynamic(dark: (1, 1, 1), light: (0.063, 0.086, 0.122))
    /// 청자 악센트 표면 위에 놓이는 텍스트/아이콘 — 두 테마 모두 먹색 고정
    /// (히어로 카드·강조 버튼 라벨이 라이트에서 밝은색이 되어 묻히는 것 방지).
    static let onAccent = Color(red: 0.075, green: 0.106, blue: 0.180)

    /// 경고/카운트다운 앰버 — 다크: 밝은 호박색(#F2BF59) / 라이트: 진한
    /// 호박색(#B87910). 인디케이터가 라이트 유리 위에서도 대비를 유지하도록
    /// 라이트에선 어둡게 내린다.
    static let warningAmber = dynamic(dark: (0.95, 0.75, 0.35), light: (0.72, 0.47, 0.06))

    /// AppKit 쪽(창 배경 등)에서 쓰는 적응형 심연 색.
    static let inkDeepNSColor = dynamicNS(dark: (0.039, 0.059, 0.102), light: (0.929, 0.949, 0.941))

    /// 현재 유효 외형(aqua/darkAqua)에 따라 두 sRGB 값 중 하나를 고르는 동적 NSColor.
    private static func dynamicNS(dark: (Double, Double, Double), light: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    private static func dynamic(dark: (Double, Double, Double), light: (Double, Double, Double)) -> Color {
        Color(nsColor: dynamicNS(dark: dark, light: light))
    }
}

/// 사용자가 고르는 화면 테마. 앱은 기본 다크(먹 세계)로 두고, 라이트를
/// 선택하면 청자 종이 그라운드 + 먹색 텍스트로 전환된다.
enum ThemeMode: String, CaseIterable {
    case dark
    case light

    var displayName: String {
        switch self {
        case .dark: return "다크"
        case .light: return "라이트"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .dark: return NSAppearance(named: .darkAqua)
        case .light: return NSAppearance(named: .aqua)
        }
    }
}

/// 화면 테마 저장·적용. 창마다 하드코딩된 darkAqua 대신 이 값을 참조해
/// 라이트/다크를 전환하며, 변경 시 열려 있는 모든 창에 즉시 반영한다.
@MainActor
enum AppTheme {
    private static let key = "themeMode"

    static var current: ThemeMode {
        get { ThemeMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            apply()
        }
    }

    /// 앱 전역(`NSApp.appearance`)과 열린 모든 창의 외형을 현재 테마로 맞춘다.
    /// 개별 창이 자체 appearance를 지정하면 NSApp 값을 덮으므로, 두 곳을 함께
    /// 갱신해 라이트↔다크 전환이 즉시 보이게 한다. 앱 시작 시·설정 변경 시 호출.
    static func apply() {
        let appearance = current.nsAppearance
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
        }
    }
}

/// 청자 채움 + 먹색 라벨 강조 버튼. 시스템 `.borderedProminent`에 옅은 청자
/// tint를 주면 라이트 모드에서 흰 라벨이 옅은 배경에 묻혀 대비가 약하다 —
/// 두 테마 모두 또렷하도록 solid 청자 캡슐 + 먹색 라벨(히어로 카드와 같은
/// "청자 위 먹색" 언어)로 직접 그린다.
struct BrandProminentButtonStyle: ButtonStyle {
    var large = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(Brand.onAccent)
            .padding(.horizontal, large ? 22 : 16)
            .padding(.vertical, large ? 11 : 7)
            .background(Brand.accent, in: Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// 아이콘 심벌의 미니 재현(세로 바 4개 + 정착 대시) — 사이드바 워드마크,
/// 빈 상태 등 인앱 브랜드 표식에 쓴다. 비율은 앱 아이콘과 동일 모티프.
struct BrandGlyph: View {
    var height: CGFloat = 18

    var body: some View {
        let unit = height / 20
        let gradient = LinearGradient(
            colors: [Brand.accentLight, Brand.accent],
            startPoint: .top, endPoint: .bottom
        )
        HStack(alignment: .center, spacing: unit * 2) {
            ForEach([7.0, 14.0, 20.0, 10.5], id: \.self) { h in
                Capsule().fill(gradient)
                    .frame(width: unit * 2.6, height: unit * h)
            }
            Capsule().fill(Brand.accentLight.opacity(0.9))
                .frame(width: unit * 6.6, height: unit * 2.6)
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
