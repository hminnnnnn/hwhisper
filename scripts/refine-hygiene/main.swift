import Foundation

// hwhisper 실 API 경로 검증 하네스 (2026-08-25 감사 후속).
// 실제 OpenAICompatibleRefiner.swift/TextRefiner.swift 소스를 그대로 컴파일해
// ①실 Gemini 성공 경로 ②404 ③URLError 키 유출 방지 ④엔드포인트 정책
// ⑤에코 서버 전사 유출 방지 ⑥에러 봉투 통과 ⑦청크 열화 로그를 검증한다.

var failures = 0
func check(_ name: String, _ ok: Bool, detail: String = "") {
    print("\(ok ? "✅" : "❌") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    if !ok { failures += 1 }
}

func geminiKey() -> String? {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Hwhisper/credentials.json")
    guard let data = try? Data(contentsOf: url),
          let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] else { return nil }
    return dict["gemini"]
}

func errMessage(_ error: Error) -> String {
    if case TextRefinerError.requestFailed(let m)? = error as? TextRefinerError { return m }
    return "\(error)"
}

func run() async {
    // ── S4: 엔드포인트 정책 (네트워크 불필요, 먼저) ─────────────────────
    let httpRemote = URL(string: "http://attacker.example/chat/completions")!
    let httpsQuery = URL(string: "https://ok.example/chat?key=abc")!
    let httpLocal = URL(string: "http://localhost:11434/v1/chat/completions")!
    let httpsClean = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
    check("S4a 정책: http 원격 거부", RefinerEndpointPolicy.rejectionReason(for: httpRemote) != nil)
    check("S4b 정책: 쿼리 스트링 거부", RefinerEndpointPolicy.rejectionReason(for: httpsQuery) != nil)
    check("S4c 정책: http localhost 허용", RefinerEndpointPolicy.rejectionReason(for: httpLocal) == nil)
    check("S4d 정책: https 무쿼리 허용", RefinerEndpointPolicy.rejectionReason(for: httpsClean) == nil)

    // ── S3: URLError 키 유출 방지 (DNS 실패 유도, 실 키 불필요) ──────────
    do {
        let badURL = URL(string: "https://hwhisper-nonexistent-host-zz.invalid/v1/chat/completions?key=FAKESECRET123")!
        let refiner = OpenAICompatibleRefiner(config: .init(endpoint: badURL, model: "m", apiKey: "k", timeout: 10))
        do {
            _ = try await refiner.refine("테스트 문장입니다.", context: RefinementContext())
            check("S3 URLError 경로 도달", false, detail: "요청이 성공해버림(?)")
        } catch {
            let m = errMessage(error)
            check("S3a URLError에 키 미포함", !m.contains("FAKESECRET123"), detail: m)
            check("S3b URLError에 URL덤프 미포함", !m.contains("NSErrorFailing") && !m.contains("?key="), detail: m)
            check("S3c 메시지가 코드+호스트 형태", m.contains("URLError") || m.contains("timedOut") || m.contains("transport"), detail: m)
        }
    }

    guard let key = geminiKey(), !key.isEmpty else {
        check("Gemini 키 로드", false, detail: "credentials.json에서 gemini 키를 읽지 못함")
        return
    }
    let gemini = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!

    // ── S1: 실 Gemini 정상 정제 + 같은 refiner 재사용(세션 재사용 경로) ──
    do {
        let refiner = OpenAICompatibleRefiner(config: .init(
            endpoint: gemini, model: "gemini-3.1-flash-lite", apiKey: key, timeout: 20, style: .polish))
        let t0 = Date()
        let out1 = try await refiner.refine("어 음 이거는 그 연결 테스트 문장인데요 어 필러가 좀 있어요.", context: RefinementContext())
        let d1 = -t0.timeIntervalSinceNow
        check("S1a 실 Gemini 정제 성공", !out1.isEmpty, detail: "\(String(format: "%.2f", d1))s, \(out1.count)자")
        check("S1b 필러 제거 동작", !out1.contains("어 음"), detail: out1.prefix(60).description)
        let t1 = Date()
        let out2 = try await refiner.refine("두 번째 호출은 같은 세션을 재사용합니다.", context: RefinementContext())
        let d2 = -t1.timeIntervalSinceNow
        check("S1c 동일 refiner 2번째 호출 성공(세션 재사용)", !out2.isEmpty,
              detail: String(format: "1st %.2fs → 2nd %.2fs", d1, d2))
    } catch {
        check("S1 실 Gemini 정제", false, detail: errMessage(error))
    }

    // ── S2: 실 Gemini 404 (없는 모델) — 본문 미유출 + 봉투 요약 ─────────
    do {
        let refiner = OpenAICompatibleRefiner(config: .init(
            endpoint: gemini, model: "hwhisper-nonexistent-model-zz", apiKey: key, timeout: 20))
        _ = try await refiner.refine("사영이일이삼 검증 문장.", context: RefinementContext())
        check("S2 404 도달", false, detail: "성공해버림(?)")
    } catch {
        let m = errMessage(error)
        check("S2a 404가 상태코드로 요약됨", m.contains("HTTP 404"), detail: m)
        check("S2b 요청 본문(transcript) 미에코", !m.contains("사영이일이삼") && !m.contains("messages"), detail: m)
        check("S2c 길이 상한(원시 body 200자 덤프 아님)", m.count < 200, detail: "\(m.count)자")
    }

    // ── S5~S7: 로컬 스텁 서버 (127.0.0.1:18765) ────────────────────────
    let stub = URL(string: "http://localhost:18765/v1/chat/completions")!
    check("S5-pre 정책: 스텁(localhost) 허용", RefinerEndpointPolicy.rejectionReason(for: stub) == nil)

    // S5: 422 에코 서버 — 전사·센티널이 에러 문자열에 절대 실리면 안 됨
    do {
        let refiner = OpenAICompatibleRefiner(config: .init(endpoint: stub, model: "echo-422", apiKey: "k", timeout: 10))
        _ = try await refiner.refine("절대유출금지구팔칠육 이라는 문장.", context: RefinementContext())
        check("S5 422 도달", false, detail: "성공해버림(?)")
    } catch {
        let m = errMessage(error)
        check("S5a 422 비봉투 body는 상태만 남음", m.contains("HTTP 422"), detail: m)
        check("S5b 센티널 미유출", !m.contains("SENTINEL-ECHO-XYZ"), detail: m)
        check("S5c 전사 미유출", !m.contains("절대유출금지구팔칠육"), detail: m)
    }

    // S6: OpenAI 봉투형 404 → code+message(120자 상한)는 통과해야 함
    do {
        let refiner = OpenAICompatibleRefiner(config: .init(endpoint: stub, model: "envelope-404", apiKey: "k", timeout: 10))
        _ = try await refiner.refine("봉투 테스트.", context: RefinementContext())
        check("S6 404 도달", false)
    } catch {
        let m = errMessage(error)
        check("S6 봉투 code/message 통과", m.contains("HTTP 404") && m.contains("model not found here"), detail: m)
    }

    // S7: 청크 경로 열화 — >2400자, "ZZFAIL" 포함 청크만 500 → 부분 raw 폴백 + diagnosticLog
    do {
        let sentence = "이 문장은 청크 분할 검증을 위해 반복되는 평범한 한국어 문장입니다. "
        var long = String(repeating: sentence, count: 60)   // ~2,100자
        long += "ZZFAIL 이 표식이 든 청크는 스텁이 오백으로 거절합니다. "
        long += String(repeating: sentence, count: 20)      // 총 ~2,900자 → 2청크
        nonisolated(unsafe) var captured: [String] = []
        let refiner = OpenAICompatibleRefiner(config: .init(
            endpoint: stub, model: "selective", apiKey: "k", timeout: 15, style: .structure,
            diagnosticLog: { captured.append($0) }))
        let out = try await refiner.refine(long, context: RefinementContext())
        check("S7a 청크 부분 실패에도 전체 결과 반환", !out.isEmpty && out.contains("ZZFAIL"),
              detail: "결과 \(out.count)자(실패 청크는 raw 유지)")
        check("S7b diagnosticLog에 열화 기록", captured.contains { $0.contains("refinement degraded") },
              detail: captured.first ?? "(없음)")
        check("S7c 성공 청크는 정제됨(스텁 응답 반영)", out.contains("REFINED-BY-STUB"), detail: out.prefix(50).description)
    } catch {
        check("S7 청크 경로", false, detail: errMessage(error))
    }
}

let sem = DispatchSemaphore(value: 0)
Task { await run(); sem.signal() }
sem.wait()
print("\n\(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")")
exit(failures == 0 ? 0 : 1)
