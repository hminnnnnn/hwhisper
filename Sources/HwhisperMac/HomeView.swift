import SwiftUI
import HwhisperCore

/// 평균 타이핑 속도 가정치(분당 단어).
///
/// ⚠ 이 값은 **영문 사무 타이핑 통계(≈40WPM)**에서 왔고, 단어 수는 공백
/// 분리라 한국어에서는 "어절" 수를 센다. 즉 한국어 발화에 대해서는 엄밀한
/// 근거가 아니라 어림값이다 — 화면 각주도 "어림값"이라고 밝힌다. 근거
/// 재정립은 별도 항목(`.omc/plans/v0.2.16-home-stats.md` §4).
///
/// `HomeView`(main-actor) 바깥에 두는 이유는 `WeekBucket` 같은 nonisolated
/// 값 타입에서도 같은 상수를 써야 하기 때문.
enum TypingBaseline {
    static let wordsPerMinute = 40.0
}

/// 집계 구간. 홈이 "이번 주"만 보여주던 시절에는 매주 일요일 00:00에 모든
/// 숫자가 0으로 떨어졌고, 사용자에게는 그게 데이터가 사라지는 것처럼 보였다
/// (실측: 누적 182회·150.6분을 8회·12.1분으로 축소 표시). 구간을 사용자가
/// 고르게 하고 기본값을 `.all`로 둬서, 쌓인 효용이 리셋되지 않게 한다.
enum StatsPeriod: String, CaseIterable, Identifiable {
    case week
    case fourWeeks
    case all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return "이번 주"
        case .fourWeeks: return "최근 4주"
        case .all: return "전체"
        }
    }

    /// 집계 시작 시각. `nil`이면 "기록 전체".
    func start(now: Date, calendar: Calendar) -> Date? {
        switch self {
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        case .fourWeeks:
            return calendar.date(byAdding: .day, value: -27, to: calendar.startOfDay(for: now))
        case .all:
            return nil
        }
    }
}

/// 홈 대시보드 (§BACKLOG v0.2 — Typeless 홈 탭 벤치마크): 선택한 구간의
/// 받아쓰기 지표(시간·단어·절약 시간·속도), 주간 추이, 현재 말하기 버튼,
/// 최근 받아쓰기.
///
/// 절약 시간은 "이 단어들을 평균 타이핑 속도로 쳤다면" 대비 실제 발화
/// 시간의 차이 — 가정치는 `typingWPM` 참고.
struct HomeView: View {
    let store: SQLiteHistoryStore
    let onOpenSettings: () -> Void
    let onOpenHistory: () -> Void

    @State private var stats = HistoryAggregate()
    @State private var appUsage: [HistoryAppCount] = []
    @State private var weekly: [WeekBucket] = []
    @State private var recent: [HistoryItem] = []
    /// 전체 기록 건수 — 선택 구간이 사실상 전체를 덮는지 판단해 캡션에 밝힌다.
    @State private var allTimeDictations = 0
    @State private var hotkeyName = HotkeyMode.current.displayName
    /// 사용자의 구간 선택은 창을 닫아도 유지된다 — 매번 기본값으로 되돌아가면
    /// "또 초기화됐다"는 인상을 다시 만든다.
    @AppStorage("homeStatsPeriod") private var periodRaw = StatsPeriod.all.rawValue

    private var period: StatsPeriod { StatsPeriod(rawValue: periodRaw) ?? .all }

    private static var typingWPM: Double { TypingBaseline.wordsPerMinute }

    /// 주간 추이 막대 하나. `savedSeconds`는 카드와 같은 공식을 쓴다.
    struct WeekBucket: Identifiable {
        let weekStart: Date
        var dictations = 0
        var speechSeconds: Double = 0
        var words = 0
        var id: Date { weekStart }

        var savedSeconds: Double {
            max(0, Double(words) / TypingBaseline.wordsPerMinute * 60 - speechSeconds)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                statsGrid
                if weekly.count >= 2 { trendCard }
                if !appUsage.isEmpty { appUsageCard }
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
        // `id: periodRaw` — 구간을 바꾸면 이 task가 취소·재시작되어 집계가
        // 다시 계산된다. `.task { }`(id 없음)는 화면이 처음 뜰 때 한 번만
        // 돌기 때문에, 피커를 움직이면 제목만 바뀌고 숫자는 처음 로드된 값에
        // 그대로 멈춰 있었다(v0.2.16 개발 중 실사고 — 세 구간이 전부 같은
        // 값으로 보임). 별도 onChange를 다는 대신 task의 id로 묶어, 구간과
        // 표시값이 구조적으로 어긋날 수 없게 한다.
        .task(id: periodRaw) { await reload() }
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
                    .foregroundStyle(Brand.inkText)
                    .lineSpacing(3)
            }
            Label("음성은 이 Mac을 떠나지 않습니다 — 전사는 온디바이스에서 끝납니다.", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("집계 구간", selection: $periodRaw) {
                ForEach(StatsPeriod.allCases) { p in
                    Text(p.label).tag(p.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 12) {
                StatCard(
                    // 히어로 카드만 구간과 무관하게 "지금까지"를 쓰지 않는다 —
                    // 구간을 바꾸면 값이 함께 바뀌므로 제목도 구간을 따라야
                    // 한다. 제목과 내용이 어긋나던 것이 이전 버전의 결함이었다.
                    title: period == .all ? "지금까지 절약한 시간" : "\(period.label) 절약한 시간",
                    value: Self.formatDuration(stats.savedSeconds(typingWordsPerMinute: Self.typingWPM)),
                    symbol: "hourglass",
                    hero: true
                )
                StatCard(
                    title: period == .all ? "총 받아쓰기 시간" : "\(period.label) 받아쓰기 시간",
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
            Text(verbatim: periodCaption)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    /// 집계 구간을 문장으로 드러낸다. 이전 버전은 구간 표시가 각주 한 줄뿐이라
    /// 주가 바뀌어 숫자가 떨어지면 데이터가 사라진 것처럼 보였다.
    private var periodCaption: String {
        let count = "\(stats.dictations)회 받아쓰기"
        let basis = "절약 시간은 타이핑 40WPM 가정 대비 어림값"
        guard let start = period.start(now: Date(), calendar: Calendar.current) else {
            return "기록 전체 · \(count) · \(basis)"
        }
        // 기록이 구간보다 짧으면 이 구간과 "전체"가 같은 값이 된다. 그 자체는
        // 정상인데, 아무 설명이 없으면 "구간을 바꿔도 숫자가 안 변한다"로
        // 읽힌다(실제 사용자 신고) — 그래서 같은 이유를 문장으로 밝힌다.
        let coversEverything = allTimeDictations > 0 && stats.dictations == allTimeDictations
        let sameAsAll = coversEverything ? " · 아직 기록이 이 구간보다 짧아 «전체»와 같습니다" : ""
        return "\(Self.dayLabel(start))~오늘 · \(count)\(sameAsAll) · \(basis)"
    }

    /// 최근 8주 주별 절약 시간. **구간 선택과 무관하게 항상 8주**를 그린다 —
    /// 이 카드의 목적은 "이번 구간이 얼마인가"가 아니라 "리셋이 아니라
    /// 흐름이다"를 보여주는 것이기 때문.
    private var trendCard: some View {
        let maxSaved = max(1, weekly.map(\.savedSeconds).max() ?? 1)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("주간 추이")
                    .font(.headline)
                    .foregroundStyle(Brand.inkText)
                Spacer()
                Text(verbatim: "주별 절약 시간 · 최근 8주")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(weekly) { bucket in
                    VStack(spacing: 6) {
                        Text(verbatim: bucket.dictations > 0 ? Self.formatDurationShort(bucket.savedSeconds) : "—")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        RoundedRectangle(cornerRadius: 5)
                            .fill(LinearGradient(colors: [Brand.accentLight, Brand.accent],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(height: max(3, 96 * bucket.savedSeconds / maxSaved))
                            .opacity(bucket.dictations > 0 ? 1 : 0.25)
                        Text(verbatim: Self.dayLabel(bucket.weekStart, weekday: false))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 148, alignment: .bottom)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.ink, in: RoundedRectangle(cornerRadius: 14))
    }

    private var appUsageCard: some View {
        let total = max(1, appUsage.reduce(0) { $0 + $1.count })
        return VStack(alignment: .leading, spacing: 12) {
            Text("어디에 많이 쓰나요")
                .font(.headline)
                .foregroundStyle(Brand.inkText)
            VStack(spacing: 10) {
                ForEach(appUsage.prefix(5)) { usage in
                    let fraction = Double(usage.count) / Double(total)
                    HStack(spacing: 10) {
                        Text(Self.appName(usage.bundleID))
                            .font(.callout)
                            .foregroundStyle(Brand.inkText.opacity(0.88))
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
                    .foregroundStyle(Brand.inkText)
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
                    .foregroundStyle(Brand.inkText)
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
                                    .foregroundStyle(Brand.inkText.opacity(0.88))
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
        let now = Date()
        let start = period.start(now: now, calendar: calendar)
        do {
            // 집계는 SQL에서 끝난다 — 전체 기간이 기본값이라, 예전처럼 모든
            // 행의 전사 본문을 메모리로 올려 세면 기록이 늘수록 무거워진다.
            stats = try await store.aggregate(since: start)
            appUsage = try await store.appCounts(since: start)
            // 전체 건수는 COUNT 한 번이라 값싸다. 구간이 전체일 때는 방금 구한
            // 값을 그대로 재사용해 중복 질의를 피한다.
            allTimeDictations = start == nil ? stats.dictations : try await store.aggregate(since: nil).dictations

            let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            let trendStart = calendar.date(byAdding: .weekOfYear, value: -7, to: thisWeekStart)
            weekly = Self.bucketByWeek(try await store.metrics(since: trendStart), calendar: calendar, now: now)

            recent = try await store.search(query: "", limit: 3)

            // 어떤 구간으로 무엇을 계산했는지 남긴다. 전사 본문은 없고 집계
            // 수치만 — 화면을 캡처할 수 없는 환경에서도 "구간을 바꿨는데
            // 숫자가 그대로"를 로그만으로 판별할 수 있게 하는 목적(함정 7).
            HwhisperLog.log(String(
                format: "home: stats loaded (period=%@, %d dictations, %.1fmin, %d words, saved %.1fmin)",
                period.rawValue, stats.dictations, stats.speechSeconds / 60, stats.words,
                stats.savedSeconds(typingWordsPerMinute: Self.typingWPM) / 60
            ))
        } catch {
            HwhisperLog.log("home: stats load failed: \(error)")
        }
    }

    /// 최근 8주를 빈 주까지 포함해 버킷으로 만든다. 데이터가 있는 주만
    /// 그리면 쉬어 간 주가 압축돼 사라져서, 추이가 실제보다 꾸준해 보인다.
    static func bucketByWeek(_ points: [HistoryMetricPoint], calendar: Calendar, now: Date) -> [WeekBucket] {
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        var buckets: [WeekBucket] = stride(from: 7, through: 0, by: -1).compactMap { back in
            calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeekStart).map { WeekBucket(weekStart: $0) }
        }
        var indexByStart: [Date: Int] = [:]
        for (i, b) in buckets.enumerated() { indexByStart[b.weekStart] = i }

        for point in points {
            guard let weekStart = calendar.dateInterval(of: .weekOfYear, for: point.createdAt)?.start,
                  let index = indexByStart[weekStart] else { continue }
            buckets[index].dictations += 1
            buckets[index].speechSeconds += point.durationSeconds
            buckets[index].words += point.words
        }
        return buckets
    }

    /// "8/9(일)" / "8/9" — 집계 구간과 막대 축 라벨용.
    static func dayLabel(_ date: Date, weekday: Bool = true) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = weekday ? "M/d(E)" : "M/d"
        return formatter.string(from: date)
    }

    /// 막대 위 라벨 — 폭이 좁아 `formatDuration`보다 더 줄인다.
    static func formatDurationShort(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded()))초" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)분" }
        return "\(minutes / 60)시간\(minutes % 60 > 0 ? "\(minutes % 60)분" : "")"
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
                .foregroundStyle(hero ? Brand.onAccent : Brand.accent)
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(hero ? Brand.onAccent : Brand.inkText)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(hero ? Brand.onAccent.opacity(0.75) : .secondary)
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
