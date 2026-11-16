#!/bin/zsh
# Runs the package tests and builds the app. Usage: scripts/test.sh
set -euo pipefail
# Never spend money in tests: apps and tests run without an OpenRouter key in the
# environment, and no test sends "allowPaid": true to a real provider. Debug builds
# read OPENROUTER_API_KEY from the environment, so a key left there would make paid
# steps real. (GLIMMER_LIVE_AI=1 is the only opt-in, for deliberate live runs.)
if [[ "${GLIMMER_LIVE_AI:-0}" != 1 ]]; then unset OPENROUTER_API_KEY; fi
cd "${0:A:h}/.."

echo "▸ Package tests"
mkdir -p build
if swift test --package-path Packages/GlimmerKit > build/test.log 2>&1; then
  grep -E 'Test run with' build/test.log || true
else
  grep -E '✘|error:|Test run with' build/test.log || tail -20 build/test.log
  echo "✘ package tests failed (build/test.log)"; exit 1
fi

echo "▸ Texts with Swedish"
scripts/check-strings.py

echo "▸ Generating Xcode project"
xcodegen generate --quiet

echo "▸ Building app"
xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build -quiet
echo "✔ Glimmer.app built: build/DerivedData/Build/Products/Debug/Glimmer.app"
