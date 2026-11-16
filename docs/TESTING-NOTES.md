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

## Heal Selection (2026-11-16)

Off in release builds (`Config/Features.xcconfig`). The rules it keeps to are in `PATENTS.md`.

Verified:

- Unit level (`GlimmerHealTests`): flat areas, a gradient, stripes and checks come back (the last two exactly); same input, same bytes; what is in the hole never reaches the fill; the smooth fill never overshoots; transparent pixels are never copied; every refusal; cancel. `HealSourceRulesTests` checks the rules in source.
- In the debug app through the API, on the site's generated sample photos: holes of 30, 60, 120, 200 and 250 px on the wooden table of `mug.jpg`, a cloud and a rock in `coast-sunset.jpg`, a drawn 5 px wire across `mountain-lake.jpg` (new layer and in place), every refusal (`no_selection`, `area_too_large` soft and hard, `bad_method`), undo.
- In the debug app by hand of the test script: Edit › Heal Selection (disabled without a selection), the question for a large area (Cancel and Fill Anyway), the new layer, undo.
- A release build with the switch off has no `heal_selection` in `/operations`, no menu item, and none of its strings in the executable except the command id `edit.heal`.

Measured on the build Mac (M-series, 8 fast cores), debug app (the heal target is optimised in debug too):

| Area | Method | Time |
|---|---|---|
| 30 px disc | texture | 0.1 s |
| 60 px disc | texture | 0.2 s |
| 120 px disc | texture | 0.9 s |
| 200 px disc | texture | 2.6 s |
| 250 px disc | texture | 3.6 s (6.1 s on pure noise, the worst case for the search) |
| 390 × 160 px ellipse | texture | 5.6–7.3 s |
| 2528 × 11 px line | texture 1.4–2.0 s, smooth 0.5 s | |

The limits (120 px asks, 250 px refuses, hole pixels × window pixels ≤ 4·10¹⁰) come from these runs. They are not verified on a slower Mac: there the largest allowed fill takes proportionally longer, and the API call is synchronous.

Known weak spots, seen in the runs:

- Fine detail crossing the area (tree tops against a cloud under the wire): the texture fill leaves a streak of the wrong surface about 120 px long; the smooth fill leaves a smear there.
- The smooth fill on a wide area (165 px) shows streaks and a visible meeting line. `auto` doesn't choose it there.
- A selection that doesn't cover the whole object makes the fill continue the object.

Not verified:

- Cancel in the job list while a fill runs (the computation runs to its end and the result is dropped; at most a few seconds).
- Photographs from a camera: only generated sample images were used, as the series' rule for pictures in reports requires.
- Holes at the canvas edge and on layers with transparency, in the app (unit-tested only).
