#!/bin/zsh
# Reads Glimmer through the accessibility API with content in place: a conversation in the
# Assistant, a job list, many layers and history steps, every sheet and alert, the link bar
# in its states, Settings › AI with a loaded model list, and Agent Access. After each state:
# the-apps/tools/axaudit --strict (no unnamed controls) and a full read of every element
# (scripts/axread.swift), and the app must still be running. Empty panels proved too little:
# on 2026-11-16 a message in the Assistant crashed the app for anyone using VoiceOver.
#
#   scripts/test-accessibility.sh                          (no network: the offline copy)
#   GLIMMER_NETWORK_TESTS=1 scripts/test-accessibility.sh  (also Settings › AI with Berget's public model list)
#
# Runs the Debug copy through scripts/test-app.sh (GUI lock, supervisor, no key). The states
# come from the debug build's fixtures (App/DebugFixtures.swift). Exit 0 = all passed.
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  xcrun swiftc -O -o build/axread scripts/axread.swift 2>/dev/null || { echo "Couldn't build scripts/axread.swift"; exit 1; }
  xcrun swiftc -O -o build/window-shot scripts/window-shot.swift 2>/dev/null || { echo "Couldn't build scripts/window-shot.swift"; exit 1; }
  # The picture services are hidden until each has been tried; the test copy shows them, with fal chosen and agreed to.
  # GLIMMER_LANG=sv: the same pass with the copy in Swedish. Every text looked for is named as the source
  # names it and resolved through the catalogue (scripts/catalog-text.py), so one script serves both.
  [[ "${GLIMMER_LANG:-en}" == en ]] || GLIMMER_ARGS="-AppleLanguages (${GLIMMER_LANG}) -AppleLocale ${GLIMMER_LANG}_SE ${GLIMMER_ARGS:-}"
  ARGS="-ai.textProvider berget -ai.textModel.berget glimmer-test/not-a-model -ai.showUntried YES -ai.imageProvider fal -ai.imageNoticeShown.fal YES ${GLIMMER_ARGS:-}"
  if [[ "${GLIMMER_NETWORK_TESTS:-0}" == 1 ]]; then
    # NETWORK TEST, on purpose: Settings › AI is read with Berget's public model list loaded (no key).
    GLIMMER_ARGS="$ARGS" exec scripts/test-app.sh "$0"
  fi
  # The default: a copy that macOS lets make no connection at all (scripts/offline-copy.sh),
  # so nothing here can reach beyond this Mac.
  COPY=$(scripts/offline-copy.sh | tail -1) || exit 1
  GLIMMER_ARGS="$ARGS" GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$0"
fi
TOOLS="${THE_APPS_TOOLS:-}"
for candidate in "$PWD/../the-apps/tools" "$HOME/Projekt/the-apps/tools"; do [[ -z "$TOOLS" && -x "$candidate/axaudit/axaudit" ]] && TOOLS="$candidate"; done
AUDIT="$TOOLS/axaudit/axaudit"; MENU="$TOOLS/safemenu/safemenu"
B=http://127.0.0.1:$GLIMMER_PORT/api/v1
H=(-H 'X-Glimmer-Agent: 1' -H 'Content-Type: application/json')
fails=0
ok() { echo "✔ $1"; }
bad() { echo "✘ $1"; fails=$((fails + 1)); }
front() { perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to tell (first process whose unix id is $GLIMMER_PID) to set frontmost to true" >/dev/null 2>&1; sleep 0.5; }
fixture() { [[ "$(curl -s --max-time 10 -o /dev/null -w '%{http_code}' $H -X POST "$B/debug/fixture" -d "{\"name\":\"$1\"}")" == 200 ]]; }
steps() { curl -s --max-time 60 -o /dev/null $H -X POST "$B/documents/$ID/steps" -d "{\"steps\":[$1]}"; }
# read_state <name> <text that must be among what was read> [seconds to wait first]
# Audits and reads everything on screen now. The app must survive both, and the expected
# text must have been read: a state that never appeared can't pass as "nothing wrong found".
LANG_="${GLIMMER_LANG:-en}"; SHOTS=build/a11y-shots$([[ $LANG_ == en ]] || echo "-$LANG_")
T() { scripts/catalog-text.py "$LANG_" "$1"; }                          # a text of the app, as a pattern, in the copy's language
M() { scripts/catalog-text.py --exact "$LANG_" "$1" | sed 's/\\\(.\)/\1/g'; }  # the same as plain words, for a menu title
shots=0; mkdir -p $SHOTS; rm -f $SHOTS/*.png
read_state() {
  sleep "${3:-1.2}"
  local audit; audit=$("$AUDIT" --pid $GLIMMER_PID --strict 2>&1); local code=$?
  local all; all=$(perl -e 'alarm 60; exec @ARGV' build/axread $GLIMMER_PID 2>&1)
  local seen; seen=$(echo "$all" | tail -1)
  if ! kill -0 $GLIMMER_PID 2>/dev/null; then bad "$1: the app is gone after being read"; echo "    $seen"; exit 1; fi
  local want; want=$(T "$2")
  if ! echo "$all" | grep -qE -- "$want"; then bad "$1: “$2” was not on screen$([[ $LANG_ == en ]] || echo " (in $LANG_: $(echo "$want" | sed 's/\\//g' | cut -c1-70))"), so this state was not read ($seen)"; return; fi
  # What the state is about is brought into view first: a picture of the top of a window is not a look at what is further down.
  perl -e 'alarm 15; exec @ARGV' build/axread $GLIMMER_PID --show any "$(echo "$want" | sed 's/\\\(.\)/\1/g; s/\.\*.*//')" >/dev/null 2>&1; sleep 0.4
  # A picture of each state too (the app's own windows only): a read does not see a sheet that is cut off or a label that wraps.
  shots=$((shots + 1)); build/window-shot $GLIMMER_PID $SHOTS "$(printf '%02d' $shots)-$(echo "$1" | tr -c 'A-Za-z0-9' '-' | cut -c1-48)" >/dev/null 2>&1
  if (( code == 0 )); then ok "$1 ($seen; $(echo "$audit" | tail -1 | cut -d: -f1))"; else bad "$1: $(echo "$audit" | grep -E "UNNAMED|WEAK|OPAQUE|VALUE|SILENT|SAMEID" | head -3 | tr '\n' ' ')"; fi
}
press() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $GLIMMER_PID) to key code $1" >/dev/null 2>&1; sleep 0.6; }

ID=$(curl -s --max-time 60 -H 'X-Glimmer-Agent: 1' -H 'Content-Type: image/jpeg' -X POST --data-binary @site/source-images/mug.jpg "$B/documents?name=accessibility" | python3 -c 'import sys,json;print(json.load(sys.stdin)["document"]["id"])')
[[ -n "$ID" ]] || { echo "Couldn't open a document."; exit 1; }
# Many layers of several kinds, and a history to go with them.
for i in 1 2 3 4; do
  steps "{\"op\":\"add_text\",\"params\":{\"text\":\"Layer $i\",\"y\":$((200 * i))}},{\"op\":\"add_adjustment\",\"params\":{\"type\":\"black_white\"}},{\"op\":\"new_layer\",\"params\":{\"name\":\"Paint $i\"}}"
done
steps '{"op":"select_rect","params":{"x":300,"y":300,"width":400,"height":300}}'
front
read_state "the document with a selection (selection bar)" "Deselect"

"$MENU" --pid $GLIMMER_PID --check "$(M Edit)" "$(M "Heal Selection")" >/dev/null 2>&1 && ok "Edit › Heal Selection is there and enabled" || bad "Edit › Heal Selection"
# Every menu, walked: each item named.
menus=$("$AUDIT" --pid $GLIMMER_PID --menus --strict 2>&1); mcode=$?
if (( mcode == 0 )); then ok "the menus, walked ($(echo "$menus" | tail -1 | cut -c1-90))"; else bad "the menus: $(echo "$menus" | grep -E "UNNAMED|WEAK|OPAQUE|VALUE|SILENT|SAMEID" | head -3 | tr '\n' ' ')"; fi
# The side panel, each tab with content.
fixture panel:layers && read_state "the Layers panel with 13 layers" "Paint 4" || bad "fixture panel:layers"
fixture panel:paths && read_state "the Paths tab" "Paths" || bad "fixture panel:paths"
fixture panel:channels && read_state "the Channels tab" "Channels" || bad "fixture panel:channels"
fixture panel:history && read_state "the History tab with steps" "Agent Edit" || bad "fixture panel:history"
fixture assistant && read_state "the Assistant: requests, a plan with a failed and a skipped step, an error, a refusal" "Claude declined this request (cyber). Nothing was changed." || bad "fixture assistant"
read_state "the plan's failed step says why" "No font named “Nope” is installed."
fixture waiting && read_state "a plan and a command that wait for Run, because the request didn't name them" "I think you mean Rasterize Layer. You didn't name it, so it waits for you." || bad "fixture waiting"
read_state "an extra step the model added, offered and waiting" "The assistant also suggests Auto Enhance, which you didn't ask for. Run it now on the picture as it is?"
fixture refusedPlan && read_state "a plan that can't run because a step would be refused: said, and no Run" "The plan asks Exposure for a setting it doesn't have (brightness), so it can't run. Nothing was changed. Ask again, perhaps in other words." || bad "fixture refusedPlan"
fixture jobs && read_state "the job list: running, failed, done with a cost, cancelled" "OpenRouter rejected the API key." || bad "fixture jobs"
fixture clear   # the job list's running job must not put its spinner in the pictures that follow

# The link bar.
fixture linked && read_state "the bar of a linked document" "Editing frame-0412.png for Flimmer. Command-S saves it back." || bad "fixture linked"
fixture brokenLink && read_state "the bar of a document whose link is broken" "no longer where it was" || bad "fixture brokenLink"
fixture clear

# Every sheet and alert, one at a time; Escape closes it.
alert() { fixture $1 && read_state "alert: $1" "$2" || bad "fixture $1"; front; press 53; fixture clear; sleep 0.4; }
alert healWarning "The area is 203 px across at its thickest. Heal Selection gives good results up to about 120 px; beyond that the fill may smear or repeat."
alert firstUse "a small picture of it"
alert firstUseNoPictures "takes no pictures, so none is sent"
alert cantSee "This model can't look at pictures"
alert error "Couldn't save photo.png: The file “photo.png” couldn’t be opened because you don’t have permission to view it."
fixture imageSize && read_state "sheet: Image Size" "Image Size" 1.5 || bad "fixture imageSize"; front; press 53; fixture clear; sleep 0.5
fixture canvasSize && read_state "sheet: Canvas Size" "Canvas Size" 1.5 || bad "fixture canvasSize"; front; press 53; fixture clear; sleep 0.5

# Agent Access, with its selectable "text for your agent".
fixture splash && read_state "Agent Access (the splash)" "Text for your agent" 1.5 || bad "fixture splash"
front; press 53

# Settings › AI with a model list loaded from the service.
front; "$MENU" --pid $GLIMMER_PID "Glimmer" "$(M "Settings…")" >/dev/null 2>&1; sleep 1.5
osascript -e "tell application \"System Events\" to tell (first process whose unix id is $GLIMMER_PID) to click (first button of toolbar 1 of window 1 whose description is \"AI\" or title is \"AI\")" >/dev/null 2>&1
sleep 5
if [[ "${GLIMMER_NETWORK_TESTS:-0}" == 1 ]]; then
# The chosen model is one Berget doesn't have, so "(no longer listed)" shows only once the
# service's list has loaded (it needs the network; Berget's list is public, no key).
read_state "Settings › AI with Berget's model list loaded" "glimmer-test/not-a-model (no longer listed)"
# Open the Model menu and read the names in it, as they came from the service.
(perl -e 'alarm 20; exec @ARGV' build/axread $GLIMMER_PID --press AXPopUpButton Model >/dev/null 2>&1 &)
sleep 2
listed=$(perl -e 'alarm 60; exec @ARGV' build/axread $GLIMMER_PID 2>/dev/null | grep -cE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.:-]+$')
kill -0 $GLIMMER_PID 2>/dev/null || { bad "the app is gone after the Model menu was read"; exit 1; }
if (( listed > 0 )); then ok "the Model menu's names were read ($listed model ids from Berget's list)"; else bad "no model name was read from the open Model menu"; fi
press 53
else
read_state "Settings › AI with Berget chosen (no network: the model list is not loaded)" "Berget"
echo "– the model list from the service is a network test: GLIMMER_NETWORK_TESTS=1 scripts/test-accessibility.sh"
fi

echo
# The picture service chosen in Settings › AI (hidden in release builds until a service is offered).
read_state "Settings › AI, Pictures with fal chosen" "Model for editing"

MODE=$([[ "${GLIMMER_NETWORK_TESTS:-0}" == 1 ]] && echo "NETWORK TEST (Berget's public model list was fetched)" || echo "no network (a copy that can make no connection)")
# What was read is the debug build, which has every switched feature. A release has only those
# set to YES in Config/Features.xcconfig; what is read here beyond them does not ship yet.
SHIP=$(grep -E '^GLIMMER_[A-Z]+ *= *YES' Config/Features.xcconfig | sed 's/GLIMMER_//; s/ *=.*//' | tr '\n' ' ')
HELD=$(grep -E '^GLIMMER_[A-Z]+ *= *NO' Config/Features.xcconfig | sed 's/GLIMMER_//; s/ *=.*//' | tr '\n' ' ')
echo "Switched features in the build that was read: all on (debug). In a release: on: ${SHIP:-none}; off: ${HELD:-none}."
echo "Language of the copy: $LANG_. Pictures of each state: $SHOTS."
if (( fails == 0 )); then echo "All accessibility checks passed. Run: $MODE."; else echo "$fails accessibility check(s) failed."; exit 1; fi
