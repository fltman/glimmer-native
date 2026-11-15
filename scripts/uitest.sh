#!/bin/zsh
# UI tests for the critical flows (new document, paint, undo, save, export).
# They drive the real app with the mouse and keyboard; don't use the Mac meanwhile.
# macOS asks once to allow UI automation (password or Touch ID). To skip that prompt on
# a dedicated test Mac: sudo automationmodetool enable-automationmode-without-authentication
set -euo pipefail
# Never spend money in tests: apps and tests run without an OpenRouter key in the
# environment, and no test sends "allowPaid": true to a real provider. Debug builds
# read OPENROUTER_API_KEY from the environment, so a key left there would make paid
# steps real. (GLIMMER_LIVE_AI=1 is the only opt-in, for deliberate live runs.)
if [[ "${GLIMMER_LIVE_AI:-0}" != 1 ]]; then unset OPENROUTER_API_KEY; fi
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild test -project Glimmer.xcodeproj -scheme GlimmerUITests -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData "$@"
# The sandboxed runner can't delete what the app saved.
rm -rf /private/tmp/GlimmerUITest-*
