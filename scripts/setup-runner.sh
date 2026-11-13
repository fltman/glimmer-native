#!/bin/zsh
# Registers this Mac as the GitHub Actions runner for fltman/glimmer-native, so CI runs
# on macOS 27 (GitHub's own machines stop at macOS 26). It installs GitHub's official
# runner in ~/actions-runner-glimmer and starts it as a login service (LaunchAgent).
#
#   scripts/setup-runner.sh            install and start
#   scripts/setup-runner.sh remove     stop, unregister and delete it
#
# The runner executes the repository's workflows as you, on every push to main.
set -euo pipefail
REPO=fltman/glimmer-native
DIR=~/actions-runner-glimmer
VERSION=2.338.2
SHA=25a065af409ffa317ab4d5a3b614dd15fc9c40f2172bc1b35a1b1258e919a388

if [[ "${1:-}" == remove ]]; then
  cd "$DIR"
  ./svc.sh stop || true
  ./svc.sh uninstall || true
  ./config.sh remove --token "$(gh api -X POST repos/$REPO/actions/runners/remove-token --jq .token)"
  cd ~ && rm -rf "$DIR"
  echo "✔ Runner removed"
  exit 0
fi

mkdir -p "$DIR" && cd "$DIR"
if [[ ! -x ./config.sh ]]; then
  curl -sL -o runner.tar.gz "https://github.com/actions/runner/releases/download/v$VERSION/actions-runner-osx-arm64-$VERSION.tar.gz"
  echo "$SHA  runner.tar.gz" | shasum -a 256 -c -
  tar xzf runner.tar.gz && rm runner.tar.gz
fi
if [[ ! -f .runner ]]; then
  ./config.sh --unattended --url "https://github.com/$REPO" \
    --token "$(gh api -X POST repos/$REPO/actions/runners/registration-token --jq .token)" \
    --name glimmer-mac --labels macos-27 --work _work
fi
./svc.sh install || true
./svc.sh start
sleep 3
gh api repos/$REPO/actions/runners --jq '.runners[] | "✔ " + .name + ": " + .status'
