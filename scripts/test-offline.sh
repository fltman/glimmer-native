#!/bin/zsh
# Proves Glimmer runs on its own: no network, no OpenRouter key, no server.
#
#   scripts/test-offline.sh
#
# Makes the no-network copy (scripts/offline-copy.sh: macOS refuses every connection it tries
# to make), starts it cold through scripts/test-app.sh (GUI lock, no key in its environment),
# and checks through the agent API on 127.0.0.1 that opening, editing, every on-device
# feature and export work, and that what needs the network answers with a clear message
# within seconds instead of hanging or crashing. Exit 0 = all checks passed.
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  COPY=$(scripts/offline-copy.sh | tail -1) || exit 1
  GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$0"
fi
B=http://127.0.0.1:$GLIMMER_PORT/api/v1
H=(-H 'X-Glimmer-Agent: 1')
OUT=$(mktemp -d)
fails=0
ok() { echo "✔ $1"; }
bad() { echo "✘ $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# post <path> <json> → body in $R, status in $CODE, seconds in $SECS (never waits more than 120 s)
post() { local t0=$EPOCHREALTIME; CODE=$(curl -s --max-time 120 -o $OUT/r.json -w '%{http_code}' $H -H 'Content-Type: application/json' -X POST "$B$1" -d "$2"); R=$(cat $OUT/r.json 2>/dev/null); SECS=$(( EPOCHREALTIME - t0 )); }
zmodload zsh/datetime
steps() { post "/documents/$ID/steps" "{\"steps\":[$1]}"; }
allDone() { [[ $CODE == 200 ]] && ! echo "$R" | grep -q '"status" : "\(failed\|skipped\)"'; }

# The copy really has no network entitlement.
check "the copy can't open outgoing connections (no network.client entitlement)" \
  '! codesign -d --entitlements - "$GLIMMER_APP" 2>/dev/null | grep -q network.client'
check "no OpenRouter key in its environment" '! ps eww -p $GLIMMER_PID | grep -q OPENROUTER_API_KEY='

# Cold start and the API.
STATUS=$(curl -s --max-time 10 $B/status)
check "cold start: the agent API answers on 127.0.0.1:$GLIMMER_PORT" '[[ "$STATUS" == *"\"Glimmer\""* ]]'
check "the guide is served locally" '[[ "$(curl -s --max-time 10 http://127.0.0.1:$GLIMMER_PORT/glimmer | head -c 400)" == *Glimmer* ]]'

# Open and edit.
ID=$(curl -s --max-time 60 $H -H 'Content-Type: image/jpeg' -X POST --data-binary @site/source-images/portrait.jpg "$B/documents?name=offline" | python3 -c 'import sys,json;print(json.load(sys.stdin)["document"]["id"])' 2>/dev/null)
check "open an image" '[[ -n "$ID" ]]'
for step in \
  '{"op":"auto_enhance"}' \
  '{"op":"auto_color"}' \
  '{"op":"add_adjustment","params":{"type":"black_white"}}' \
  '{"op":"apply_filter","params":{"type":"gaussian_blur","params":{"radius":4}}}' \
  '{"op":"apply_filter","params":{"type":"lens_blur"}}' \
  '{"op":"select_subject"},{"op":"deselect"}' \
  '{"op":"select_people"},{"op":"deselect"}' \
  '{"op":"add_text","params":{"text":"Offline works","position":"top"}},{"op":"style_text","params":{"match":"works","bold":true,"color":"#E0303A"}}' \
  '{"op":"transform_layer","params":{"degrees":8,"scaleX":120,"scaleY":120}}' \
  '{"op":"add_layer_effect","params":{"type":"dropShadow"}}' \
  '{"op":"select_layer","params":{"name":"offline"}},{"op":"remove_background"}' ; do
  steps "$step"
  name=$(echo "$step" | grep -o '"op":"[a-z_]*"' | head -3 | cut -d'"' -f4 | tr '\n' ' ')
  check "on device: ${name}(${SECS%.*} s)" 'allDone'
  allDone || echo "    $(echo "$R" | python3 -c 'import sys,json;print([r.get("error") for r in json.load(sys.stdin)["results"]])' 2>/dev/null)"
done
# The sky needs a photo with a sky in it.
SKY=$(curl -s --max-time 60 $H -H 'Content-Type: image/jpeg' -X POST --data-binary @site/source-images/mountain-lake.jpg "$B/documents?name=sky" | python3 -c 'import sys,json;print(json.load(sys.stdin)["document"]["id"])' 2>/dev/null)
post "/documents/$SKY/steps" '{"steps":[{"op":"select_sky"}]}'
# Select Sky uses the depth model, which is downloaded once. Without it (a fresh copy, no
# network) the step must say so at once; with it, the sky is selected.
if allDone; then
  check "on device: select_sky, model already downloaded (${SECS%.*} s)" '[[ "$R" == *"\"hasSelection\" : true"* ]]'
else
  MSG=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"]["message"])' 2>/dev/null)
  check "needs a model download: select_sky says so within seconds (${SECS%.*} s)" '[[ $CODE == 422 && ${SECS%.*} -lt 15 && "$MSG" == *"downloads once"*"Connect to the internet"* ]]'
  echo "    $MSG"
fi
PRESET=$(curl -s --max-time 10 $B/operations | python3 -c '
import sys,json
ops=json.load(sys.stdin).get("operations",[])
p=[o for o in ops if o.get("name")=="apply_preset"]
e=p[0]["params"]["properties"]["name"].get("enum",[]) if p else []
print(e[0] if e else "")' 2>/dev/null)
if [[ -n "$PRESET" ]]; then steps "{\"op\":\"apply_preset\",\"params\":{\"name\":\"$PRESET\"}}"; check "on device: apply_preset “$PRESET”" 'allDone'; fi
steps '{"op":"upscale","params":{"scale":2}}'
check "on device: upscale 2× with the bundled Real-ESRGAN (${SECS%.*} s)" '[[ $CODE == 200 || $CODE == 202 ]]'
if [[ $CODE == 202 ]]; then
  JOB=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["job"]["id"])')
  for _ in {1..120}; do
    ST=$(curl -s --max-time 10 $B/jobs/$JOB | python3 -c 'import sys,json;print(json.load(sys.stdin)["job"]["status"])' 2>/dev/null)
    [[ "$ST" == running || "$ST" == queued ]] || break; sleep 1
  done
  check "upscale job finished: $ST" '[[ "$ST" == done ]]'
fi
post "/documents/$ID/undo" '{}'; check "undo" '[[ $CODE == 200 ]]'
post "/documents/$ID/redo" '{}'; check "redo" '[[ $CODE == 200 ]]'

# Export.
for fmt in jpeg png webp; do
  curl -s --max-time 120 $H -H 'Content-Type: application/json' -X POST $B/documents/$ID/export -d "{\"format\":\"$fmt\"}" -o $OUT/out.$fmt
  check "export $fmt ($(stat -f %z $OUT/out.$fmt) bytes)" '[[ $(stat -f %z $OUT/out.$fmt) -gt 10000 ]] && ! head -c 20 $OUT/out.$fmt | grep -q error'
done
curl -s --max-time 120 $H -H 'Content-Type: application/json' -X POST $B/documents/$ID/export -d '{"preset":"podcast-cover","maxBytes":512000}' -o $OUT/cover.jpg
check "export podcast cover under 512 kB" '[[ $(sips -g pixelWidth $OUT/cover.jpg | tail -1 | awk "{print \$2}") == 3000 || $(sips -g pixelWidth $OUT/cover.jpg | tail -1 | awk "{print \$2}") == 1400 ]] && [[ $(stat -f %z $OUT/cover.jpg) -le 512000 ]]'

# What needs the network or a key: a clear answer, fast.
steps '{"op":"generate_layer","params":{"prompt":"a red balloon"}}'
check "a paid step is refused with a reason, at once: $(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"]["code"])' 2>/dev/null)" '[[ $CODE == 402 && ${SECS%.*} -lt 3 ]]'
steps '{"op":"add_waveform"}'
MSG=$(echo "$R" | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"]["message"])' 2>/dev/null)
check "a sibling step says the sibling isn't running, within seconds (${SECS%.*} s): $MSG" '[[ $CODE == 422 && ${SECS%.*} -lt 15 && -n "$MSG" ]]'

check "the app is still running" 'kill -0 $GLIMMER_PID'
check "no crash report was written" '[[ -z "$(find ~/Library/Logs/DiagnosticReports -name "Glimmer*" -newer $OUT 2>/dev/null)" ]]'
echo
if (( fails == 0 )); then echo "All offline checks passed."; else echo "$fails offline check(s) failed."; exit 1; fi
