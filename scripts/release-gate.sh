#!/usr/bin/env bash
# Refinement RELEASE GATE.
#
# Builds HwhisperEval and runs the refinement suite (Sources/HwhisperEval/
# RefineSuite.swift) against the LIVE Gemini API. BLOCKS the release with a
# non-zero exit unless coverage is 100%. Run this FIRST on every version bump,
# before make-app.sh / make-dmg.sh / git tag / push.
#
# Requires a Gemini key in credentials.json (BYOK):
#   ~/Library/Application Support/Hwhisper/credentials.json  {"gemini":"<key>"}
#
# Usage: bash scripts/release-gate.sh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "==> Building refinement gate (HwhisperEval)…"
swift build --product HwhisperEval >/dev/null

echo "==> Running refinement release gate (live API)…"
if .build/debug/HwhisperEval --refine-suite; then
    echo ""
    echo "==> ✅ GATE PASSED (100% coverage) — safe to build & release."
else
    echo ""
    echo "==> ❌ GATE FAILED — refinement coverage < 100%. Release BLOCKED." >&2
    echo "    Fix the failing case(s) above (prompt or code) before releasing." >&2
    exit 1
fi
