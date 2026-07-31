#!/usr/bin/env bash
#
# Mechanical half of an hwhisper release: preflight → gate → version bump →
# build → package → verify → doc sync.
#
# The judgment half deliberately stays out of here — the commit message, the
# Korean release notes, and the choice of version number all need a human or a
# model. This script exists so the parts that are pure repetition cannot be
# mistyped or skipped, which is what actually went wrong before it existed:
# BUNDLE_VERSION was hand-edited with sed each time, and the version references
# in CLAUDE.md/BACKLOG.md were silently left stale across three releases.
#
# Usage: bash scripts/release.sh <NEW_VERSION>          e.g. 0.2.15
#        bash scripts/release.sh <NEW_VERSION> --dry-run
#
# On success it prints the exact remaining steps (commit/tag/push/publish),
# which the caller performs once the release text is written.

set -euo pipefail

die() { printf '\n\033[31m==> ABORT: %s\033[0m\n' "$1" >&2; exit 1; }
step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok() { printf '    \033[32m✓\033[0m %s\n' "$1"; }

[ $# -ge 1 ] || die "버전을 지정하세요. 예: bash scripts/release.sh 0.2.15"
NEW="$1"
DRY_RUN=false
[ "${2:-}" = "--dry-run" ] && DRY_RUN=true

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_SCRIPT="scripts/make-app.sh"
[ -f "$APP_SCRIPT" ] || die "$APP_SCRIPT 을 찾을 수 없습니다 (저장소 루트에서 실행하세요)"

# ---------------------------------------------------------------- preflight
step "Preflight"

[[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "버전 형식이 X.Y.Z 가 아닙니다: $NEW"

OLD="$(sed -n 's/^BUNDLE_VERSION="\(.*\)"$/\1/p' "$APP_SCRIPT")"
[ -n "$OLD" ] || die "$APP_SCRIPT 에서 BUNDLE_VERSION 을 읽지 못했습니다"
[ "$OLD" != "$NEW" ] || die "현재 버전과 동일합니다 ($OLD)"
# 되돌리는 릴리스를 실수로 찍는 일을 막는다.
[ "$(printf '%s\n%s\n' "$OLD" "$NEW" | sort -V | tail -1)" = "$NEW" ] \
  || die "새 버전이 현재 버전보다 낮습니다 ($OLD → $NEW)"
ok "버전 $OLD → $NEW"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[ "$BRANCH" = "main" ] || die "main 브랜치가 아닙니다 (현재: $BRANCH)"
ok "브랜치 main"

# make-app.sh 에 다른 미커밋 수정이 섞여 있는 것 자체는 정상이다 — 빌드 방식을
# 바꾸면서 함께 내보내는 릴리스가 실제로 있다(v0.2.15 유니버설 전환). 막아야 할
# 것은 BUNDLE_VERSION 줄이 *이미* 손대져 있는 경우뿐이다. 그때는 무엇을 기준으로
# 올리는 건지가 모호해진다.
COMMITTED_VER="$(git show "HEAD:$APP_SCRIPT" 2>/dev/null | sed -n 's/^BUNDLE_VERSION="\(.*\)"$/\1/p' || true)"
if [ -n "$COMMITTED_VER" ] && [ "$COMMITTED_VER" != "$OLD" ]; then
  die "BUNDLE_VERSION 이 이미 수정돼 있습니다 (커밋됨 $COMMITTED_VER / 작업본 $OLD) — 정리 후 실행하세요"
fi
ok "BUNDLE_VERSION 미선점 (커밋본과 일치)"

git rev-parse -q --verify "refs/tags/v$NEW" >/dev/null \
  && die "태그 v$NEW 가 이미 존재합니다"
git ls-remote --exit-code --tags origin "refs/tags/v$NEW" >/dev/null 2>&1 \
  && die "원격에 태그 v$NEW 가 이미 존재합니다"
ok "태그 v$NEW 미사용"

command -v gh >/dev/null || die "gh CLI 가 없습니다"
gh auth status >/dev/null 2>&1 || die "gh 인증이 필요합니다 (gh auth login)"
ok "gh 인증됨"

if $DRY_RUN; then
  printf '\n\033[33m==> --dry-run: 여기서 중단합니다. 게이트/빌드는 실행하지 않았습니다.\033[0m\n'
  exit 0
fi

# --------------------------------------------------------------- 릴리스 게이트
# 품질 게이트는 건너뛸 수 있는 옵션을 두지 않는다 — 건너뛸 수 있으면 언젠가 건너뛴다.
step "릴리스 게이트 (정제 회귀 스위트, 실 API — 수 분 소요)"
bash scripts/release-gate.sh || die "게이트 실패 — 배포를 중단합니다"
ok "게이트 통과"

# ------------------------------------------------------------ 버전 반영 + 빌드
step "버전 반영 및 빌드"
sed -i '' "s/^BUNDLE_VERSION=\"$OLD\"$/BUNDLE_VERSION=\"$NEW\"/" "$APP_SCRIPT"
grep -q "^BUNDLE_VERSION=\"$NEW\"$" "$APP_SCRIPT" || die "BUNDLE_VERSION 치환 실패"
ok "$APP_SCRIPT BUNDLE_VERSION=$NEW"

bash scripts/make-app.sh >/dev/null || die "앱 번들 빌드 실패"
bash scripts/make-dmg.sh >/dev/null || die "DMG 생성 실패"
ok "앱 번들 + DMG 생성"

# ------------------------------------------------------------------ 산출물 검증
# "빌드 통과 ≠ 완료" — 번들에 박힌 버전과 DMG 파일명이 실제로 일치하는지 본다.
step "산출물 검증"
DMG="dist/hwhisper-$NEW.dmg"
[ -f "$DMG" ] || die "$DMG 가 없습니다"
PLIST_VER="$(defaults read "$REPO_ROOT/dist/Hwhisper.app/Contents/Info.plist" CFBundleShortVersionString)"
[ "$PLIST_VER" = "$NEW" ] || die "번들 버전 불일치: Info.plist=$PLIST_VER, 기대=$NEW"
ok "Info.plist CFBundleShortVersionString = $NEW"
ok "$DMG ($(du -h "$DMG" | cut -f1))"

# --------------------------------------------------------------- 문서 버전 동기화
# 이 단계가 없어서 CLAUDE.md/BACKLOG.md 가 세 릴리스 동안 v0.2.11 에 멈춰 있었다.
step "문서 버전 동기화"
TODAY="$(date +%Y-%m-%d)"
sync() { # file, sed-expr, verify-pattern, label
  [ -f "$1" ] || { printf '    - %s 없음 — 건너뜀\n' "$1"; return 0; }
  sed -i '' "$2" "$1"
  if grep -q "$3" "$1"; then ok "$4"; else printf '    \033[33m! %s — 패턴을 못 찾아 수동 확인 필요\033[0m\n' "$4"; fi
}
sync CLAUDE.md "s/\*\*현재 릴리스: v$OLD\*\* ([0-9-]*)/**현재 릴리스: v$NEW** ($TODAY)/" \
     "현재 릴리스: v$NEW" "CLAUDE.md 현재 릴리스 → v$NEW ($TODAY)"
sync CLAUDE.md "s/BUNDLE_VERSION\` 올림 (현재 $OLD)/BUNDLE_VERSION\` 올림 (현재 $NEW)/" \
     "올림 (현재 $NEW)" "CLAUDE.md 릴리스 워크플로우 현재 버전"
sync BACKLOG.md "s/^# hwhisper 백로그 ([0-9-]* 현행화 — v$OLD 배포됨)/# hwhisper 백로그 ($TODAY 현행화 — v$NEW 배포됨)/" \
     "v$NEW 배포됨" "BACKLOG.md 헤더"
sync BACKLOG.md "s/릴리스 v0\.2\.0~v$OLD\./릴리스 v0.2.0~v$NEW./" \
     "v0.2.0~v$NEW" "BACKLOG.md 릴리스 범위"

# ----------------------------------------------------------------- 남은 단계 안내
cat <<EOF

$(printf '\033[32m==> 기계적 단계 완료 — v%s 배포 준비됨\033[0m' "$NEW")

남은 단계 (릴리스 문구가 필요해 자동화하지 않음):

  1. 커밋 메시지 작성 후:
       git add scripts/make-app.sh <이번에 바뀐 소스 파일들>
       git commit        # 끝에 Co-Authored-By 트레일러
  2. git tag -a v$NEW -m "hwhisper v$NEW — <한 줄 요약>"
  3. git push origin main && git push origin v$NEW
  4. gh release create v$NEW $DMG --title "hwhisper v$NEW" --notes "<릴리스 노트>"
  5. 검증: gh release view v$NEW --json tagName,isDraft,assets
  6. 앱 재실행: pkill -f "Hwhisper.app/Contents/MacOS/Hwhisper"; open dist/Hwhisper.app

  베타 다운로드 페이지는 GitHub Releases 를 직접 읽으므로 별도 조치 불필요.
  (CLAUDE.md·BACKLOG.md 는 gitignore 라 커밋 대상이 아님 — 위에서 이미 갱신됨)
EOF
