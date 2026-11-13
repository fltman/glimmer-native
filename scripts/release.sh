#!/bin/zsh
# Builds a notarized, stapled Glimmer.dmg signed with Developer ID, plus a Sparkle appcast.
#
#   scripts/release.sh [--publish]
#
# One-time setup:
#   xcrun notarytool store-credentials glimmer --apple-id <id> --team-id V783A2L763   (app-specific password)
#   The first run creates the Sparkle EdDSA key in your login keychain (Sparkle's generate_keys).
# Env: NOTARY_PROFILE (default "glimmer"); SKIP_SPARKLE=1 builds without update signing (dry runs).
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE=${NOTARY_PROFILE:-glimmer}
OUT=build/release
VERSION=$(awk '/MARKETING_VERSION/ {gsub(/"/,"",$2); print $2; exit}' project.yml)
rm -rf "$OUT" && mkdir -p "$OUT"

echo "▸ Glimmer $VERSION"
xcodegen generate >/dev/null
xcodebuild -resolvePackageDependencies -project Glimmer.xcodeproj -scheme Glimmer -derivedDataPath build/DerivedData >/dev/null

SPARKLE_BIN=$(find build/DerivedData/SourcePackages/artifacts -path "*Sparkle/bin" -type d | head -1)
[[ -n "$SPARKLE_BIN" ]] || { echo "Sparkle tools not found"; exit 1; }
PUBKEY=""
if [[ "${SKIP_SPARKLE:-0}" == 1 ]]; then
  echo "▸ SKIP_SPARKLE=1: building without an update key"
else
  PUBKEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null || true)
fi
if [[ -z "$PUBKEY" && "${SKIP_SPARKLE:-0}" != 1 ]]; then
  echo "▸ Creating the Sparkle signing key (stored in your login keychain)"
  "$SPARKLE_BIN/generate_keys" >/dev/null
  PUBKEY=$("$SPARKLE_BIN/generate_keys" -p)
fi

echo "▸ Archiving"
xcodebuild archive -project Glimmer.xcodeproj -scheme Glimmer -configuration Release \
  -derivedDataPath build/DerivedData -archivePath "$OUT/Glimmer.xcarchive" \
  SPARKLE_PUBLIC_KEY="$PUBKEY" -quiet

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>V783A2L763</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

echo "▸ Exporting (Developer ID)"
xcodebuild -exportArchive -archivePath "$OUT/Glimmer.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -quiet
APP="$OUT/export/Glimmer.app"
codesign --verify --deep --strict "$APP"

notarize() {
  if xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "▸ Notarizing $(basename "$1")"
    xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait
    return 0
  fi
  echo "⚠︎ No notarytool profile \"$PROFILE\"; skipping notarization (see the header of this script)."
  return 1
}

NOTARIZED=0
ditto -c -k --keepParent "$APP" "$OUT/Glimmer.zip"
if notarize "$OUT/Glimmer.zip"; then
  xcrun stapler staple "$APP"
  NOTARIZED=1
fi

echo "▸ Building the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Glimmer-$VERSION.dmg"
hdiutil create -volname "Glimmer $VERSION" -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null
codesign --sign "Developer ID Application: Brattoo AB (V783A2L763)" --timestamp "$DMG"
if [[ $NOTARIZED == 1 ]] && notarize "$DMG"; then
  xcrun stapler staple "$DMG"
fi

if [[ "${SKIP_SPARKLE:-0}" == 1 ]]; then echo "✔ $DMG (no appcast)"; exit 0; fi
echo "▸ Sparkle appcast"
mkdir -p "$OUT/updates"
cp "$DMG" "$OUT/updates/"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/fltman/glimmer-native/releases/download/v$VERSION/" "$OUT/updates"

if [[ "${1:-}" == "--publish" ]]; then
  [[ $NOTARIZED == 1 ]] || { echo "Refusing to publish an unnotarized build."; exit 1; }
  gh release create "v$VERSION" "$DMG" "$OUT/updates/appcast.xml" --title "Glimmer $VERSION" --generate-notes
fi

echo "✔ $DMG"
[[ $NOTARIZED == 1 ]] && spctl --assess --type open --context context:primary-signature -v "$DMG" || true
