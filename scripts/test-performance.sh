#!/bin/zsh
# The tests that assert a time limit, as real assertions. Run on a quiet Mac: before a
# release, and whenever the renderer or the compositor changes. The load average is printed
# beside the result, and the last run is kept in docs/performance-last.txt.
# (scripts/commit-checked.sh runs the same tests but only warns: a busy Mac must not decide a commit.)
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
load() { sysctl -n vm.loadavg | awk '{print $2}'; }
BEFORE=$(load)
swift test --package-path Packages/GlimmerKit --filter "PerformanceTests" > build/performance.log 2>&1; CODE=$?
AFTER=$(load)
{
  echo "Timing tests, $(date '+%Y-%m-%d %H:%M'), commit $(git rev-parse --short HEAD). Load average before $BEFORE, after $AFTER."
  sed 's/\x1b\[[0-9;]*m//g' build/performance.log | grep -E "✔ Test|✘ Test|recorded an issue|ms|fps|per second" | grep -v "^◇" | cut -c1-220
  if [[ $CODE == 0 ]] && ! grep -q "recorded an issue" build/performance.log; then echo "Result: all within their limits."; else echo "Result: a limit was missed."; fi
} | tee docs/performance-last.txt
grep -q "all within their limits" docs/performance-last.txt
