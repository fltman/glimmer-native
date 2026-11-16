#!/bin/zsh
# A release must not contain a feature that Config/Features.xcconfig switches off: not its
# code, not its texts. Looks for each switched-off feature's own strings in the built binary.
# A feature that is switched on must be there: a release without it would not match the manual.
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
MARKERS[RAW]="gives no picture for this RAW file|develop this RAW file|Develop RAW"
found=0
ALL=$(strings -a "$TARGET")
for feature in ${(k)MARKERS}; do
  if grep -Eq "^GLIMMER_${feature}[[:space:]]*=[[:space:]]*YES" Config/Features.xcconfig; then
    # Counted, not -q: with pipefail, grep leaving early would fail the pipe and read as "absent".
    if (( $(echo "$ALL" | grep -Ec "${MARKERS[$feature]}") > 0 )); then
      echo "✔ $feature is switched on and in the binary"
    else
      echo "✘ $feature is switched on, but the binary has none of its texts"; found=1
    fi
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
