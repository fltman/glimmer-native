#!/bin/zsh
# What Glimmer does when the disk is full, tested inside a small disk image and nowhere else.
#
#   scripts/test-disk-full.sh
#
# Creates a 48 MB APFS image under build/ (on this repository's volume), mounts it under
# /Volumes with a name of its own, fills it
# to a few megabytes free, runs the tests that write an undo snapshot there, and detaches and
# deletes the image again. No real volume is ever filled.
set -uo pipefail
cd "$(dirname "$0")/.."
IMAGE="$PWD/build/diskfull/full.dmg"
NAME="GlimmerFull$$"
MOUNT="/Volumes/$NAME"
mkdir -p "$PWD/build/diskfull"
[[ -e "$MOUNT" ]] && { echo "$MOUNT already exists; not touching it."; exit 1; }
cleanup() {
  # Only the image this run attached, by its own mount point.
  [[ -d "$MOUNT" ]] && hdiutil detach "$MOUNT" -force >/dev/null 2>&1
  [[ -f "$IMAGE" ]] && rm -f "$IMAGE"
}
trap cleanup EXIT INT TERM
[[ -f "$IMAGE" ]] && rm -f "$IMAGE"
hdiutil create -size 48m -fs APFS -volname "$NAME" "$IMAGE" >/dev/null 2>&1 || { echo "Couldn't create the disk image."; exit 1; }
hdiutil attach "$IMAGE" -nobrowse >/dev/null 2>&1 || { echo "Couldn't attach the disk image."; exit 1; }
[[ -d "$MOUNT" ]] || { echo "The disk image didn't mount at $MOUNT."; exit 1; }
# Fill it, leaving about 3 MB.
FREE_KB=$(df -k "$MOUNT" | awk 'NR==2 {print $4}')
dd if=/dev/zero of="$MOUNT/filler" bs=1k count=$(( FREE_KB - 3000 )) 2>/dev/null
echo "test disk: $(df -k "$MOUNT" | awk 'NR==2 {printf "%.1f MB free of %.0f MB", $4/1024, $2/1024}')"
cd Packages/GlimmerKit
GLIMMER_FULL_DISK="$MOUNT" swift test --filter UndoSnapshotTests 2>&1 | grep -E "error|✘|✔ Test|Test run|recorded"
