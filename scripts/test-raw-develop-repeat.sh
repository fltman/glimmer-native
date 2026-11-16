#!/bin/zsh
# Develop, again and again, on one RAW file: looking for a final development that does not
# come back (seen once with a 40-megapixel file on a busy Mac, 2026-11-16). Each run opens
# Layer › Develop…, waits for the picture, presses Develop and waits for the sheet to close,
# with a limit per run; the app says where each run's time went.
#
#   GLIMMER_RAW_SAMPLE=/path/to/file scripts/test-raw-develop-repeat.sh [runs, default 10]
#
# Debug build. Supervised, at most 9 minutes in all. Exit 0 = every run closed within its limit.
set -uo pipefail
cd "$(dirname "$0")/.."
RUNS="${1:-10}"
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  [[ -f "${GLIMMER_RAW_SAMPLE:-}" ]] || { echo "Set GLIMMER_RAW_SAMPLE to a camera RAW file."; exit 2; }
  xcrun swiftc -O -o build/axread scripts/axread.swift 2>/dev/null || exit 1
  COPY=$(scripts/offline-copy.sh | tail -1) || exit 1
  GLIMMER_TEST_LIMIT=540 GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$0" "$RUNS"
fi
TOOLS="${THE_APPS_TOOLS:-$HOME/Projekt/the-apps/tools}"
B=http://127.0.0.1:$GLIMMER_PORT/api/v1
H=(-H 'X-Glimmer-Agent: 1')
zmodload zsh/datetime
read_all() { perl -e 'alarm 60; exec @ARGV' build/axread $GLIMMER_PID 2>&1; }
isfront() { [[ "$(perl -e 'alarm 10; exec @ARGV' osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)" == "$GLIMMER_PID" ]]; }
front() { perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to tell (first process whose unix id is $GLIMMER_PID) to set frontmost to true" >/dev/null 2>&1; sleep 0.5; }
load() { sysctl -n vm.loadavg | awk '{print $2}'; }
NAME=$(basename "$GLIMMER_RAW_SAMPLE"); LIMIT=45; stuck=0
CODE=$(curl -s --max-time 240 -o /dev/null -w '%{http_code}' $H -H 'Content-Type: application/octet-stream' -X POST --data-binary @"$GLIMMER_RAW_SAMPLE" "$B/debug/raw?name=$NAME")
[[ $CODE == 200 ]] || { echo "✘ $NAME did not open ($CODE)"; exit 1; }
for _ in {1..45}; do "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID --check "Layer" "Develop…" >/dev/null 2>&1 && break; sleep 1; done
echo "$NAME, $RUNS runs, limit $LIMIT s per run, load average at start $(load)"
for run in {1..$RUNS}; do
  front; "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID "Layer" "Develop…" >/dev/null 2>&1
  for _ in {1..60}; do read_all | grep -qF "The picture shows the settings as they are." && break; sleep 0.5; done
  front; isfront || { echo "✘ run $run: the test copy is not frontmost; stopped"; exit 1; }
  t0=$EPOCHREALTIME
  osascript -e "tell application \"System Events\" to key code 36" >/dev/null 2>&1
  closed=0
  while (( EPOCHREALTIME - t0 < LIMIT )); do read_all | grep -qF "Preview of the developed picture" || { closed=1; break; }; sleep 0.5; done
  took=$(printf '%.1f' $(( EPOCHREALTIME - t0 )))
  trace=$(curl -s --max-time 10 $H "$B/debug/raw-develop-trace" | python3 -I -c 'import sys,json;print(json.load(sys.stdin)["last"])' 2>/dev/null)
  if (( closed )); then echo "✔ run $run: closed after $took s (load $(load)); $trace"
  else
    stuck=$((stuck + 1)); echo "✘ run $run: NOT closed after $LIMIT s (load $(load)); the app says: ${trace:-nothing yet}"
    sample $GLIMMER_PID 2 -file build/raw-develop-stuck-$run.txt >/dev/null 2>&1 && echo "    where it was: build/raw-develop-stuck-$run.txt"
    # Cancel must work at this moment.
    front; isfront && osascript -e "tell application \"System Events\" to key code 53" >/dev/null 2>&1; sleep 2
    read_all | grep -qF "Preview of the developed picture" && echo "    ✘ Cancel did not close the sheet" || echo "    ✔ Cancel closed the sheet"
    sleep 20
  fi
done
kill -0 $GLIMMER_PID && echo "the app is still running" || { echo "✘ the app is gone"; exit 1; }
if (( stuck == 0 )); then echo "All $RUNS runs closed within $LIMIT s."; else echo "$stuck of $RUNS runs did not close within $LIMIT s."; exit 1; fi
