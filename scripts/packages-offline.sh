#!/bin/zsh
# Nothing that fetches, compiles or installs third-party code runs without Anders's yes in the session's window
# (the-apps rule, 2026-11-17). Glimmer has one third-party package, Sparkle, pinned to one version and revision in
# Config/Package.resolved. An ordinary build uses the copy already checked out and never asks the network.
#
#   scripts/packages-offline.sh <derived data folder>     → prints the xcodebuild flags for an offline build, or stops
#
# It puts the pinned Package.resolved into the generated project, checks that Sparkle is checked out in that derived
# data folder at the pinned revision (sources and the binary artifact), and prints the flags that keep xcodebuild from
# resolving or updating. When the checkout is missing it stops with a plain message; with GLIMMER_ALLOW_FETCH=1
# (set by hand, after Anders has said yes to this fetch) it lets xcodebuild fetch the pinned version instead.
set -euo pipefail
cd "$(dirname "$0")/.."
DD="${1:?give the derived data folder, for example build/DerivedData}"
PIN=Config/Package.resolved
[[ -f "$PIN" ]] || { echo "Config/Package.resolved is missing: the pinned version of Sparkle is not known." >&2; exit 1; }
WANT=$(python3 -I -c 'import json,sys; print([p["state"]["revision"] for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "sparkle"][0])' "$PIN")
# The generated project is not in git; the pin is. (xcodegen leaves the workspace folder alone, but a fresh clone has none.)
DEST=Glimmer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
if [[ -d Glimmer.xcodeproj ]]; then mkdir -p "$DEST"; cmp -s "$PIN" "$DEST/Package.resolved" || cp "$PIN" "$DEST/Package.resolved"; fi
HAVE=""
[[ -d "$DD/SourcePackages/checkouts/Sparkle/.git" || -f "$DD/SourcePackages/checkouts/Sparkle/.git" ]] && HAVE=$(git -C "$DD/SourcePackages/checkouts/Sparkle" rev-parse HEAD 2>/dev/null || true)
ARTIFACT=$(ls -d "$DD"/SourcePackages/artifacts/sparkle/Sparkle 2>/dev/null | head -1 || true)
if [[ "$HAVE" == "$WANT" && -n "$ARTIFACT" ]]; then
  echo "-disableAutomaticPackageResolution -skipPackageUpdates"
  exit 0
fi
if [[ "${GLIMMER_ALLOW_FETCH:-0}" == 1 ]]; then
  echo "Sparkle is not checked out in $DD at the pinned revision; fetching it (GLIMMER_ALLOW_FETCH=1)." >&2
  echo "-disableAutomaticPackageResolution"
  exit 0
fi
{
  echo "Sparkle (third-party code) is not checked out in $DD at the pinned revision ${WANT:0:12}"
  echo "(found: ${HAVE:-nothing}${ARTIFACT:+, artifact present})."
  echo "Building now would fetch it from github.com. That needs Anders's yes in this session's window."
  echo "After his yes: GLIMMER_ALLOW_FETCH=1 <the same command>. Or copy a checkout that is already on this Mac:"
  echo "  cp -R build/DerivedData/SourcePackages $DD/"
} >&2
exit 1
