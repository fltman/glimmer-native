#!/bin/zsh
# After a visit (the-apps/SIBLINGS.md §1): empties what the guest copy kept, and says what it removed.
#
#   scripts/guest-clean.sh           → removes and lists
#   scripts/guest-clean.sh --dry-run → only lists
#
# It touches nothing but the guest copy's own sandbox container (bundle id com.brattoo.glimmer.debug.guest), and in
# it only: autosaved documents, the saved window state, and the link journal. Not its settings, not its keychain
# (the guest is started without one), and nothing of the real Glimmer or of the Debug copy Glimmer's own tests use.
# It refuses while a guest copy is running. A visitor runs it when its pass is done: the guest's start line restores
# no windows, so a document left at Quit would otherwise lie there unseen.
set -euo pipefail
ID=com.brattoo.glimmer.debug.guest
DATA="$HOME/Library/Containers/$ID/Data"
DRY=0; [[ "${1:-}" == "--dry-run" ]] && DRY=1
[[ -d "$DATA" ]] || { echo "The guest copy has no container yet ($DATA): nothing to clean."; exit 0; }
[[ "$DATA" == "$HOME/Library/Containers/com.brattoo.glimmer.debug.guest/Data" ]] || exit 1
for p in $(pgrep -x Glimmer || true); do
  if [[ "$(ps -o command= -p "$p")" == */build/guest/*Glimmer.app/Contents/MacOS/Glimmer* ]]; then
    echo "A guest copy is running (pid $p). Quit it first; nothing was removed."; exit 1
  fi
done
removed=0
for folder in "$DATA/Library/Autosave Information" "$DATA/Library/Saved Application State/$ID.savedState" "$DATA/Library/Application Support"/LinkJournal*(N); do
  [[ -d "$folder" ]] || continue
  for item in "$folder"/*(ND); do
    size=$(du -sh "$item" 2>/dev/null | cut -f1)
    kind="autosaved document"
    [[ "$folder" == *LinkJournal* ]] && kind="link journal entry$( [[ -f "$item/record.json" ]] && python3 -I -c 'import json,sys; r=json.load(open(sys.argv[1])); print(" (%s for %s, %s)" % (r.get("fileName"), r.get("link",{}).get("requester"), "%s step(s) not saved back" % r.get("unreturnedSteps", "?") if r.get("unreturned") else "nothing waiting"))' "$item/record.json" 2>/dev/null )"
    [[ "$folder" == *savedState ]] && kind="saved window state"
    echo "$([[ $DRY == 1 ]] && echo "would remove" || echo "removed") $kind: ${item#$DATA/} ($size)"
    [[ $DRY == 1 ]] || { chmod -R u+w "$item" 2>/dev/null || true; rm -rf "$item"; }
    removed=$((removed + 1))
  done
done
(( removed == 0 )) && echo "The guest copy kept nothing: nothing to remove." || echo "$removed item(s) $([[ $DRY == 1 ]] && echo "would be removed" || echo "removed") from the guest copy's container."
