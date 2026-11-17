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
# How the copy stands to the system's window restoration. The link must survive in all three (SIBLINGS.md §6):
#   GLIMMER_RESTORE=on (default here)  windows are restored, as when "Close windows when quitting an application" is off
#   GLIMMER_RESTORE=person             that setting on, which is how macOS comes: nothing is restored after Quit
#   GLIMMER_RESTORE=guest              the guest rule's start line (-ApplePersistenceIgnoreState YES): nothing is ever restored
case "${GLIMMER_RESTORE:-on}" in
  on) RESTORE="-ApplePersistenceIgnoreState NO -NSQuitAlwaysKeepsWindows YES"; RESTORE_COLD="-NSQuitAlwaysKeepsWindows YES" ;;
  person) RESTORE="-ApplePersistenceIgnoreState NO -NSQuitAlwaysKeepsWindows NO"; RESTORE_COLD="-NSQuitAlwaysKeepsWindows NO" ;;
  guest) RESTORE="-ApplePersistenceIgnoreState YES"; RESTORE_COLD="-ApplePersistenceIgnoreState YES" ;;
  *) echo "GLIMMER_RESTORE is on, person or guest."; exit 1 ;;
esac
echo "Window restoration: ${GLIMMER_RESTORE:-on} ($RESTORE)"
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
  for d in "$DATA/Library/Autosave Information" "$DATA/tmp/Autosave Information" "$DATA/tmp/com.brattoo.glimmer.debug.savedState" "$DATA/tmp/TemporaryItems" "$DATA/Library/Application Support/LinkJournal" "$DATA/Library/Saved Application State/com.brattoo.glimmer.debug.savedState"; do
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
    env -u OPENROUTER_API_KEY "$HANDOVER" "$APP" "$1" -skipWelcome -skipAgentSplash -AppleLanguages "(en)" -ai.noKeychain YES ${=RESTORE_COLD} -linkAnyOpen Flimmer || exit 1
  else
    env -u OPENROUTER_API_KEY open -n "$APP" --args -skipWelcome -skipAgentSplash -AppleLanguages "(en)" -ai.noKeychain YES ${=RESTORE} -linkAnyOpen Flimmer
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
# Quit must go through without any question: one that stands in the way is read out and the copy is stopped.
quit() {
  menu "Glimmer" "Quit Glimmer" >/dev/null; for _ in {1..40}; do kill -0 $PID 2>/dev/null || break; sleep 0.25; done
  kill -0 $PID 2>/dev/null || return 0
  echo "   Quit was stopped by: $(perl -e 'alarm 30; exec @ARGV' build/axread $PID 2>/dev/null | grep -i "do you want\|unsaved\|keep this\|not saved back" | head -2 | tr '\n' ' ')"
  kill -TERM $PID; for _ in {1..20}; do kill -0 $PID 2>/dev/null || break; sleep 0.25; done
  return 1
}
# docs → "name|available|requester|id" per document, linked or "-"
journal() { curl -s --max-time 10 $B/status | python3 -c 'import sys,json;j=json.load(sys.stdin)["linkJournal"];print("%s entries, %s unreturned, %s broken" % (j["entries"], j["unreturned"], len(j["broken"])))'; }
# How each document came to be open: "kept" (left knowingly at Quit), "recovered" (after a stop), or "-"; with the steps that wait.
recovered() { curl -s --max-time 10 $B/documents | python3 -c 'import sys,json
for d in json.load(sys.stdin)["documents"]:
    l = d.get("linkedFile") or {}
    print("%s:%s:%s" % (d["name"], "kept" if l.get("kept") else "recovered" if l.get("recovered") else "-", l.get("unreturnedSteps", 0)), end=" ")'; }
written() { for _ in {1..40}; do sleep 0.25; [[ "$(curl -s --max-time 5 $B/debug/journal-idle)" == *true* ]] && return 0; done; return 1; }
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
check "the journal has the entry, with nothing waiting: $(journal)" '[[ "$(journal)" == "1 entries, 0 unreturned, 0 broken" ]]'
check "Glimmer quits from its menu, without a question" 'quit'
start
L=$(linked); ID=${L##*|}
if [[ "${GLIMMER_RESTORE:-on}" == on ]]; then
  check "after Quit the window is back and linked: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
else
  # Nothing was waiting to be saved back, so the window follows the system's setting like any window: not kept.
  check "with windows not kept, a linked window with nothing waiting does not come back: $(docs | tr '\n' ' ')" '[[ -z "$L" ]]'
  check "and its journal entry is gone: $(journal)" '[[ "$(journal)" == "0 entries, 0 unreturned, 0 broken" ]]'
  open -a "$APP" "$FILE"; sleep 3
  L=$(linked); ID=${L##*|}
  check "handed over again, it is linked: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
fi
check "exactly one window for the file" '[[ $(docs | grep -c "^photo.png|") == 1 ]]'
check "the menu has Save Back and no plain Save" 'hasmenu "File" "Save Back to photo.png" && ! hasmenu "File" "Save"'
[[ -n "$ID" ]] || { echo "no linked document; stopping"; stop; exit 1; }
edit $ID "Two" center
check "Save Back still writes the file after the relaunch (sandbox)" 'saveback'

echo "== Quit with an unsaved edit, relaunch"
N=$(layers $ID)
edit $ID "Three" bottom
check "the journal says an edit waits: $(journal)" 'written && [[ "$(journal)" == "1 entries, 1 unreturned, 0 broken" ]]'
check "Glimmer quits from its menu, without a question" 'quit'
start
L=$(linked); ID=${L##*|}
check "after Quit with unsaved work the window is back and linked: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
check "it says it was kept from last time, with one step waiting: $(recovered)" '[[ "$(recovered)" == *"photo.png:kept:1"* ]]'
check "the unsaved edit is still in it ($(layers $ID) layers, $N before the edit)" '[[ $(layers $ID) == $((N + 1)) ]]'
check "Save Back writes the file" 'saveback'
check "after Save Back it no longer says so and nothing waits: $(recovered)" '[[ "$(recovered)" == *"photo.png:-:0"* ]]'

echo "== stopped hard right after a step, relaunch"
N=$(layers $ID)
edit $ID "Four" top
written; echo "   the journal after the step: $(journal)"
kill -KILL $PID; for _ in {1..40}; do kill -0 $PID 2>/dev/null || break; sleep 0.25; done
start
L=$(linked); ID=${L##*|}
check "after the hard stop the window is back and linked: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
check "with the step made just before it ($(layers $ID) layers, $N before) and marked as brought back: $(recovered)" '[[ $(layers $ID) == $((N + 1)) && "$(recovered)" == *"photo.png:recovered:"* ]]'
check "Save Back writes the file" 'saveback'

echo "== killed with an unsaved edit, then the same file is handed over again, cold"
N=$(layers $ID)
edit $ID "Cold" bottom
written
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
written
killit
cp site/source-images/mug.png "$DIR/other.png"
start "$DIR/other.png"; sleep 2
# Two linked documents: the one handed over now, and the one whose edit was waiting, which comes back at every launch.
check "the other file is linked, and the first one is back beside it with its edit waiting: $(docs | tr '\n' ' ') $(recovered)" '[[ $(docs | grep -c "^other.png|True|Flimmer|") == 1 && $(docs | grep -c "^photo.png|True|Flimmer|") == 1 && "$(recovered)" == *"photo.png:recovered:"* ]]'
check "the journal holds both: $(journal)" '[[ "$(journal)" == "2 entries, 1 unreturned, 0 broken" ]]'
check "Glimmer quits from its menu, without a question" 'quit'
# The second document has done its part. With windows kept it would come back too and stand in front of the
# first one in what follows, so its entry is taken out of the journal by hand while Glimmer is closed.
python3 -I - "$DATA/Library/Application Support/LinkJournal" <<'PY'
import glob, json, os, shutil, sys
for record in glob.glob(os.path.join(sys.argv[1], "*", "record.json")):
    if json.load(open(record)).get("fileName") == "other.png": shutil.rmtree(os.path.dirname(record))
PY
start
L=$(linked); ID=${L##*|}
check "at the next normal launch the first file's window is back, linked: $(docs | tr '\n' ' ')" '[[ -n "$L" && $(docs | grep -c "^photo.png|") == 1 ]]'
[[ -n "$ID" ]] || { echo "no linked document; stopping"; stop; exit 1; }
check "with its unsaved edit ($(layers $ID) layers, $N before the edit)" '[[ $(layers $ID) == $((N + 1)) ]]'
check "Save Back writes the file" 'saveback'

echo "== the file is renamed while Glimmer is closed, relaunch"
# With windows not kept, only a document with something waiting comes back: so something waits.
[[ "${GLIMMER_RESTORE:-on}" == on ]] || { edit $ID "Waiting" center; written; }
check "Glimmer quits from its menu, without a question" 'quit'
mv "$FILE" "$DIR/renamed.png"
start
D=$(docs | grep "|True|Flimmer|")
check "the link follows the renamed file: $D" '[[ "$D" == "renamed.png|True|Flimmer|"* ]] && hasmenu "File" "Save Back to renamed.png"'
check "Glimmer quits from its menu, without a question" 'quit'
mv "$DIR/renamed.png" "$FILE"
start
L=$(linked); ID=${L##*|}
check "and back again: $(docs | tr '\n' ' ')" '[[ -n "$L" ]]'
[[ -n "$ID" ]] || { echo "no linked document; stopping"; stop; exit 1; }

echo "== the file is gone, relaunch"
edit $ID "Five" center
check "Glimmer quits from its menu, without a question" 'quit'
rm "$FILE"
# An entry that can't be read (no record, no work copy): reported, left where it is, never removed by the app.
JOURNAL="$DATA/Library/Application Support/LinkJournal"
mkdir -p "$JOURNAL/not-an-entry"; echo "half a write" > "$JOURNAL/not-an-entry/junk.txt"
start
check "an entry that can't be read is reported and left where it is: $(journal)" '[[ "$(journal)" == *", 1 broken" && -f "$JOURNAL/not-an-entry/junk.txt" ]]'
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
check "the entry that can't be read is still there at the end" '[[ -f "$JOURNAL/not-an-entry/junk.txt" ]]'

echo "== a document of the person's own, untitled and changed, at Quit (not linked: what the system does with it)"
OWN=$(curl -s --max-time 20 -H 'X-Glimmer-Agent: 1' -H 'Content-Type: application/json' -X POST $B/documents -d '{"width":640,"height":480,"name":"own"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["document"]["id"])')
edit $OWN "Mine" center; sleep 2
menu "Glimmer" "Quit Glimmer" >/dev/null; for _ in {1..24}; do kill -0 $PID 2>/dev/null || break; sleep 0.25; done
ASKED=""; kill -0 $PID 2>/dev/null && ASKED=$(perl -e 'alarm 30; exec @ARGV' build/axread $PID 2>/dev/null | grep -i "do you want to keep\|unsaved changes" | head -1)
KEPT=$(ls "$DATA/Library/Autosave Information" 2>/dev/null | grep -c "\.glimmer$")
case "${GLIMMER_RESTORE:-on}" in
  on)
    check "windows kept: Quit goes through without a question and the document is kept ($KEPT kept)" '[[ -z "$ASKED" ]] && ! kill -0 $PID 2>/dev/null && (( KEPT >= 1 ))'
    start
    BACK=$(curl -s --max-time 10 $B/documents | python3 -c 'import sys,json;print(max([d.get("layerCount", 0) for d in json.load(sys.stdin)["documents"] if not d.get("linkedFile")] + [0]))')
    check "and it is back in a window after the relaunch, with its change (a document of the person's own with $BACK layers)" '(( BACK >= 2 ))' ;;
  person)
    check "windows not kept (the default Mac): the system asks before anything is dropped: ${ASKED:0:60}" '[[ -n "$ASKED" ]]' ;;
  guest)
    # Known and not mended here: the Mac keeps windows, so the system saves the document and quits without asking,
    # and a start line that restores nothing then never shows it. It is kept on disk, unseen. (The visiting script
    # empties the guest's container afterwards and says what it removed.)
    # Reported, not counted: what the guest line does to a changed untitled document is the line's doing
    # (-ApplePersistenceIgnoreState YES), and is said in the guest rule.
    echo "   the guest line: asked: ${ASKED:-no}; quit: $(kill -0 $PID 2>/dev/null && echo no || echo yes); kept on disk: $KEPT" ;;
esac
stop; clean
rm -rf "$DIR"
echo
if (( fails == 0 )); then echo "All linked-restart checks passed."; else echo "$fails check(s) failed."; exit 1; fi
