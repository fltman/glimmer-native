#!/bin/zsh
# A release must not contain a feature that Config/Features.xcconfig switches off: not its
# code, not its texts. Looks for each switched-off feature's own strings in the built binary.
#
#   scripts/check-release-binary.sh <path to Glimmer.app or to its binary>
#
# Exit 0 = clean. Run by scripts/release.sh after the build; add a line per new switch.
set -uo pipefail
cd "$(dirname "$0")/.."
TARGET="${1:?usage: check-release-binary.sh <Glimmer.app or binary>}"
[[ -d "$TARGET" ]] && TARGET="$TARGET/Contents/MacOS/Glimmer"
[[ -f "$TARGET" ]] || { echo "No binary at $TARGET"; exit 2; }
typeset -A MARKERS
MARKERS[HEAL]="heal_selection|Heal Selection"   # not the command id "edit.heal": that constant is in every build and reaches nothing
MARKERS[PSD]="8BPS|Import Report|is now pixels|Photoshop file"
MARKERS[RAW]="isn't a RAW file|RAW file that this Mac|Develop RAW"
found=0
ALL=$(strings -a "$TARGET")
for feature in ${(k)MARKERS}; do
  if grep -Eq "^GLIMMER_${feature}[[:space:]]*=[[:space:]]*YES" Config/Features.xcconfig; then
    echo "– $feature is switched on for releases: not checked"
    continue
  fi
  grep -Eq "^GLIMMER_${feature}[[:space:]]*=[[:space:]]*NO" Config/Features.xcconfig || { echo "✘ Config/Features.xcconfig has no GLIMMER_${feature} line"; found=1; continue; }
  hits=$(echo "$ALL" | grep -E "${MARKERS[$feature]}" | sort -u | head -5)
  if [[ -n "$hits" ]]; then
    echo "✘ $feature is switched off, but the binary contains:"; echo "$hits" | sed 's/^/    /'; found=1
  else
    echo "✔ $feature is switched off and not in the binary"
  fi
done
exit $found
