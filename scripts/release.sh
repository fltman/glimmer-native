#!/bin/zsh
# Builds a notarized, stapled Glimmer.dmg signed with Developer ID, plus a Sparkle appcast.
#
#   scripts/release.sh [<version>] [--publish | --notarize-only | --dry-run]
#
# --notarize-only is a full release rehearsal: it builds, signs, notarizes and staples
# exactly like a release, builds the DMG and the appcast, and runs Gatekeeper's checks,
# but commits, tags, pushes and uploads nothing. Everything stays in build/release.
#
# --dry-run builds, signs with Developer ID and makes the DMG and a local appcast, but
# skips notarization, uploading and pushing (for rehearsals; the app is not notarized,
# so Gatekeeper rejects it on other Macs). DOWNLOAD_PREFIX overrides the download URL
# written into the appcast (default: the GitHub release of that version).
#
# With a version (e.g. 0.2.0) it sets that version in project.yml and raises the build
# number (Sparkle compares build numbers, so every release needs a higher one). It runs
# the tests first (SKIP_TESTS=1 skips them). --publish also commits the version, tags
# v<version>, pushes, and creates the GitHub release with the DMG and appcast.
#
# Notarization goes through Xcode, using the account in Xcode › Settings › Accounts.
# Xcode notarizes the app, not the DMG around it, and Gatekeeper rejects an unnotarized
# DMG ("source=Unnotarized Developer ID"), so the script also notarizes and staples the DMG
# with notarytool, using the keychain profile NOTARY_PROFILE (default brattoo-notary, shared
# by the series). It stops before building if the profile is missing; create it once with
# `xcrun notarytool store-credentials brattoo-notary` (Apple ID, team V783A2L763, app-specific password).
# The Sparkle EdDSA key must already be in your login keychain (Sparkle's generate_keys); the
# script stops if it isn't, because a new key would break updates for existing users.
# CREATE_SPARKLE_KEY=1 creates one, for the very first release only.
# Env: SKIP_SPARKLE=1 builds without update signing.
set -euo pipefail
# A full build or test suite: one at a time across the three sessions (scripts/with-build-lock.sh).
[[ "${GLIMMER_BUILD_LOCKED:-0}" == 1 ]] || exec "$(dirname "$0")/with-build-lock.sh" "$0" "$@"
cd "$(dirname "$0")/.."

PUBLISH=0
DRY_RUN=0
NOTARIZE_ONLY=0
NEW_VERSION=""
for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --notarize-only) NOTARIZE_ONLY=1 ;;
    [0-9]*.[0-9]*) NEW_VERSION="$arg" ;;
    *) echo "Unknown argument: $arg"; exit 1 ;;
  esac
done

if (( PUBLISH + DRY_RUN + NOTARIZE_ONLY > 1 )); then echo "Choose one of --publish, --notarize-only and --dry-run."; exit 1; fi
if [[ $PUBLISH == 1 && -n "$(git status --porcelain)" ]]; then
  echo "Commit or stash your changes before publishing."; exit 1
fi
NOTARY_PROFILE="${NOTARY_PROFILE:-brattoo-notary}"
if [[ $DRY_RUN != 1 ]] && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "The notarytool profile \"$NOTARY_PROFILE\" isn't in this Mac's keychain (or Apple can't be reached), so the DMG can't be notarized."
  echo "Create it once (Apple ID, team V783A2L763, an app-specific password from account.apple.com):"
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id V783A2L763"
  echo "or pass NOTARY_PROFILE=<name> for another profile."
  exit 1
fi
if [[ -n "$NEW_VERSION" ]]; then
  BUILD=$(awk '/CURRENT_PROJECT_VERSION/ {gsub(/"/,"",$2); print $2; exit}' project.yml)
  sed -i '' -E "s/(MARKETING_VERSION: )\"[^\"]*\"/\\1\"$NEW_VERSION\"/; s/(CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\\1\"$((BUILD + 1))\"/" project.yml
  # The agent guide on the site names the version (SiteExportTests checks it).
  echo "▸ Agent guide for $NEW_VERSION"; scripts/export-agents-guide.sh
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
if [[ -z "$PUBKEY" && "${SKIP_SPARKLE:-0}" != 1 && "${CREATE_SPARKLE_KEY:-0}" != 1 ]]; then
  # A new key would lock out everyone on an earlier version: their app only trusts the old one.
  echo "The Sparkle signing key isn't in this Mac's login keychain (Sparkle's generate_keys -p found nothing)."
  echo "Import the existing key (generate_keys -f <file>) before releasing. Only for the very first release:"
  echo "CREATE_SPARKLE_KEY=1 $0 $*"
  exit 1
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

# A feature that Config/Features.xcconfig switches off must not be in the release at all.
# Checked on the archive, before anything is signed for distribution or sent anywhere.
scripts/check-release-binary.sh "$OUT/Glimmer.xcarchive/Products/Applications/Glimmer.app" \
  || { echo "The release contains a switched-off feature (see above). Nothing was uploaded."; exit 1; }

if [[ $DRY_RUN == 1 ]]; then
  # Rehearsal: sign with Developer ID locally, no notarization upload.
  cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>V783A2L763</string>
  <key>signingStyle</key><string>automatic</string>
</dict></plist>
PLIST
  echo "▸ Exporting (dry run: Developer ID signature, no notarization)"
  xcodebuild -exportArchive -archivePath "$OUT/Glimmer.xcarchive" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates -quiet
else
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
fi
APP="$OUT/export/Glimmer.app"
if [[ $DRY_RUN == 1 ]]; then
  codesign --verify --deep --strict "$APP"
  SIGNATURE=$(codesign -dvv "$APP" 2>&1)
  [[ "$SIGNATURE" == *"Authority=Developer ID Application: Brattoo AB"* ]] || { echo "Not signed with Developer ID"; exit 1; }
else
  xcrun stapler validate "$APP"
fi
# Only the Release build is Glimmer: Debug builds are com.brattoo.glimmer.debug.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
[[ "$BUNDLE_ID" == com.brattoo.glimmer ]] || { echo "The app is $BUNDLE_ID, not com.brattoo.glimmer; release builds only."; exit 1; }
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
if [[ $DRY_RUN != 1 ]]; then
  echo "▸ Notarizing the DMG (notarytool, profile $NOTARY_PROFILE)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

if [[ "${SKIP_SPARKLE:-0}" == 1 ]]; then echo "✔ $DMG (no appcast)"; exit 0; fi
echo "▸ Sparkle appcast"
mkdir -p "$OUT/updates"
cp "$DMG" "$OUT/updates/"
# Release notes: docs/release-notes/<version>.html, shown in Sparkle's update window.
if [[ -f "docs/release-notes/$VERSION.html" ]]; then
  cp "docs/release-notes/$VERSION.html" "$OUT/updates/Glimmer-$VERSION.html"
else
  echo "  (no docs/release-notes/$VERSION.html: the update window will show no release notes)"
fi
"$SPARKLE_BIN/generate_appcast" --download-url-prefix "${DOWNLOAD_PREFIX:-https://github.com/fltman/glimmer-native/releases/download/v$VERSION/}" "$OUT/updates"
# The app reads its feed from glimmer.brattoo.com (SUFeedURL); this file must be hosted there.
echo "▸ Appcast: $OUT/updates/appcast.xml (host it at $(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$APP/Contents/Info.plist"))"

if [[ $PUBLISH == 1 ]]; then
  if [[ -n "$(git status --porcelain project.yml site/agents.md)" ]]; then
    git commit -qm "Release $VERSION" project.yml site/agents.md
  fi
  git tag "v$VERSION"
  git push -q origin HEAD "v$VERSION"
  gh release create "v$VERSION" "$DMG" "$OUT/updates/appcast.xml" --title "Glimmer $VERSION" --generate-notes
fi

echo "✔ $DMG"
if [[ $DRY_RUN == 1 ]]; then
  echo "  Dry run: not notarized (Gatekeeper will reject it on other Macs), nothing uploaded or pushed."
else
  echo "▸ Gatekeeper"
  spctl --assess --type execute -vvv "$APP"
  spctl --assess --type install -vvv "$DMG"
  xcrun stapler validate "$DMG"
  if [[ $NOTARIZE_ONLY == 1 ]]; then echo "  Notarize-only: nothing committed, tagged, pushed or uploaded; the appcast is local."; fi
fi
