#!/bin/zsh
# Runs the package tests and builds the app. Usage: scripts/test.sh
set -euo pipefail
cd "${0:A:h}/.."

echo "▸ Package tests"
swift test --package-path Packages/GlimmerKit 2>&1 | grep -E '✘|error:|Test run with' || true
swift test --package-path Packages/GlimmerKit --quiet >/dev/null 2>&1 || { echo "✘ package tests failed"; exit 1; }

echo "▸ Generating Xcode project"
xcodegen generate --quiet

echo "▸ Building app"
xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build -quiet
echo "✔ Glimmer.app built: build/DerivedData/Build/Products/Debug/Glimmer.app"
