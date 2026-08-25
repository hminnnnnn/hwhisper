#!/bin/bash
# 정제기 로그 위생·오류 경로 회귀 테스트 (2026-08-25 감사에서 승격).
#
# 실제 OpenAICompatibleRefiner.swift 소스를 그대로 컴파일해 8개 시나리오를 굴린다:
#   S1 실 Gemini 정상 정제 + 동일 refiner 재사용(세션 재사용)   ← credentials.json 키 필요
#   S2 실 Gemini 404 — 상태코드만 남고 요청 본문 미에코
#   S3 URLError — ?key=… 자격증명이 에러 문자열에 절대 안 실림 (키 유출 방지)
#   S4 RefinerEndpointPolicy — https/localhost·무쿼리 규칙 4종
#   S5 전사를 에코하는 422 프록시(FastAPI형) — 전사·센티널이 에러에 미유출
#   S6 OpenAI 봉투형 에러 — code/message(120자 상한)는 통과
#   S7 청크 부분 실패 — raw 폴백 + diagnosticLog "refinement degraded"
#
# 정제기 오류 처리/로그 코드를 건드리면 반드시 재실행. 실패 시 exit≠0.
set -euo pipefail
cd "$(dirname "$0")/.."

HYG=scripts/refine-hygiene
OUT=$(mktemp -d)
trap 'kill "$STUB_PID" 2>/dev/null; rm -rf "$OUT"' EXIT

python3 "$HYG/stub.py" &
STUB_PID=$!
sleep 0.5

swiftc -O "$HYG/main.swift" \
  Sources/HwhisperCore/OpenAICompatibleRefiner.swift \
  Sources/HwhisperCore/TextRefiner.swift \
  -o "$OUT/refine-hygiene"
"$OUT/refine-hygiene"
