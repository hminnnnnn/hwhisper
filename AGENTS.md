# AGENTS.md — 이 저장소의 에이전트 도구 목록

프로젝트 맥락·아키텍처·함정은 **`CLAUDE.md`**(로컬 전용)에 있다. 이 파일은 **"이 저장소에
무엇이 준비돼 있는지"의 목록**만 담는다 — 스킬이나 테스트 훅을 추가·삭제하면 여기를 갱신한다.

## 스킬

| 스킬 | 경로 | 언제 |
|---|---|---|
| `hwhisper-release` | `.claude/skills/hwhisper-release/SKILL.md` | 패치 릴리스 전 과정. 기계적 단계는 `scripts/release.sh`, 판단(버전·커밋 메시지·릴리스 노트)만 사람이 |

## 자동화 스크립트

| 스크립트 | 하는 일 |
|---|---|
| `scripts/release.sh <버전>` | preflight → 릴리스 게이트 → 버전 반영 → 빌드 → 산출물 검증 → 문서 동기화. `--dry-run`은 preflight까지만 |
| `scripts/release-gate.sh` | 정제 회귀 스위트 26케이스(실 API, best-of-3 과반). **실패 시 배포 차단** |
| `scripts/make-app.sh` / `make-dmg.sh` | 유니버설 앱 번들 + 서명 / DMG |
| `scripts/shoot.sh OUT.png [훅…]` | 창 단독 캡처(포커스·오디오 없이). **인라인 bash로 재작성 금지** |
| `scripts/e2e-pipeline-test.sh <wav> <label>` | 파이프라인 E2E 러너 |
| `scripts/refine-hygiene-test.sh` | 정제기 로그 위생·오류 경로 8시나리오(실 Gemini+로컬 스텁 — 키 유출·전사 에코·청크 열화 로그). **정제기 오류 처리/로그 수정 시 필수 재실행** |

## 테스트 훅 (앱 실행 인자)

권한·키보드·합성 시스템 키 없이 도는 것부터 위험한 것 순.

| 훅 | 검증 대상 | 안전성 |
|---|---|---|
| `--test-hotkey-clock` | 단일키 탭 판정 6종 (함정 27) | 완전 안전 |
| `--test-home-stats` | 홈 주간 추이 버킷 7종 | 완전 안전 |
| `--test-history-aggregate` | 히스토리 집계 == 행별 합계, `word_count` 백필 정확·멱등, `metrics`==`aggregate` | 안전 — **실 DB 사본**에서만 돌고 끝나면 지움 |
| `--test-home-period-cycle` | 구간 전환이 재계산을 유발하는지 | 안전. **`-homeStatsPeriod` 인자와 함께 쓰지 말 것**(NSArgumentDomain이 가림) |
| `--test-indicator` / `--test-warning` / `--test-countdown` / `--test-refining-slow` / `--test-indicator-race` | 인디케이터 렌더·레이스 | 안전(창 캡처용) |
| `--open-main` / `--open-onboarding` / `--open-settings` | 창 표시 (`--no-activate`로 포커스 유지) | 안전 |
| `--test-pipeline <wav>` | 전체 파이프라인 E2E | **주의: 실제 삽입이 일어나고 히스토리에 행이 쌓임**. CLAUDE.md의 주의 3건 확인 후 사용 |

## 갱신 규칙

- 스킬·훅·스크립트를 **추가하거나 지우면 이 표를 같이 고친다.**
- 상세 설명은 여기 쓰지 말고 `CLAUDE.md`에 두고 여기서는 한 줄로만 가리킨다 — 두 곳에 같은 설명을 두면 한쪽이 반드시 낡는다.
