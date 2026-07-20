import SwiftUI
import HwhisperCore

/// 홈 대시보드 (§BACKLOG v0.2 — Typeless 홈 탭 벤치마크): 이번 주 받아쓰기
/// 지표(시간·단어·절약 시간·속도), 현재 말하기 버튼, 최근 받아쓰기.
/// 절약 시간은 "이 단어들을 평균 타이핑 속도로 쳤다면" 대비 실제 발화
/// 시간의 차이 — 근거 수치는 `typingWPM` 참고.
struct HomeView: View {
    let store: SQLiteHistoryStore
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void

    @State private var stats = WeekStats()
    @State private var recent: [HistoryItem] = []
    @State private var hotkeyName = HotkeyMode.current.displayName

    /// 평균 타이핑 속도 가정치(분당 단어). 일반 사무 타이핑 통계(≈40WPM)
    /// 기준 — 홈 화면 각주에도 그대로 명시한다.
    private static let typingWPM = 40.0

    struct AppUsage: Identifiable {
        let bundleID: String
        let count: Int
        var id: String { bundleID }
    }

    struct WeekStats {
        var dictations = 0
        var words = 0
        var speechSeconds: Double = 0
        /// Descending by count — the home tab's "어디에 많이 쓰나" widget.
        var appUsage: [AppUsage] = []

        var typedSecondsEquivalent: Double { Double(words) / HomeView.typingWPM * 60 }
        var savedSeconds: Double { max(0, typedSecondsEquivalent - speechSeconds) }
        var wordsPerMinute: Int {
            speechSeconds >= 5 ? Int((Double(words) / speechSeconds * 60).rounded()) : 0
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                statsGrid
                if !stats.appUsage.isEmpty { appUsageCard }
                hotkeyCard
                recentSection
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(alignment: .top) {
            // 아이콘과 같은 문법의 청자 "숨결" 글로우 — 잉크 위 생동감.
            RadialGradient(
                colors: [Brand.accent.opacity(0.16), .clear],
                center: .init(x: 0.5, y: -0.15),
                startRadius: 10, endRadius: 520
            )
            .ignoresSafeArea()
        }
        .background(Brand.inkDeep)
        .navigationTitle("홈")
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .hwhisperHistoryDidRecord)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .hotkeyModeDidChange)) { _ in
            hotkeyName = HotkeyMode.current.displayName
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                BrandGlyph(height: 26)
                Text("말하세요,\n받아 적는 건 제 일입니다.")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineSpacing(3)
            }
            Label("음성은 이 Mac을 떠나지 않습니다 — 전사는 온디바이스에서 끝납니다.", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                StatCard(
                    title: "절약된 시간",
                    value: Self.formatDuration(stats.savedSeconds),
                    symbol: "hourglass",
                    hero: true
                )
                StatCard(
                    title: "총 받아쓰기 시간",
                    value: Self.formatDuration(stats.speechSeconds),
                    symbol: "waveform"
                )
                StatCard(
                    title: "받아쓴 단어",
                    value: stats.words.formatted(),
                    symbol: "text.word.spacing"
                )
                StatCard(
                    title: "평균 받아쓰기 속도",
                    value: stats.wordsPerMinute > 0 ? "\(stats.wordsPerMinute) WPM" : "—",
                    symbol: "gauge.with.needle"
                )
            }
            Text("이번 주 \(stats.dictations)회 받아쓰기 기준 · 절약 시간은 일반 타이핑 속도 40WPM 대비")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var appUsageCard: some View {
        let total = max(1, stats.appUsage.reduce(0) { $0 + $1.count })
        return VStack(alignment: .leading, spacing: 12) {
            Text("어디에 많이 쓰나요")
                .font(.headline)
                .foregroundStyle(.white)
            VStack(spacing: 10) {
                ForEach(stats.appUsage.prefix(5)) { usage in
                    let fraction = Double(usage.count) / Double(total)
                    HStack(spacing: 10) {
                        Text(Self.appName(usage.bundleID))
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 118, alignment: .leading)
                            .lineLimit(1)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Brand.inkRaise)
                                Capsule()
                                    .fill(LinearGradient(colors: [Brand.accentLight, Brand.accent],
                                                         startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(6, geo.size.width * fraction))
                            }
                        }
                        .frame(height: 10)
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: 14))
    }

    private var hotkeyCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "keyboard")
                .font(.system(size: 20))
                .foregroundStyle(Brand.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("말하기 버튼")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                Text("짧게 한 번 탭 = 시작/종료 · 시작 직후 다시 탭 = 취소")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(hotkeyName)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(Brand.accentLight)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Brand.inkRaise, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Brand.accent.opacity(0.35)))
            Button("변경") { onOpenSettings() }
                .buttonStyle(.bordered)
        }
        .padding(16)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: 14))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("최근 받아쓰기")
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                Button("전체 보기") { onOpenHistory() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Brand.accent)
            }
            if recent.isEmpty {
                Text("아직 기록이 없습니다 — \(hotkeyName) 키를 탭하고 말해 보세요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Brand.ink, in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(spacing: 8) {
                    ForEach(recent.prefix(3)) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(Brand.accent).frame(width: 5, height: 5).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.insertedText)
                                    .font(.callout)
                                    .foregroundStyle(.white.opacity(0.88))
                                    .lineLimit(2)
                                Text(item.createdAt.formatted(.relative(presentation: .named)))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Brand.ink, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    private func reload() async {
        let calendar = Calendar.current
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? calendar.startOfDay(for: Date())
        do {
            let weekItems = try await store.items(since: weekStart)
            var next = WeekStats()
            next.dictations = weekItems.count
            var appCounts: [String: Int] = [:]
            for item in weekItems {
                next.words += Self.wordCount(item.insertedText)
                next.speechSeconds += item.durationSeconds
                if let bundleID = item.targetBundleID, !bundleID.isEmpty {
                    appCounts[bundleID, default: 0] += 1
                }
            }
            next.appUsage = appCounts
                .map { AppUsage(bundleID: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count }
            stats = next
            recent = Array(weekItems.prefix(3))
            if recent.isEmpty {
                recent = try await store.search(query: "", limit: 3)
            }
        } catch {
            HwhisperLog.log("home: stats load failed: \(error)")
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    /// Human-readable app name for a bundle ID; falls back to the last
    /// dotted component for apps no longer installed (mirrors the history
    /// row's resolver).
    private static func appName(_ bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID.components(separatedBy: ".").last ?? bundleID
    }

    /// "45초", "12분", "1시간 5분" — 홈 카드용 짧은 한국어 시간 표기.
    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)초" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)분" }
        return "\(minutes / 60)시간 \(minutes % 60)분"
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let symbol: String
    var hero = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(hero ? Brand.ink : Brand.accent)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(hero ? Brand.ink : .white)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(hero ? Brand.ink.opacity(0.75) : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            // 브랜드의 유일한 "생동감" 지점 — 히어로 카드만 아이콘 바와
            // 같은 청자 그라데이션, 나머지 카드는 조용한 잉크.
            hero
                ? AnyShapeStyle(LinearGradient(colors: [Brand.accentLight, Brand.accent],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                : AnyShapeStyle(Brand.ink),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }
}
