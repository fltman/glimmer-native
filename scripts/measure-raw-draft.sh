#!/bin/zsh
# How fast the Develop sheet's draft follows a control, measured in the app, for every RAW
# file in a folder. One run, at most five minutes. Holds the GUI lock and the model lock
# (GUI first), so that nothing else of ours uses the GPU; prints the load average and what
# else is running beside the numbers, because on a busy Mac they mean little.
#
#   GLIMMER_RAW_SAMPLES=/path/to/folder scripts/measure-raw-draft.sh
#
# Debug build (RAW is off in releases). The result is also kept in build/raw-draft-timing.txt.
set -uo pipefail
cd "$(dirname "$0")/.."
TOOLS="${THE_APPS_TOOLS:-$HOME/Projekt/the-apps/tools}"
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  [[ -d "${GLIMMER_RAW_SAMPLES:-}" ]] || { echo "Set GLIMMER_RAW_SAMPLES to the folder with camera files."; exit 2; }
  COPY=$(scripts/offline-copy.sh | tail -1) || exit 1
  GLIMMER_TEST_LIMIT=300 GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$TOOLS/with-model-lock.sh" glimmer --wait 120 -- "$0"
fi
B=http://127.0.0.1:$GLIMMER_PORT/api/v1
H=(-H 'X-Glimmer-Agent: 1')
OUT=build/raw-draft-timing.txt
{
echo "RAW draft timing in the app, $(date '+%Y-%m-%d %H:%M'), commit $(git rev-parse --short HEAD), debug build."
echo "Load average at start: $(sysctl -n vm.loadavg | awk '{print $2, $3, $4}'). Busiest other processes: $(ps -Ao pcpu,comm -r | sed 1d | grep -v "Glimmer" | head -4 | awk '{n=split($2,a,"/"); printf "%s %s%%; ", a[n], $1}')"
for f in "$GLIMMER_RAW_SAMPLES"/*; do
  case "${f:l}" in *.txt|*.md) continue;; esac
  name=$(basename "$f")
  code=$(curl -s --max-time 90 -o /dev/null -w '%{http_code}' $H -H 'Content-Type: application/octet-stream' -X POST --data-binary @"$f" "$B/debug/raw?name=$name")
  if [[ $code != 200 ]]; then echo "$name: not developed by macOS ($code)"; continue; fi
  sleep 1
  curl -s --max-time 120 $H -X POST "$B/debug/raw-draft-timing" | python3 -I -c '
import json,sys
d=json.load(sys.stdin); name=sys.argv[1]; load=sys.argv[2]
if "error" in d: print(name+": "+str(d["error"])); sys.exit()
c=[int(x) for x in d["changesMs"]]
late=[x for x in c if x>100]
full=d["full"]; draft=d["draft"]; dec=int(d["decoderMs"]); first=int(d["firstPictureMs"])
print(f"{name}: {full} → draft {draft}; decoder {dec} ms, first picture {first} ms, warm-up after it {int(d.get("warmUpMs",0))} ms; 15 changes: {c} ms; over 100 ms: {len(late)} of 15, worst {max(c)} ms, median {sorted(c)[7]} ms (load {load})")' "$name" "$(sysctl -n vm.loadavg | awk '{print $2}')"
done
echo "Load average at end: $(sysctl -n vm.loadavg | awk '{print $2, $3, $4}')."
} | tee $OUT
kill -0 $GLIMMER_PID || { echo "The app is not running."; exit 1; }
