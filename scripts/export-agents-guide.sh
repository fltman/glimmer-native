#!/bin/zsh
# Regenerates site/agents.md from the same register the app serves at GET /glimmer.
set -euo pipefail
cd "$(dirname "$0")/../Packages/GlimmerKit"
GLIMMER_WRITE_SITE=1 swift test --filter SiteExportTests 2>&1 | grep -E "✔|✘|error" | tail -3
