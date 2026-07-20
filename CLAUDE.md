# hwhisper — 개인용 로컬 우선 macOS 딕테이션 앱

전역 단축키 → 온디바이스 STT(한/영) → LLM 정제(다듬기/구조화) → 활성 커서에 삽입.
Wispr Flow/Typeless의 오픈소스·무료·프라이버시 대체재. 기획·ADR: `.omc/plans/hwhisper.md`, 백로그: `BACKLOG.md`.

## 빌드·실행

```bash
swift build                  # 디버그 (CLT-only 호스트 — xcodebuild 없음/불필요)
bash scripts/make-app.sh     # dist/Hwhisper.app 번들 + hwhisper-dev 인증서 서명 (버전은 스크립트 BUNDLE_VERSION)
bash scripts/make-dmg.sh     # dist/hwhisper-<버전>.dmg (hdiutil, 공증 아님 — 첫 실행 xattr 안내 동봉)
open dist/Hwhisper.app
```

- **배포**: README 한글 메인 + `README.en.md` 영문. 공증($99)은 비상업 목적엔 선택 — 무료 경로(소스 빌드 / self-signed dmg + `xattr -dr com.apple.quarantine` 1회). 근거: `.omc/plans/v0.3-distribution.md`.

- **서명**: 키체인의 self-signed `hwhisper-dev` 인증서로 자동 서명 → **재빌드해도 TCC(마이크/손쉬운 사용) 권한 유지**. 인증서 없으면 ad-hoc 폴백(권한 리셋됨). 재생성: `scripts/make-signing-cert.sh`.
- **디버그 루프**: `.build/debug/HwhisperMac --open-settings` 터미널 직접 실행 — 권한이 터미널에 귀속되어 재빌드 무관. 단 unbundled는 UserDefaults 도메인이 다르고(코드 기본값 사용) UserNotifications 비활성.
- 로그: `~/Library/Logs/Hwhisper.log` (상태 전이·전사·정제·삽입 전부 기록 — 디버깅 1차 소스).

## 아키텍처 (계획 §3)

- `Sources/HwhisperCore/` — 플랫폼 무관(AppKit 금지, iOS 재사용 대비): `SpeechRecognizer` 프로토콜(AppleSpeechRecognizer=기본 B1, WhisperKitRecognizer=폴백 B2), `TextRefiner`(OpenAICompatibleRefiner: Gemini/Groq/Ollama/커스텀 단일 클라이언트, RefinementStyle polish/structure), `PipelineActor`(§3.1 상태머신: idle→listening→transcribing→refining→inserting→restoring, 큐 depth3), `EnergyVAD`(적응형 임계값 — 고정 임계값은 조용한 발화를 자르는 버그였음).
- `Sources/HwhisperMac/` — 앱: `AppDelegate`(UI 어댑터+파이프라인 배선), `SingleKeyHotkey`(우측⌘/우측⌥/fn 단독 탭, flagsChanged 모니터), `GlobalHotkey`(KeyboardShortcuts 조합키 — **1.15.0 핀 고정, 1.16.0+는 #Preview가 CLT에서 컴파일 불가**), `RecordingIndicator`(유리 필+웨이브폼), `Insertion/`(C1 클립보드+⌘V 기본, AX는 TextEdit/Notes 화이트리스트+read-back 검증, TargetContextSnapshot AC8, 보안필드 TOCTOU), `CredentialStore`(**API 키는 키체인 아님** — `~/Library/Application Support/Hwhisper/credentials.json` 0600; 키체인은 self-signed ACL 반복 프롬프트 버그로 폐기), `SettingsWindow`, `WelcomeWindow`, `MainWindow`(독립 앱 셸: 사이드바 히스토리/설정, 창 열림 시 .regular 승격·닫힘 시 .accessory 복귀, `--open-main` 테스트 훅), 히스토리 배선은 `insertAndReport`→`recordHistory`(raw/정제 쌍 저장, `HistorySettings` 토글).
- 히스토리 저장소: Core의 `SQLiteHistoryStore` — LIKE 부분 문자열 검색(FTS5 unicode61은 한국어 부분일치를 놓쳐 채택 안 함), `history.sqlite3` 0600, actor 격리(OpaquePointer는 @unchecked Sendable Connection 홀더로 deinit 처리).
- 개인 사전: Core의 `FilePersonalDictionary`(`dictionary.json` 0600, 원자적 저장) — N-3 3중 방어: `contextualStrings` 바이어싱 + `protectedTerms` 정제 보호 + last-mile 치환(`insertAndReport` 첫 단계, 최장 변형 우선·대소문자 무시). UI는 메인 창 "개인 사전" 탭. 사전 편집은 다음 딕테이션부터 즉시 반영(파이프라인이 매번 actor에서 읽음 — 캐시 무효화 배선 불필요).
- `Sources/HwhisperEval/` — 엔진 베이크오프 하네스 (`--probe <id>` 단일 픽스처 진단). 데이터: `.omc/research/m0-bakeoff.md`.

## 반드시 알아야 할 함정 (재발 방지)

1. **테스트 시 전역 핫키 합성 전 `lsappinfo front` 확인 — 메신저(카카오톡/Slack/Discord)가 전면이면 절대 금지.** 실제 오삽입 사고 2회 있었음. TextEdit를 먼저 전면에 띄우고 테스트할 것. 실행 중인 dist 앱과 디버그 앱을 동시에 띄우면 핫키가 둘 다 발동함 — 동시 실행 금지.
2. **AssetInventory.reserve()는 false 반환이 정상일 수 있음** (이미 예약됨) — 실패로 취급하면 안 됨. 예약은 번들ID 단위 영구 보존.
3. **SecItemCopyMatching은 프롬프트에서 스레드를 영구 블록** — task group 타임아웃으로 구제 불가(그룹이 블록된 자식을 기다림). 블록 가능한 동기 호출은 unstructured detached + 마감 폴링으로 격리할 것 (AppDelegate.fetchAPIKey 패턴).
4. **SpeechAnalyzer 협상 포맷은 Float32가 아니라 Int16일 수 있음** — makePCMBuffer가 commonFormat 분기 처리함.
5. **Gemini 모델명은 은퇴됨** — 2026-07 기준 유효: `gemini-3.1-flash-lite`. 404 "no longer available" 뜨면 모델명 갱신.
6. `swift test`는 이 CLT 설치의 swift-testing 결함으로 실행 출력이 없음 (빌드는 정상) — 전체 Xcode 설치 시 해소. 핵심 로직 검증은 독립 swiftc 컴파일 테스트 또는 HwhisperEval로.
   - **엔진 라우팅(D3)**: macOS 26+는 Apple B1, 26미만은 WhisperKit B2 자동 폴백(`processQueuedJob` `#available(macOS 26)` 분기). 26 기기에선 else 분기가 도달 불가라 라우팅은 인텔/구형 Mac에서만 실검증 가능. WhisperKit 엔진 자체는 `HwhisperEval --probe <id>`로 검증(모델 `~/Documents/huggingface/...632MB` 캐시). **WhisperKit 첫 추론은 CoreML 최초 컴파일로 수 분** 소요(로드 10s + 첫 transcribe 343s 관측) → 이후 빠름. "준비 중" 인디케이터로 커버.
7. 상태 전이·삽입 결과는 전부 HwhisperLog에 남김 — 무음 실패 금지 원칙 (과거 "성공 경로 무로그"가 디버깅을 막았음).

## 검증 원칙

빌드 통과 ≠ 완료. E2E는 실제로: 앱 실행 → 우측⌘ CGEvent 탭(keycode 54) → `afplay fixtures/audio/*.wav`(스피커→마이크) → 탭 → 로그에서 transcribed/refinement/insertion outcome 확인 → 대상 앱 내용 확인(AX read 또는 스크린샷). 픽스처는 TTS(say Yuna/Samantha) — 실육성 검증과 구분해 보고할 것.

## 브랜드 (v1, 2026-07-20)

- 「먹(ink) × 청자(celadon)」 — 근거·규칙: `.omc/research/brand-identity.md`, 보드: claude.ai/code/artifact/2f1170ff-361e-43c2-a7b7-56185ee99963
- 팔레트 단일 소스: `Sources/HwhisperMac/BrandTheme.swift` ↔ `scripts/render-app-icon.swift` 동시 갱신 → `swift scripts/render-app-icon.swift assets` 재생성
- 인앱 브랜드: 메인 창은 시스템 라이트/다크 무관 **먹 다크 고정**(window.appearance=darkAqua + inkDeep 배경 + 투명 타이틀바), 사이드바 브랜드 헤더(BrandGlyph+워드마크). List 행 내부 borderless 버튼은 상위 .tint가 안 닿음 — 청자 foregroundStyle 직접 지정 필요(복사 버튼 사례). 창 표시는 "main window shown" 로그로 증명(--no-activate 훅으로 포커스 없이 검증 가능).

## 개인 사전 함정 (2026-07-20 실버그)

- **정제기 protectedTerms는 원문에 실제 등장하는 용어만 전달할 것.** 사전의 모든 용어를 무조건 "이 용어 유지하라"로 LLM에 주면, 지시형 문장에서 LLM이 그 용어를 수신자로 오판해 없던 문장을 지어냄(실사고: 원문에 없는 "오웬, 브리핑해 주세요" 주입). `FilePersonalDictionary.protectedTerms(presentIn:)` 사용 — 용어 또는 그 변형이 원문에 있을 때만 canonical 용어 보호.
- **last-mile 치환에서 ASCII 변형(예 "ON")은 단어 경계 필수.** 부분문자열 매칭이면 "conference"→"c오웬ference"로 단어 내부 오염. `isWholeWord`로 ASCII 영숫자 변형만 경계 검사, 한글 변형은 기존 부분문자열 유지.
