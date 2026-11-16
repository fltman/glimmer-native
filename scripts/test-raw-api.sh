#!/bin/zsh
# The agent API for RAW files, with real camera files: a RAW file opens as a RAW layer,
# raw/info says what it allows, develop_raw develops it again, and everything that must be
# refused is refused with its reason.
#
#   GLIMMER_RAW_SAMPLES=/path/to/folder scripts/test-raw-api.sh
#
# Needs in the folder: a file with lens data (Panasonic*.RW2), one without (Apple*.DNG) and one
# macOS gives no picture for (Nikon*.NEF). GLIMMER_OFFLINE_CONFIG=Release runs the release build. Exit 0 = passed.
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  [[ -d "${GLIMMER_RAW_SAMPLES:-}" ]] || { echo "Set GLIMMER_RAW_SAMPLES to the folder with camera files."; exit 2; }
  COPY=$(scripts/offline-copy.sh | tail -1) || exit 1
  GLIMMER_TEST_LIMIT=420 GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$0"
fi
B=http://127.0.0.1:$GLIMMER_PORT/api/v1
H=(-H 'X-Glimmer-Agent: 1')
OUT=$(mktemp -d); fails=0
ok() { echo "✔ $1"; }
bad() { echo "✘ $1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
py() { python3 -I -c "import sys,json;d=json.load(open('$OUT/r.json'));print($1)" 2>/dev/null; }
open_raw() { CODE=$(curl -s --max-time 180 -o $OUT/r.json -w '%{http_code}' $H -H 'Content-Type: application/octet-stream' -X POST --data-binary @"$1" "$B/documents?name=$(basename "$1")"); }
steps() { CODE=$(curl -s --max-time 180 -o $OUT/r.json -w '%{http_code}' $H -H 'Content-Type: application/json' -X POST "$B/documents/$1/steps" -d "{\"steps\":[$2]}"); }
reason() { py 'd["error"].get("reason") or [r.get("reason") for r in d.get("results",[]) if r.get("reason")]'; }
brightness() { curl -s --max-time 60 $H "$B/documents/$1/image?maxSide=64&format=png" -o $OUT/i.png; sips -s format bmp $OUT/i.png --out $OUT/i.bmp >/dev/null 2>&1; python3 -I -c "
d=open('$OUT/i.bmp','rb').read(); off=int.from_bytes(d[10:14],'little'); px=d[off:]; print(round(sum(px)/len(px)))"; }
PAN=$(ls "$GLIMMER_RAW_SAMPLES"/Panasonic*.RW2 | head -1); IPH=$(ls "$GLIMMER_RAW_SAMPLES"/Apple*.DNG | head -1); NIK=$(ls "$GLIMMER_RAW_SAMPLES"/Nikon*.NEF | head -1)

open_raw "$PAN"; DOC=$(py 'd["document"]["id"]'); LAYER=$(py 'd["document"]["layers"][0]["id"]')
check "a RAW file opens as a document ($CODE; $(py 'str(d["document"]["width"])+" × "+str(d["document"]["height"])'))" '[[ $CODE == 201 && -n "$DOC" ]]'
check "its layer has raw: $(py 'd["document"]["layers"][0]["raw"]["fileName"], d["document"]["layers"][0]["raw"]["byteCount"], d["document"]["layers"][0]["raw"]["pixelsAsDeveloped"], d["document"]["layers"][0]["raw"]["process"]')" '[[ "$(py "d[\"document\"][\"layers\"][0][\"raw\"][\"pixelsAsDeveloped\"]")" == True ]]'
curl -s --max-time 30 $H "$B/documents/$DOC/layers/$LAYER/raw/info" -o $OUT/r.json
check "raw/info: size, lens data, controls with ranges ($(py 'd["raw"]["width"], d["raw"]["height"], d["raw"]["hasLensCorrectionData"], [c["name"] for c in d["raw"]["controls"] if c["supported"]]'))" '[[ "$(py "d[\"raw\"][\"hasLensCorrectionData\"], len(d[\"raw\"][\"controls\"])")" == "True 8" ]]'
B0=$(brightness $DOC)
steps $DOC '{"op":"develop_raw","params":{"exposure":1}}'
check "develop_raw exposure 1: done ($CODE; $(py 'd["results"][0].get("info")' | cut -c1-150))" '[[ $CODE == 200 && "$(py "d[\"results\"][0][\"status\"]")" == done ]]'
B1=$(brightness $DOC)
check "the picture is brighter (mean $B0 → $B1 of 255)" '(( B1 > B0 + 10 ))'
curl -s --max-time 30 $H "$B/documents/$DOC/layers/$LAYER/raw/info" -o $OUT/r.json
check "raw/info gives the settings as they now are (exposure $(py 'd["raw"]["settings"]["exposure"]'))" '[[ "$(py "float(d[\"raw\"][\"settings\"][\"exposure\"])")" == 1.0 ]]'
steps $DOC '{"op":"develop_raw","params":{"temperature":7500}}'
check "only what is given changes: temperature set, exposure kept ($(py 'd["results"][0]["info"]["settings"]["temperature"], d["results"][0]["info"]["settings"]["exposure"]'))" '[[ "$(py "float(d[\"results\"][0][\"info\"][\"settings\"][\"temperature\"]), float(d[\"results\"][0][\"info\"][\"settings\"][\"exposure\"])")" == "7500.0 1.0" ]]'
BT=$(brightness $DOC)   # the picture with exposure 1 and 7,500 K: what undo must come back to
steps $DOC '{"op":"develop_raw","params":{"exposure":7}}'
check "a value outside the range is refused with the range, not clamped ($CODE $(reason): $(py 'd["error"]["message"]'))" '[[ $CODE == 422 && "$(reason)" == *out_of_range* ]]'
steps $DOC '{"op":"develop_raw","params":{"brightness":1,"exposure":0}}'
check "a parameter it doesn't have is refused by name before anything runs, and the valid value beside it is not applied ($CODE: $(py 'd["error"]["message"]' | cut -c1-90); mean still $(brightness $DOC))" '[[ $CODE == 400 && "$(py "d[\"error\"][\"message\"]")" == *"no parameter named brightness"* ]] && (( $(brightness $DOC) - BT < 3 && BT - $(brightness $DOC) < 3 ))'
steps $DOC '{"op":"develop_raw","params":{}}'
check "nothing given is refused ($CODE $(reason))" '[[ $CODE == 422 && "$(reason)" == *nothing_to_set* ]]'
steps $DOC '{"op":"develop_raw","params":{"asShot":true}}'
B2=$(brightness $DOC)
check "asShot goes back (mean $B2, was $B0 at the start)" '[[ $CODE == 200 ]] && (( B2 - B0 < 4 && B0 - B2 < 4 ))'
UNDO=$(curl -s --max-time 60 -o $OUT/r.json -w '%{http_code}' $H -H 'Content-Type: application/json' -X POST "$B/documents/$DOC/undo" -d '{}'); sleep 1; B3=$(brightness $DOC)
check "undo takes the last development back (mean $B3; it was $BT before the undone step and $B2 after it)" '[[ $UNDO == 200 ]] && (( B3 - BT < 3 && BT - B3 < 3 && (BT - B2 > 3 || B2 - BT > 3) ))'
# A layer changed after it was developed.
steps $DOC '{"op":"apply_filter","params":{"type":"gaussian_blur","params":{"radius":3}}}'
steps $DOC '{"op":"develop_raw","params":{"exposure":0.5}}'
check "a changed layer is refused unless told to replace ($CODE $(reason))" '[[ $CODE == 422 && "$(reason)" == *replaces_changes* ]]'
steps $DOC '{"op":"develop_raw","params":{"exposure":0.5,"replaceChanges":true}}'
check "with replaceChanges it is developed ($CODE)" '[[ $CODE == 200 ]]'
# A file without lens data: the switch is refused by name.
open_raw "$IPH"; DOC2=$(py 'd["document"]["id"]')
steps $DOC2 '{"op":"develop_raw","params":{"lensCorrection":true}}'
check "a control the file doesn't have is refused by name ($CODE $(reason): $(py 'd["error"]["message"]'))" '[[ $CODE == 422 && "$(reason)" == *unsupported_control* ]]'
# An ordinary picture.
CODE=$(curl -s --max-time 60 -o $OUT/r.json -w '%{http_code}' $H -H 'Content-Type: image/jpeg' -X POST --data-binary @site/source-images/mug.jpg "$B/documents?name=mug"); DOC3=$(py 'd["document"]["id"]')
check "an ordinary picture has no raw in its layer" '[[ "$(py "\"raw\" in d[\"document\"][\"layers\"][0]")" == False ]]'
steps $DOC3 '{"op":"develop_raw","params":{"exposure":1}}'
check "develop_raw on it is refused ($CODE $(reason): $(py 'd["error"]["message"]' | cut -c1-110))" '[[ $CODE == 422 && "$(reason)" == *not_raw* ]]'
# A file macOS gives no picture for.
if [[ -f "$NIK" ]]; then
  open_raw "$NIK"
  check "a RAW file macOS can't develop: 422 with the reason, not a silent fall-back ($CODE $(reason): $(py 'd["error"]["message"]' | cut -c1-100))" '[[ $CODE == 422 && "$(reason)" == *raw_not_developed* ]]'
fi
check "the app is still running" 'kill -0 $GLIMMER_PID'
echo
if (( fails == 0 )); then echo "All RAW API checks passed."; else echo "$fails check(s) failed."; exit 1; fi
