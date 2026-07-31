#!/bin/bash
# Drives one --test-pipeline pass and reports the log slice + the history row
# it produced. Serial by design: one app instance owns the insertion target.
#
# usage: run_pipeline_test.sh <wav> <label>
set -u
WAV="$1"; LABEL="${2:-run}"
LOG="$HOME/Library/Logs/Hwhisper.log"
DB="$HOME/Library/Application Support/Hwhisper/history.sqlite3"

START_LINES=$(wc -l < "$LOG")
START_ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM history;")

.build/debug/HwhisperMac \
  --test-pipeline "$WAV" \
  -refinementEnabled YES \
  -refinementProvider gemini \
  -refinementModel gemini-3.1-flash-lite \
  -refinementStyle structure \
  -onboardingCompleted YES \
  -hotkeyMode singleKeyRightCommand \
  >/dev/null 2>&1 &
PID=$!

# Wait for the pipeline to return to idle (or give up).
for _ in $(seq 1 90); do
  sleep 1
  if tail -n +$((START_LINES+1)) "$LOG" | grep -q "state: restoring → idle"; then break; fi
done
sleep 1
kill $PID 2>/dev/null
wait $PID 2>/dev/null

echo "########## $LABEL ##########"
tail -n +$((START_LINES+1)) "$LOG" | grep -vE "launch \(version|hotkey mode active|running unbundled"

END_ROWS=$(sqlite3 "$DB" "SELECT COUNT(*) FROM history;")
if [ "$END_ROWS" -gt "$START_ROWS" ]; then
  echo "--- history row ---"
  sqlite3 "$DB" "SELECT 'raw     : '||substr(raw_text,1,60) FROM history ORDER BY rowid DESC LIMIT 1;"
  sqlite3 "$DB" "SELECT 'raw len : '||length(raw_text)||'자   앞 공백: '||(substr(raw_text,1,1)=' ') FROM history ORDER BY rowid DESC LIMIT 1;"
  sqlite3 "$DB" "SELECT 'refined : '||COALESCE(substr(refined_text,1,60),'<NULL = raw 폴백>') FROM history ORDER BY rowid DESC LIMIT 1;"
else
  echo "--- history row 없음 ---"
fi
echo ""
