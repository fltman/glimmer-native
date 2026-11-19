#!/bin/zsh
# Regenerates site/agents.md from the same register the app serves at GET /glimmer, and
# brings the manual and FAQ in step with the features the release build has
# (Config/Features.xcconfig, Config/site-features.json).
set -euo pipefail
"$(dirname "$0")/apply-features.py"
cd "$(dirname "$0")/../Packages/GlimmerKit"
GLIMMER_WRITE_SITE=1 swift test --filter "SiteExportTests|RequirementsTests" 2>&1 | grep -E "✔|✘|error" | tail -3
