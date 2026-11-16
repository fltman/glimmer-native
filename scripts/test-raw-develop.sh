#!/bin/zsh
# Layer › Develop… with a real camera file: the file opens as a RAW layer, the sheet comes up
# with a developed picture, is read through the accessibility API and saved as a picture of
# the app's own windows (build/raw-shots), and Develop puts a new development in the layer.
#
#   GLIMMER_RAW_SAMPLE=/path/to/file.dng scripts/test-raw-develop.sh
#
# The sample is not in the repository (docs/TESTING-NOTES.md says where the fetched ones are).
# Debug build only: RAW development is switched off in releases, and the file is handed to
# the test copy through a debug route, since a sandboxed copy can't read the sample folder.
# Budget: 5 minutes. Exit 0 = passed.
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  [[ -f "${GLIMMER_RAW_SAMPLE:-}" ]] || { echo "Set GLIMMER_RAW_SAMPLE to a camera RAW file."; exit 2; }
  xcrun swiftc -O -o build/axread scripts/axread.swift 2>/dev/null || { echo "Couldn't build scripts/axread.swift"; exit 1; }
  xcrun swiftc -O -o build/window-shot scripts/window-shot.swift 2>/dev/null || { echo "Couldn't build scripts/window-shot.swift"; exit 1; }
  COPY=$(scripts/offline-copy.sh | tail -1) || exit 1
  GLIMMER_TEST_LIMIT=300 GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$0"
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
CODE=$(curl -s --max-time 120 -o /dev/null -w '%{http_code}' $H -H 'Content-Type: application/octet-stream' -X POST --data-binary @"$GLIMMER_RAW_SAMPLE" "$B/debug/raw?name=$NAME")
check "$NAME opens as a document ($CODE, $(printf '%.1f' $(( EPOCHREALTIME - t0 ))) s)" '[[ $CODE == 200 ]]'
sleep 2
"$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID --check "Layer" "Develop…" >/dev/null 2>&1 && ok "Layer › Develop… is there and enabled for the RAW layer" || bad "Layer › Develop… is not enabled"
front; "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID "Layer" "Develop…" >/dev/null 2>&1
# The first picture: the sheet is up at once and says it is developing; then the picture is there.
sleep 1
SEEN=$(read_all)
check "the sheet is up at once, with the file's name and size" 'echo "$SEEN" | grep -qF "$NAME"'
for _ in {1..40}; do SEEN=$(read_all); echo "$SEEN" | grep -qF "The picture shows the settings as they are." && break; sleep 1; done
check "the first developed picture arrives ($(printf '%.0f' $(( EPOCHREALTIME - t0 ))) s after the file was sent)" 'echo "$SEEN" | grep -qF "The picture shows the settings as they are."'
for name in "Exposure" "Temperature" "Tint" "Shadows" "As Shot" "Develop" "Cancel" "Preview of the developed picture"; do
  check "the sheet has: $name" 'echo "$SEEN" | grep -qF "$name"'
done
"$TOOLS/axaudit/axaudit" --pid $GLIMMER_PID --strict > build/raw-axaudit.log 2>&1 && ok "the sheet has no unnamed controls" || { bad "axaudit found something (build/raw-axaudit.log)"; tail -5 build/raw-axaudit.log | sed 's/^/    /'; }
build/window-shot $GLIMMER_PID build/raw-shots "develop-$NAME" >/dev/null 2>&1 && ok "saved as a picture: build/raw-shots/develop-$NAME-1.png (to be looked at)" || bad "no picture of the sheet"
# Develop (the default button) puts the new development in the layer as one undo step.
front
if isfront; then
  osascript -e "tell application \"System Events\" to key code 36" >/dev/null 2>&1
  for _ in {1..60}; do SEEN=$(read_all); echo "$SEEN" | grep -qF "Preview of the developed picture" || break; sleep 1; done
  check "Develop closes the sheet when the layer is developed" '! echo "$SEEN" | grep -qF "Preview of the developed picture"'
  "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID --check "Edit" "Undo Develop RAW" >/dev/null 2>&1 && ok "Edit › Undo Develop RAW is there" || bad "no Undo Develop RAW in the Edit menu"
  "$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID --check "Layer" "Develop…" >/dev/null 2>&1 && ok "the layer can be developed again" || bad "Develop… is no longer enabled"
else
  bad "the test copy is not frontmost; Return was not typed"
fi
check "the app is still running" 'kill -0 $GLIMMER_PID'
echo
if (( fails == 0 )); then echo "All RAW develop checks passed."; else echo "$fails check(s) failed."; exit 1; fi
