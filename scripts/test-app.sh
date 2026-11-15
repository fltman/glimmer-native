#!/bin/zsh
# Starts a test copy of the debug build, runs a command against it, and quits that copy
# (only it, by pid) when the command ends, fails or is interrupted.
#
#   scripts/test-app.sh <command> [args…]
#   scripts/test-app.sh zsh -c 'curl -s http://127.0.0.1:$GLIMMER_PORT/api/v1/status'
#
# The command gets GLIMMER_PID and GLIMMER_PORT. The copy runs without OPENROUTER_API_KEY
# (no test spends money), and the script holds the shared GUI lock /tmp/gui-test.lock
# while it runs. Build first with scripts/test.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/DerivedData/Build/Products/Debug/Glimmer.app"
[[ -d "$APP" ]] || { echo "Build first: scripts/test.sh"; exit 1; }
(( $# > 0 )) || { echo "Usage: $0 <command> [args…]"; exit 1; }

if ! mkdir /tmp/gui-test.lock 2>/dev/null; then
  echo "The GUI lock is held by: $(cat /tmp/gui-test.lock/owner 2>/dev/null || echo unknown)"; exit 1
fi
echo glimmer > /tmp/gui-test.lock/owner
PID=""
cleanup() {
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID"
    for _ in {1..20}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
  fi
  rm -rf /tmp/gui-test.lock
}
trap cleanup EXIT INT TERM

BEFORE=" $( (pgrep -x Glimmer || true) | tr "\n" " ") "
env -u OPENROUTER_API_KEY open -n "$APP" --args -skipWelcome -skipAgentSplash
PORT=""
for _ in {1..80}; do
  if [[ -z "$PID" ]]; then
    for p in $(pgrep -x Glimmer || true); do  # only to find it; it's stopped by this pid alone
      if [[ "$BEFORE" != *" $p "* && "$(ps -o command= -p "$p")" == "$APP/Contents/MacOS/Glimmer"* ]]; then PID=$p; fi
    done
  fi
  if [[ -n "$PID" ]]; then
    PORT=$(lsof -nP -a -p "$PID" -iTCP -sTCP:LISTEN 2>/dev/null | awk -F: '/LISTEN/ {split($2, a, " "); print a[1]; exit}' || true)
    if [[ -n "$PORT" ]]; then break; fi
  fi
  sleep 0.25
done
[[ -n "$PID" && -n "$PORT" ]] || { echo "The test copy didn't start its agent server."; exit 1; }
if ps eww -p "$PID" | grep -q "OPENROUTER_API_KEY="; then echo "The test copy has an OpenRouter key in its environment."; exit 1; fi
echo "▸ Test copy pid $PID on port $PORT"
GLIMMER_PID=$PID GLIMMER_PORT=$PORT "$@"
