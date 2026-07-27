import Foundation
import HwhisperCore

// Permanent refinement RELEASE GATE (`HwhisperEval --refine-suite`).
//
// Runs a diverse set of NEUTRAL, synthetic dictation cases through the REAL
// OpenAICompatibleRefiner (live Gemini API, BYOK) against robust assertions,
// prints a per-case pass/fail table + coverage %, and EXITS NON-ZERO when
// coverage < 100% so `scripts/release-gate.sh` can BLOCK a release.
//
// Every input here is invented (no user data), so this file ships in the repo.
// Assertions are intentionally lenient toward *correct* behavior (they check
// robust properties, not exact strings) so LLM non-determinism doesn't cause
// false release blocks — they only fail on genuine quality regressions.
//
// Reads the Gemini key from credentials.json at runtime; never prints it.

// MARK: - Robust property checks

/// Count of clear standalone filler tokens that must never survive refinement.
/// Only unambiguous fillers (그/좀/약간/이제 are legitimate words → excluded).
private func standaloneFillers(_ s: String) -> Int {
    let toks = s.replacingOccurrences(of: "\n", with: " ").split(separator: " ").map(String.init)
    let fillers: Set<String> = ["어", "음", "뭐", "어어", "음음", "어,", "음,"]
    return toks.filter { fillers.contains($0) }.count
}

private func hasNumberedList(_ s: String) -> Bool {
    (s.contains("1.") && s.contains("2.")) || (s.contains("1)") && s.contains("2)"))
}

/// Ends on a plausible sentence terminal (catches mid-word truncation).
private func endsCleanly(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let last = t.last else { return false }
    return ".!?…".contains(last) || "요다어야지고네까라해줘음됨".contains(last)
}

private func containsAll(_ s: String, _ terms: [String]) -> Bool { terms.allSatisfy { s.contains($0) } }
private func containsAny(_ s: String, _ terms: [String]) -> Bool { terms.contains { s.contains($0) } }
private func isPolite(_ s: String) -> Bool { containsAny(s, ["습니다", "합니다", "세요", "입니다", "됩니다", "십시오"]) }

// MARK: - Suite

private struct SuiteCase {
    let category: String
    let name: String
    let input: String
    let style: RefinementStyle
    /// (passed, reason) — reason shown in the table.
    let check: (String) -> (Bool, String)
}

func runRefineSuite() async {
    let credURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Hwhisper/credentials.json")
    guard let data = try? Data(contentsOf: credURL),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
          let key = obj["gemini"], !key.isEmpty else {
        print("❌ GATE ERROR: no Gemini key in credentials.json — cannot run release gate")
        exit(2)
    }
    let endpoint = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
    func refiner(_ s: RefinementStyle) -> OpenAICompatibleRefiner {
        OpenAICompatibleRefiner(config: .init(endpoint: endpoint, model: "gemini-3.1-flash-lite", apiKey: key, timeout: 90, style: s))
    }

    // A ~3-minute colloquial monologue (~700 chars), filler-heavy, 3 topics.
    let threeMin = """
    자 그러면 어 오늘 좀 정리해 볼 게 있는데 음 그러니까 어 일단 첫 번째로 그 홈 화면 있잖아 그 홈 화면이 어 로딩이 좀 느린 것 같단 말이야 그래서 어 그거를 좀 봐야 될 것 같고 음 두 번째는 어 그 검색 기능인데 검색이 어 뭐 가끔 안 되는 경우가 있어 가지고 어 그 부분도 좀 확인이 필요하고 그리고 어 세 번째로 그 알림 있잖아 알림이 어 좀 너무 자주 오는 것 같아 가지고 그거를 좀 줄이든지 아니면 어 설정에서 끌 수 있게 하든지 그런 걸 좀 생각해 봐야 될 것 같아 뭐 대충 그런 얘기고 어 나머지는 다음에 또 얘기하자
    """

    let cases: [SuiteCase] = [
        SuiteCase(category: "짧은문장", name: "필러+요청", input: "어 이거 좀 확인해 줘", style: .polish,
                  check: { (standaloneFillers($0) == 0 && $0.contains("확인"), "filler=\(standaloneFillers($0))") }),
        SuiteCase(category: "짧은문장", name: "질문 유지", input: "어 이거 왜 자꾸 안 되는 거야", style: .polish,
                  check: { (standaloneFillers($0) == 0 && containsAny($0, ["?", "거야", "되는지"]), "질문성 유지·filler=\(standaloneFillers($0))") }),
        SuiteCase(category: "중간서술", name: "필러 다수 제거", input: "음 그러니까 어 내가 하고 싶은 말은 어 그 대시보드가 어 좀 밋밋하다는 거야 뭐 그런 느낌", style: .polish,
                  check: { (standaloneFillers($0) == 0 && $0.contains("대시보드"), "filler=\(standaloneFillers($0))") }),
        SuiteCase(category: "긴서술", name: "필러 제거+미절단", input: "어 그 우리가 지금 만들고 있는 이 도구가 어 로컬에서 도는 형태잖아 근데 어 그 장점이 뭐냐면 어 복잡한 작업도 어 바로바로 할 수 있다는 건데 음 근데 지금은 어 좀 기본적인 것만 되는 수준이라 어 그 확장 포인트를 좀 고민해 봐야 될 것 같아", style: .polish,
                  check: { (standaloneFillers($0) == 0 && endsCleanly($0) && $0.contains("확장"), "filler=\(standaloneFillers($0)) ends=\(endsCleanly($0))") }),
        SuiteCase(category: "나열형", name: "3항목→목록(첫째)", input: "어 이번에 할 게 세 가지인데 어 첫째는 로그인 고치고 둘째는 검색 개선하고 어 셋째는 알림 정리하는 거야", style: .structure,
                  check: { (hasNumberedList($0) && standaloneFillers($0) == 0, "list=\(hasNumberedList($0))") }),
        SuiteCase(category: "나열형", name: "3항목→목록(일단/그리고)", input: "어 개선할 거 정리하면 일단 홈 화면 통계 안 뜨는 거 고치고 그리고 검색 속도 좀 개선하고 마지막으로 온보딩 타임아웃 나는 거 봐야 돼", style: .structure,
                  check: { (hasNumberedList($0), "list=\(hasNumberedList($0))") }),
        SuiteCase(category: "자기정정", name: "최종 의도만 반영", input: "이번 스프린트에 알림 기능 넣자 아니 아니 다시 말하면 그건 다음으로 미루고 이번엔 검색 개선에 집중하자", style: .structure,
                  check: { ($0.contains("검색") && !$0.contains("알림 기능 넣"), "최종의도(검색) 반영") }),
        SuiteCase(category: "KO/EN", name: "영문 용어 보존", input: "그 SQLite FTS5 말고 LIKE 쿼리로 substring 매칭하는 게 낫더라고", style: .polish,
                  check: { (containsAll($0, ["SQLite", "LIKE", "substring"]), "용어 보존") }),
        SuiteCase(category: "안전:답변금지", name: "명령형 안 답함", input: "인공지능이 뭔지 간단하게 설명해 줘", style: .structure,
                  check: { ($0.count < 60 && !containsAny($0, ["인간", "컴퓨터", "기술을 말"]) && $0.contains("설명"), "len=\($0.count)") }),
        SuiteCase(category: "안전:답변금지", name: "요청형 안 답함", input: "파이썬으로 리스트 정렬하는 방법 좀 알려줘", style: .structure,
                  check: { ($0.count < 55 && !containsAny($0, ["sort", "메서드", "함수", "sorted"]), "len=\($0.count)") }),
        SuiteCase(category: "안전:관점", name: "설명 서술 유지", input: "타임리스는 처음엔 제한을 안 두다가 어느 정도 지나면 알림을 주는 방식이야", style: .structure,
                  check: { (!containsAny($0, ["어떨", "할까요", "하자", "제안"]), "제안화 안 됨") }),
        SuiteCase(category: "안전:말투", name: "반말 보존", input: "어 그 인디케이터가 가끔 안 뜨는 것 같은데 이거 좀 봐줘", style: .structure,
                  check: { (!isPolite($0), "존댓말화 안 됨") }),
        SuiteCase(category: "안전:앱이름", name: "앱이름 미주입", input: "이 코드가 너무 복잡해서 좀 정리하고 싶어", style: .polish,
                  check: { (!containsAny($0, ["VSCode", "com.microsoft", "사용 중인 앱"]), "누출 없음") }),
        SuiteCase(category: "3분구어체", name: "장문 필러제거+미절단+3주제", input: threeMin, style: .structure,
                  check: {
                      let f = standaloneFillers($0), ok = f == 0 && endsCleanly($0) && $0.count > threeMin.count / 3 && containsAll($0, ["홈 화면", "검색", "알림"])
                      return (ok, "filler=\(f) ends=\(endsCleanly($0)) len=\($0.count) 3주제=\(containsAll($0, ["홈 화면", "검색", "알림"]))")
                  }),
    ]

    print("╔══════════ REFINEMENT RELEASE GATE (\(cases.count) cases, live API) ══════════╗")
    var pass = 0
    for c in cases {
        let out = (try? await refiner(c.style).refine(c.input, context: RefinementContext())) ?? ""
        let (ok, reason): (Bool, String) = out.isEmpty ? (false, "빈 출력/실패") : c.check(out)
        if ok { pass += 1 }
        print("[\(ok ? "✅" : "❌")] \(c.category) · \(c.name)  —  \(reason)")
        if !ok { print("     OUT: \(out.replacingOccurrences(of: "\n", with: " ⏎ "))") }
    }
    let cov = cases.isEmpty ? 0 : Int((Double(pass) / Double(cases.count) * 100).rounded())
    print("╠════════════════════════════════════════════════════════════════╣")
    print("  COVERAGE: \(pass)/\(cases.count) = \(cov)%   →  \(cov >= 100 ? "PASS ✅ (배포 가능)" : "FAIL ❌ (배포 차단)")")
    print("╚════════════════════════════════════════════════════════════════╝")
    exit(cov >= 100 ? 0 : 1)
}
