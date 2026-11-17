#!/bin/zsh
# A linked edit ("Edit in Glimmer" from a sibling, SIBLINGS.md §6) must survive Glimmer's
# restart as a linked edit: after Quit, after being killed, and say so when the file is gone.
#
#   scripts/test-linked-restart.sh
#
# The copy is started in English whatever this Mac's language is: the test presses menus by their English names.
# Runs the Debug copy with window restoration ON (test copies normally start without it),
# under the series' GUI lock, without an OpenRouter key. It first empties this debug copy's
# own autosaved untitled documents (only when no debug copy is running), so that only
# this test's windows come back. Menus are pressed through the-apps/tools/safemenu.
# Exit 0 = every check passed.
set -uo pipefail
cd "$(dirname "$0")/.."
# GLIMMER_APP: another debug copy to test (for instance one signed without an entitlement, to see that this test notices).
APP="${GLIMMER_APP:-$PWD/build/DerivedData/Build/Products/Debug/Glimmer.app}"
[[ -d "$APP" ]] || { echo "Build first: scripts/test.sh"; exit 1; }
TOOLS="${THE_APPS_TOOLS:-}"
if [[ -z "$TOOLS" ]]; then
  for candidate in "$PWD/../the-apps/tools" "$HOME/Projekt/the-apps/tools"; do
    if [[ -x "$candidate/with-gui-lock.sh" ]]; then TOOLS="$candidate"; break; fi
  done
fi
[[ -n "$TOOLS" && -x "$TOOLS/with-gui-lock.sh" && -x "$TOOLS/safemenu/safemenu" ]] || { echo "Can't find the-apps/tools (with-gui-lock.sh, safemenu): set THE_APPS_TOOLS."; exit 1; }
if [[ "${GLIMMER_HOLDS_GUI_LOCK:-}" != 1 ]]; then
  # Under the series' supervisor: a time limit, and it ends when whoever started it is gone; the trap stops the test copy by its pid.
  [[ -x "$TOOLS/run-supervised.sh" ]] || { echo "Can't find run-supervised.sh in $TOOLS."; exit 1; }
  exec "$TOOLS/with-gui-lock.sh" glimmer --wait "${GLIMMER_LOCK_WAIT:-600}" -- "$TOOLS/run-supervised.sh" --timeout "${GLIMMER_TEST_LIMIT:-1800}" --watch "$PPID" -- env GLIMMER_HOLDS_GUI_LOCK=1 "$0" "$@"
fi
[[ "$(cat /tmp/gui-test.lock/owner 2>/dev/null)" == glimmer ]] || { echo "Not holding the GUI lock; not starting."; exit 75; }
MENU="$TOOLS/safemenu/safemenu"
HANDOVER="$PWD/build/handover"
xcrun swiftc -O -o "$HANDOVER" scripts/handover.swift 2>/dev/null || { echo "Couldn't build scripts/handover.swift"; exit 1; }
zmodload zsh/datetime

fails=0
ok() { echo "✔ $1"; }
bad() { echo "✘ $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

running() { for p in $(pgrep -x Glimmer || true); do [[ "$(ps -o command= -p "$p")" == "$APP/Contents/MacOS/Glimmer"* ]] && echo $p; done; }
PID=""; PORT=""
stop() { if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then kill -TERM "$PID"; for _ in {1..20}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done; fi; }
trap stop EXIT INT TERM

# This debug copy's own leftovers (com.brattoo.glimmer.debug only; nothing of the real app).
DATA="$HOME/Library/Containers/com.brattoo.glimmer.debug/Data"
clean() {
  [[ -z "$(running)" ]] || { echo "A debug copy is running; not cleaning its state."; return 1; }
  # Untitled documents the system keeps for restoring windows (with restoration on), their
  # version stores, and what copies started without restoration left in tmp.
  for d in "$DATA/Library/Autosave Information" "$DATA/tmp/Autosave Information" "$DATA/tmp/com.brattoo.glimmer.debug.savedState" "$DATA/tmp/TemporaryItems"; do
    [[ -d "$d" ]] || continue
    chmod -R u+w "$d" 2>/dev/null
    # The folders themselves stay: without "Autosave Information" the next autosave has nowhere to go.
    find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  done
  return 0
}
start() {  # sets PID and PORT; with a file: a cold start for that file
  local before=" $(running | tr '\n' ' ') "
  PID=""; PORT=""
  if [[ -n "${1:-}" ]]; then
    # Cold start by a sibling handing a file over: Glimmer itself then restores no windows.
    # (Through NSWorkspace, as a sibling does: `open -n app file --args …` doesn't deliver the file as an open event.)
    env -u OPENROUTER_API_KEY "$HANDOVER" "$APP" "$1" -skipWelcome -skipAgentSplash -AppleLanguages "(en)" -ai.noKeychain YES -NSQuitAlwaysKeepsWindows YES -linkAnyOpen Flimmer || exit 1
  else
    env -u OPENROUTER_API_KEY open -n "$APP" --args -skipWelcome -skipAgentSplash -AppleLanguages "(en)" -ai.noKeychain YES -ApplePersistenceIgnoreState NO -NSQuitAlwaysKeepsWindows YES -linkAnyOpen Flimmer
  fi
  for _ in {1..80}; do
    if [[ -z "$PID" ]]; then for p in $(running); do [[ "$before" != *" $p "* ]] && PID=$p; done; fi
    if [[ -n "$PID" ]]; then
      PORT=$(lsof -nP -a -p "$PID" -iTCP -sTCP:LISTEN 2>/dev/null | awk -F: '/LISTEN/ {split($2, a, " "); print a[1]; exit}' || true)
      [[ -n "$PORT" ]] && break
    fi
    sleep 0.25
  done
  [[ -n "$PID" && -n "$PORT" ]] || { echo "The test copy didn't start."; exit 1; }
  ! ps eww -p "$PID" | grep -q "OPENROUTER_API_KEY=" || { echo "The test copy has an OpenRouter key."; exit 1; }
  B=http://127.0.0.1:$PORT/api/v1
  sleep 2.5   # restored windows appear
}
front() { perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to set frontmost to true" >/dev/null 2>&1; sleep 0.6; }
menu() { front; "$MENU" --pid $PID "$@"; }
hasmenu() { front; "$MENU" --pid $PID --check "$@" >/dev/null 2>&1; }
quit() { menu "Glimmer" "Quit Glimmer" >/dev/null; for _ in {1..40}; do kill -0 $PID 2>/dev/null || break; sleep 0.25; done; ! kill -0 $PID 2>/dev/null; }
# docs → "name|available|requester|id" per document, linked or "-"
docs() { curl -s --max-time 10 $B/documents | python3 -c '
import sys,json
for d in json.load(sys.stdin)["documents"]:
    l=d.get("linkedFile")
    print("%s|%s|%s|%s" % (d["name"], "-" if not l else l.get("available"), "-" if not l else l.get("requester"), d["id"]))'; }
linked() { docs | grep "^photo.png|True|Flimmer|" | head -1; }
edit() { curl -s -o /dev/null --max-time 60 -H 'X-Glimmer-Agent: 1' -H 'Content-Type: application/json' -X POST "$B/documents/$1/steps" -d "{\"steps\":[{\"op\":\"add_text\",\"params\":{\"text\":\"$2\",\"position\":\"$3\"}}]}"; }
layers() { curl -s --max-time 10 $B/documents/$1 | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["document"]["layers"]))'; }
killit() { kill -TERM $PID; for _ in {1..40}; do kill -0 $PID 2>/dev/null || break; sleep 0.25; done; }
stamp() { stat -f '%m:%z:%i' "$FILE"; }
saveback() {  # presses Save Back and waits for the file to change
  local before=$(stamp)
  menu "File" "Save Back to photo.png" >/dev/null || return 1
  for _ in {1..40}; do [[ "$(stamp)" != "$before" ]] && break; sleep 0.25; done
  [[ "$(stamp)" != "$before" && "${$(stamp)##*:}" == "${before##*:}" ]] && sips -g pixelWidth "$FILE" >/dev/null 2>&1
}

DIR="$PWD/build/linktest"; rm -rf "$DIR"; mkdir -p "$DIR"; FILE="$DIR/photo.png"
cp site/source-images/mug.png "$FILE"
clean || exit 1

echo "== hand over, edit, save back"
start
open -a "$APP" "$FILE"; sleep 3
L=$(linked); ID=${L##*|}
check "the handed-over file is linked: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
edit $ID "One" top
check "Save Back writes the file in place" 'saveback'

echo "== Quit right after saving back, relaunch"
check "Glimmer quits from its menu" 'quit'; echo "   kept for restoring: $(ls "$DATA/Library/Autosave Information" | tr "\n" " ")"
start
L=$(linked); ID=${L##*|}
check "after Quit the window is back and linked: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
check "exactly one window came back for the file" '[[ $(docs | grep -c "^photo.png|") == 1 ]]'
check "the menu has Save Back and no plain Save" 'hasmenu "File" "Save Back to photo.png" && ! hasmenu "File" "Save"'
[[ -n "$ID" ]] || { echo "no linked document; stopping"; stop; exit 1; }
edit $ID "Two" center
check "Save Back still writes the file after the relaunch (sandbox)" 'saveback'

echo "== Quit with an unsaved edit, relaunch"
edit $ID "Three" bottom
check "Glimmer quits from its menu" 'quit'; echo "   kept for restoring: $(ls "$DATA/Library/Autosave Information" | tr "\n" " ")"
start
L=$(linked); ID=${L##*|}
check "after Quit with unsaved work the window is back and linked: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
LAYERS=$(curl -s $B/documents/$ID | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["document"]["layers"]))')
check "the unsaved edit is still in it ($LAYERS layers)" '[[ $LAYERS -ge 4 ]]'
check "Save Back writes the file" 'saveback'

echo "== killed after autosave, relaunch"
edit $ID "Four" top
echo "   waiting 50 s for autosave"; sleep 50
kill -TERM $PID; for _ in {1..40}; do kill -0 $PID 2>/dev/null || break; sleep 0.25; done
start
L=$(linked); ID=${L##*|}
check "after being killed the window is back and linked: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
check "Save Back writes the file" 'saveback'

echo "== killed with an unsaved edit, then the same file is handed over again, cold"
N=$(layers $ID)
edit $ID "Cold" bottom
echo "   waiting 50 s for autosave"; sleep 50
killit
start "$FILE"; sleep 2
L=$(linked); ID=${L##*|}
check "one linked window for the file: $(docs | tr '\n' ' ')" '[[ -n "$L" && $(docs | grep -c "^photo.png|") == 1 ]]'
[[ -n "$ID" ]] || { echo "no linked document; stopping"; stop; exit 1; }
check "it is the kept document with the unsaved edit ($(layers $ID) layers, $N before the edit)" '[[ $(layers $ID) == $((N + 1)) ]]'
check "Save Back writes the file" 'saveback'

echo "== killed with an unsaved edit, another file handed over cold, then a normal launch"
N=$(layers $ID)
edit $ID "Later" top
echo "   waiting 50 s for autosave"; sleep 50
killit
cp site/source-images/mug.png "$DIR/other.png"
start "$DIR/other.png"; sleep 2
check "the other file is linked and the first one's window is not opened: $(docs | tr '\n' ' ')" '[[ $(docs | grep -c "^other.png|True|Flimmer|") == 1 && $(docs | grep -c "^photo.png|") == 0 ]]'
check "Glimmer quits from its menu" 'quit'
start
L=$(linked); ID=${L##*|}
check "at the next normal launch the first file's window is back, linked: $(docs | tr '\n' ' ')" '[[ -n "$L" && $(docs | grep -c "^photo.png|") == 1 ]]'
[[ -n "$ID" ]] || { echo "no linked document; stopping"; stop; exit 1; }
check "with its unsaved edit ($(layers $ID) layers, $N before the edit)" '[[ $(layers $ID) == $((N + 1)) ]]'
check "Save Back writes the file" 'saveback'

echo "== the file is renamed while Glimmer is closed, relaunch"
check "Glimmer quits from its menu" 'quit'; echo "   kept for restoring: $(ls "$DATA/Library/Autosave Information" | tr "\n" " ")"
mv "$FILE" "$DIR/renamed.png"
start
D=$(docs | grep "|True|Flimmer|")
check "the link follows the renamed file: $D" '[[ "$D" == "renamed.png|True|Flimmer|"* ]] && hasmenu "File" "Save Back to renamed.png"'
check "Glimmer quits from its menu" 'quit'; echo "   kept for restoring: $(ls "$DATA/Library/Autosave Information" | tr "\n" " ")"
mv "$DIR/renamed.png" "$FILE"
start
L=$(linked); ID=${L##*|}
check "and back again: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
[[ -n "$ID" ]] || { echo "no linked document; stopping"; stop; exit 1; }

echo "== the file is gone, relaunch"
edit $ID "Five" center
check "Glimmer quits from its menu" 'quit'; echo "   kept for restoring: $(ls "$DATA/Library/Autosave Information" | tr "\n" " ")"
rm "$FILE"
start
D=$(docs | grep "^photo.png|")
check "the window is back and says the file can't be reached: $D" '[[ "$D" == "photo.png|False|Flimmer|"* ]]'
check "the menu still has Save Back, and no plain Save" 'hasmenu "File" "Save Back to photo.png" && ! hasmenu "File" "Save"'
menu "File" "Save Back to photo.png" >/dev/null; sleep 1.5
PANEL=$(perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get (count of (text fields of sheet 1 of window 1))" 2>/dev/null || echo 0)
check "Save explains instead of opening Save As (text fields in the sheet: $PANEL)" '[[ "$PANEL" == 0 ]]'
check "nothing was written where the file was" '[[ ! -e "$FILE" ]]'
check "the app is still running" 'kill -0 $PID'

echo "== the file is removed, restored and replaced while Glimmer is running"
cp site/source-images/mug.png "$FILE"
open -a "$APP" "$FILE"; sleep 3
L=$(linked); ID=${L##*|}
check "a hand-over is linked: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
rm "$FILE"; sleep 2.5
D=$(docs | grep "^photo.png|" | head -1)
check "2.5 s after the file is removed the document says it can't be saved back: $D" '[[ "$D" == "photo.png|False|Flimmer|"* ]]'
check "the menu still has Save Back, and no plain Save" 'hasmenu "File" "Save Back to photo.png" && ! hasmenu "File" "Save"'
menu "File" "Save Back to photo.png" >/dev/null; sleep 1.5
PANEL=$(perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get (count of (text fields of sheet 1 of window 1))" 2>/dev/null || echo 0)
SAID=$(perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to get value of every static text of sheet 1 of window 1" 2>/dev/null)
check "Save explains and points to Save a Glimmer Copy… (no Save As panel, no bare error): ${SAID:0:120}" '[[ "$PANEL" == 0 && "$SAID" == *"no longer where it was"*"Save a Glimmer Copy"* ]]'
check "nothing was written where the file was" '[[ ! -e "$FILE" ]]'
front; osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PID) to key code 36" >/dev/null 2>&1; sleep 1
cp site/source-images/mug.png "$FILE"; sleep 2.5
check "2.5 s after the file is put back the document is linked again: $(docs | tr '\n' ' ')" '[[ -n "$(linked)" ]]'
check "Save Back writes the restored file" 'saveback'
cp site/source-images/mug.png "$DIR/new.png"; BEFORE=$(stat -f %i "$FILE"); mv "$DIR/new.png" "$FILE"; sleep 2.5
check "after the file is replaced by another one (new inode $(stat -f %i "$FILE"), was $BEFORE) the document is still linked" '[[ -n "$(linked)" && "$(stat -f %i "$FILE")" != "$BEFORE" ]]'
check "Save Back writes the replacing file" 'saveback'
check "the app is still running" 'kill -0 $PID'

echo "== closing a linked window after saving back asks nothing"
cp site/source-images/mug.png "$FILE"
open -a "$APP" "$FILE"; sleep 3
L=$(linked); ID=${L##*|}
check "a new hand-over is linked" '[[ -n "$L" ]]'
if [[ -n "$ID" ]]; then
  edit $ID "Six" top
  check "Save Back writes the file" 'saveback'
  sleep 1.5
  menu "File" "Close" >/dev/null; sleep 2
  check "the window closed without a question: $(docs | tr '\n' ' ')" 'kill -0 $PID && [[ -n "$(docs)" && -z "$(linked)" ]]'
fi
check "the app is still running" 'kill -0 $PID'
stop; clean
rm -rf "$DIR"
echo
if (( fails == 0 )); then echo "All linked-restart checks passed."; else echo "$fails check(s) failed."; exit 1; fi
