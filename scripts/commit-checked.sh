#!/bin/zsh
# Commits only when the checks pass. A failing check leaves nothing committed and nothing
# newly staged. (2026-11-16: a commit went in with a site test failing, because the commit
# was chained after the checks without their result deciding it.)
#
#   scripts/commit-checked.sh <file with the commit message>
#   GLIMMER_COMMIT_RELEASE=1 scripts/commit-checked.sh <file>   (also the release build and its binary check)
#
# Runs: the site texts against the switches, check-strings, the package tests, the Debug
# build, and the site build in strict mode. Each check's whole output is kept in build/commit-check/.
set -uo pipefail
cd "$(dirname "$0")/.."
MSG="${1:?usage: commit-checked.sh <file with the commit message>}"
[[ -s "$MSG" ]] || { echo "No commit message in $MSG"; exit 2; }
[[ -n "$(git status --porcelain)" ]] || { echo "Nothing to commit."; exit 2; }
LOGS=build/commit-check; mkdir -p $LOGS
run() {   # run <name> <command…>
  local name="$1"; shift
  if "$@" > "$LOGS/$name.log" 2>&1; then echo "✔ $name"; else echo "✘ $name failed: $LOGS/$name.log"; tail -5 "$LOGS/$name.log" | sed 's/^/    /'; echo "Nothing was committed."; exit 1; fi
}
tests() {
  swift test --package-path Packages/GlimmerKit 2>&1 | tee "$LOGS/tests-full.log" | grep -E "error:|✘|Test run with" ; 
  ! grep -qE "error:|✘ Test run|recorded an issue" "$LOGS/tests-full.log" && [[ $(grep -c "✔ Test run with" "$LOGS/tests-full.log") -ge 5 ]]
}
debug_build() { xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD" | tee /dev/stderr | grep -q "BUILD SUCCEEDED"; }
release_build() {
  xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration Release -derivedDataPath build/DerivedData-release \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build 2>&1 | grep -E "error:|BUILD" | tee /dev/stderr | grep -q "BUILD SUCCEEDED" \
    && scripts/check-release-binary.sh build/DerivedData-release/Build/Products/Release/Glimmer.app
}
site() { local here="$PWD"; for s in "$PWD/../the-apps/site" "$HOME/Projekt/the-apps/site"; do [[ -f "$s/build.mjs" ]] && { (cd "$s" && node build.mjs --strict); return; }; done; echo "the-apps/site not found"; return 1; }
run features scripts/apply-features.py --check
run strings scripts/check-strings.py
run tests tests
run debug-build debug_build
[[ "${GLIMMER_COMMIT_RELEASE:-0}" == 1 ]] && run release-build release_build
run site site
git add -A && git commit -q -F "$MSG" && git log --oneline -1
