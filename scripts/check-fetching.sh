#!/bin/zsh
# Holds the rule that nothing fetches third-party code or asks an update feed by itself (the-apps, 2026-11-17).
#   scripts/check-fetching.sh        exit 0 = holds
# - Sparkle is the one third-party package, at one exact version in project.yml, with its revision pinned in Config/Package.resolved.
# - GlimmerKit has no package dependencies, so `swift build` and `swift test` have nothing to fetch.
# - Every xcodebuild in scripts/ takes its package flags from scripts/packages-offline.sh.
# - No script runs npm, npx, pip, brew, or downloads with curl or wget, except behind GLIMMER_ALLOW_FETCH.
# - A Debug build or a copy under another bundle id never starts Sparkle (App/Updater.swift).
# - The agent API never starts a model download: only the download sheet and Settings › Models call ModelStore.download.
set -uo pipefail
cd "$(dirname "$0")/.."
fails=0
bad() { echo "✘ $1"; fails=$((fails + 1)); }
grep -q "exactVersion:" project.yml && ! grep -A4 "sparkle-project/Sparkle" project.yml | grep -qE "^\s*(from|minorVersion|majorVersion|branch):" || bad "project.yml does not pin Sparkle to one exact version"
VERSION=$(grep -A4 "sparkle-project/Sparkle" project.yml | sed -n 's/.*exactVersion: *//p')
grep -q "\"version\" : \"$VERSION\"" Config/Package.resolved 2>/dev/null || bad "Config/Package.resolved does not pin Sparkle $VERSION"
grep -q "\.package(" Packages/GlimmerKit/Package.swift && bad "GlimmerKit has a package dependency: swift build and swift test could fetch it"
while IFS= read -r line; do
  file=${line%%:*}; rest=${line#*:}; number=${rest%%:*}
  [[ "$file" == scripts/packages-offline.sh || "$file" == scripts/check-fetching.sh ]] && continue
  sed -n "$(( number > 3 ? number - 3 : 1 )),${number}p" "$file" | grep -q "packages-offline.sh\|PACKAGE_FLAGS\|FLAGS\|flags" || bad "$file:$number runs xcodebuild without the offline package flags"
done < <(grep -nE '^[^#]*\bxcodebuild +(-|\$|archive|test|build)' scripts/*.sh | grep -v "exportArchive\|exportNotarizedApp\|-version")
while IFS= read -r line; do
  file=${line%%:*}; rest=${line#*:}; number=${rest%%:*}
  sed -n "$(( number > 4 ? number - 4 : 1 )),${number}p" "$file" | grep -q "GLIMMER_ALLOW_FETCH" || bad "$file:$number fetches or installs without GLIMMER_ALLOW_FETCH: ${rest#*:}"
done < <(grep -nE '^[^#]*\b(npm|npx|pip3?|brew) +[a-z]|^[^#]*\b(curl|wget)\b[^#]*https?://[a-z0-9.-]*\.[a-z]{2,}' scripts/*.sh scripts/*.py 2>/dev/null | grep -v "127\.0\.0\.1\|localhost\|check-fetching.sh")
grep -q "#if DEBUG" App/Updater.swift && grep -A12 "static var mayUpdate" App/Updater.swift | grep -q 'bundleIdentifier == "com.brattoo.glimmer"' || bad "App/Updater.swift lets a Debug build or a copy under another id start Sparkle"
grep -q "guard Self.mayUpdate" App/Updater.swift || bad "App/Updater.swift starts Sparkle without asking mayUpdate"
grep -nE "ModelStore[A-Za-z.]*\.download\(|\.download\(model" App/*.swift | grep -v "^App/ModelDownloadSheet.swift:" | grep -q . && bad "a model download is started outside the download sheet: $(grep -lE 'ModelStore[A-Za-z.]*\.download\(' App/*.swift | grep -v ModelDownloadSheet | tr '\n' ' ')"
(( fails == 0 )) && echo "Nothing fetches by itself: Sparkle $VERSION pinned, models only from the download sheet, builds offline, no installer in the scripts, no update check outside a release." || { echo "$fails fault(s)."; exit 1; }
