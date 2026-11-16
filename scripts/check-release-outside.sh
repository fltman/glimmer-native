#!/bin/zsh
# The release build seen from the outside: what its agent API lists and what its guide says
# must match Config/Features.xcconfig. Nothing switched off is described, nothing switched on
# is missing. (The same question as scripts/check-release-binary.sh, asked of the running app.)
#
#   scripts/check-release-outside.sh        (builds nothing: build the release first)
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  COPY=$(GLIMMER_OFFLINE_CONFIG=Release scripts/offline-copy.sh | tail -1) || exit 1
  GLIMMER_TEST_LIMIT=120 GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$0"
fi
B=http://127.0.0.1:$GLIMMER_PORT
OPS=$(curl -s --max-time 20 $B/api/v1/operations); GUIDE=$(curl -s --max-time 20 $B/glimmer)
fails=0
typeset -A IN_OPS IN_GUIDE
IN_OPS[HEAL]='"heal_selection"'; IN_GUIDE[HEAL]='heal_selection'
IN_OPS[RAW]='"develop_raw"';     IN_GUIDE[RAW]='develop_raw'
IN_OPS[PSD]='';                  IN_GUIDE[PSD]='importReport'
for feature in HEAL PSD RAW; do
  on=0; grep -Eq "^GLIMMER_${feature}[[:space:]]*=[[:space:]]*YES" Config/Features.xcconfig && on=1
  for where in ops guide; do
    if [[ $where == ops ]]; then marker=${IN_OPS[$feature]}; text=$OPS; else marker=${IN_GUIDE[$feature]}; text=$GUIDE; fi
    [[ -z "$marker" ]] && continue
    has=0; [[ "$text" == *"$marker"* ]] && has=1
    if (( has == on )); then echo "✔ $feature is $( (( on )) && echo on || echo off ): $( (( has )) && echo present in || echo absent from ) the release's $where"
    else echo "✘ $feature is $( (( on )) && echo on || echo off ) but $( (( has )) && echo present in || echo absent from ) the release's $where"; fails=$((fails + 1)); fi
  done
done
[[ "$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' -H 'X-Glimmer-Agent: 1' -X POST $B/api/v1/debug/fixture -d '{}')" == 404 ]] && echo "✔ the release has no debug routes" || { echo "✘ a debug route answers in the release"; fails=$((fails + 1)); }
echo "  ($(echo "$OPS" | grep -o '"name"' | wc -l | tr -d ' ') operations listed; the guide is $(echo "$GUIDE" | wc -c | tr -d ' ') bytes)"
(( fails == 0 )) && echo "The release matches its switches, from the outside." || { echo "$fails mismatch(es)."; exit 1; }
