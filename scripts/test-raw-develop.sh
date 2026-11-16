#!/bin/zsh
# Layer › Develop… with a real camera file: the file opens as a RAW layer, the sheet comes up
# with a developed picture, is read through the accessibility API and saved as a picture of
# the app's own windows (build/raw-shots), and Develop puts a new development in the layer.
#
#   GLIMMER_RAW_SAMPLE=/path/to/file.dng scripts/test-raw-develop.sh
#
# The sample is not in the repository (docs/TESTING-NOTES.md says where the fetched ones are).
# GLIMMER_OFFLINE_CONFIG=Release runs the release build (build it first). In a debug build the
# file is handed over through a debug route, which opens it as File › Open… does; a release
# build has no such route and gets it through the agent API's own endpoint.
# Budget: 9 minutes (a 40-megapixel file in the debug build on a busy Mac needs most of it). Exit 0 = passed.
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  [[ -f "${GLIMMER_RAW_SAMPLE:-}" ]] || { echo "Set GLIMMER_RAW_SAMPLE to a camera RAW file."; exit 2; }
  xcrun swiftc -O -o build/axread scripts/axread.swift 2>/dev/null || { echo "Couldn't build scripts/axread.swift"; exit 1; }
  xcrun swiftc -O -o build/axread scripts/axread.swift 2>/dev/null
  xcrun swiftc -O -o build/window-shot scripts/window-shot.swift 2>/dev/null || { echo "Couldn't build scripts/window-shot.swift"; exit 1; }
  COPY=$(scripts/offline-copy.sh | tail -1) || exit 1   # GLIMMER_OFFLINE_CONFIG=Release: the release build (build it first)
  GLIMMER_TEST_LIMIT=540 GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$0"
fi
TOOLS="${THE_APPS_TOOLS:-}"
for candidate in "$PWD/../the-apps/tools" "$HOME/Projekt/the-apps/tools"; do [[ -z "$TOOLS" && -x "$candidate/axaudit/axaudit" ]] && TOOLS="$candidate"; done
B=http://127.0.0.1:$GLIMMER_PORT/api/v1
H=(-H 'X-Glimmer-Agent: 1')
fails=0
ok() { echo "✔ $1"; }
bad() { echo "✘ $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
read_all() { perl -e 'alarm 60; exec @ARGV' build/axread $GLIMMER_PID 2>&1; }
isfront() { [[ "$(perl -e 'alarm 10; exec @ARGV' osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)" == "$GLIMMER_PID" ]]; }
front() { perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to tell (first process whose unix id is $GLIMMER_PID) to set frontmost to true" >/dev/null 2>&1; sleep 0.6; }
NAME=$(basename "$GLIMMER_RAW_SAMPLE")

zmodload zsh/datetime; t0=$EPOCHREALTIME
# Through the debug route where there is one (it opens the file as File › Open… does, with the progress window);
# in a release build, which has none, through the agent API's own endpoint.
CODE=$(curl -s --max-time 240 -o /dev/null -w '%{http_code}' $H -H 'Content-Type: application/octet-stream' -X POST --data-binary @"$GLIMMER_RAW_SAMPLE" "$B/debug/raw?name=$NAME")
[[ $CODE == 200 ]] || CODE=$(curl -s --max-time 240 -o /dev/null -w '%{http_code}' $H -H 'Content-Type: application/octet-stream' -X POST --data-binary @"$GLIMMER_RAW_SAMPLE" "$B/documents?name=$NAME")
check "$NAME opens as a document ($CODE, $(printf '%.1f' $(( EPOCHREALTIME - t0 ))) s)" '[[ $CODE == 200 || $CODE == 201 ]]'
# The document's window comes up a moment after the answer (longer on a busy Mac): wait for the menu item, up to 45 s.
for _ in {1..45}; do "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID --check "Layer" "Develop…" >/dev/null 2>&1 && break; sleep 1; done
"$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID --check "Layer" "Develop…" >/dev/null 2>&1 && ok "Layer › Develop… is there and enabled for the RAW layer" || bad "Layer › Develop… is not enabled"
front; "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID "Layer" "Develop…" >/dev/null 2>&1
# The first picture: the sheet is up at once and says it is developing; then the picture is there.
sleep 1
SEEN=$(read_all)
check "the sheet is up at once, with the file's name and size" 'echo "$SEEN" | grep -qF "$NAME"'
for _ in {1..120}; do SEEN=$(read_all); echo "$SEEN" | grep -qF "The picture shows the settings as they are." && break; sleep 1; done
check "the first developed picture arrives ($(printf '%.0f' $(( EPOCHREALTIME - t0 ))) s after the file was sent)" 'echo "$SEEN" | grep -qF "The picture shows the settings as they are."'
for name in "Exposure" "Temperature" "Tint" "Shadows" "As Shot" "Develop" "Cancel" "Preview of the developed picture"; do
  check "the sheet has: $name" 'echo "$SEEN" | grep -qF "$name"'
done
"$TOOLS/axaudit/axaudit" --pid $GLIMMER_PID --strict > build/raw-axaudit.log 2>&1 && ok "the sheet has no unnamed controls" || { bad "axaudit found something (build/raw-axaudit.log)"; tail -5 build/raw-axaudit.log | sed 's/^/    /'; }
build/window-shot $GLIMMER_PID build/raw-shots "develop-$NAME" >/dev/null 2>&1 && ok "saved as a picture: build/raw-shots/develop-$NAME-1.png (to be looked at)" || bad "no picture of the sheet"
# The controls, used as a person uses them. Pointer events go through safepointer (it refuses a point outside the app's windows).
shot() { build/window-shot $GLIMMER_PID build/raw-shots "$1-$NAME" >/dev/null 2>&1 || bad "no picture of $1"; }
value_of() { echo "$SEEN" | grep -A1 -x "$1" | tail -1; }   # the text after a control's name: its value
settle() { for _ in {1..40}; do SEEN=$(read_all); echo "$SEEN" | grep -qF "The picture shows the settings as they are." && return 0; sleep 0.5; done; return 1; }
frame_of() { perl -e 'alarm 20; exec @ARGV' build/axread $GLIMMER_PID --frame "$1" "$2" 2>/dev/null; }
BEFORE=$(echo "$SEEN" | grep -E "stops$" | head -1)
F=($(frame_of AXSlider "Exposure"))
if (( ${#F} == 4 )); then
  front
  "$TOOLS/safepointer/safepointer" --pid $GLIMMER_PID drag $((F[1] + F[3] / 2)) $((F[2] + F[4] / 2)) $((F[1] + F[3] * 3 / 4)) $((F[2] + F[4] / 2)) >/dev/null 2>&1
  settle; AFTER=$(echo "$SEEN" | grep -E "stops$" | head -1)
  check "dragging Exposure changes it ($BEFORE → $AFTER) and the picture catches up" '[[ -n "$AFTER" && "$AFTER" != "$BEFORE" ]] && echo "$SEEN" | grep -qF "The picture shows the settings as they are."'
  shot exposure-dragged
else bad "no frame for the Exposure slider"; fi
# The grey point: tick the box, click the middle of the picture, and the white balance changes.
TEMP_BEFORE=$(echo "$SEEN" | grep -E "^[0-9].{0,8} K$" | head -1)
perl -e 'alarm 20; exec @ARGV' build/axread $GLIMMER_PID --press AXCheckBox "Click the picture to set what should be grey" >/dev/null 2>&1
P=($(frame_of any "Preview of the developed picture"))
if (( ${#P} == 4 )); then
  front
  "$TOOLS/safepointer/safepointer" --pid $GLIMMER_PID click $((P[1] + P[3] / 2)) $((P[2] + P[4] / 2)) >/dev/null 2>&1
  sleep 2; settle; TEMP_AFTER=$(echo "$SEEN" | grep -E "^[0-9].{0,8} K$" | head -1)
  check "a click on the picture sets the white balance ($TEMP_BEFORE → $TEMP_AFTER)" '[[ -n "$TEMP_AFTER" && "$TEMP_AFTER" != "$TEMP_BEFORE" ]]'
  shot grey-point
else bad "no frame for the preview"; fi
# As Shot: back to the camera's white balance and no exposure change.
perl -e 'alarm 20; exec @ARGV' build/axread $GLIMMER_PID --press AXButton "As Shot" >/dev/null 2>&1; sleep 1; settle
check "As Shot goes back ($(echo "$SEEN" | grep -E "stops$" | head -1), $(echo "$SEEN" | grep -E "^[0-9].{0,8} K$" | head -1))" '[[ "$(echo "$SEEN" | grep -E "stops$" | head -1)" == "$BEFORE" && "$(echo "$SEEN" | grep -E "^[0-9].{0,8} K$" | head -1)" == "$TEMP_BEFORE" ]]'

# Develop (the default button) puts the new development in the layer as one undo step.
front
if isfront; then
  osascript -e "tell application \"System Events\" to key code 36" >/dev/null 2>&1
  d0=$EPOCHREALTIME
  for _ in {1..200}; do SEEN=$(read_all); echo "$SEEN" | grep -qF "Preview of the developed picture" || break; sleep 1; done
  check "Develop closes the sheet when the layer is developed ($(printf '%.0f' $(( EPOCHREALTIME - d0 ))) s)" '! echo "$SEEN" | grep -qF "Preview of the developed picture"'
  "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID --check "Edit" "Undo Develop RAW" >/dev/null 2>&1 && ok "Edit › Undo Develop RAW is there" || bad "no Undo Develop RAW in the Edit menu"
  "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID --check "Layer" "Develop…" >/dev/null 2>&1 && ok "the layer can be developed again" || bad "Develop… is no longer enabled"
else
  bad "the test copy is not frontmost; Return was not typed"
fi
# A layer that was changed after it was developed: the sheet warns that developing again replaces the change.
DOC=$(curl -s --max-time 10 $H $B/documents | python3 -I -c 'import sys,json;print(json.load(sys.stdin)["documents"][-1]["id"])' 2>/dev/null)
curl -s --max-time 120 -o /dev/null $H -H 'Content-Type: application/json' -X POST "$B/documents/$DOC/steps" -d '{"steps":[{"op":"apply_filter","params":{"type":"gaussian_blur","params":{"radius":3}}}]}'
if "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID --check "Layer" "Develop…" >/dev/null 2>&1; then
  front; "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID "Layer" "Develop…" >/dev/null 2>&1; sleep 2; SEEN=$(read_all)
  check "after a filter on the layer, the sheet warns that developing again replaces the change" 'echo "$SEEN" | grep -qF "Developing again replaces those changes."'
  shot changed-warning
  front; isfront && osascript -e "tell application \"System Events\" to key code 53" >/dev/null 2>&1; sleep 1
else
  bad "after a filter the layer is no longer a RAW layer (Develop… is not enabled)"
fi
check "the app is still running" 'kill -0 $GLIMMER_PID'
echo
if (( fails == 0 )); then echo "All RAW develop checks passed."; else echo "$fails check(s) failed."; exit 1; fi
