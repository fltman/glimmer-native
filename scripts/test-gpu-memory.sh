#!/bin/zsh
# One measured run: does a texture allocation ever fail (the app would end) when a document
# gets many full layers, or does the system swap instead? Mid-size canvas, never a huge one.
#
#   scripts/test-gpu-memory.sh
#
# Budget: one run, 10 minutes (the supervisor ends it). Stops at the first of: free space on
# the home volume down to 10 GB, the test copy's memory footprint at 10 GB, swap grown by
# 2 GB since the start, 150 layers. Nothing is saved; the app is ended by test-app.sh.
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  GLIMMER_TEST_LIMIT=600 exec scripts/test-app.sh "$0"
fi
B=http://127.0.0.1:$GLIMMER_PORT/api/v1
H=(-H 'X-Glimmer-Agent: 1' -H 'Content-Type: application/json')
free_gb() { df -g "$HOME" | tail -1 | awk '{print $4}'; }
swap_mb() { sysctl -n vm.swapusage | sed -E 's/.*used = ([0-9.]+)M.*/\1/' | cut -d. -f1; }
foot_mb() { footprint -p $GLIMMER_PID 2>/dev/null | grep -m1 -i "phys_footprint:" | awk '{v=$2; u=$3; if (u ~ /GB/) v*=1024; if (u ~ /KB/) v/=1024; printf "%d", v}'; }
START=$(date +%s); SWAP0=$(swap_mb)
echo "start: free $(free_gb) GB on home, swap ${SWAP0} MB, footprint $(foot_mb) MB"
SRC=$(curl -s --max-time 60 -H 'X-Glimmer-Agent: 1' -H 'Content-Type: image/jpeg' -X POST --data-binary @site/source-images/mug.jpg "$B/documents?name=source" | python3 -c 'import sys,json;print(json.load(sys.stdin)["document"]["id"])')
ID=$(curl -s --max-time 60 -H 'X-Glimmer-Agent: 1' -H 'Content-Type: image/jpeg' -X POST --data-binary @site/source-images/mug.jpg "$B/documents?name=many-layers" | python3 -c 'import sys,json;print(json.load(sys.stdin)["document"]["id"])')
curl -s --max-time 120 -o /dev/null $H -X POST "$B/documents/$ID/steps" -d '{"steps":[{"op":"resize_image","params":{"width":4000}}]}'
why="150 layers"; n=0
while (( n < 150 )); do
  code=$(curl -s --max-time 120 -o /dev/null -w '%{http_code}' $H -X POST "$B/documents/$ID/layers?fit=cover" -d "{\"fromDocument\":\"$SRC\"}")
  if ! kill -0 $GLIMMER_PID 2>/dev/null; then why="THE APP ENDED after $n layers"; break; fi
  [[ $code == 201 ]] || { why="adding a layer answered HTTP $code after $n layers"; break; }
  n=$((n + 1))
  f=$(foot_mb); s=$(swap_mb); g=$(free_gb)
  (( n % 10 == 0 )) && echo "  $n layers: footprint ${f:-?} MB, swap $s MB, free $g GB, $(( $(date +%s) - START )) s"
  (( g <= 10 )) && { why="free space on home at $g GB"; break; }
  (( ${f:-0} >= 10240 )) && { why="footprint at $f MB"; break; }
  (( s - SWAP0 >= 2048 )) && { why="swap grew by $((s - SWAP0)) MB"; break; }
  (( $(date +%s) - START > 520 )) && { why="time budget"; break; }
done
echo "stopped: $why"
echo "end: $n full layers of 4000 px wide, free $(free_gb) GB on home, swap $(swap_mb) MB (start ${SWAP0}), footprint $(foot_mb) MB, $(( $(date +%s) - START )) s"
kill -0 $GLIMMER_PID 2>/dev/null && echo "the app is still running" || echo "the app is gone"
ls -t ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i glimmer | head -1
