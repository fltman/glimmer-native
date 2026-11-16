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

Also verified in the debug app:

- Cancel in the AI panel's job list while a 240 px fill runs: no layer is added, the document is as it was. (The computation runs to its end and the result is dropped; at most a few seconds.)
- A hole at the canvas edge and in a corner: filled. A hole that reaches over transparent room around the image: the transparent part of the hole is filled with image too, in a new layer and in place alike. A hole wholly in transparent room: refused with `nothing_to_sample`.
- Edit › Heal Selection reads as disabled for up to about a second after a selection is made through the API. Select › Deselect does the same: it is the menu's own delay in re-reading its state, not something of this command, and Heal Selection has no shortcut that could be pressed in that second.

Not verified:

- Photographs from a camera: only generated sample images were used, as the series' rule for pictures in reports requires.
- A slower Mac (see the limits above).

## Saving only the changed layers: looked into 2026-11-16, not built

Decision (coordinator for Anders): leave saving as it is. Recorded so the investigation isn't repeated.

What was measured, with temporary logging in the writer, on a document saved outside the container:

- Save As, Save in place and the autosave in place all hand the writer a new temporary folder on the document's own volume (`<volume>/.TemporaryItems/folders.<uid>/TemporaryItems/NSIRD_Glimmer_…/<name>.glimmer`), which the system then swaps in. An untitled document's autosave goes to the container's temporary folder.
- On a save in place that folder arrives with the package's subfolders (`layers`, `QuickLook`) but no files. The writer gets the previous snapshot (`previous`), not the previous files.
- The system does not carry over files the writer leaves out: a probe that wrote only `manifest.json` produced a saved package with only `manifest.json`. So every file must be written, or come from somewhere.
- The only "somewhere" is the document's own file URL, and Apple's guidance for the Document protocol says not to use `URLDocumentConfiguration.fileURL` inside `read` or `write`, only the URL handed to the call.

The options, none built:

- A. Clone unchanged layer files from the document's file URL into the temporary folder (instant on APFS). Likely to work, but against that guidance, and it leans on what the system does with the old package during a save.
- B. Go back to Apple's `FileWrapperDocumentWriter` and its documented incremental path (the previous `FileWrapper` is passed in). Sanctioned, but our own writer exists because of the full-disk work (it removes the empty folder on failure and explains the error), and it is unknown whether the system then really avoids rewriting unchanged files. Both would need measuring and the full-disk cycle verifying again.
- C. Leave it. Unchanged layers are already not re-encoded; what remains is disk time: about 2 s for the measured 697 MB document on the internal disk (390 MB/s), about 21 s on the external USB volume it was measured on (33 MB/s). Chosen.

## Text services and local models (2026-11-16)

Verified without any paid call:

- Every text request goes through one interface (`TextModel`); a guard test fails if anything goes around it.
- The chat adapter against answers in the documented form (a made-up provider behind a URLProtocol): Berget, Grunden, Ollama's own chat API and OpenRouter each get the request their documentation describes; a refusal is shown with the service's name, its status and its own words.
- The model-list parsers against what `api.berget.ai/v1/models` and `api.grunden.ai/v1/models` returned on 2026-11-16 (both are public, no key).
- The keychain move of OpenRouter's key (`openrouter-api-key` → `openrouter`), including an interruption at each point.
- OpenRouter's documented Image API (`POST /api/v1/images`) against a made-up answer. The old route is the default until a real call has been made through the new one (`-ai.openRouterImageRoute images`).
- In the debug app: Settings › AI shows the Berget section (key field, links, model list, Refresh); `/status` reports `providerKeys`.

Not verified, because nobody has made a real call: Berget and Grunden with a key (Anders decided they are offered from their documentation alone), and OpenRouter's Image API.

Local model, measured with `LocalModelEvaluation` (twelve everyday requests, six in Swedish, the short tool list, Ollama's own API with a 16,384-token context) against what was already installed in Ollama 0.15.6:

| Model | Right | English | Swedish | Median | Slowest | Verdict |
|---|---|---|---|---|---|---|
| `qwen3:8b` | 10 of 12 | 6 of 6 | 4 of 6 | 4.3 s | 20.4 s | does not pass (the rule: 10 of 12, 5 of 6 in each language, none over 60 s) |
| `gemma3:4b` | not run | | | | | Ollama lists it without tools |

The two misses were both Swedish: "Gör bilden svartvit" got an adjustment without its type, and "Gör bilden hälften så stor" got `width: 1200`. The second was the test's mistake, not the model's: the test document is 2400 × 1600, so a width of 1200 is half the size. The case now accepts that (and `height: 800`, or both), and only those.

With the corrected case, three more runs of `qwen3:8b` (reasoning off, as before):

| Run | Right | English | Swedish | Median | Slowest | Verdict |
|---|---|---|---|---|---|---|
| 1 | 11 of 12 | 6 of 6 | 5 of 6 | 3.9 s | 9.2 s | passes |
| 2 | 11 of 12 | 6 of 6 | 5 of 6 | 3.1 s | 17.5 s | passes |
| 3 | 12 of 12 | 6 of 6 | 6 of 6 | 6.4 s | 65.0 s | does not pass (one answer over 60 s; a GUI test was running on the Mac at the time) |

With reasoning on (`think: true`), one run before the correction: 11 of 12 as judged then, median 23.7 s, slowest 65.3 s. Slower for no clear gain, so reasoning stays off.

So the model sits at the line: right often enough, and the one miss that repeats is "Gör bilden svartvit" answered with an adjustment that lacks its type. Whether Ollama is shown is the coordinator's and Anders's call; until then it is hidden. With every operation as a tool and Ollama's default 4096-token context, the same model had taken two to seven minutes per request and got one of three right. Run it again with `GLIMMER_LOCAL_EVAL=<model> swift test --filter evaluateInstalledModels` (`GLIMMER_LOCAL_EVAL_THINK=1` turns reasoning on).
