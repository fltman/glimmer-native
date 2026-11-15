# Testing notes (for us, not for users)

What is and isn't verified about disk and memory limits. Keep this current when a gap is closed.

## Verified

- Saving to a full disk (Save As onto a 64 MB disk image with 3 MB free): the system's sheet, then Glimmer's explanation; nothing left on the disk; the document stays open and unsaved; saving works once there is room; a later change saves in place. `scripts/test-disk-full.sh` covers the writer at unit level in a 48 MB image.
- Undo spill on a full disk, at unit level in the disk image: refused before writing, nothing half-written, the step stays in memory. The app-level policy (forget the oldest steps, tell the user once) is unit-tested with given free-space numbers.
- Undo spill in the app with a 64 MB budget: ten steps of a two-layer 3000 × 2000 document took 224 MB; undo and redo from disk gave an identical image; a folder left by a killed copy was removed at the next launch.

## Not verified

- Autosave of an **untitled** document when the **home volume** is full. The autosave goes to the app's container on the home volume, which a test must never fill, and the sandboxed app can't be pointed at a disk image for it. It uses the same writer and free-space check as Save, so the same behaviour is expected, but nobody has seen it.
- The low-disk undo notice in the running app (only the policy function and the write failure are tested).
- A 12000 × 8000 document with 60 layers: stopped on the 16 GB build Mac (14 GB of memory, the home volume nearly filled). The numbers in the manual for that size are calculated from the 6000 × 4000 run.

## Rules for tests that can use a lot of disk or memory

- Any test that writes more than about 1 GB, or can make the app do so, runs with a free-space watchdog (stop at 6 GB free on the home volume) and puts its own files on the repository's volume.
- Disk-full behaviour is tested only inside a small disk image that the test creates and detaches.
