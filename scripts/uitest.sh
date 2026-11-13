#!/bin/zsh
# UI tests for the critical flows (new document, paint, undo, save, export).
# They drive the real app with the mouse and keyboard; don't use the Mac meanwhile.
# macOS asks once to allow UI automation (password or Touch ID). To skip that prompt on
# a dedicated test Mac: sudo automationmodetool enable-automationmode-without-authentication
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild test -project Glimmer.xcodeproj -scheme GlimmerUITests -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData "$@"
