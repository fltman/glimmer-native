#!/bin/zsh
# A copy of the Debug build for a visiting test (another app's session trying its round trip
# against Glimmer): the same program under a bundle id of its own, so it has its own sandbox
# container. Nothing of the visitor's lands in the saved state, autosaved documents, settings
# or keychain items of the copy Glimmer's own work uses, and nothing of ours is seen by it.
#
#   scripts/guest-copy.sh            → prints the copy's path (build/guest/Glimmer.app)
#
# Bundle id: com.brattoo.glimmer.debug.guest. Signed ad hoc with the Debug build's own
# entitlements (it can reach other apps on this Mac, as a real Glimmer can; the no-network
# copy for our own tests is scripts/offline-copy.sh). Start it silently and without restored
# windows:  open -n <path> --args -skipWelcome -skipAgentSplash -skipStartCard YES -quiet YES -ai.noKeychain YES -ApplePersistenceIgnoreState YES
# (-skipStartCard: the start document without its card "Drop a file anywhere…", which is not the Welcome window.)
# After the visit: scripts/guest-clean.sh empties what the guest kept and says what it removed.
# It takes the first free port of 9001, 9101–9119; GET /api/v1/status says its bundle id, port and pid.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD/build/DerivedData/Build/Products/Debug/Glimmer.app"
OUT="$PWD/build/guest/Glimmer.app"
[[ -d "$SRC" ]] || { echo "Build first: scripts/test.sh"; exit 1; }
[[ "$OUT" == */build/guest/Glimmer.app ]] || exit 1
mkdir -p "$PWD/build/guest"
# The copy before this one is kept once (a visitor may still be running it); older ones and their set-aside extensions go.
for old in "$PWD"/build/guest/old-*.app(N) "$PWD"/build/guest/PlugIns-unused-*(N); do rm -rf "$old"; done
if [[ -d "$OUT" ]]; then mv "$OUT" "$PWD/build/guest/old-$$.app"; fi   # (replaced, not deleted in place)
cp -R "$SRC" "$OUT"
# The Quick Look and thumbnail extensions carry the original's ids and are not part of a visit.
if [[ -d "$OUT/Contents/PlugIns" ]]; then rm -rf "$OUT/Contents/PlugIns"; fi   # only the copy's; the Debug build keeps its own
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.brattoo.glimmer.debug.guest" "$OUT/Contents/Info.plist"
ENT="$PWD/build/guest/guest.entitlements"
codesign -d --entitlements - --xml "$SRC" 2>/dev/null > "$ENT"
[[ -s "$ENT" ]] || { echo "Couldn't read the Debug build's entitlements."; exit 1; }
codesign --force --sign - --entitlements "$ENT" "$OUT" >/dev/null 2>&1
codesign -d --entitlements - "$OUT" 2>/dev/null | grep -q "app-sandbox" || { echo "The copy is not sandboxed: it would share files with everything."; exit 1; }
echo "$OUT"
