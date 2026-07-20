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
    /// 시스템 tint.
    static let accent = Color(red: 0.275, green: 0.725, blue: 0.612)
    /// 밝은 청자 — 그라데이션 상단(#A5EEDC), 웨이브폼 하이라이트용.
    static let accentLight = Color(red: 0.647, green: 0.933, blue: 0.863)
    /// 먹(ink) — 아이콘 배경과 같은 딥 네이비(#131B2E). 사이드바 그라운드.
    static let ink = Color(red: 0.075, green: 0.106, blue: 0.180)
    /// 심연(ink deep, #0A0F1A) — 메인 창 콘텐츠 그라운드.
    static let inkDeep = Color(red: 0.039, green: 0.059, blue: 0.102)
    /// 살짝 떠 있는 표면(#1B2740) — 카드/구분 표면.
    static let inkRaise = Color(red: 0.106, green: 0.153, blue: 0.251)

    /// AppKit 쪽(창 배경 등)에서 쓰는 심연 색.
    static let inkDeepNSColor = NSColor(srgbRed: 0.039, green: 0.059, blue: 0.102, alpha: 1)
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
