#!/usr/bin/env bash
#
# shoot.sh — 프라이버시 안전 UI 스크린샷 헬퍼 (디버그 빌드).
#
# 디버그 바이너리를 주어진 launch-arg 훅으로 띄우고, Hwhisper.log에서 그
# 창의 번호를 읽어 **그 창만** 단독 캡처(screencapture -l)한 뒤 정리한다.
# 영역(-R) 캡처는 뒤 배경의 실제 딕테이션/개인정보를 함께 담을 수 있어 절대
# 쓰지 않는다(함정 #1·검증 원칙). --no-activate를 항상 주입해 포커스를 뺏지
# 않는다.
#
# 사용법:
#   bash scripts/shoot.sh OUT.png [launch-args...]
#
# 예:
#   bash scripts/shoot.sh home.png -themeMode light --open-main --open-section home
#   bash scripts/shoot.sh onb.png  --open-onboarding --onboarding-page 4 -themeMode dark
#   bash scripts/shoot.sh ind.png  --test-indicator -themeMode light
#
# 프라이버시 샌드박스 (권장 — 홈/히스토리/사전 캡처):
#   SHOOT_HOME=/path/to/fakehome bash scripts/shoot.sh home.png --open-main
# 로 실행하면 `CFFIXED_USER_HOME`으로 앱의 홈 디렉터리를 갈아끼워
# 히스토리 DB·사전·로그·UserDefaults가 전부 그 디렉터리 안에서 생성된다.
# 실제 딕테이션 데이터(~/Library/Application Support/Hwhisper)를 아예 열지
# 않으므로 "백업 → 샘플 교체 → 복원" 없이도 공개 캡처가 안전하다.
# (검증: HOME만 바꿔도 앱은 실제 홈을 쓴다 — CFFIXED_USER_HOME이 필요.)
#
# 참고:
# - --open-onboarding가 없으면 `-onboardingCompleted YES`를 자동 주입해 첫 실행
#   온보딩 오버레이가 메인/설정 캡처를 가리지 않게 한다.
# - dist 앱(Hwhisper.app)이 실행 중이면 디버그 바이너리와 전역 핫키가 둘 다
#   발동하니(함정 #1) 캡처 전에 dist 앱을 꺼 두는 걸 권장. 이 스크립트는
#   디버그 바이너리(HwhisperMac)만 정리한다.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: bash scripts/shoot.sh OUT.png [launch-args...]" >&2
  exit 2
fi

OUT="$1"; shift
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/.build/debug/HwhisperMac"
APP_HOME="${SHOOT_HOME:-$HOME}"
LOG="$APP_HOME/Library/Logs/Hwhisper.log"

if [[ ! -x "$BIN" ]]; then
  echo "shoot.sh: $BIN 없음 — 먼저 'swift build' 하세요." >&2
  exit 1
fi

# --open-onboarding를 요청하지 않은 캡처는 온보딩 오버레이를 눌러 둔다.
EXTRA=()
if [[ " $* " != *" --open-onboarding "* ]]; then
  EXTRA+=("-onboardingCompleted" "YES")
fi

# 이전 디버그 인스턴스 정리(핫키 이중 발동 방지). dist 앱은 건드리지 않음.
pkill -f "$BIN" 2>/dev/null || true
sleep 1

# 로그를 바이트 오프셋으로 자른다. macOS `wc`는 공백 패딩이 있어 반드시 trim.
# (`tail -n +N`은 이 패딩 때문에 깨졌던 실패를 반복하지 않도록 -c 사용.)
LOG_START=0
[[ -f "$LOG" ]] && LOG_START="$(wc -c < "$LOG" | tr -d ' ')"

# `${EXTRA[@]+...}`: macOS의 bash 3.2에서 빈 배열 확장이 `set -u`로 죽는 것 방지.
if [[ -n "${SHOOT_HOME:-}" ]]; then
  mkdir -p "$SHOOT_HOME"
  env CFFIXED_USER_HOME="$SHOOT_HOME" HOME="$SHOOT_HOME" \
    "$BIN" --no-activate ${EXTRA[@]+"${EXTRA[@]}"} "$@" >/dev/null 2>&1 &
else
  "$BIN" --no-activate ${EXTRA[@]+"${EXTRA[@]}"} "$@" >/dev/null 2>&1 &
fi
PID=$!

# 고정 sleep 대신 폴링: 창이 뜨며 남기는 "... shown ... number=N"을 최대 ~6s
# 기다린다(main/onboarding/indicator 세 형식 모두 매칭).
WIN=""
for _ in $(seq 1 30); do
  sleep 0.2
  LINE="$(tail -c "+$((LOG_START + 1))" "$LOG" 2>/dev/null \
          | grep -E '(main window shown|onboarding window shown|indicator shown)' \
          | tail -1 || true)"
  if [[ -n "$LINE" ]]; then
    WIN="$(printf '%s' "$LINE" | grep -oE 'number=[0-9]+' | grep -oE '[0-9]+' || true)"
    [[ -n "$WIN" ]] && break
  fi
done

STATUS=0
if [[ -n "$WIN" ]]; then
  # 창이 뜬 직후 fade-in(인디케이터는 alpha 0→1 ~0.2s) 중에 캡처하면
  # "could not create image from window"가 날 수 있어 잠깐 안정화를 기다린다.
  sleep 0.5
  screencapture -x -l "$WIN" "$OUT" 2>/dev/null \
    || { sleep 0.6; screencapture -x -l "$WIN" "$OUT"; }   # 1회 재시도
  echo "shoot.sh: captured window $WIN -> $OUT"
else
  echo "shoot.sh: 로그에서 창 번호를 못 찾음 (창이 안 떴거나 형식 불일치)" >&2
  STATUS=1
fi

kill "$PID" 2>/dev/null || true
exit "$STATUS"
