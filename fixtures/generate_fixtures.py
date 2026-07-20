#!/usr/bin/env python3
"""M0 bake-off fixture generator (T6).

Synthesizes fixtures/sentences.json entries via macOS `say` (Yuna=ko-KR,
Samantha=en-US), then downsamples/converts to 16kHz mono 16-bit PCM WAV via
`afconvert` (matching WhisperKit.sampleRate / typical STT engine input).

NOTE (plan-mandated caveat, §2 Decision b): this audio is TTS-synthesized,
not real human speech. The bake-off it feeds is a *relative* engine
comparison on this fixture set, not a certification of real-world accuracy.

Usage: python3 fixtures/generate_fixtures.py
Requires: macOS `say` and `afconvert` (both present on any macOS host; no
network, no SwiftPM).
"""
import json
import subprocess
import sys
from pathlib import Path

FIXTURES_DIR = Path(__file__).resolve().parent
SENTENCES_PATH = FIXTURES_DIR / "sentences.json"
RAW_DIR = FIXTURES_DIR / "audio_raw"
OUT_DIR = FIXTURES_DIR / "audio"


def main() -> int:
    data = json.loads(SENTENCES_PATH.read_text(encoding="utf-8"))
    sentences = data["sentences"]

    RAW_DIR.mkdir(parents=True, exist_ok=True)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    failures = []
    for entry in sentences:
        sentence_id = entry["id"]
        voice = entry["voice"]
        text = entry["text"]

        aiff_path = RAW_DIR / f"{sentence_id}.aiff"
        wav_path = OUT_DIR / f"{sentence_id}.wav"

        say_cmd = ["say", "-v", voice, "-o", str(aiff_path), text]
        result = subprocess.run(say_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            failures.append((sentence_id, "say", result.stderr.strip()))
            continue

        # 16kHz mono 16-bit little-endian PCM WAV.
        afconvert_cmd = [
            "afconvert",
            "-f", "WAVE",
            "-d", "LEI16@16000",
            "-c", "1",
            str(aiff_path),
            str(wav_path),
        ]
        result = subprocess.run(afconvert_cmd, capture_output=True, text=True)
        if result.returncode != 0:
            failures.append((sentence_id, "afconvert", result.stderr.strip()))
            continue

        print(f"OK  {sentence_id:10s} ({voice:9s}) -> {wav_path.name}")

    if failures:
        print("\nFAILURES:", file=sys.stderr)
        for sentence_id, stage, message in failures:
            print(f"  {sentence_id} [{stage}]: {message}", file=sys.stderr)
        return 1

    print(f"\nGenerated {len(sentences)} fixtures in {OUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
