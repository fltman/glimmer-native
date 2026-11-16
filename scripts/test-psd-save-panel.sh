#!/bin/zsh
# File › Export… › Photoshop File… all the way to a saved file: the sheet's Save…, the save
# panel, and the file on disk read back. (The other tests take the bytes from the agent API.)
#
#   scripts/test-psd-save-panel.sh
#
# Keys are typed only while the test copy is frontmost (checked by pid before each). The file
# goes to build/psd-samples. Budget: 5 minutes (the supervisor ends it).
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  mkdir -p build/psd-samples
  GLIMMER_TEST_LIMIT=300 exec scripts/test-app.sh "$0"
fi
B=http://127.0.0.1:$GLIMMER_PORT/api/v1
fails=0
ok() { echo "✔ $1"; }
bad() { echo "✘ $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
isfront() { [[ "$(perl -e 'alarm 10; exec @ARGV' osascript -e 'tell application "System Events" to get unix id of first process whose frontmost is true' 2>/dev/null)" == "$GLIMMER_PID" ]]; }
front() { perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to tell (first process whose unix id is $GLIMMER_PID) to set frontmost to true" >/dev/null 2>&1; sleep 0.6; }
# keys <AppleScript after "to">: typed only when the test copy is frontmost.
keys() { front; isfront || { bad "the test copy is not frontmost; nothing was typed ($1)"; return 1; }; perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to $1" >/dev/null 2>&1; sleep "${2:-0.8}"; }

OUT="$PWD/build/psd-samples"; NAME="saved-by-panel-$$"; FILE="$OUT/$NAME.psd"; rm -f "$FILE"
ID=$(curl -s --max-time 60 -H 'X-Glimmer-Agent: 1' -H 'Content-Type: image/jpeg' -X POST --data-binary @site/source-images/mug.jpg "$B/documents?name=panel" | python3 -c 'import sys,json;print(json.load(sys.stdin)["document"]["id"])')
curl -s --max-time 60 -o /dev/null -H 'X-Glimmer-Agent: 1' -H 'Content-Type: application/json' -X POST "$B/documents/$ID/steps" -d '{"steps":[{"op":"add_text","params":{"text":"Panel","position":"top"}},{"op":"add_adjustment","params":{"type":"invert"}}]}'
check "a document with three layers is open" '[[ -n "$ID" ]]'
curl -s --max-time 10 -o /dev/null -H 'X-Glimmer-Agent: 1' -H 'Content-Type: application/json' -X POST "$B/debug/fixture" -d '{"name":"psdExport"}'
sleep 6   # the sheet prepares the file
keys 'key code 36' 2 || exit 1                                   # Save… (the sheet's default button)
keys 'keystroke "g" using {command down, shift down}' 1.2 || exit 1   # Go to Folder
keys "keystroke \"$OUT\"" 1 || exit 1
keys 'key code 36' 1.5 || exit 1
keys 'keystroke "a" using {command down}' 0.5 || exit 1
keys "keystroke \"$NAME\"" 0.8 || exit 1
keys 'key code 36' 3 || exit 1                                   # Save
for _ in {1..20}; do [[ -s "$FILE" ]] && break; sleep 0.5; done
check "the save panel wrote the file ($(stat -f %z "$FILE" 2>/dev/null) bytes)" '[[ -s "$FILE" && "$(head -c 4 "$FILE")" == 8BPS ]]'
check "macOS reads it ($(sips -g pixelWidth "$FILE" 2>/dev/null | tail -1 | awk "{print \$2}") px wide)" '[[ "$(sips -g pixelWidth "$FILE" 2>/dev/null | tail -1 | awk "{print \$2}")" == 2528 ]]'
R=$(curl -s --max-time 120 -H 'X-Glimmer-Agent: 1' -H 'Content-Type: image/vnd.adobe.photoshop' -X POST --data-binary @"$FILE" "$B/documents?name=back")
NAMES=$(echo "$R" | python3 -c 'import sys,json;print([l["name"] for l in json.load(sys.stdin)["document"]["layers"]])' 2>/dev/null)
check "Glimmer reads the saved file back with its three layers: $NAMES" '[[ "$NAMES" == *Invert*Panel*panel* ]]'
DIFF=$(echo "$R" | python3 -c 'import sys,json;x=json.load(sys.stdin)["document"]["importReport"];print(round(x["differenceFromFile"]["mean"],3), x["differenceFromFile"]["shareVisiblyDifferent"], [n["what"][:60] for n in x["notes"]])' 2>/dev/null)
check "and its flattened picture matches its layers: $DIFF" 'echo "$R" | python3 -c "import sys,json;x=json.load(sys.stdin)[\"document\"][\"importReport\"][\"differenceFromFile\"];sys.exit(0 if x[\"mean\"]<1.5 and x[\"shareVisiblyDifferent\"]<0.01 else 1)"'
check "the app is still running" 'kill -0 $GLIMMER_PID'
rm -f "$FILE"
echo
if (( fails == 0 )); then echo "The save panel path passed."; else echo "$fails check(s) failed."; exit 1; fi
