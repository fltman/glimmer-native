#!/bin/zsh
# Runs a heavy build or a full test suite under the series' build lock: one at a time across the
# three app sessions (the-apps/tools/with-build-lock.sh says why: 16 GB of memory, and on
# 2026-11-16 three sessions building at once paged the apps under test out).
#
#   scripts/with-build-lock.sh <command> [args…]
#
# Order when holding several locks: build lock first, then the GUI lock, then the model lock;
# never take this one while holding one of the others. Inside a run that already holds it
# (GLIMMER_BUILD_LOCKED=1) the command runs as it is. Without the series' tool on this Mac,
# likewise: there is then nobody to take turns with.
if [[ "${GLIMMER_BUILD_LOCKED:-0}" == 1 ]]; then exec "$@"; fi
for tool in "${0:A:h}/../../the-apps/tools/with-build-lock.sh" "$HOME/Projekt/the-apps/tools/with-build-lock.sh"; do
  [[ -x "$tool" ]] && exec "$tool" glimmer --wait "${GLIMMER_BUILD_WAIT:-3600}" -- env GLIMMER_BUILD_LOCKED=1 "$@"
done
exec "$@"
