---
name: hwhisper-release
description: hwhisper 패치 릴리스를 끝까지 수행한다 — 릴리스 게이트, 버전 반영, 빌드/DMG, 문서 동기화, 커밋·태그·푸시, GitHub Release 발행, 검증까지. "릴리스 해줘", "vX.Y.Z 배포", "패치 내보내자" 같은 요청에 사용.
---

# hwhisper 릴리스

기계적인 절차는 `scripts/release.sh`가 처리한다. 이 스킬은 **자동화할 수 없는 판단**만 담당한다: 버전 결정, 커밋 메시지, 한국어 릴리스 노트, BACKLOG 항목, 그리고 결과 검증.

## 이 스킬이 존재하는 이유

같은 10단계를 손으로 반복하다 실제로 사고가 났다. `BUNDLE_VERSION`을 매번 `sed`로 직접 고쳤고, CLAUDE.md·BACKLOG.md의 버전 표기는 **세 릴리스 동안 갱신되지 않은 채 방치**됐다(BACKLOG는 릴리스 항목 3개가 통째로 누락). 반복 구간을 스크립트로 굳히고, 글이 필요한 부분만 사람이 쓴다.

## 절차

### 1. 버전 결정

사용자가 버전을 지정하지 않았으면 **변경 성격을 보고 제안한 뒤 확인받는다**. 기본은 패치 증가(`0.2.14` → `0.2.15`). 사용자 대면 동작이 바뀌지 않는 개발 도구·문서 변경이면 **릴리스를 만들지 말고** 그냥 커밋만 하라고 제안한다.

### 2. 기계적 단계 실행

```bash
bash scripts/release.sh <NEW_VERSION>
```

이 스크립트가 하는 일 — 직접 반복하지 말 것:

- **Preflight**: 버전 형식, 하향 방지, `main` 브랜치, `make-app.sh` 클린, 태그 중복(로컬·원격), `gh` 인증
- **릴리스 게이트**(`release-gate.sh`) — 실패 시 중단. **건너뛰는 옵션은 없고, 만들지도 말 것**
- `BUNDLE_VERSION` 치환 → `make-app.sh` → `make-dmg.sh`
- **산출물 검증**: `Info.plist`의 `CFBundleShortVersionString`과 DMG 파일명이 실제로 새 버전인지 대조
- **문서 동기화**: CLAUDE.md 2곳, BACKLOG.md 2곳의 버전·날짜 표기

먼저 확인만 하려면 `bash scripts/release.sh <VER> --dry-run`(preflight까지만, 게이트·빌드 없음).

스크립트가 중단되면 **그 원인을 해결하기 전에는 다음 단계로 가지 않는다.** 특히 게이트 실패는 정제 품질 회귀 신호다.

### 3. 릴리스 문구 작성 (판단 영역)

**커밋 메시지** — 저장소 관례를 따른다:
- 영문, 명령형 제목 한 줄 + 빈 줄 + 본문
- 본문은 *무엇을 고쳤는지*보다 **왜 그게 문제였는지와 근거 수치**를 쓴다. 이 저장소의 기존 커밋들이 그렇게 되어 있다(예: "9 of 121 in this app's own history (7.4%)")
- 끝에 `Co-Authored-By:` 트레일러 — **실제로 작업한 모델명**으로

**릴리스 노트** — 한국어, 사용자 관점:
- 무엇이 달라졌는지를 먼저 쓰고 내부 구현은 뒤에
- 측정값이 있으면 표로 넣는다(before/after)
- 마지막에 게이트 결과와 "공증되지 않은 빌드 — README의 'Install' 참고" 고지

**BACKLOG.md 릴리스 항목** — 스크립트는 헤더만 동기화한다. `## vX.Y.Z (배포됨 …)` 섹션은 직접 추가할 것. **이걸 빼먹은 게 실제 사고였다.** 최신순 정렬을 유지하고, 상세는 CLAUDE.md 함정 번호로 참조해 중복을 줄인다.

**재발 방지가 필요한 버그였다면** CLAUDE.md 함정 목록에도 추가한다 — 원인·실측치·진단 신호·교훈까지.

### 4. 커밋 · 태그 · 푸시

```bash
git add scripts/make-app.sh <이번에 바뀐 소스 파일들>   # 파일을 명시할 것
git commit -F -   # 위에서 쓴 메시지
git tag -a vX.Y.Z -m "hwhisper vX.Y.Z — <한 줄 요약>"
git push origin main && git push origin vX.Y.Z
```

**`git add -A`/`git add .` 금지.** `scratchpad/`와 도구 산출물이 딸려 들어간다. CLAUDE.md·BACKLOG.md는 gitignore라 커밋 대상이 아니다(로컬에만 갱신됨).

### 5. 발행 및 검증

```bash
gh release create vX.Y.Z dist/hwhisper-X.Y.Z.dmg --title "hwhisper vX.Y.Z" --notes "<노트>"
gh release view vX.Y.Z --json tagName,isDraft,assets -q '{tag:.tagName,draft:.isDraft,assets:[.assets[].name]}'
```

**두 번째 명령의 출력을 확인하기 전에는 배포 완료라고 말하지 않는다.** draft가 아니고 DMG가 첨부됐는지 눈으로 본다.

베타 다운로드 페이지(https://hwhisper-beta.vercel.app)는 GitHub Releases API를 직접 읽으므로 **별도 조치가 필요 없다**. 페이지 디자인·문구를 고쳤을 때만 `cd web/hwhisper-beta && vercel --prod --yes`.

### 6. 앱 재실행

```bash
pkill -f "Hwhisper.app/Contents/MacOS/Hwhisper"; open dist/Hwhisper.app
tail -2 ~/Library/Logs/Hwhisper.log   # 새 버전으로 떴는지 확인
```

디스크의 `.app`을 새로 빌드해도 **실행 중인 프로세스는 이전 바이너리 그대로**다. 재실행하지 않으면 사용자는 수정 내용을 못 받는다 — 매번 확인할 것.

### 7. 보고

`✓ 검증됨(실행 증거)` / `⚠ 미검증(이유)` / `✗ 실패` 3단계로 구분한다. 실기기·실육성으로만 확인 가능한 항목은 **미검증으로 명시하고 사용자에게 확인을 요청**한다 — "될 거예요" 금지.

## 함정

- **게이트는 LLM 비결정성 때문에 케이스당 3회 중 과반**으로 판정한다. 단발 실패를 회귀로 단정하지 말고, 반대로 게이트 통과가 신뢰성(타임아웃·raw 폴백)까지 보증하지는 않는다.
- 게이트는 `credentials.json`의 Gemini 키를 쓴다(BYOK). 키가 없으면 배포 불가.
- 정제 프롬프트나 정제 코드를 건드렸다면 `RefineSuite.swift`에 케이스를 추가해 커버리지를 유지한다.
