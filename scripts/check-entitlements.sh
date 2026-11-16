#!/bin/zsh
# The entitlements a release must carry stand in project.yml (XcodeGen writes the .entitlements file
# from it) and in the generated file. With an app as argument: also in that app's signature.
#   scripts/check-entitlements.sh [<Glimmer.app>]
set -u
cd "$(dirname "$0")/.."
NEEDED=(com.apple.security.app-sandbox com.apple.security.files.user-selected.read-write com.apple.security.files.bookmarks.app-scope
        com.apple.security.network.client com.apple.security.network.server)
bad=0
for key in $NEEDED; do
  grep -q "^ *$key: true" project.yml || { echo "✘ $key is not in project.yml's entitlements (XcodeGen would drop it)"; bad=1; }
  grep -q "<key>$key</key>" App/Glimmer.entitlements || { echo "✘ $key is not in App/Glimmer.entitlements: run xcodegen generate"; bad=1; }
done
if [[ -n "${1:-}" ]]; then
  SIGNED=$(codesign -d --entitlements - --xml "$1" 2>/dev/null | plutil -p - 2>/dev/null)
  for key in $NEEDED; do
    [[ "$SIGNED" == *"\"$key\" => true"* ]] || { echo "✘ $key is not in the signature of $1"; bad=1; }
  done
fi
(( bad == 0 )) && echo "The entitlements are in place${1:+, also in the signed app}."
exit $bad
