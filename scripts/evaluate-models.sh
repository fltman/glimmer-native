#!/bin/zsh
# Runs an evaluation that loads a language model on this Mac, one at a time for the whole
# series: under the-apps/tools/with-model-lock.sh and the supervisor, with a time limit.
#
#   scripts/evaluate-models.sh ollama qwen3:8b[,other]   Glimmer's evaluation against Ollama (free, 127.0.0.1)
#   scripts/evaluate-models.sh on-device                 the live tests of Apple's on-device router
#
# A run that used Ollama unloads its model before it ends, also when interrupted: left loaded
# it holds several GB for minutes and Apple's on-device model then fails for every app.
# Never run both kinds in one pass. The log of an Ollama run is build/evaluation.log.
set -uo pipefail
cd "$(dirname "$0")/.."
TOOLS="${THE_APPS_TOOLS:-}"
for candidate in "$PWD/../the-apps/tools" "$HOME/Projekt/the-apps/tools"; do [[ -z "$TOOLS" && -x "$candidate/with-model-lock.sh" ]] && TOOLS="$candidate"; done
[[ -x "$TOOLS/with-model-lock.sh" && -x "$TOOLS/run-supervised.sh" ]] || { echo "Can't find with-model-lock.sh and run-supervised.sh in the-apps/tools."; exit 1; }
KIND="${1:-}"
if [[ -z "${GLIMMER_HOLDS_MODEL_LOCK:-}" ]]; then
  [[ "$KIND" == ollama && -n "${2:-}" || "$KIND" == on-device ]] || { sed -n 2,7p "$0"; exit 2; }
  exec "$TOOLS/with-model-lock.sh" glimmer --wait "${GLIMMER_LOCK_WAIT:-900}" -- \
    "$TOOLS/run-supervised.sh" --timeout "${GLIMMER_TEST_LIMIT:-900}" --watch "$PPID" -- env GLIMMER_HOLDS_MODEL_LOCK=1 "$0" "$@"
fi
mkdir -p build
if [[ "$KIND" == ollama ]]; then
  MODELS="$2"
  unload() { for m in ${(s:,:)MODELS}; do curl -s --max-time 20 -o /dev/null http://127.0.0.1:11434/api/generate -d "{\"model\":\"$m\",\"keep_alive\":0}"; done }
  trap unload EXIT INT TERM
  rm -f build/evaluation.log
  GLIMMER_LOCAL_EVAL="$MODELS" GLIMMER_LOCAL_EVAL_LOG="$PWD/build/evaluation.log" swift test --package-path Packages/GlimmerKit --filter evaluateInstalledModels 2>&1 | grep -E "Test run with|error:"
  cat build/evaluation.log 2>/dev/null
  unload
  echo "Loaded in Ollama afterwards: $(curl -s --max-time 5 http://127.0.0.1:11434/api/ps | python3 -c 'import sys,json;print([m["name"] for m in json.load(sys.stdin).get("models",[])])' 2>/dev/null)"
else
  GLIMMER_ON_DEVICE_TESTS=1 swift test --package-path Packages/GlimmerKit --filter LiveOnDeviceRouterTests 2>&1 | grep -E "→|✘ Test|✔ Test [a-zA-Z]+\(\) passed|Test run with" | sed 's/\x1b\[[0-9;]*m//g'
fi
