#!/bin/zsh
# Builds a notarized, stapled Glimmer.dmg signed with Developer ID, plus a Sparkle appcast.
#
#   scripts/release.sh [<version>] [--publish]
#
# With a version (e.g. 0.2.0) it sets that version in project.yml and raises the build
# number (Sparkle compares build numbers, so every release needs a higher one). It runs
# the tests first (SKIP_TESTS=1 skips them). --publish also commits the version, tags
# v<version>, pushes, and creates the GitHub release with the DMG and appcast.
#
# Notarization goes through Xcode, using the account in Xcode › Settings › Accounts.
# The first run creates the Sparkle EdDSA key in your login keychain (Sparkle's generate_keys).
# Env: SKIP_SPARKLE=1 builds without update signing.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISH=0
NEW_VERSION=""
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    [0-9]*.[0-9]*) NEW_VERSION="$arg" ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

if [[ $PUBLISH == 1 && -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes before publishing."; exit 1
fi
if [[ -n "$NEW_VERSION" ]]; then
  BUILD=$(awk '/CURRENT_PROJECT_VERSION/ {gsub(/"/,"",$2); print $2; exit}' project.yml)
  sed -i '' -E "s/(MARKETING_VERSION: )\"[^\"]*\"/\\1\"$NEW_VERSION\"/; s/(CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\\1\"$((BUILD + 1))\"/" project.yml
fi

OUT=build/release
VERSION=$(awk '/MARKETING_VERSION/ {gsub(/"/,"",$2); print $2; exit}' project.yml)
BUILD=$(awk '/CURRENT_PROJECT_VERSION/ {gsub(/"/,"",$2); print $2; exit}' project.yml)
if [[ $PUBLISH == 1 ]] && git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
  echo "v$VERSION is already released; pass a new version."; exit 1
fi
if [[ "${SKIP_TESTS:-0}" != 1 ]]; then scripts/test.sh; fi
rm -rf "$OUT" && mkdir -p "$OUT"

echo "▸ Glimmer $VERSION (build $BUILD)"
xcodegen generate >/dev/null
xcodebuild -resolvePackageDependencies -project Glimmer.xcodeproj -scheme Glimmer -derivedDataPath build/DerivedData >/dev/null

SPARKLE_BIN=$(find build/DerivedData/SourcePackages/artifacts -path "*Sparkle/bin" -type d | head -1)
[[ -n "$SPARKLE_BIN" ]] || { echo "Sparkle tools not found"; exit 1; }
PUBKEY=""
if [[ "${SKIP_SPARKLE:-0}" == 1 ]]; then
  echo "▸ SKIP_SPARKLE=1: building without an update key"
else
  # generate_keys -p prints its error to stdout, so only trust the output on success.
  PUBKEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null) || PUBKEY=""
fi
if [[ -z "$PUBKEY" && "${SKIP_SPARKLE:-0}" != 1 ]]; then
  echo "▸ Creating the Sparkle signing key (stored in your login keychain)"
  "$SPARKLE_BIN/generate_keys" >/dev/null
  PUBKEY=$("$SPARKLE_BIN/generate_keys" -p)
fi
[[ "${SKIP_SPARKLE:-0}" == 1 || "$PUBKEY" =~ ^[A-Za-z0-9+/=]{40,}$ ]] || { echo "Bad Sparkle public key: $PUBKEY"; exit 1; }

echo "▸ Archiving"
xcodebuild archive -project Glimmer.xcodeproj -scheme Glimmer -configuration Release \
  -derivedDataPath build/DerivedData -archivePath "$OUT/Glimmer.xcarchive" \
  SPARKLE_PUBLIC_KEY="$PUBKEY" -quiet

# Xcode uploads the app for notarization with the Apple ID signed in under Xcode › Settings › Accounts.
cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>teamID</key><string>V783A2L763</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST

echo "▸ Exporting and notarizing (Xcode)"
xcodebuild -exportArchive -archivePath "$OUT/Glimmer.xcarchive" -exportPath "$OUT/upload" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates -quiet
for i in {1..90}; do
  xcodebuild -exportNotarizedApp -archivePath "$OUT/Glimmer.xcarchive" -exportPath "$OUT/export" >/dev/null 2>&1 && break
  (( i == 90 )) && { echo "Notarization didn't finish in 30 minutes."; exit 1; }
  sleep 20
done
APP="$OUT/export/Glimmer.app"
xcrun stapler validate "$APP"
BUILT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" -c "Print CFBundleVersion" "$APP/Contents/Info.plist" | tr '\n' ' ')
[[ "$BUILT" == "$VERSION $BUILD " ]] || { echo "The app says version $BUILT, expected $VERSION $BUILD"; exit 1; }

echo "▸ Building the DMG"
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
DMG="$OUT/Glimmer-$VERSION.dmg"
hdiutil create -volname "Glimmer $VERSION" -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null
codesign --sign "Developer ID Application: Brattoo AB (V783A2L763)" --timestamp "$DMG"

if [[ "${SKIP_SPARKLE:-0}" == 1 ]]; then echo "✔ $DMG (no appcast)"; exit 0; fi
echo "▸ Sparkle appcast"
mkdir -p "$OUT/updates"
cp "$DMG" "$OUT/updates/"
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "https://github.com/fltman/glimmer-native/releases/download/v$VERSION/" "$OUT/updates"

if [[ $PUBLISH == 1 ]]; then
  if [[ -n "$(git status --porcelain project.yml)" ]]; then
    git commit -qm "Release $VERSION" project.yml
  fi
  git tag "v$VERSION"
  git push -q origin HEAD "v$VERSION"
  gh release create "v$VERSION" "$DMG" "$OUT/updates/appcast.xml" --title "Glimmer $VERSION" --generate-notes
fi

echo "✔ $DMG"
spctl --assess --type execute -v "$APP"
