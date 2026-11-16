#!/bin/zsh
# Rehearses a Sparkle update from one dry-run build to the next, entirely on this Mac.
#
#   scripts/rehearse-update.sh <old-export-dir> <new-export-dir>
#
# Both directories are `export/` folders from `scripts/release.sh --dry-run`. The script
# copies both apps, points their feed at http://localhost:8765/appcast.xml (with an App
# Transport Security exception for localhost), re-signs them with Developer ID, builds a
# DMG of the new app, writes a local appcast signed with the Sparkle key in the keychain,
# serves it, and installs the old app in ~/Applications/Glimmer Update Rehearsal.
# Then open the old app, choose Glimmer › Check for Updates…, and install.
set -euo pipefail
cd "$(dirname "$0")/.."
OLD="$1/Glimmer.app"; NEW="$2/Glimmer.app"
[[ -d "$OLD" && -d "$NEW" ]] || { echo "Usage: $0 <old-export-dir> <new-export-dir>"; exit 1; }
WORK=build/rehearsal/update; INSTALL="$HOME/Applications/Glimmer Update Rehearsal"
IDENTITY="Developer ID Application: Brattoo AB (V783A2L763)"
rm -rf "$WORK" && mkdir -p "$WORK/old" "$WORK/new" "$WORK/feed"

patch() {  # Points the app at the local feed and re-signs it (nested code keeps its signatures).
  local app="$1" plist="$1/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :SUFeedURL http://localhost:8765/appcast.xml" "$plist"
  /usr/libexec/PlistBuddy -c "Delete :NSAppTransportSecurity" "$plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" \
    -c "Add :NSAppTransportSecurity:NSExceptionDomains dict" \
    -c "Add :NSAppTransportSecurity:NSExceptionDomains:localhost dict" \
    -c "Add :NSAppTransportSecurity:NSExceptionDomains:localhost:NSExceptionAllowsInsecureHTTPLoads bool true" "$plist"
  codesign -d --entitlements - --xml "$app" > "$WORK/entitlements.plist" 2>/dev/null
  codesign --force --options runtime --timestamp --entitlements "$WORK/entitlements.plist" --sign "$IDENTITY" "$app"
  codesign --verify --deep --strict "$app"
}

ditto "$OLD" "$WORK/old/Glimmer.app"; patch "$WORK/old/Glimmer.app"
ditto "$NEW" "$WORK/new/Glimmer.app"; patch "$WORK/new/Glimmer.app"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$WORK/new/Glimmer.app/Contents/Info.plist")
STAGE="$WORK/dmg"; mkdir -p "$STAGE"; ditto "$WORK/new/Glimmer.app" "$STAGE/Glimmer.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Glimmer $VERSION" -srcfolder "$STAGE" -ov -format ULFO "$WORK/feed/Glimmer-$VERSION.dmg" >/dev/null
codesign --sign "$IDENTITY" --timestamp "$WORK/feed/Glimmer-$VERSION.dmg"
# The release notes beside the DMG, as release.sh puts them, so the update window shows them here too.
[[ -f "docs/release-notes/$VERSION.html" ]] && cp "docs/release-notes/$VERSION.html" "$WORK/feed/Glimmer-$VERSION.html"

SPARKLE_BIN=$(find build/DerivedData/SourcePackages/artifacts -path "*Sparkle/bin" -type d | head -1)
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "http://localhost:8765/" "$WORK/feed"
echo "▸ Appcast:"; grep -E "<title>|sparkle:version|shortVersionString|edSignature|url=" "$WORK/feed/appcast.xml" | sed 's/edSignature="[^"]*"/edSignature="…"/' | head

rm -rf "$INSTALL" && mkdir -p "$INSTALL" && ditto "$WORK/old/Glimmer.app" "$INSTALL/Glimmer.app"
echo "▸ Installed $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$INSTALL/Glimmer.app/Contents/Info.plist") at $INSTALL"
lsof -tiTCP:8765 -sTCP:LISTEN >/dev/null 2>&1 && kill $(lsof -tiTCP:8765 -sTCP:LISTEN) || true
(cd "$WORK/feed" && nohup python3 -m http.server 8765 --bind 127.0.0.1 > ../server.log 2>&1 &)
sleep 1
curl -sf http://localhost:8765/appcast.xml >/dev/null && echo "▸ Serving $WORK/feed at http://localhost:8765/"
echo "Next: env -u OPENROUTER_API_KEY open \"$INSTALL/Glimmer.app\", choose Glimmer › Check for Updates…, install and relaunch."
