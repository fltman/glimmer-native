#!/bin/zsh
# Starts a test copy of the debug build, runs a command against it, and quits that copy
# (only it, by pid) when the command ends, fails or is interrupted.
#
#   scripts/test-app.sh <command> [args…]
#   scripts/test-app.sh zsh -c 'curl -s http://127.0.0.1:$GLIMMER_PORT/api/v1/status'
#
# The copy is the Debug build, com.brattoo.glimmer.debug: its own container, settings, saved
# windows and keychain item, so tests never touch the real Glimmer.
# The command gets GLIMMER_PID, GLIMMER_PORT and GLIMMER_APP. GLIMMER_ARGS adds launch arguments.
# The copy starts without restoring earlier windows, so the test sees only its own.
# The copy runs without OPENROUTER_API_KEY
# (no test spends money). It runs under the series' shared GUI lock through
# the-apps/tools/with-gui-lock.sh, which takes the lock atomically, never runs without it
# and releases only its own (exit 75: the lock wasn't free within GLIMMER_LOCK_WAIT seconds,
# default 600). Build first with scripts/test.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${GLIMMER_TEST_APP:-$PWD/build/DerivedData/Build/Products/Debug/Glimmer.app}"  # GLIMMER_TEST_APP: another copy, e.g. the offline one
[[ -d "$APP" ]] || { echo "Build first: scripts/test.sh"; exit 1; }
(( $# > 0 )) || { echo "Usage: $0 <command> [args…]"; exit 1; }

# Re-run this script under the shared lock; everything below runs only while it's held.
# The series' shared tools: THE_APPS_TOOLS, or the-apps/tools beside this repository, or in ~/Projekt.
TOOLS="${THE_APPS_TOOLS:-}"
if [[ -z "$TOOLS" ]]; then
  for candidate in "$PWD/../the-apps/tools" "$HOME/Projekt/the-apps/tools"; do
    if [[ -x "$candidate/with-gui-lock.sh" ]]; then TOOLS="$candidate"; break; fi
  done
fi
LOCKER="$TOOLS/with-gui-lock.sh"
if [[ "${GLIMMER_HOLDS_GUI_LOCK:-}" != 1 ]]; then
  [[ -n "$TOOLS" && -x "$LOCKER" ]] || { echo "Can't find with-gui-lock.sh: set THE_APPS_TOOLS to the-apps/tools."; exit 1; }
  # Inside the lock, under the series' supervisor: a time limit (GLIMMER_TEST_LIMIT seconds,
  # default 1800), and it ends when whoever started this script is gone, so a stopped agent
  # can't leave the app running on screen. The trap below then stops the test copy by its pid.
  SUPERVISOR="$TOOLS/run-supervised.sh"
  [[ -x "$SUPERVISOR" ]] || { echo "Can't find run-supervised.sh in $TOOLS."; exit 1; }
  exec "$LOCKER" glimmer --wait "${GLIMMER_LOCK_WAIT:-600}" -- "$SUPERVISOR" --timeout "${GLIMMER_TEST_LIMIT:-1800}" --watch "$PPID" -- env GLIMMER_HOLDS_GUI_LOCK=1 "$0" "$@"
fi
[[ "$(cat /tmp/gui-test.lock/owner 2>/dev/null)" == glimmer ]] || { echo "Not holding the GUI lock; not starting."; exit 75; }

PID=""
cleanup() {  # stops only this test copy; with-gui-lock.sh releases the lock
  if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID"
    for _ in {1..20}; do kill -0 "$PID" 2>/dev/null || break; sleep 0.25; done
  fi
}
trap cleanup EXIT INT TERM

BEFORE=" $( (pgrep -x Glimmer || true) | tr "\n" " ") "
# GLIMMER_FAKE_SERVICE=http://127.0.0.1:<port>: the copy calls a stand-in on this Mac instead of OpenRouter, with a key that
# is no key (scripts/test-service-failures.sh). Refused for any other address, so no test can send a paid request anywhere.
KEYENV=(-u OPENROUTER_API_KEY)
if [[ -n "${GLIMMER_FAKE_SERVICE:-}" ]]; then
  [[ "$GLIMMER_FAKE_SERVICE" == http://127.0.0.1:* ]] || { echo "GLIMMER_FAKE_SERVICE must be on 127.0.0.1."; exit 1; }
  KEYENV=(OPENROUTER_API_KEY=not-a-key-for-the-stand-in)
  GLIMMER_ARGS="-ai.endpoint $GLIMMER_FAKE_SERVICE ${GLIMMER_ARGS:-}"
fi
# The tests look for the app's English words (menus, sheets), so the copy speaks English whatever this Mac's language is,
# unless the test chose a language itself (GLIMMER_ARGS with -AppleLanguages).
[[ "${GLIMMER_ARGS:-}" == *"-AppleLanguages"* ]] || GLIMMER_ARGS="-AppleLanguages (en) ${GLIMMER_ARGS:-}"
env $KEYENV open -n "$APP" --args -skipWelcome -skipAgentSplash -quiet YES -ai.noKeychain YES -ApplePersistenceIgnoreState YES ${=GLIMMER_ARGS:-}
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
# A key in the environment is allowed in one case only: the one that is no key, in a copy pointed at the stand-in on this Mac.
ENVKEYS=$( (ps eww -p "$PID" | grep -o "OPENROUTER_API_KEY=[^ ]*" || true) | sort -u)
if [[ -n "$ENVKEYS" ]]; then
  if [[ -n "${GLIMMER_FAKE_SERVICE:-}" && "$ENVKEYS" == "OPENROUTER_API_KEY=not-a-key-for-the-stand-in" && "$(ps -o command= -p "$PID")" == *"-ai.endpoint http://127.0.0.1:"* ]]; then :
  else echo "The test copy has an OpenRouter key in its environment."; exit 1; fi
fi
echo "▸ Test copy pid $PID on port $PORT"
GLIMMER_PID=$PID GLIMMER_PORT=$PORT GLIMMER_APP=$APP "$@"
