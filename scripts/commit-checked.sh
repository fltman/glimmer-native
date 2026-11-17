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
# A full build or test suite: one at a time across the three sessions (scripts/with-build-lock.sh).
[[ "${GLIMMER_BUILD_LOCKED:-0}" == 1 ]] || exec "$(dirname "$0")/with-build-lock.sh" "$0" "$@"
cd "$(dirname "$0")/.."
MSG="${1:?usage: commit-checked.sh <file with the commit message>}"
[[ -s "$MSG" ]] || { echo "No commit message in $MSG"; exit 2; }
[[ -n "$(git status --porcelain)" ]] || { echo "Nothing to commit."; exit 2; }
LOGS=build/commit-check; mkdir -p $LOGS
run() {   # run <name> <command…>
  local name="$1"; shift
  if "$@" > "$LOGS/$name.log" 2>&1; then echo "✔ $name"; else echo "✘ $name failed: $LOGS/$name.log"; tail -5 "$LOGS/$name.log" | sed 's/^/    /'; echo "Nothing was committed."; exit 1; fi
}
# Tests that assert a wall-clock limit do not decide a commit: on a Mac where other sessions
# are building they fail for the machine's reasons, and a gate that does that teaches
# running it again until it passes. They run here and a missed limit is a warning;
# scripts/test-performance.sh is where they are real assertions (before a release, and after
# any change to the renderer or the compositor). The limits themselves are not loosened.
TIMED="PerformanceTests"
tests() {
  swift test --package-path Packages/GlimmerKit --skip "$TIMED" 2>&1 | tee "$LOGS/tests-full.log" | grep -E "error:|✘|Test run with"
  ! grep -qE "error:|✘ Test run|recorded an issue" "$LOGS/tests-full.log" && [[ $(grep -c "✔ Test run with" "$LOGS/tests-full.log") -ge 5 ]]
}
timed_tests() {
  if swift test --package-path Packages/GlimmerKit --filter "$TIMED" > "$LOGS/timed.log" 2>&1 && ! grep -q "recorded an issue" "$LOGS/timed.log"; then
    echo "✔ timing tests (not part of the gate)"
  else
    echo "⚠ a timing test missed its limit (load average $(sysctl -n vm.loadavg | awk '{print $2}')): $LOGS/timed.log. Not a reason to refuse this commit; run scripts/test-performance.sh on a quiet Mac."
    grep "recorded an issue" "$LOGS/timed.log" | sed 's/\x1b\[[0-9;]*m//g' | cut -c1-200 | sed 's/^/    /'
  fi
}
debug_build() { xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration Debug -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|BUILD" | tee /dev/stderr | grep -q "BUILD SUCCEEDED"; }
release_build() {
  xcodebuild -project Glimmer.xcodeproj -scheme Glimmer -configuration Release -derivedDataPath build/DerivedData-release \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= build 2>&1 | grep -E "error:|BUILD" | tee /dev/stderr | grep -q "BUILD SUCCEEDED" \
    && scripts/check-release-binary.sh build/DerivedData-release/Build/Products/Release/Glimmer.app
}
site() { local here="$PWD"; for s in "$PWD/../the-apps/site" "$HOME/Projekt/the-apps/site"; do [[ -f "$s/build.mjs" ]] && { (cd "$s" && node build.mjs --strict); return; }; done; echo "the-apps/site not found"; return 1; }
# In zsh `path` is tied to PATH: a script that uses it as an ordinary variable empties the search path
# (it happened in two sessions' GUI scripts, whose cleanup then never ran). The series' check, when it is there.
zsh_path() { local tool; for tool in "$PWD/../the-apps/tools/check-zsh-path.sh" "$HOME/Projekt/the-apps/tools/check-zsh-path.sh"; do [[ -x "$tool" ]] && { "$tool" scripts; return; }; done; echo "check-zsh-path.sh not found: skipped"; }
run zsh-path zsh_path
run features scripts/apply-features.py --check
run strings scripts/check-strings.py
run entitlements scripts/check-entitlements.sh
run text-logic scripts/check-text-logic.py
run tests tests
timed_tests
run debug-build debug_build
[[ "${GLIMMER_COMMIT_RELEASE:-0}" == 1 ]] && run release-build release_build
run site site
git add -A && git commit -q -F "$MSG" && git log --oneline -1
