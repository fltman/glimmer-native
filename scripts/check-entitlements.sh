#!/bin/zsh
# The entitlements a release must carry stand in project.yml (XcodeGen writes the .entitlements file
# from it) and in the generated file. With an app as argument: also in that app's signature.
#   scripts/check-entitlements.sh [<Glimmer.app>]
set -u
cd "$(dirname "$0")/.."
NEEDED=(com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope
        com.apple.security.network.client com.apple.security.network.server)
# GLIMMER_PROJECT_YML / GLIMMER_ENTITLEMENTS: other files to read, for trying the check itself on a planted fault.
YML="${GLIMMER_PROJECT_YML:-project.yml}"; FILE="${GLIMMER_ENTITLEMENTS:-App/Glimmer.entitlements}"
bad=0
for key in $NEEDED; do
  grep -q "^ *$key: true" "$YML" || { echo "✘ $key is not in project.yml's entitlements (XcodeGen would drop it)"; bad=1; }
  grep -q "<key>$key</key>" "$FILE" || { echo "✘ $key is not in App/Glimmer.entitlements: run xcodegen generate"; bad=1; }
done
if [[ -n "${1:-}" ]]; then
  SIGNED=$(codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -p - 2>/dev/null)
  for key in $NEEDED; do
    [[ "$SIGNED" == *"\"$key\" => true"* ]] || { echo "✘ $key is not in the signature of $1"; bad=1; }
  done
  # And nothing beyond what was decided: the five above and Sparkle's two installer services.
  for key in $(echo "$SIGNED" | grep -o '"com\.apple\.[^"]*" =>' | cut -d'"' -f2); do
    [[ " $NEEDED com.apple.security.temporary-exception.mach-lookup.global-name com.apple.security.get-task-allow " == *" $key "* ]] || { echo "✘ $key is in the signature of $1 and was not decided"; bad=1; }
  done
  echo "$SIGNED" | grep -E '^ +[0-9]+ => ' | grep -v -E '"com\.brattoo\.glimmer(\.debug)?(\.guest)?-spk[si]"' | grep -q . && { echo "✘ the Sparkle exception in $1 names something other than Glimmer's two installer services"; bad=1; }
fi
(( bad == 0 )) && echo "The entitlements are in place${1:+, also in the signed app}."
exit $bad
