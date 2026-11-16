#!/bin/zsh
# Opens generated Photoshop files in the running app and checks that the layers come in and
# that the import report is shown and can be read: no import happens silently.
#
#   scripts/test-psd-import.sh
#
# Writes its sample files with the test suite's own writer (nothing downloaded), runs the
# no-network copy through scripts/test-app.sh (GUI lock, supervisor, no key). Exit 0 = passed.
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  xcrun swiftc -O -o build/axread scripts/axread.swift 2>/dev/null || { echo "Couldn't build scripts/axread.swift"; exit 1; }
  mkdir -p build/psd-samples
  GLIMMER_PSD_OUT="$PWD/build/psd-samples" swift test --package-path Packages/GlimmerKit --filter PSDSampleFiles >/dev/null 2>&1 || { echo "Couldn't write the sample files."; exit 1; }
  COPY=$(scripts/offline-copy.sh | tail -1) || exit 1
  GLIMMER_TEST_LIMIT=600 GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$0"
fi
TOOLS="${THE_APPS_TOOLS:-}"
for candidate in "$PWD/../the-apps/tools" "$HOME/Projekt/the-apps/tools"; do [[ -z "$TOOLS" && -x "$candidate/axaudit/axaudit" ]] && TOOLS="$candidate"; done
B=http://127.0.0.1:$GLIMMER_PORT/api/v1
fails=0
ok() { echo "✔ $1"; }
bad() { echo "✘ $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
open_psd() { curl -s --max-time 60 -H 'X-Glimmer-Agent: 1' -H 'Content-Type: image/vnd.adobe.photoshop' -X POST --data-binary @"$1" "$B/documents?name=$2"; }
field() { python3 -c "import sys,json;d=json.load(sys.stdin)['document'];print($1)" 2>/dev/null; }
press() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $GLIMMER_PID) to key code $1" >/dev/null 2>&1; sleep 0.6; }
front() { perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to tell (first process whose unix id is $GLIMMER_PID) to set frontmost to true" >/dev/null 2>&1; sleep 0.5; }

# A file where everything comes through.
R=$(open_psd build/psd-samples/clean.psd clean)
check "clean.psd: two layers, 8 × 8" '[[ "$(echo "$R" | field "len(d[\"layers\"]), d[\"width\"], d[\"height\"]")" == "2 8 8" ]]'
check "clean.psd: the answer carries the report, and nothing was lost" '[[ "$(echo "$R" | field "d[\"importReport\"][\"looksTheSame\"], len(d[\"importReport\"][\"notes\"]), d[\"importReport\"][\"layersKept\"]")" == "True 0 2" ]]'
DIFF=$(echo "$R" | field 'round(d["importReport"]["differenceFromFile"]["mean"], 3), d["importReport"]["differenceFromFile"]["shareVisiblyDifferent"]')
check "clean.psd: measured against the file's own picture in the app: mean and share $DIFF" '[[ -n "$DIFF" ]] && python3 -c "import sys; m, s = map(float, sys.argv[1:3]); sys.exit(0 if m < 1 and s == 0 else 1)" ${=DIFF}'
sleep 1.5
SEEN=$(perl -e 'alarm 60; exec @ARGV' build/axread $GLIMMER_PID 2>&1)
check "clean.psd: the report sheet is on screen and says everything came through" 'echo "$SEEN" | grep -qF "Everything came through: 2 layers, 0 of them groups (RGB, 8 bits per channel)."'
check "clean.psd: and that the picture matches the file's" 'echo "$SEEN" | grep -qF "Glimmer'"'"'s picture matches the one saved in the file."'
"$TOOLS/axaudit/axaudit" --pid $GLIMMER_PID --strict >/dev/null 2>&1 && ok "the report sheet has no unnamed controls" || bad "the report sheet: axaudit found something"
front; press 36

# A file with things that don't come through.
R=$(open_psd build/psd-samples/mixed.psd mixed)
check "mixed.psd: Background and the group Heading with Title and Glow" '[[ "$(echo "$R" | field "[l[\"name\"] for l in d[\"layers\"]]")" == *Heading*Background* ]]'
check "mixed.psd: 6 of 7 kept, the look may differ" '[[ "$(echo "$R" | field "d[\"importReport\"][\"layersInFile\"], d[\"importReport\"][\"layersKept\"], d[\"importReport\"][\"looksTheSame\"]")" == "7 6 False" ]]'
echo "$R" | field '"\n".join("    " + (n["layer"] or "-") + ": " + n["what"] for n in d["importReport"]["notes"])'
sleep 1.5
SEEN=$(perl -e 'alarm 60; exec @ARGV' build/axread $GLIMMER_PID 2>&1)
for line in "It was text (“Summer Sale”) and is now pixels: the words can't be edited as text." "It was a Vibrance adjustment layer. That kind is not read in this version, so it was left out." "The blend mode Lighter Color became Normal: Glimmer doesn't have it."; do
  check "mixed.psd: the sheet says: $line" 'echo "$SEEN" | grep -qF "$line"'
done
# This sample's flattened picture is only its background: the tests' writer can't draw Vibrance or
# Lighter Color into it. So the measured difference says nothing about the import and is not shown here.
check "mixed.psd: the sheet has a line about the picture (not comparable for this sample: its flattened picture is only the background)" 'echo "$SEEN" | grep -q "Glimmer'"'"'s picture \(differs from\|matches\) the one saved in the file"'
front; press 36
"$TOOLS/safemenu/safemenu" --pid $GLIMMER_PID --check "File" "Import Report…" >/dev/null 2>&1 && ok "File › Import Report… is there and enabled for this window" || bad "File › Import Report…"

# Export: the imported document back out as a Photoshop file, through the agent API, and in again.
MIXED=$(echo "$R" | field 'd["id"]')
curl -s --max-time 120 -D build/psd-samples/export.headers -o build/psd-samples/exported.psd -H 'X-Glimmer-Agent: 1' -H 'Content-Type: application/json' -X POST "$B/documents/$MIXED/export" -d '{"format":"psd"}'
check "export as psd: a Photoshop file comes back ($(stat -f %z build/psd-samples/exported.psd) bytes, $(head -c 4 build/psd-samples/exported.psd))" '[[ "$(head -c 4 build/psd-samples/exported.psd)" == 8BPS ]]'
REPORT=$(grep -i '^x-glimmer-export-report:' build/psd-samples/export.headers | cut -d' ' -f2- | tr -d '\r')
check "export as psd: the report is in the answer's header: ${REPORT:0:150}" 'echo "$REPORT" | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if d[\"layersWritten\"]>=5 else 1)"'
check "macOS reads the exported file ($(sips -g pixelWidth -g pixelHeight build/psd-samples/exported.psd 2>/dev/null | tail -2 | awk "{print \$2}" | tr "\n" " "))" '[[ "$(sips -g pixelWidth build/psd-samples/exported.psd 2>/dev/null | tail -1 | awk "{print \$2}")" == 64 ]]'
R2=$(open_psd build/psd-samples/exported.psd again)
check "the exported file opens in Glimmer again with the same layers: $(echo "$R2" | field "[l[\"name\"] for l in d[\"layers\"]]")" '[[ "$(echo "$R2" | field "[l[\"name\"] for l in d[\"layers\"]]")" == "$(echo "$R" | field "[l[\"name\"] for l in d[\"layers\"]]")" ]]'
check "and its own flattened picture matches its layers this time: $(echo "$R2" | field "d[\"importReport\"][\"differenceFromFile\"]")" 'echo "$R2" | python3 -c "import sys,json;x=json.load(sys.stdin)[\"document\"][\"importReport\"][\"differenceFromFile\"];sys.exit(0 if x[\"mean\"]<1.5 and x[\"shareVisiblyDifferent\"]<0.01 else 1)"'
front; press 36
# The sheet that says what the file will hold, before it is saved.
curl -s --max-time 10 -o /dev/null -H 'X-Glimmer-Agent: 1' -H 'Content-Type: application/json' -X POST "$B/debug/fixture" -d '{"name":"psdExport"}'; sleep 4
SEEN=$(perl -e 'alarm 60; exec @ARGV' build/axread $GLIMMER_PID 2>&1)
check "File › Export… › Photoshop File…: the sheet says what is written and that Photoshop has not been tried" 'echo "$SEEN" | grep -q "layers and groups" && echo "$SEEN" | grep -qF "the layers have not been tried in Photoshop"'
"$TOOLS/axaudit/axaudit" --pid $GLIMMER_PID --strict >/dev/null 2>&1 && ok "the export sheet has no unnamed controls" || bad "the export sheet: axaudit found something"
front; press 53

# Something that is not a Photoshop file inside, with the signature: refused with words.
printf '8BPS\0\1garbage' > build/psd-samples/broken.psd
CODE=$(curl -s --max-time 30 -o build/psd-samples/broken.json -w '%{http_code}' -H 'X-Glimmer-Agent: 1' -H 'Content-Type: image/vnd.adobe.photoshop' -X POST --data-binary @build/psd-samples/broken.psd "$B/documents?name=broken")
check "a damaged file is refused with a reason ($CODE: $(python3 -c 'import json;print(json.load(open("build/psd-samples/broken.json"))["error"]["message"])' 2>/dev/null))" '[[ $CODE == 400 ]]'
check "the app is still running" 'kill -0 $GLIMMER_PID'
echo
if (( fails == 0 )); then echo "All Photoshop import checks passed."; else echo "$fails check(s) failed."; exit 1; fi
