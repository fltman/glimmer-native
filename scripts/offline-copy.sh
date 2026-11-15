#!/bin/zsh
# Makes a copy of the Debug build that can't reach the network, for scripts/test-offline.sh.
#
# The copy is signed ad hoc (no identity, no keys) without the App Sandbox's outgoing-network
# entitlement, so macOS itself refuses every connection it tries to make, to the internet and
# to other programs on this Mac alike. It can still listen: the agent API on 127.0.0.1 works.
# Nothing else on the Mac is touched (no firewall rule, no system setting).
# It has its own bundle id (com.brattoo.glimmer.offline.debug): own container and settings.
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$PWD/build/DerivedData/Build/Products/Debug/Glimmer.app"
OUT="$PWD/build/offline/Glimmer.app"
[[ -d "$SRC" ]] || { echo "Build first: scripts/test.sh"; exit 1; }
[[ "$OUT" == */build/offline/Glimmer.app ]] || exit 1
mkdir -p "$PWD/build/offline"
if [[ -d "$OUT" ]]; then mv "$OUT" "$PWD/build/offline/old-$$.app"; fi  # (replaced, not deleted in place)
cp -R "$SRC" "$OUT"
# The Quick Look and thumbnail extensions aren't part of this test, and their ids wouldn't match.
if [[ -d "$OUT/Contents/PlugIns" ]]; then mv "$OUT/Contents/PlugIns" "$PWD/build/offline/PlugIns-unused-$$"; fi
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.brattoo.glimmer.offline.debug" "$OUT/Contents/Info.plist"
ENT="$PWD/build/offline/offline.entitlements"
cat > "$ENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.network.server</key><true/>
</dict></plist>
PLIST
codesign --force --sign - --entitlements "$ENT" "$OUT" >/dev/null 2>&1
codesign -d --entitlements - "$OUT" 2>/dev/null | grep -q "network.client" && { echo "The copy still has the network entitlement."; exit 1; }
echo "$OUT"
