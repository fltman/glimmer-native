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

From 2026-11-16 the evaluation has fourteen cases: two questions were added (one per language) that must be answered in words with no figure the editor state didn't give, after Jämmer's assistant stated an invented measurement. The rule is the same share: five in six overall and in each language (12 of 14, 6 of 7). `qwen3:8b`, one run with a GUI-free Mac but high swap use: 14 of 14, median 5.2 s, slowest 33.0 s, passes. The Swedish question also asks what upscaling costs; the judge fails any stated price or figure, but it cannot tell whether a claim without a figure ("it is free") is true.

With reasoning on (`think: true`), one run before the correction: 11 of 12 as judged then, median 23.7 s, slowest 65.3 s. Slower for no clear gain, so reasoning stays off.

So the model sits at the line: right often enough, and the one miss that repeats is "Gör bilden svartvit" answered with an adjustment that lacks its type. Whether Ollama is shown is the coordinator's and Anders's call; until then it is hidden. With every operation as a tool and Ollama's default 4096-token context, the same model had taken two to seven minutes per request and got one of three right. Run it again with `GLIMMER_LOCAL_EVAL=<model> swift test --filter evaluateInstalledModels` (`GLIMMER_LOCAL_EVAL_THINK=1` turns reasoning on).

## The paid tests that are Anders's to make (hidden until each is made)

Everything below is built from the services' documentation and tested against made-up answers in the documented form. None has had a real call. Use a debug build, started with the launch arguments shown; keys are entered in Settings › AI by hand.

Text, one service at a time: `-ai.showUntried YES`, then Settings › AI › Service lists the untried ones as "(not tried yet)". Save the key, choose a model from the service's own list, and press **Run Glimmer's Test of This Model…**. It asks first, sends nineteen requests (eighteen counted and one known gap; each carries the list of operations, a few thousand tokens, and gets a short answer), and shows each outcome and the verdict by the same rule as for local models (five in six overall and per language: 15 of 18, 9 of 10 in English, 7 of 8 in Swedish; none over 60 s). That result decides whether the service is offered.

| Service | Built on | Notes for the test |
|---|---|---|
| Berget, Grunden | chat completions | Already offered by Anders's decision; the same button works for them and would be their first real call. |
| Google | its OpenAI-compatible route | |
| OpenAI, xAI | the Responses API | The reply arrives whole, not streamed. |
| Anthropic | the Messages API, version `2026-10-21` (as on platform.claude.com on 2026-11-16) | |

The first-use notice ("Send this to <service>?") shows at the first request to each cloud service and has not been seen in the running app, because no key has ever been saved in a test copy: look at it at the first test and say if the text is right.

Images, one service at a time: with `-ai.showUntried YES`, Settings › AI has a **Pictures** section. Choose the service (Glimmer shows what is sent to it and asks once), save the key, and type the model's id as the service's documentation shows it; for fal also the id of the model's edit endpoint when it isn't `<id>/edit`. The model is typed in because the services' lists of image models were not read. The section is hidden in release builds while OpenRouter is the only service offered for pictures. Then one **Generate** and one **Edit Image with Prompt** (or Generative Fill) in the AI panel.

| Service | How the pictures travel | What to watch for |
|---|---|---|
| OpenRouter, new route (`-ai.openRouterImageRoute images`) | data URLs in the request; base64 back | After one generation and one edit, the new route becomes the default and the old one is removed. |
| OpenAI | data URLs in the request; base64 back | The account may need OpenAI's organisation verification for image models. |
| Google | inline base64 parts; the picture inline in the answer | |
| fal | data URIs in the request, the result asked for as a data URI | If fal answers with a link instead, Glimmer refuses to fetch it and says so: then that model can't be used this way. |
| Hedra | bytes uploaded to Hedra (private handle, one hour), a job, a signed download | Only pictures of yourself, by Hedra's rules. |

Costs: Berget's and Grunden's lists give prices per million tokens (about €0.15–0.50 in), so a nineteen-request run is a fraction of a euro cent. For the others no figure is given here, because their text prices were not read; the image prices per service are in `the-apps/research/providers-glimmer.md` and Flimmer's notes.

## Accessibility is read with content in place

`scripts/test-accessibility.sh` puts up each state through the debug build's fixtures (`App/DebugFixtures.swift`, `POST /api/v1/debug/fixture`), then runs `axaudit --strict` and reads every element (`scripts/axread.swift`). Each state names a text that must have been read, so a state that never appeared cannot pass. The first version of the script passed with the side panel closed: the element count was the same in five states, which is how it was caught.

Found this way on 2026-11-16: the crash on reading a message in the Assistant; the same pattern in Agent Access ("Text for your agent"); and the status chip, whose label replaced its whole content, so the document's name, size and link state were never spoken.

## The Assistant states no figure it wasn't given

`AssistantNumbers` (GlimmerAI) takes out of the Assistant's text, and out of each step's reason, every sentence with a number that is not in the editor state sent with the request, in what the person wrote, or in the plan's own steps; a sentence about money goes the same way. The plan records what was removed. When an answer without steps loses everything, Glimmer writes the size and layer count itself. Where the Assistant's text can carry numbers today: the plan's message, each step's reason, and the summaries of Suggest Edits and Find Distractions, which do not go through this check yet. Costs shown in the app (the job list, the total) come from the service's response, never from the model.

A known gap is measured beside the verdict, not in it (2026-11-16): "Is generating a new image free?". The check sees figures, not claims, so a model calling a paid feature free would get through. `qwen3:8b`, two runs with fifteen requests: 13 of 14 both times (the miss both times: "Gör bilden svartvit" got an adjustment without its type), passes; to the gap question it answered that `generate_layer` "is an AI job that costs money", which is right and comes from Glimmer's own list of operations. The first rule for the gap also demanded a pointer to Settings and marked that answer as not held; the rule was changed after seeing the answer, to accept "it costs" without a figure, and no run has been made under the changed rule. The first question tried was "Is upscaling free?", a bad test: upscaling is done on the Mac at no cost.

Runs that use Ollama end by unloading the model (`keep_alive: 0`): left loaded, `qwen3:8b` holds about 6.6 GB for minutes, and Apple's on-device model then fails with "SensitiveContentAnalysisML error 15" on this 16 GB Mac (seen twice; the four `OnDeviceRouterTests` were green again once the model was unloaded). No on-device tests in the same pass as an Ollama evaluation.

The summaries of Find Distractions and the reasons it gives go through the figures check as well (how many were found is Glimmer's own count and may be said). Suggest Edits proposes edits, so its numbers are the proposal ("crop to 4:5") and stay; only a sentence about money with a figure removes a suggestion. An answer that lost a sentence ends with "Glimmer left out a figure it could not verify.", once.

Since 2026-11-16 the check also runs while an answer arrives (`AssistantNumbers.shownWhileArriving`, applied inside `AgentPlanner.plan`, so the app never receives unchecked text): text without digits or money words flows as it comes; a sentence with either is held until it is finished and checked. A test feeds an answer one character at a time and requires that the invented figures appear at no point.

## Tests reach nothing but this Mac (2026-11-16)

Package tests: `NetworkGuard` (Packages/GlimmerKit/Tests/Support) is loaded into every test process before any test runs (a C constructor, so no test can get ahead of it). It stands first for `URLSession.shared` and for every session made from the default or ephemeral configuration, refuses a request to any host but this Mac before a name is looked up, and makes the run fail at exit. Proven once with a throw-away test that asked for `https://example.invalid` through both kinds of session: both refused, exit 1. The two fakes (`FakeProvider`, `FakeJammer`) are the only sessions tests build themselves, and a test fails if a third appears. What the suite reached before the guard: nothing public; the service adapters, the model lists of Berget and Grunden included, were already tested against the fake. Only the gated suites go out: `GLIMMER_LIVE_AI=1` (OpenRouter, paid, never run by an agent) and `GLIMMER_NETWORK_TESTS=1`; the guard prints "NETWORK TESTS" when either is set. The Ollama evaluation talks to 127.0.0.1 only.

Scripts: `test-offline.sh` and now `test-accessibility.sh` run a copy that macOS lets make no connection. `GLIMMER_NETWORK_TESTS=1 scripts/test-accessibility.sh` is the one network test: it reads Settings › AI with Berget's public model list (no key) and says so in its last line. `test-linked-restart.sh`, `test-gpu-memory.sh` and `test-disk-full.sh` run the ordinary debug copy, which is allowed to connect; nothing in them opens Settings or asks for anything paid, and the updater is off in builds without a signing key, but that the copy makes no connection at all in those runs is reasoning, not measured.

A key stays with its service: every request that carries a key refuses a redirect to another host or down to plain http (`KeyStaysHome`), so the redirect becomes the answer. The one address Glimmer takes from a service's answer and fetches is Hedra's signed download: https only, fetched without the key. Hedra's job id goes into a path of requests with the key and must be a plain identifier.

Added 2026-11-16, all hidden: streaming for Anthropic and OpenAI (the Assistant's text arrives as it is written; xAI's pages name no stream events for its Responses API, so its reply stays whole), and MLX (`mlx_lm.server` on 127.0.0.1:8080, the plainest chat-completions request, no key). MLX is built from one documented fact, its endpoint; `mlx_lm` is not installed on this Mac, so it has made no call at all and has not run the evaluation. In a debug copy with `-ai.showUntried YES` it is listed under Service as "MLX (not tried yet)", with the test button.

## What a small model is sent, and requests that name no edit (2026-11-16)

Series rule: the evaluation is run whenever an operation is added, removed or reworded, for every model offered by default, and the list sent to a small model does not change without a recorded decision.

- The short list for local models (the planner's operations that are also "core"): 11 tools before this week's additions and 11 after. On 2026-11-15 (abe4a84) crop, resize_image and set_layer took the places of apply_filter, apply_preset and auto_color. As JSON it is 9,642 bytes today; the system prompt is 1,790 bytes. `ShortToolListTests` pins the eleven names and the size (300 bytes of room for a reworded description).
- The full list for cloud models went from 25 operations to 33 this week, 25,211 bytes today. No evaluation has been run with it: the default cloud model costs money, so that run is on Anders's list.
- The on-device router (Apple's model) is not sent the operations at all: fixed instructions (974 characters) and at most a dozen palette matches. It does not grow with the list.
- Nothing was measured before this week: the evaluation was written on 2026-11-16, after the swap. Today's numbers are the baseline.

Baseline, `qwen3:8b`, the short list above, seventeen counted cases (three new ones that name no edit: "Write a poem about the sea", "Berätta ett skämt", "Thanks, that looks good", which pass only when no step is planned): 16 of 17 (English 9 of 9, Swedish 7 of 8), median 2.8 s, slowest 28.9 s, passes. The miss is the known one ("Gör bilden svartvit", an adjustment without its type). All three no-edit requests got an answer in words and no step. The known gap ("Is generating a new image free?") under the changed rule: not held, 0 of 1; the answer began "No, generating a new image using the `generate_layer` tool i…" and the log cut it there, so why the rule rejected it is not known. The log now keeps 240 characters.

The on-device router's four live tests were red in the same hour (FoundationModels, "SensitiveContentAnalysisML error 15"), with Ollama's model unloaded and swap at 15.2 of 16 GB; they fail in 0.03 s, before any answer. So unloading Ollama is not the whole explanation, and there is no on-device number for today.

What Glimmer did with a plan until 2026-11-16: a plan whose steps were all the editor's own ran at once; only a plan with a paid step waited for Run. Since then (`PlanCheck`): a plan runs at once only when the request names every step that changes the document (word stems in English and Swedish per operation; a text layer's text must be in the request itself); otherwise it is shown, says why, and waits for Run. The same for a single command chosen by the on-device router. An operation Glimmer has no words for always waits. The evaluation has a case that must still run at once ("Make it black and white") and its three no-edit cases pass only when nothing would change without confirmation. Eighteen counted cases: 15 of 18, 9 of 10 in English, 7 of 8 in Swedish. Not yet run with a model under this rule; `qwen3:8b` adds an Auto Enhance step to its black-and-white plans, which the new case will count against it.

The live on-device tests are out of the ordinary run (`GLIMMER_ON_DEVICE_TESTS=1`, set by `scripts/evaluate-models.sh on-device`); `scripts/test.sh` says what it skipped.

Later the same hour, under the series' model lock (`scripts/evaluate-models.sh on-device`, one model at a time for all three apps): the on-device router's four live tests passed, 4.6 s in all. The red run above coincided with Jämmer running an evaluation of its own at the same moment, which is what the lock now prevents. Evaluations go through `scripts/evaluate-models.sh` (`ollama <model>` or `on-device`): model lock, supervisor, a time limit, and Ollama's model unloaded at the end and on interruption. The ordinary package test run still includes the four live on-device tests whenever Apple's model is available, outside the lock.

## Photoshop files (phase 10), import (2026-11-16)

Reader and import are Glimmer's own code from Adobe's published specification. All test files are written by the tests' own writer (`Tests/Support/PSDTestSupport`); none is downloaded and none comes from Photoshop, so the reader has only met files written from the same reading of the specification. A real file from Photoshop may hold things the generator can't imagine.

- Read back sample for sample: 8 and 16 bits, PSD and PSB, raw, run-length and both ZIP forms.
- Hostile input: files cut at every length; every byte set to four values, one at a time, in three variants; lying sizes and counts; groups without ends and ends without groups; nesting deeper than 64; run-length and ZIP data that would give more than the plane holds. No crash, nothing decoded beyond the budget. There is no time limit on an import yet.
- Appearance, measured against the flattened picture each generated file carries (mean per channel on 0…255, share of pixels off by more than 8): one opaque layer, 8 and 16 bit: 0.0 and 0; Multiply over a gradient: 0.04 and 0; a 50 % transparent layer: 0.06 and 0 with the document blending in gamma, 1.27 and 19 % if it blended in linear light. The gamma setting is what keeps the look. (Multiply alone does not show the difference: it is nearly the same in both.)
- In the running app (`scripts/test-psd-import.sh`, the no-network copy): a file where everything comes through and one with text, a Levels layer and a Lighter Color layer in a group; the report sheet appears, is read through the accessibility API and has no unnamed controls; the answer of the agent API carries the same report; a damaged file is refused with a reason. For the second file the report says the picture differs from the file's (25 % of the pixels), because the Lighter Color layer is drawn as Normal.

Not built yet: text strings and font names kept on the layer; the contents of smart objects kept in the document; adjustment, fill and shape layers; layer effects and vector masks; the three missing blend modes; writing Photoshop files. The report's lines are in English only, and the report is not saved with the document.

Photoshop import is behind a build switch, `GLIMMER_PSD` in `Config/Features.xcconfig`, NO for releases until a file saved by Photoshop itself has met the reader (the coordinator's decision, 2026-11-16). Debug builds have it. With NO the reader, the import, the report sheet and the menu item are not compiled in at all (checked in a Release build with `strings`: no "8BPS", no report text), and a Photoshop file opens as before, as the flattened picture macOS reads from it. The manual's section and the agent guide's line follow the switch (`Config/site-features.json`).

Not built, and why: Dissolve, Darker Color and Lighter Color. Adobe's help page on blending modes answered 403 to the fetch, so I have no source for how Darker Color and Lighter Color pick a colour (I remember "the total of all channel values" and will not build on a memory), and Dissolve's pattern can't match another program's pixel for pixel. They wait for a readable source or a file from Photoshop to measure against.

When a check fails, its whole output is kept in a file before it is summarised (`build/site-build.log` for the site build), after one failed site build whose text was lost.

The import report is now saved in the document (its manifest) and shown in the person's language; the agent API gives it in English, each note with its kind. `scripts/check-release-binary.sh` fails a release whose binary holds the strings of a feature that `Config/Features.xcconfig` switches off (Heal, Photoshop import); `scripts/release.sh` runs it on the archive before anything is exported or uploaded. Not exercised: `release.sh` itself with the new check, since a release run needs Anders; the check was run by hand on an ad hoc Release build (clean) and, once, caught `heal_selection` in a word table.

Darker Color, Lighter Color and Dissolve are not built (decision 2026-11-16): the documented rule for the first two ("the total of all channel values for the blend and base color", as tutorials quote Adobe's help; the help page itself answered 403) is reported not to match what Photoshop does (an Adobe community thread and an ImageMagick forum post, found by the coordinator: https://community.adobe.com/t5/photoshop/darker-color-blend-mode-behaviour/m-p/9484300 , https://www.imagemagick.org/discourse-server/viewtopic.php?p=120551 , https://vargiskhan.com/log/?p=1771 ). The open question is sum of channels or luminance; a file from Photoshop with those modes, measured against its own composite, tells them apart. Until then such a layer comes in as Normal with the measured difference in the report. Dissolve's pattern can't match another program's, so it stays out.

Photoshop import, part 3 (2026-11-16), from the byte layouts read on the specification page:
- Descriptors (the structure settings are stored in) are read generically, bounded in depth and item count; a descriptor cut at every length or with an unknown type gives an error, never a crash.
- A solid colour fill comes in as a fill layer; with a vector mask it is a shape with its outline as an editable path (path records: 26 bytes, points as 8.24 fixed-point shares of the image, vertical first). An inverted outline is left out and said.
- Levels, Curves and Invert come in as adjustment layers. Measured against the arithmetic by the book: Levels (10, 240, gamma 1.2) mean 0.17 of 255, nothing visibly different; Invert 0.0; a shape over a gradient 0.0. Curves has the same points and a note that the curve between them may differ; it was not measured.
- A text layer's words are quoted in the report.
- Not from the page, and so unverified until a file from Photoshop is measured: the names of the colour keys inside a fill's descriptor (the page does not give them; red, green, blue are taken by the keys other files use, else in order), the order of the vector mask's flag bits (the page says "bit 1 = invert, bit 2 = not link, bit 3 = disable"; read as the three lowest bits), and that a text block's first string is its words. The composite comparison is the check on all three once a real file exists.
- Left out and named, because the page gives no layout for their data or their arithmetic differs between programs: Brightness/Contrast, Exposure, Hue/Saturation, Vibrance, Color Balance, Black & White, Photo Filter, Channel Mixer, Posterize, Threshold, Gradient Map, Selective Color, Color Lookup; gradient and pattern fills.
- In the app's test the second sample reports 100 % of the pixels different: its flattened picture is only the background, because the tests' writer does not draw the layers into it. That number says nothing about the import; the measured cases above are the ones with a correct picture in the file.

Evaluation under the plan check (2026-11-16, `scripts/evaluate-models.sh ollama qwen3:8b`, model lock, one run, with the package tests running beside it): 16 of 18 (English 9 of 10, Swedish 7 of 8), median 6.1 s, slowest 50.5 s, passes. The two misses are both the black-and-white adjustment without its type ("Gör bilden svartvit" and the new "Make it black and white"); in all three black-and-white answers the model also added Auto Enhance, which nobody asked for, so under the plan check those plans wait for Run. The known gap under the changed rule: not held, and now with the whole answer: "No, generating a new image using the `generate_layer` tool is not free; it is an AI job that costs money and takes time. However, the `auto_enhance` tool is free…". The answer is right; the rule rejects it because the word "free" comes back about another tool. The rule is cruder than the answer, and is left as it is rather than tuned to this answer a second time. Ollama's model was unloaded afterwards.

Photoshop import: an import gives up after 60 seconds (`PSDFile.Limits.seconds`). The words of a layer that was text are kept on the layer (`Layer.formerText`, saved, in the agent API's layer description) as well as in the report. The font's name is not kept: the specification gives no layout for where a text block holds it. To measure against a file from Photoshop when there is one: Curves between its points, the three assumptions above, Darker Color and Lighter Color, and each adjustment kind now left out.

The assistant with `qwen3:8b`, the same model and the same eighteen cases, as the app changed on 2026-11-16 (one run each, under the model lock):

| What changed in the app | Result | Misses |
|---|---|---|
| The plan check alone | 16 of 18 | "Gör bilden svartvit" and "Make it black and white": the adjustment came without its type |
| A missing type is taken from the request when its words name exactly one kind | 17 of 18 | "Make it black and white": the type is filled in, but the plan waits because of the Auto Enhance the model added |
| A line in the prompt: plan only what the request asks for | 17 of 18 | the same; the model still added Auto Enhance to all three black-and-white requests, and nothing else changed |
| An unasked Auto Enhance or Auto Color beside what was asked is held back as an offer; the rest runs | 18 of 18 | none |

The model did not get better; the app did. The prompt line had no measured effect on this model and is kept (it states the rule the plan check enforces, and nothing got worse). Between runs the model sometimes gives the black-and-white type itself and sometimes not, so single runs differ by a case. The known gap stayed "0 of 1 held" throughout. Not seen in a real conversation in the app: the offer and the filled-in type are tested through the planner with scripted answers and, for the offer's look, through a fixture.

Kept for later (the coordinator's decision, 2026-11-16: wait for a real file and do it once): the contents of smart objects. The sketch: keep the placed file's bytes as they are in the document package under attachments/<id> with the original name, matched to its layer by finding the linked block's unique id among the strings of the layer's descriptor; the layer stays pixels with a mark; the report gives name and size per file and the total; a limit from the import budget; "Save Placed File…" to write one out. Making them Glimmer smart objects needs the transform, whose key names the specification does not give.

Linked edit, the file changing while Glimmer runs (2026-11-16, found by Flimmer's re-test: `available` stayed true and ⌘S gave a bare "doesn't exist" error): the linked file is looked at once a second while the document is linked or was, and again at the moment of ⌘S. Removed: the bar, the menu and the agent API's `available` change within the next second, and ⌘S explains and points to Save a Glimmer Copy…. Put back, or replaced by another file at the same place: linked again, and Save Back writes into it. A second fault showed in the same run and is fixed: a file handed over again while its window had a broken link opened a second document for the same file; the hand-over now takes the window that is there. `scripts/test-linked-restart.sh`: 45 checks, all pass. It is a once-a-second look, not a file-system watch: up to a second can pass before the bar changes, and the check at ⌘S covers that gap. Not tried: a file on a volume that is unmounted.

## Photoshop files, export (phase 10), not yet reachable from the app (2026-11-16)

`PSDWriter` (model to bytes) and `PSDExport` (a Glimmer document to that model), behind `GLIMMER_PSD`.

Written as what they are: pixel layers (straight alpha, sRGB, 8 or 16 bits), groups open or closed, masks with their default colour and on/off state, names (also in Unicode), opacity, visibility, clipping, the 25 blend modes, solid colour fills, shapes with their outline, Levels, Curves, Invert, the colour profile (sRGB), and the flattened picture over white. Written as pixels that look the same, and said: text, smart objects, gradient and pattern fills, layers with effects. Not written as a layer, and said: the other adjustment kinds (the flattened picture still shows them). Also said: a mask's feather and density (written plain), pixels in tiles wholly outside the canvas, a Display P3 document (written in sRGB), and a document that blends in linear light, with the measured difference of its layers blended in gamma.

Measured, a 48 × 32 document with one of everything (`PSDRoundTripTests`), Glimmer → PSD → Glimmer:
- Every field comes back: order and nesting, names, blend modes, opacity to 1/255, visibility, clipping, group open/closed, fill colours, the shape's outline within 0.001 px, Levels within the file's steps, Curves points exactly, masks' default and on/off. A second trip changes nothing more.
- The picture before against after: mean 0.03 of 255 at 8 and at 16 bits, nothing visibly different.
- The file's flattened picture as macOS (ImageIO) decodes it, against the document: mean 0.02, nothing visibly different. ImageIO names the file `com.adobe.photoshop-image`.
- A gradient fill written as pixels: mean 0.20 after the trip, nothing visibly different.
- A document in linear light: its layers blended in gamma differ by mean 6.4, visibly on 70 % of the pixels of this test document. That is the number the export shows before saving.
- The writer refuses what its reader would refuse (sides over 30,000, depths and modes it doesn't write, planes that don't fit, more than 8,000 layers); a written file cut at every length and with every byte changed is refused or read without a crash; the same file written twice is the same bytes.

Not verified: that Photoshop reads the layers. The only outside reader on this Mac reads the flattened picture. The 16-bit round trip uses the same 8-bit comparison, so it shows no loss rather than measuring 16-bit precision. Text is not in the test document (it would be written as pixels like the gradient fill).

Export in the app (2026-11-16): File › Export… has a **Photoshop File…** button (a button in the Export sheet, not an entry in the format list: the list is a shared type used by Shortcuts and batch export too). Its sheet shows the report before saving, the bit depth, and for a linear-light document the choice between the layers as they are and one merged layer, with the measured difference. The agent API: `export` with `"format": "psd"` (`depth`, `flatten`), the report as JSON in the `X-Glimmer-Export-Report` header. Tried in the running app (`scripts/test-psd-import.sh`): a document exported through the API, read by macOS (`sips`), opened in Glimmer again with the same layers and with its flattened picture matching them; the sheet read through the accessibility API, no unnamed controls. Not tried: the Save… panel itself (a file dialog), and the merged-layer choice in the app (it is tested in the package only by its report; no test reads the merged file back).

## RAW development (phase 11), part 1, not yet reachable from the app (2026-11-16)

Decoder: Apple's `CIRAWFilter` (facts from the header in the installed macOS 27 SDK). Behind `GLIMMER_RAW`, NO for releases until Anders has looked at a real camera file developed by it.

`RawDevelopment` (GlimmerRender): the file's size and what can be set, read from its header and checked against the megapixel limit before anything is decoded; development to Glimmer's own pixels with exposure, temperature and tint, shadows, contrast, highlight recovery, both noise reductions, sharpness, lens correction and the process (decoder version); a small draft for while a control moves; white balance from a clicked point, which the decoder gives directly (`neutralLocation`).

Test files: the tests write their own DNG (a Bayer mosaic in a TIFF with DNG tags; `DNGTestWriter`). Apple's decoder takes it once it has the crop, scale and calibration tags and is not tiny: a 64 × 48 file gave a filter with no picture, 640 × 480 works. A "linear" DNG (three samples per pixel) was accepted too but its colours came out wrong in my attempt, so the tests use the mosaic. Nothing was downloaded.

Measured on the test file (sRGB values of a patch): middle grey 155 at −1 stop, 204 as shot, 241 at +1 stop; white balance at 3000 K gives (170, 205, 247), at 12000 K (245, 227, 199); clicking on a warm patch (255, 199, 197) gives a balance under which it is (238, 238, 238); the stored process gives the same picture again and a process the system does not offer is refused with words; a draft at a quarter scale is a quarter the size; the file cut at 37 lengths is refused every time; data that is not a RAW file is refused.

Not verified: any file from a real camera. The test file's decoder reports no lens correction, so that control has never been switched on anything. What happens inside Apple's decoder on a hostile file is not something Glimmer can test or bound.

## Photoshop files written by Photoshop (2026-11-16)

Anders approved the fetch in the session window. Eighteen test files from the psd-tools project's `tests/psd_files` (repository licence MIT, "Copyright (c) 2019 Kota Yamaguchi"; its `third-party-psds` folder was not fetched), about 3 MB, kept in `/Volumes/work2/glimmer-samples/psd`, outside the repository. They carry Photoshop's own block set. Run: `GLIMMER_PSD_SAMPLES=<folder> swift test --filter PSDRealFiles`.

No crash, no hang, the slowest file 0.8 s. What the real files showed that Glimmer's own generated files could not:

| Found | What it was | Now |
|---|---|---|
| `mask-vector-density.psd` refused as damaged | A layer with a vector mask and a painted mask stores the painted mask a second time with a rectangle of its own (channel −3), and the mask data can hold density and feather values; the reader used the first rectangle for both | read correctly |
| Curves layers left out | In real files the block is one byte, version 1, a four-byte bit map; the specification's page describes the load-file form (no leading byte, two-byte map) | read |
| Curves read but the picture differed (61 % of the pixels, mean 8.5) | Photoshop draws a natural cubic spline through the points; Glimmer's own curve is monotone | curves from a file are drawn the natural way (a flag on the adjustment), and the picture matches; a curve made in Glimmer is exported with points added along it (read back within 0.5 of 255) |
| Every file with a transparent background "differed" by about 79 % | The flattened picture in such a file is already laid on white, with the transparency in a fourth channel; macOS's reader applies that channel once more | the comparison reads the file's colour planes directly |
| Darker Color, Lighter Color | In the files blue wins over red and red over green in Darker Color (and the reverse in Lighter Color); their channel sums are equal, their luminances are not | both built, by luminance; both files match |
| The three assumptions | Colour keys in a fill are "Rd  ", "Grn ", "Bl  "; the vector mask's flags were 0 in every file (so the bit order is still not settled); no file had text | two of three settled |

Per file, Glimmer's picture of the layers against the picture saved in the file:

| File | Result |
|---|---|
| 16bit5x5, group, blend-modes normal / multiply / darker-color / lighter-color, adjustments levels, adjustments curves | match |
| adjustments invert | 0.6 % of the pixels visibly, mean 0.1 |
| blend-modes dissolve | differs (79 %): Dissolve is not built, the layers come in as Normal, and the report says so |
| adjustments brightness/contrast, exposure, hue/saturation, posterize, threshold | differ (71 to 99 %): those adjustment kinds are left out and named |
| fill_adjustments (every adjustment kind, shapes with effects) | differs (100 %): 14 kinds left out and named, effects not read |
| mask-vector-density | differs (37 %): vector masks on pixel layers are not read, and said |
| gradient-fill | 32 bits per channel: opened as the file's flattened picture, and said |

Every difference is one the report names. Still not met by any real file: text layers, smart objects, the vector mask's flag bits when set, PSB, CMYK and Lab.

## RAW files from cameras (2026-11-16)

Eight files from raw.pixls.us, fetched with Anders's yes; each file's row in the site's own table gives "Creative Commons 0 - Public Domain". 224 MB in `/Volumes/work2/glimmer-samples/raw`, outside the repository. Run: `GLIMMER_RAW_SAMPLES=<folder> GLIMMER_RAW_OUT=<folder> swift test --filter RawRealFiles` (under the supervisor). The developed previews for Anders to look at are in `/Volumes/work2/glimmer-samples/raw-developed`: 39 JPEGs, each named after its file and its settings (as shot, exposure +1 and −1, cooler, warmer, shadows lifted, lens correction switched).

| File | Size | Result |
|---|---|---|
| Apple iPhone 12 Pro, DNG | 3024 × 4032 | develops; processes 6 to 9 (DNG); no lens correction |
| Google Pixel 8 Pro, DNG | 8144 × 6128 | develops; lens correction supported and on |
| Canon EOS R10, CR3 | 4000 × 6000 | develops; processes 7, 8 |
| Fujifilm X-T50, RAF (X-Trans) | 7728 × 5152 | develops; processes 7 to 9 |
| OM System OM-5, ORF | 5184 × 3888 | develops; lens correction supported and on |
| Panasonic S5 II, RW2 | 6000 × 4000 | develops; lens correction supported and on |
| Nikon Z f, NEF ("8bit lossy compressed") | – | refused: macOS's decoder gives no picture for this file |
| Sony A7 IV, ARW ("APS-C raw compressed (lossy)") | – | refused, the same |

Times on this Mac while other sessions were building: reading the header 0.04 to 0.4 s; developing 0.3 to 4.5 s; making the layer (the developed picture into Glimmer's tiles) 0.2 to 8 s, the 50-megapixel file the slowest. Each file cut at five lengths: refused or only its header read, no crash.

What the camera files showed that the tests' own DNG could not:
- The decoder's "native size" is the sensor's; a picture taken upright comes out turned. The size Glimmer reports and checks is now the developed picture's.
- With the decoder's own scale setting and draft mode, the phone DNG came back cropped (the top-left quarter at full size) instead of scaled. Drafts are now made by developing and then scaling down. That is correct, and slower: a draft costs about what a full development does (up to about 4 s for the largest files), which is too slow for following a slider as it moves. To be solved before the Develop sheet feels right; not solved.
- Two cameras' files in lossy-compressed modes are not supported by macOS. The message says which cameras work is decided by macOS; it does not say that another mode of the same camera may work.

Not verified: the developed pictures have been looked at by me at small size (they are landscapes and plants and look right: no colour cast, no crop, right way up), not yet by Anders, whose look is the condition for the switch. Lens correction on and off gave the same centre colour, as expected, but I have not compared the corners.

## GLIMMER_PSD switched on for releases (2026-11-16)

Decided by the coordinator on Anders's rule ("on when the fetched files open right"). What was done before and with the switch:

- **Abuse with real files as seeds.** The eighteen files, each cut at every length in its first 2,000 bytes and 300 more, and with single bytes changed (every byte of the first 3,000 to 0x00 and 0xFF, 1,500 more places): 43,503 damaged variants run in an 18-second budget per file (an even sample of about 9,750 per file; two small files ran all of theirs). 25,581 were still read, none crashed, none decoded more than its budget, the slowest took 1.45 s. `GLIMMER_PSD_ABUSE_SECONDS` raises the budget. A real file declaring 29,308 × 29,308 pixels (this Mac's limit, 858 megapixels) with its real layer records: read and imported in 1.1 s with 289 KB decoded; nothing the size of the canvas is allocated, and the picture comparison is skipped above 64 megapixels.
- **Invert's 0.6 %** was a fault in Glimmer, not rounding: the file's Invert layer has a mask whose edge row is 229 of 255, and Glimmer mixed an adjustment layer's opacity and mask in linear light even in a document that blends in gamma. Fixed in the shader (`adjust_fragment`), with a test; the file now matches (worst pixel off by 1).
- **The switch did not reach a release build at first.** Xcode keeps a package manifest's result until the manifest's own text changes, and the manifest reads the switch from another file. `scripts/apply-features.py` now writes the switches into a comment line in `Package.swift`, and `scripts/check-release-binary.sh` fails when a switched-on feature's texts are missing from the binary (it would have caught this). That check also had a fault of its own: `echo … | grep -q` on 330 KB under `pipefail` reads as "absent"; it counts now.
- **In the release build** (ad hoc signed, the no-network copy): `scripts/check-release-binary.sh` (PSD present, Heal and RAW absent), `GLIMMER_OFFLINE_CONFIG=Release scripts/test-offline.sh` (all passed), `GLIMMER_OFFLINE_CONFIG=Release scripts/test-psd-import.sh` (all passed: both sheets read through the accessibility API with `axaudit --strict`, the export sheet reached through File › Export… as a person does, since a release has no fixtures).
- **Looked at as pictures** (`build/window-shot`, the app's own windows only; `build/psd-shots`): the import report (both kinds) is whole. The export sheet was not: in a small window its last sentence was cut to "the layers have not been tri…", the one sentence that must stay. The accessibility read had passed it, because the whole text is there for VoiceOver. Fixed; looked at again.

Not done: the full populated accessibility pass (`scripts/test-accessibility.sh`) cannot run on a release build, because its states come from debug fixtures; the two sheets that are new in a release were read in the release build by the import script instead. Not yet looked at as pictures: the first-use notices, the Heal question, the link bar's three states, the offer under a plan.

## RAW: the draft that follows a control (2026-11-16)

Requirement from the coordinator: while a slider moves, the picture follows within about a tenth of a second on the sample files. Measured on the six camera files that develop, draft 1,600 pixels on the long side, pixels read out each time (not a deferred picture). The Mac was shared with other sessions' builds and model runs throughout, and the numbers moved a lot between runs.

- **What cost before:** a new decoder for every change (0.3 to 4 s). `RawDraft` keeps one decoder for as long as the sheet is open.
- **Chosen:** the real development on the kept decoder, scaled down afterwards. The draft differs from the finished picture at the same settings by 0.02 to 0.06 of 255 on average on all six: nothing jumps on release.
- **Idea 1, the decoder's own scale setting: rejected by measurement.** Against scaling afterwards it differed on every file: 1.6 (Canon), 4.2 (OM), and 75 to 127 on the other four, where it is a crop, not a smaller picture. With draft mode as well it is 1 to 7 off where it is not cropped.
- **Idea 2, a neutral copy with ordinary operations:** exposure as a plain multiplication matched the two DNG files exactly and was 8 to 12 of 255 off on the four camera-maker formats at +1 stop. Not built: it would make the picture jump on release for most cameras.
- **Speed, once warm:** 11 to 20 ms per change (iPhone, Canon, OM), 32 to 60 ms (Panasonic, Fujifilm 40 megapixels). **The requirement is met there.**
- **Not met:** the 50-megapixel Pixel file took 0.1 to 1.9 s per change, differently in every run. And "once warm" took between one and five changes, each up to several seconds (worst: the Fujifilm, five changes of 4 to 8 s in one run, none in the run before). I do not know whether that is the decoder, Core Image compiling its kernels, or the other sessions' use of the GPU; it has to be measured again in the app on a quiet Mac.
- **Consequence for the sheet:** it must never wait for a draft. Drafts are rendered off the main thread, only the latest setting is rendered, and a line says when the picture is behind. That is idea 3 as the floor, with the fast path on top when the file allows it.

Lens correction on against off, on the three files that carry the data (a 400-pixel square): Pixel 8 Pro corner 1.7 and centre 1.7 of 255; OM-5 corner 24.0, centre 19.2; Panasonic corner 8.0, centre 8.4. The centre moves as much as the corner on the two cameras, so the correction rescales the whole picture, not only its edges. A pair of corner crops per file is in the folder for Anders ("8 corner, lens correction on/off").

The refusal for the two files macOS gives no picture for now reads: "macOS gives no picture for this RAW file. Which cameras and recording modes work is decided by macOS; another recording mode of the same camera may work."

The per-file licences were read from the data file the site's table loads (https://raw.pixls.us/json/getrepository.php?set=all, 2026-11-16), not from the rendered page: the browser extension was not connected.

### Photoshop files still to fetch (candidates found by a reading subagent, nothing downloaded)

Covering text, smart objects, PSB, CMYK and Lab; each fetch needs Anders's yes. Best: more files from psd-tools' tests (MIT, same folder as before: type-layer, text.psd/.psb, smartobject-layer, placedLayer, smart-object-slice, the colormodes folder), and EmilDohne/PhotoshopAPI's test documents (BSD-3-Clause; its README says they were made with Photoshop 2022: ten text files, two smart-object files, CMYK PSB). Large: nothing verified; two CC0 OpenGameArt archives (92.6 MB and 14 MB) of unknown writer, and PhotoshopAPI's benchmark files, which are the right size but carry no licence. Rejected: ag-psd (licence excludes its images), OpenImageIO ("Origin unknown"), Krita (GPL), psd-tools' third-party-psds (one file, no licence note).

## More Photoshop files: text, smart objects, PSB, CMYK, Lab (2026-11-16)

Fetched with Anders's yes: sixteen more files from psd-tools' tests (MIT; `/Volumes/work2/glimmer-samples/psd-more`) and sixteen from PhotoshopAPI's test documents (BSD 3-Clause, "Copyright (c) 2024, Emil Dohne", nothing excluded; its README: "generated using Photoshop Version 22.3.2 (Photoshop 2022)"; `psd-photoshopapi`). 22 MB. None crashed or hung. Which program wrote each psd-tools file is not stated.

| What | Files | Result |
|---|---|---|
| Text (as pixels, words quoted in the report) | 14 | 10 match; 3 differ on 0.3 to 0.8 % of the pixels, along letter edges; 1 has no picture to compare with |
| Smart objects (as pixels) | 7 | 5 match; one differs 0.3 %; one 4.4 % with layer effects, which the report names |
| PSB | 5 | read like PSD |
| CMYK, Lab, 32-bit | 9 | opened as the flattened picture, and said |

Found and fixed:
- **A report that was not true.** `unicode_pathname.psd` said "Everything came through" beside "differs on 100 % of the pixels". The import was right; the file's flattened picture is blank, because it was saved with Maximize Compatibility off. Photoshop says so in the file (resource 1057, fifth byte). Glimmer reads that now: the report says there was nothing to compare with, and a file whose layers Glimmer can't read and that has no picture is refused with what to do, instead of opening as a blank page.
- **A painted mask dropped silently.** `masks2.psb`: a shape with an outline and a painted mask came in with only the outline (3.9 % of the pixels differed, no note). The two are now multiplied into one mask, with a note that the outline is no longer a path. 0.7 % remains, in the text layer.
- **Text edges** (`text.psb`, `TextLayers_VerticalBox.psd`, `masks2.psb`): Glimmer's antialiased edge pixels are darker than the file's (64 against 103, 136 against 170). The numbers are roughly what blending text with gamma 1.45 gives, which is a Photoshop colour setting and not stored in the file; `text.psd` from the same source matches exactly. Not confirmed, not changed.

Speed: in the tests' debug build on a busy Mac these files took up to 70 s, which looked like a fault. In the release app through the agent API: 0.6 to 1.6 s each, the largest 1,890 × 1,417 with three layers (1.1 to 1.5 s), twice each, the same both times.

Still open: nothing large from Photoshop; the vector mask's flag bits (0 or 3-as-version in every file; no inverted or disabled outline seen); vector masks on layers of pixels.

## RAW: Develop… in the app (2026-11-16, debug builds only)

Built: a RAW file opens (File › Open…, drag) as a document with one RAW layer; **Layer › Develop…** shows the sheet (picture, exposure, temperature, tint, grey point by click, shadows, and what the file allows of contrast, sharpness, noise, highlights, lens correction); Develop puts the new picture in the layer as one undo step. Drafts are rendered off the main thread on one kept decoder, only the latest settings, starting when the sheet opens; a line under the picture says when it is behind; the last picture stays meanwhile.

`GLIMMER_RAW_SAMPLE=<file> scripts/test-raw-develop.sh`, with the Panasonic file (24 megapixels): all 18 checks passed. The file opened in 10.8 s (debug build, through the debug route, other sessions busy); the first picture in the sheet was there about 7 s later; the sheet was read through the accessibility API with `axaudit --strict` clean, and looked at as a picture (whole, nothing cut; the status line sat too far under the picture and was moved up). Develop closed the sheet, Edit › Undo Develop RAW was there, and the layer could be developed again.

Not verified:
- **Dragging a slider** in the app: the script does not move one. The draft's speed in the app, on a quiet Mac with both locks held, is still to be measured; the status stays "met on five of six once warm, not met on the 50-megapixel file or during warm-up".
- The grey-point click, As Shot, and the warning for a painted-on layer: built, not exercised by a script.
- Opening blocks the main thread while the file is developed (10.8 s here in debug). It needs to move off the main thread with a progress line.
- The other five cameras' files in the app; only the Panasonic file was run.
- The manual text for RAW is written (Config/site-features.json, "raw") but not on the site: it follows the switch.
- Not built yet: the RAW file's size in the document's size estimate, the megapixel check shown before decoding, anything in the agent API.

## Large Photoshop files (2026-11-16)

Fetched with Anders's yes: two archives from OpenGameArt, each page giving "License(s): CC0" (pages kept beside the files in `/Volumes/work2/glimmer-samples/psd-large`). Only the PSD and the PSB were unpacked. Which program wrote them is not stated. Opened in the release build (the no-network copy) through the agent API, once each:

| File | Size | Opened in | Result |
|---|---|---|---|
| Abandon City layered.psd, 21.9 MB | 2,467 × 1,696, 12 layers | 1.9 s, memory 121 → 304 MB | all 12 layers, no notes, picture matches the file's (mean 0.0009 of 255) |
| Cloudy Mountains.psb, 227.6 MB | 3,642 × 2,160, 10 layers, 9 of them smart objects | 5.9 s, memory 282 → 625 MB | all 10 layers, 9 notes (smart objects now pixels), picture matches the file's (mean 0.09) |

The memory figures are the process's resident size before and after, with the first document still open during the second. Not tried: anything larger, and these two with their ends cut or bytes changed.

## RAW: opening in the background, and the draft measured in the app (2026-11-16)

- **Opening no longer freezes the app.** A RAW file is developed away from the main thread while a small window says "Developing <name>…". If macOS gives no developed picture, the preview stored in the file opens as an ordinary picture when there is one; otherwise the RAW reason is shown. `scripts/test-raw-develop.sh` passed with the Canon file (upright, 24 megapixels) after the change. Not looked at as a picture yet: the progress window.
- **The megapixel check** is already made from the header, before anything is decoded (`RawDevelopment.info`, tested); its message is the same as for other images.
- **The draft in the app** (`scripts/measure-raw-draft.sh`: opens each file in the debug copy, then times the draft as the sheet makes it; GUI lock then model lock; one run, about 90 s). First run, on a busy Mac (load average 13 to 17, three other builds running), so not the measurement that counts:

| File | First picture | 15 changes, median | Over 100 ms |
|---|---|---|---|
| iPhone 12 Pro, 12 MP | 140 ms | 9 ms | 0 of 15 |
| Canon R10, 24 MP | 405 ms | 11 ms | 3 (376, 287, 1,592 ms) |
| Fujifilm X-T50, 40 MP | 3,059 ms | 53 ms | 0 |
| OM-5, 20 MP | 1,193 ms | 17 ms | 1 (268 ms) |
| Panasonic S5 II, 24 MP | 1,125 ms | 42 ms | 1 (1,705 ms) |
| Pixel 8 Pro, 50 MP | 1,946 ms | 992 ms | 15 of 15 |

  The slow ones sit at the first change of each kind: the first exposure change, and the first temperature change. So the sheet now warms the decoder when it opens: after the first picture is shown, and unless a control has already moved, it renders a hair's change of exposure, white balance and shadows and throws the pictures away (`RawDraft.warmUp`). Measured below.
  The 50-megapixel file is about a second per change throughout; warm-up will not help it. For that file the sheet's "catching up" line is what the person sees.
- **The commit gate** no longer fails on tests that assert a time limit (`PerformanceTests`): they run and a missed limit is a warning with the load average. `scripts/test-performance.sh` runs them as assertions and keeps its last result in `docs/performance-last.txt`; for a quiet Mac, before a release and after changes to the renderer or compositor. Not yet run.

**Second run, with the warm-up, in the window the coordinator called (17:04; load average 4.7 at the start and 7.3 at the end, from a backup and system services, none of ours; both locks held):**

| File | First picture | Warm-up after it | 15 changes | Over 100 ms |
|---|---|---|---|---|
| iPhone 12 Pro, 12 MP | 148 ms | 193 ms | 8 to 24 ms | 0 |
| Canon R10, 24 MP | 847 ms | 296 ms | 10 to 13 ms | 0 |
| OM-5, 20 MP | 1,483 ms | 308 ms | 14 to 17 ms | 0 |
| Fujifilm X-T50, 40 MP | 4,887 ms | 172 ms | 31 to 33 ms | 0 |
| Panasonic S5 II, 24 MP | 1,248 ms | 210 ms | 34 to 52 ms | 0 |
| Pixel 8 Pro, 50 MP | 1,865 ms | 1,663 ms | 103 to 1,270 ms, median 194 | 15 of 15 |

Status: the requirement (a change shown within about a tenth of a second) is **met on five of the six files**, including the first change of each kind, which the warm-up took care of. It is **not met on the 50-megapixel file**; its best is just over the limit, and whether a quiet Mac would bring it under is not known. The Mac was not quiet, and the run was not repeated. The whole printout is in `build/raw-draft-timing.txt`.

## RAW: the controls used in the app, all six files (2026-11-16)

`scripts/test-raw-develop.sh` now also drags the Exposure slider (through safepointer), ticks the grey-point box and clicks the middle of the picture, presses As Shot, and after Develop runs a filter on the layer and opens the sheet again to see the warning. Each state is saved as a picture of the app's own windows (`build/raw-shots`). `scripts/axread.swift` learned to print what a slider says its value is (the words VoiceOver speaks) and to give an element's place on screen.

All six files that develop passed every check (debug build, load average 11 to 24 from other sessions):

| File | Opens | Exposure dragged | Grey point by click | Develop |
|---|---|---|---|---|
| iPhone 12 Pro | 2.3 s | 0 → +1.59 stops | 5,201 → 5,226 K | passed |
| Canon R10 | 9.3 s | same | 5,062 → 3,673 K | passed |
| OM-5 | – | same | 5,376 → 4,180 K | passed |
| Panasonic S5 II | 4.1 s | same | 4,872 → 4,077 K | passed |
| Fujifilm X-T50 | 12.9 s | same | 5,045 → 4,431 K | 14 s |
| Pixel 8 Pro | 5.2 s | same | 6,019 → 2,778 K | 3 s |

As Shot went back to 0 stops and the camera's temperature on all six. The warning for a changed layer showed on all six, and the layer was still a RAW layer after the filter.

Looked at as pictures (the OM-5 run): the sheet after the drag and the grey-point click, and the sheet with the warning while its first picture was still developing: whole, nothing cut, progress shown from the moment the sheet opens. Not looked at: the small "Developing <name>…" window while a file opens, and the other files' pictures.

**One failure not explained.** In one of three runs with the Fujifilm file (load average 24 to 32), Develop had not closed the sheet after 60 s; the app was still running, nothing crashed. The two other runs took 14 s. An earlier run of the same file did not open within 120 s at load 32. Whether those were only the load or something that can stick is not known; it has to be watched for when the Mac is quiet.

Still before the switch: Anders's look at the developed pictures; the RAW's size in the document's size estimate; the agent API; the evaluation with the new operation.

## The glow behind the icon breathes (2026-11-16)

Anders's wish, for all three apps. In Glimmer the icon has a glow in two places: the empty document's start card and the Agent Access splash. (The Welcome window's icon has no glow, and About is the system's panel.) `App/GlowPulse.swift`: a Core Animation shadow whose opacity eases between 60 % and 100 % of a peak a little above the old still glow, and whose radius follows by about a fifth; two seconds in, two out. The window server animates it; the app does nothing per frame.

Measured in the debug copy with the start card showing (load average 19 from other sessions): the app used 0.00 % of a core over 30 s in front (below what `ps` can resolve, 0.03 %), and 0.10 % over 20 s in the background; no power assertion names Glimmer. Four pictures of the app's own window a second apart show the glow at different strengths (the centre crop's mean blue 45.5 to 48.2) and the icon unchanged. The accessibility read gives the same texts at two moments; the element count is 53 on the very first read after launch and 54 on every read after, with or without time passing, so it is not the animation.

Not verified: Reduce Motion (the code stands still when the system says so and listens for the change; I do not change system settings to try it); the splash's glow, which uses the same view but was not looked at; that the animation is really removed when the window is covered (the code removes it on the occlusion notification; the background CPU figure is consistent with that but does not prove it).

## RAW: the Develop that did not come back, found (2026-11-16)

First the user's side, whatever the cause: the final development now has a progress line ("Developing the picture at full size… Cancel leaves the layer as it was."), Cancel abandons it at any moment (its result is thrown away if it arrives later; the document stays as it was), and after 90 s the sheet gives up by itself, says so, and returns to the settings with nothing changed.

Then the cause. `scripts/test-raw-develop-repeat.sh` runs Develop ten times on one file, with a limit per run, and the app says where each run's time went (decoder call, tiles, waiting for the main thread, the undo step).

| | Runs closed within 45 s | Decoder call | Into tiles | Undo step |
|---|---|---|---|---|
| Before (Fujifilm, 40 MP; load 11 to 26) | 7 of 10 (12 to 38 s); 3 not | 0.08 to 0.17 s | 11 to 44 s | 0.00 to 0.10 s |
| After (same file; load 6 to 8) | 10 of 10 (2.8 to 11.1 s) | 2.2 to 10.4 s | 0.13 to 0.16 s | 0.00 to 0.02 s |

The decoder's picture was a deferred one: it came back in a tenth of a second, undeveloped, and was then developed piece by piece while it was being cut into tiles, far more slowly than developing it once. `RawDevelopment.develop` now asks for the picture to be made at once. Nothing was stuck; it was slow in a place that looked like nothing was happening. In the three runs that passed the limit, Cancel closed the sheet each time.

Consequences for earlier figures in these notes: the "developed in 0.07 to 0.4 s" times in the first RAW table were the deferred call and say nothing; the "as a layer" times (2 to 14 s) included the slow path and are now lower; opening a RAW file is faster for the same reason. The draft figures were always real (they read the pixels out). The two loads differ, so the before and after rows are not a clean comparison of speed; the stage that moved is the finding.

What remains long: 2 to 10 s for the full development of a 40-megapixel file in the debug build, behind a progress line with a working Cancel.

### The glow, when it must stand still (2026-11-16, picture pairs 1.3 s apart of the app's own windows)

| State | Mean colour difference between the two pictures (of 255) |
|---|---|
| Start card seen, app in front | 0.39 to 0.41 (breathing) |
| App in the background (Finder in front) | 0.000 |
| The document window covered by an opaque window of the same size (debug fixture "cover") | 0.000, both windows |
| Agent Access splash, in front | 0.34 (breathing); looked at: the glow sits round the icon, nothing else moves |

So the covered and background cases are shown, not only coded. Reduce Motion is still not tried.

## RAW through the agent API (2026-11-16, debug builds)

Built as the coordinator approved it. `GLIMMER_RAW_SAMPLES=<folder> scripts/test-raw-api.sh`: 19 checks, all passed, with the Panasonic file (lens data), the iPhone file (none) and the Nikon file (no picture from macOS).

- `POST /documents` with RAW bytes opens a RAW layer (201); the layer has `raw` (file name, bytes, settings, process, whether its pixels are as developed). A file macOS gives no picture for is answered 422 `raw_not_developed` with the app's own reason, also when the system's reader does not recognise the bytes at all (then the name it was sent with decides). The size is read from the header before anything is decoded.
- `develop_raw`: only what is given changes (exposure kept when temperature is set); a value outside its range is refused with the range (422 `out_of_range`), a control the file lacks by name (`unsupported_control`), a layer without RAW with `not_raw`, a changed layer with `replaces_changes` unless `replaceChanges` is true, nothing given with `nothing_to_set`. One undo step; undo and `asShot` checked on the picture's brightness.
- `GET …/layers/{layer}/raw/info`: size as developed, lens data, each control with its range and whether the file has it, the settings as they now are.
- Development ran in 1.5 s for the 24-megapixel file, so it is not a job.

**Found by the test:** a parameter `develop_raw` does not have ("brightness") beside a valid one was passed over and the step ran with the valid value alone. It looked like undo failing. Unknown parameters are now refused by name (`unknown_control`) and nothing is applied.

The assistant: `develop_raw` is offered only when the active layer is a RAW layer, and never in the short tool list (tested). Three unseen requests are written (`LocalModelEvaluation.rawCases`: "Make it a stop brighter" and "Gör bilden varmare" on a RAW layer, and the first again on an ordinary layer, where developing must not be chosen). **Not run on any model:** the local models get the short list, which does not have the operation, and a model with the full list is a paid test. The evaluation of the 18 scored cases was not rerun either: the short list is unchanged (pinned by test), so the local result cannot have moved; a full-list model's can.

The document's size estimate counts kept RAW files (`keptRawBytes`, tested).

### Test copies are silent

The series' rule after sound escaped in the siblings' GUI passes. Glimmer's own sounds are three alert beeps (a paste with nothing to paste, a history state that cannot be restored, a palette item that cannot run). They go through `AppSound`, and `scripts/test-app.sh` always starts its copy with `-quiet YES`, which silences them. Glimmer plays no audio or video. Not covered: the alert sound AppKit itself plays for a key that nothing handles; the scripts send Return and Escape only where a sheet takes them.

## A parameter nobody knows is refused, everywhere (2026-11-16)

The series' rule after `develop_raw` passed over "brightness". `StepParameters` (GlimmerAI) reads everything from the register that describes each operation, so a new operation is covered without a line of its own.

- **Steps.** A parameter the operation doesn't have: 400, by name, with what it does have, before any step of the request runs. The same for the nested settings of `add_adjustment`, `apply_filter` and `add_layer_effect`, checked against their `type`; for a setting put beside `"op"` instead of inside `"params"`; and for unknown names in the steps body.
- **Endpoints.** Query parameters and JSON bodies: only the names each path takes.
- **The assistant's plans.** A step with a parameter its operation doesn't have is said in the step ("this step will be refused: its operation has no parameter named …"), the plan is shown instead of run at once, and the step is refused if run. A kind taken from the request's words is still filled in first, as before.

**What the walk found.**
- Before the change, every one of the 34 operations let an unknown parameter through in silence; none checked. Now every one refuses (`StepParametersTests` walks the register; `scripts/test-unknown-parameters.sh` walks the running app's own `/operations` and each endpoint: 17 checks, all passed, the document untouched afterwards).
- The worst case found was not an operation's own parameter but the nested settings: `add_adjustment` stored any key it was given and ignored it, so `{"type": "exposure", "params": {"brightness": 0.2}}` added an Exposure layer that did nothing and answered 200.
- No parameter that an executor reads was missing from the register (52 names read, all registered).
- Four operations (crop, resize_image, resize_canvas, select_rect) answered an unknown name with their "needs width…" message; the unknown name is now said first.
- Nothing Glimmer's own scripts send was refused: the offline test (30 steps of many kinds), the Photoshop import script, the linked-file script (45 checks) and the RAW API script all pass unchanged, apart from the RAW script's own expectation (400 now, where it had 422).

**Not checked:** what Flimmer and Jämmer send to Glimmer. If either sends a name Glimmer doesn't have, it was being ignored until now and is refused from now on. The on-device and local models: a model that adds a parameter of its own invention now gets its plan shown instead of run, so the local evaluation's "runs at once" cases may score differently; it was not rerun.

Evaluation after the change (qwen3:8b through Ollama, the same 18 scored cases, under the GUI lock and the model lock): **18 of 18**, median 2.5 s, slowest 26.2 s; the known gap still 0 of 1 (as before: it answers "not free", which is right, in words the crude judge does not accept). No plan was held back for a parameter of the model's own invention. Ollama had nothing loaded afterwards. The three RAW requests were not part of it.

The small "Developing <name>…" window shown while a RAW file opens was looked at as a picture (the Fujifilm file): title, spinner and the whole line, nothing cut; the accessibility read gives the same line. `scripts/window-shot.swift` now also takes floating panels, which it had been leaving out. With that, what holds GLIMMER_RAW is Anders's look at the developed pictures.

### What is refused is also published (SIBLINGS.md §3, 2026-11-16)

Flimmer's three suggestions, through the coordinator:
- Every schema in `/api/v1/operations` is closed (`"additionalProperties": false`), steps and endpoint operations alike.
- The settings of `add_adjustment`, `apply_filter` and `add_layer_effect` are published per type, under `x-byType` on the `params` property: one closed schema for each adjustment, filter and effect, with ranges and defaults. (An extension key rather than `oneOf`: tool-calling services reject or mishandle `oneOf`, and a caller that checks before calling reads the table directly.)
- `rationale` is accepted, published and without effect on every operation offered as a tool, also the endpoint operations (in the query where the body is not JSON).

Sizes as JSON with sorted keys: `/operations` 44,694 bytes, of which the per-type tables are 8,151; the full tool list sent to a model 28,769 bytes (it does not carry the per-type tables: the settings are in the description there, and the tables would add those 8 kB); the short list 9,992 bytes (9,642 before; the 350 more are the closing of eleven schemas).

The short list is the one a local model is measured on, so the evaluation was run again on it: qwen3:8b, the same 18 cases, **18 of 18**, median 6.9 s (2.5 s in the run an hour earlier; the Mac was busier), slowest 25.5 s. The pinned size is now 9,992. After the run Ollama had `bge-m3` loaded, which is not a model this run uses; qwen3:8b was unloaded.

The walk now also checks, in the package test and against the running app, that every published schema is closed, has `rationale`, lists exactly the names the check accepts, and that no nested `params` is a bare object.

## What had only been read is now looked at (2026-11-16)

`scripts/test-accessibility.sh` saves a picture of the app's own windows for every state it reads (`build/a11y-shots`, 22 states), and two more were put up by hand: the import report with a long list (a real file with 19 notes) and the Photoshop export sheet for a linear-light document. Looked at: the first-use notice with and without pictures, the Heal question, the link bar linked and broken, the waiting plan and the command that waits, the offer of an extra step, the long import report, the export sheet. The accessibility pass (23 checks) and the offline test in the release build (switches as they ship: PSD on, Heal and RAW off) passed on this build.

Whole and right: both first-use notices, the Heal question, the waiting plan, the offer.

Three things the read had passed and the pictures showed:
- **The link bar cut the sender's name**: "For Fli…" in a 900-point window, and in the broken state the words "can't save back" were gone altogether, leaving only an orange icon and "For Fli…". Now whom it is for ("For Flimmer") and what is wrong ("Can't save back") are never cut; the hint after them gives way first, then a running job's name. The manual's wording for the broken state follows ("Can't save back to Flimmer").
- **The import report's list ended in a row cut in half**, with nothing to say there was more (macOS shows a scroll bar only while scrolling, also when asked to show it always). Under a list of more than five points the sheet now says "19 points in all. Scroll the list to read them."
- **The export sheet** had the same, and the row it cut was the measured difference. Same line there, over four points.

Not a fault but seen: in these pictures a "Heal Selection…" spinner sits in the status bar from state 10 on. It is the running job of the job-list fixture, which the fixture "clear" does not remove; a real cancelled Heal leaves nothing.

## iPad: what builds today (2026-11-16, tried, not estimated)

In a scratch worktree (removed afterwards), with one change, `.iOS("27.0")` added to the package's platforms:

- All five package targets (GlimmerCore, GlimmerRender with its Metal shaders, GlimmerTools, GlimmerAI, GlimmerHeal: 87 files, about 20,000 lines) **build for iPadOS with no error**, for a device in Debug and Release and for the simulator. None of them uses AppKit.
- **Not run.** No simulator with iOS 27 is set up on this Mac and I created none; a device is attached and I did not touch it. So "builds" is all that is known: nothing about Metal on an iPad's GPU, memory limits, the RAW decoder or the on-device models there.
- The app itself (App/, 64 files, 17,553 lines) does not build: the compiler stops at the first `import AppKit`. By reference count, 40 files (8,463 lines) use no AppKit symbol and 24 files (9,090 lines) do; the heaviest are the canvas view (1,404 lines, 106 references: mouse, keyboard, cursor, the text editor), the document opener (587 lines, 47: NSDocumentController, Apple events, panels), then the session, the tool options, the menus. Mac-only by nature: Sparkle, sibling calls and linked files (Apple events between Mac apps), Ollama and MLX servers.

## GLIMMER_RAW switched on for releases (2026-11-16)

Anders looked at the developed pictures and said, in the session window: "raw ser ok ut". Reported to the coordinator before the switch; no objection. What was done with it:

- `Config/Features.xcconfig`: `GLIMMER_RAW = YES`. The manual's "Camera RAW files" section and the FAQ line are on the site's sources; the guide has the RAW note, `develop_raw`, and the line for a sibling (send the file, `develop_raw`, `export`).
- The release build (ad hoc signed): `scripts/check-release-binary.sh`: RAW and PSD present, Heal absent. `scripts/check-release-outside.sh`, new, asks the running release the same from the outside: its `/operations` and its guide have `develop_raw` and the import report and no `heal_selection`, and no debug route answers.
- In the release build (the no-network copy): the offline test, the Photoshop import script, the RAW API script (19 checks) and the Develop script with the controls (the Panasonic file: opened in 5.2 s through the public endpoint, first picture 4 s later, drag, grey point, As Shot, Develop in 2 s, the changed-layer warning) all passed. The sheet was looked at as a picture in the release build: whole.
- `docs/release-notes/NEXT.md` has the lines for RAW, for the unknown-parameter rule and for the glow.

What ships with known limits, all said in the manual or these notes: two lossy-compressed recording modes (Nikon Z f, Sony A7 IV) are not developed by macOS; the draft follows within a tenth of a second on five of six files and not on the 50-megapixel one; nothing was measured on a quiet Mac; only the Panasonic file was run in the release build (all six in debug); the three RAW requests of the assistant's evaluation have not been run on any model.

Phase 13 (iPad) is dropped: Anders, the same day, "strunta i ipad". The findings are in docs/PLAN.md.

### What Glimmer sends to its siblings, against their closed schemas (2026-11-16)

Read from the code, not run against Flimmer or Jämmer:
- `GET /api/v1/operations`, `GET /api/v1/documents`, `GET /api/v1/jobs/{id}`: no parameters. `GET …/waveform?width=N` to Jämmer: one query parameter.
- A sibling's step: `POST …/steps` with `{"steps": [{"op", "params"}], "allowPaid": false}`. A sibling's endpoint operation: its parameters placed by `x-in`. In both, `document` and `rationale`, which Glimmer adds to the tool it offers a model, are taken out before anything is sent.
- So nothing Glimmer itself puts together carries a name a sibling doesn't know. What could was a name the model invents: it went out as it was and the sibling's 400 came back as the step's failure. Now, when the sibling's schema is closed, Glimmer refuses first, with the same words, and sends nothing (`SiblingOperation.stray`, tested); a sibling with an open schema still decides for itself.
- The tool offered to a model is the sibling's schema as it is, so a closed schema stays closed there, with `document` and `rationale` inside it (tested).
- Not covered: the nested per-type settings a sibling may publish under `x-byType`; Glimmer does not read that key from a sibling yet. And a plan with such a step is not held back before it runs, as a plan with a stray name in one of Glimmer's own operations is: the sibling's list of operations is fetched when the step runs.

Closed the same day, on the coordinator's word:
- **A sibling's settings per sort are read.** When a sibling's operation carries an `x-byType` table, the nested settings are checked against the sort chosen, with the same refusal as for a top-level name ("sensitivity in settings"). Which property chooses the sort is taken from `x-byTypeKey` if the sibling gives it, else the property whose allowed values are the table's sorts, else `type` or `kind`. SIBLINGS.md §3 does not say how a reader finds that property; Glimmer's own schemas now name it (`"x-byTypeKey": "type"`). Tested with a schema shaped like the description of Jämmer's restore; **not tried against Jämmer itself**.
- **A plan with a step that would be refused is not run at all.** The check is made when the plan is made, for Glimmer's own operations and for a sibling's (against the list the sibling gave for that plan). The Assistant shows the plan, says "This plan can't run: … Nothing was changed.", and offers no Run. Before, the steps ahead of the refused one ran first. Read in the accessibility pass (fixture `refusedPlan`) and looked at as a picture: whole, both steps shown as not run, no Run button. A rough edge seen there: the reason is in the API's words ("add_adjustment has no parameter named brightness in params. It has: exposure, offset, gamma."), which is right for an agent and heavy for a person reading the Assistant.

## After the switch: the sweep's first round (2026-11-16)

- **A refused plan speaks to a person.** The Assistant now says "The plan asks Exposure for a setting it doesn't have (brightness), so it can't run. Nothing was changed. Ask again, perhaps in other words."; the step's note says "asks for a setting that doesn't exist: brightness"; the API's exact words are under a disclosure, "Exact words". Read in the accessibility pass and looked at: whole.
- **The fixture "clear" takes the job-list fixture's jobs away**, and the accessibility script clears after the job list: the pictures of later states no longer carry another state's spinner (looked at: the link bar reads "For Flimmer – ⌘S saves back", nothing else).
- **Three unused strings removed** from the catalogue (the two old link-bar sentences and a lone "Developing").
- **All six camera files in the release build**, one run each with the Develop script and its controls (load average 8 to 22):

| File | Opens (public endpoint) | First picture after | Develop |
|---|---|---|---|
| iPhone 12 Pro | 3.4 s | 5 s | 1 s |
| Canon R10 | 5.2 s | 8 s | 1 s |
| Panasonic S5 II | 5.2 s | 9 s | 2 s |
| OM-5 | 4.7 s | 10 s | 2 s |
| Pixel 8 Pro, 50 MP | 6.9 s | 11 s | 3 s |
| Fujifilm X-T50, 40 MP | 11.3 s | 18 s | 12 s |

  Every check passed on all six. The Fujifilm file stands out, as before: 12 s for the final development at load 22.
- **A sibling's table of settings per sort** is read in both places SIBLINGS.md §3 now allows (on a nested settings property, or on the operation's own schema when the settings sit beside the chooser), always by the chooser named in `x-byTypeKey`. A table without that name is not guessed at: the step's settings go unchecked and the plan's step says so. Tested with schemas of both shapes; not yet tried against Jämmer's real `/operations`.
- Left as it is and noted: File › Open… on a RAW file maps the file's bytes on the main thread before the development is handed off (not measured as a problem).

**The reader against Jämmer's real list (2026-11-16, one run).** Jämmer's debug build (its commit 3b3cdf2) was started under the GUI lock the way its own script starts a test copy (no key, no restored windows, `-silentOutput YES`), asked for `/api/v1/operations` and stopped; nothing but GETs was sent to it. 64 operations, every schema closed; `restore` and `restore_preview` carry the table on their own schema with `"x-byTypeKey": "kind"`. Glimmer's reader on that file (`GLIMMER_SIBLING_OPS=<file> swift test --filter RealSiblingOperations`): denoise with amount, dehum with humFrequency and declick with sensitivity pass; denoise or dehum with declick's sensitivity, declick with dehum's humFrequency, and a name nobody has are refused, each by name with what that sort does take ("sensitivity for denoise … It has: amount, end, id, kind, start, tracks"). No table in the list is unreadable. What this does not show: a real restore going through from Glimmer's Assistant to Jämmer (no step was sent), only that the check before sending gives the right answer for Jämmer's published schema.

## The new sheets in Swedish, and fourteen texts that were never Swedish (2026-11-16)

A test copy started in Swedish (`-AppleLanguages (sv)`), nine states put up and looked at as pictures (`build/sv-shots`): the import report, the Photoshop export sheet, the refused plan, the waiting plan, the link bar linked and broken, the Heal question, the first-use notice, the Develop sheet.

- The Develop sheet, the Heal question, the link bar ("Kan inte spara tillbaka"), the buttons: Swedish, whole, nothing cut by the longer words.
- **Found: fourteen texts stayed English in the Swedish app.** Every text with more than one inserted value: the import report's summary line, the measured-difference lines in both report sheets, the first-use notice's whole body, the lines about a model without tools or without pictures, the memory line for a local model, and the billing lines in Settings. Their keys in the string catalogue were written with numbered placeholders (`%1$@ … %2$@`); the app looks a text up under plain ones (`%@ … %@`), so the Swedish was there and never found. `scripts/check-strings.py` had treated the two forms as the same and reported "Every text found has Swedish". The keys are renamed (the translations keep their numbering), the check now matches the key exactly as the app asks for it, and it fails on any catalogue key with a numbered placeholder. Looked at again in Swedish: the import report and the first-use notice are Swedish now.
- Still English in the Swedish app, seen and not changed: the titles of a plan's steps in the Assistant ("Crop", "Exposure") and Glimmer's own notes inside a step ("asks for a setting that doesn't exist", "type taken from your request"); "Sweden" in "Stockholm, Sweden" from the provider's data; the debug fixtures' own sentences. The colour format in the report ("RGB, 8 bits per channel") comes from the report's source line and is English too.

Also the same day:
- Under "Exact words" a line in the app's language says "The agent API's own message, in English:".
- A debug build accepts its siblings' guest copies (`com.brattoo.flimmer.debug.guest`, `com.brattoo.jammer.debug.guest`) for the API and for linked hand-over; a release build never does. Glimmer's own guest copy counts as a debug build, which it did not before: with `.guest` at the end of its id it would have looked for release siblings.

**Refusals in the person's language.** The 37 refusal messages of the Photoshop and RAW code are written in English in the package, which is what the agent API answers with; a window showed the same English in the Swedish app. `App/PersonMessage.swift` now says them through the string catalogue where they are shown to a person (the error bar, the alerts when a file can't be opened, the Develop and export sheets); the 26 without a figure or a name in them have Swedish, and `scripts/check-strings.py` requires it for each such message from now on. The 11 with a figure or a name in them (a file's size, a layer's name, a process number) are still shown in English. Not looked at in the app yet.

**Swedish in the Assistant's plans and the import report (same day, looked at in Swedish).** A plan's steps are named as the menus name them, through the same catalogue entries ("Beskär", "Exponering"), and the formats around what the model wrote are Swedish ("Text ”…”", "Skala upp 2×"). Glimmer's own notes inside a step are said in Swedish when shown (the plan itself keeps them in English, which is what the evaluation reads). The import report describes the file in Swedish ("RGB, 8 bitar per kanal") and names adjustments, fills and blend modes as Glimmer's menus do. What stays English: what the model wrote, the API's exact words under their disclosure, "Sweden" from a provider's data.

## The populated pass in Swedish (2026-11-16)

`GLIMMER_LANG=sv scripts/test-accessibility.sh` runs the same pass with the copy in Swedish. Every text the script looks for is named as the source names it and resolved through the catalogue by `scripts/catalog-text.py` (a key as it is, a sentence with values filled in, or a part of one key; what the catalogue doesn't have is data and is looked for as it is; menu titles that belong to macOS are listed there). The debug fixtures now say Glimmer's own sentences through the catalogue, as the real code does, so the Swedish copy shows them in Swedish. The pass also walks every menu (`axaudit --menus --strict`). Pictures of each state go to `build/a11y-shots` or `build/a11y-shots-sv`.

Result: 25 checks pass in English and in Swedish; the menus have 363 controls, all named, in both. Looked at in Swedish for cut-off words, a selection of the 23 states: Settings › AI, the Layers panel, the Assistant with a refused plan, the job list state, the Heal question, Image Size, Canvas Size, Agent Access. Nothing cut.

Found by it:
- **The Heal question's body was English** in the Swedish app (title Swedish, body English). It comes from the package with figures in it. `PersonMessage` now also finds a message with figures or names in it, by the catalogue entry whose fixed words it has, and says it with the same values; the eleven Photoshop and RAW refusals with a figure or a name in them have Swedish now too, and `check-strings.py` requires it. Looked at: the Heal question is Swedish throughout.
- **A fixture named a command that does not exist** ("image.flatten"): the waiting-command state would have done nothing on Run. It names Rasterize Layer now.
- My first version of the menu lookup took "Settings…" for a part of "Open Settings…" and the English pass lost Settings; menu titles are now resolved as whole keys only.

Seen and not changed:
- In Settings › AI, macOS lays its own "Lösenord…" (Passwords) suggestion over the API key field, covering part of the row below.
- The pictures of the two Settings states show the top of the Settings window; the part the state is about (the model list, the picture service) is further down and not in the picture. The same for the job list, which sits below the conversation in the panel. The reads cover them; the pictures do not.
- "Sweden" in a provider's place, the model's own words and fixture data remain English, as decided.

**The three left open, closed (same day).**
- **The Passwords suggestion over the API key field is gone.** Telling macOS the field takes no content type changed nothing. What worked: the three key fields are declared as one-time codes, for which macOS has nothing to suggest, and the first one no longer takes the keyboard by itself when Settings opens. Looked at in Swedish: no suggestion over the row below. Not tried: typing and saving a key afterwards (no key is entered by automation).
- **A state's subject is scrolled into view before its picture.** `axread --show` moves the scroll bar of the scroll area an element sits in until the element is inside it (the element's own "scroll to visible" does nothing for SwiftUI's forms and lists). The Settings pictures now show the service and model rows they are about, and the job-list picture shows the list.
- **All 23 Swedish pictures have been looked at.** Nothing is cut except the hint in the link bar ("– ⌘S sparar tillb…"), which is the part meant to give way in a narrow window; "För Flimmer" and "Kan inte spara tillbaka" are whole.

Seen there and not changed: for the picture services that are hidden until tried (shown in the test copy only), the service's note and "(not tried yet)" are English in the Swedish app; they have no Swedish in the catalogue. They would need it before any of those services is offered.

**The hidden picture services have their Swedish (2026-11-16).** The notes Settings shows for Google, fal and Hedra, the label "(not tried yet)", and the six messages their adapters give when an answer is not usable have Swedish in the catalogue, and `scripts/check-strings.py` now requires it for every service's note and every adapter message (it found three more of the messages the moment it was added). Not looked at in the app: the services are hidden, and their messages need a real answer from the service to appear, which is a paid test.

## What could be finished without Anders (2026-11-16, evening; "kör klart det du kan")

- **The timing tests as assertions** (`scripts/test-performance.sh`, result in `docs/performance-last.txt`): all five within their limits, on a Mac that was not quiet (load average 9.4 before, 19.2 after; other sessions building). Compositing a large document 0.58 s for the test, filters on an 8k layer 1.6 s, brush dabs 0.05 s, liquify at 4k 0.09 s, the WebP encode 35 s. A pass on a busy Mac says the limits hold with room; it does not replace the quiet-Mac run for the figures themselves.
- **The API key field still takes a key** after being declared a one-time code. In the test copy a made-up value (22 characters, not a key) was typed into the field: it shows as 22 dots, Save and Test Key wake up, no Passwords suggestion appears when the field is clicked or typed in, and the field was emptied again. Nothing was saved, so storing and reading the key back is still for a person with a real key.

Not done, because it cannot be without him or a quiet Mac: the RAW draft and the Fujifilm file's final development as figures to rely on; the paid tests; the signed update rehearsal; Reduce Motion.
- **Apple's on-device router, live** (`scripts/evaluate-models.sh on-device`, under the GUI lock and the model lock): its four tests pass after the day's changes to plans and operations (a single command, a new picture, a general fix to Auto Enhance, a multi-step edit to the Assistant).

## RAW on a quiet Mac (2026-11-16, 21:19; Anders said go, the coordinator held Flimmer and Jämmer)

Both locks held; load average 3.6 to 4.2 during the draft run; busiest other processes were system services and this session's own tool, nothing building.

**The draft** (`scripts/measure-raw-draft.sh`, once), 15 changes per file after the warm-up:

| File | First picture | 15 changes | Over 100 ms |
|---|---|---|---|
| iPhone 12 Pro, 12 MP | 117 ms | 8 to 19 ms | 0 |
| Canon R10, 24 MP | 395 ms | 10 to 11 ms | 0 |
| OM-5, 20 MP | 1,612 ms | 13 to 17 ms | 0 |
| Panasonic S5 II, 24 MP | 1,332 ms | 31 to 36 ms | 0 |
| Fujifilm X-T50, 40 MP | 1,518 ms | 34 to 44 ms | 0 |
| Pixel 8 Pro, 50 MP | 1,876 ms | 97 to 811 ms, median 593 | 13 of 15 |

The requirement (a change shown within about a tenth of a second) is **met on five of six files, measured on a quiet Mac**. It is **not met on the 50-megapixel file, and the quiet Mac did not help**: it is the file's size, not the load. The sheet's "catching up" line is what a person sees there, and the manual says so.

**The Fujifilm file's final development** (`scripts/test-raw-develop-repeat.sh`, ten runs): all ten closed. Runs 1 and 2 took 2.6 and 3.1 s; runs 3 to 10 took 8.5 to 13.0 s. The whole of it is the decoder call (tiles 0.13 to 0.17 s, the undo step 0.00 to 0.03 s). The load average rose from 3.8 to about 10 during the ten runs although nothing else was building, so the load was at least partly this test's own. Why the later runs are four times slower than the first two is **not known**. One candidate in Glimmer's own code: when Develop is pressed the sheet's draft decoder is still alive, and may still be warming, so two decoders work on the same 40-megapixel file at once. Not tested.

**The suspicion tried, and what the memory figures say (21:40, after the window).** The sheet now lets its draft decoder go when the final development starts (`RawDraftWorker.stop`), and makes it again if the development is cancelled, fails or gives up; one decoder at a time on a file. Ten runs again, this time with swap and memory beside each. It was not a clean test: the other sessions had started building again and the load average climbed from 2.6 to 71 during the ten runs.

| Runs | Load | Swap used | Decoder call |
|---|---|---|---|
| 2 and 3 | 7.6 | 15.5 GB | 1.6 and 1.9 s |
| 1 | 6.5 | 14.9 GB | 7.1 s |
| 4 to 10 | 21 to 71 | 16 to 21 GB | 8.6 to 24 s |

What can be said: the file itself costs about 2 s (four runs across two sessions now, 1.6 to 2.3 s). Every slower run was on a Mac under load, and this Mac has 15 to 21 GB in swap on 16 GB of memory; in the slow runs the app's own resident memory had fallen to 30 to 300 MB, which is an app being paged out, not one computing. So the slowness is the machine's memory and load, as far as these figures go. Whether two decoders at once made it worse was **not settled**: the change is in because it halves what the sheet holds of a 40-megapixel file, not because it was shown to help. The earlier "four times slower from run 3" in the quiet window is still unexplained; the load rose to 10 then with the siblings quiet, and I do not know what from.

**Decided for the 50-megapixel draft (coordinator, 2026-11-16):** the true picture keeps following once or twice a second, and the sheet says it once it has seen it: when a draft after the first takes more than a tenth of a second, a line under the picture reads "A large file: the picture follows the controls a moment behind. What it shows when it has caught up is what you get." No smaller or approximate draft, and no drawing only on release: a picture that jumps when the control is let go is worse than one that is a moment behind. The manual already says the same.

**One heavy build at a time.** The gate, `scripts/test.sh`, `scripts/test-performance.sh`, `scripts/release.sh` and the release build inside the offline test take the series' build lock around themselves (`scripts/with-build-lock.sh`; build lock first, then the GUI lock, then the model lock).

## The first real call: Berget, by Anders (2026-11-16, evening)

Anders saved his own Berget key in Settings › AI of the debug build (started without an OpenRouter key in its environment) and pressed **Run Glimmer's Test of This Model…**. What the app showed afterwards was read from its Settings window through the accessibility API (kept in `build/trial-berget-glm53flash.txt`).

**zai-org/GLM-5.3-Flash through Berget: 16 of 18** (English 9 of 10, Swedish 7 of 8), median 3.8 s, slowest 9.5 s: passes. Known gap 0 of 1. Berget's answers carry no cost; the cost is on Berget's usage page (not read).

- All twelve requests for an edit gave the right step in both languages, and the three that must change nothing (a poem, a joke, thanks) changed nothing.
- The two that failed are the two questions to answer in words, and both failed on Glimmer's own check for figures, not on a wrong answer: "How big is this document, in pixels?" (figures 3 and 2 taken out) and "Hur många lager har dokumentet och vad kostar det att förstora det?" (figures 2 and 4 taken out). What the person would have seen is Glimmer's own sentence or the model's with the figure's sentence removed.
- The same check took figures out of three answers that passed: 1350 beside a crop to 16:9 (2400 × 1350 is that crop; it was labelled a price), and 1200 and 800 beside "half as large" (half of 2400 × 1600). Only the removed figures are shown, not the model's sentences, so that these were correct arithmetic or values from the operations' own descriptions (2× and 4× for upscaling) is a reading, not a certainty. If it is right, the check is removing true figures that a capable model works out or reads from the tool list, which the local model never did.
- The known gap: the model answered "No — generating a new image … costs money", which is right; the crude judge does not accept its wording. As before, not counted.

What only Anders saw: the first-use notice, whether macOS's Passwords suggestion appeared over the key field, and whether the key was still there on reopening Settings. Asked about the three, his answer was "verkar funka". He has not said in so many words that the notice's text is approved.

Not done in this run: the three RAW requests (they are not among the nineteen the button sends), any other service, any picture service.

## The figures rule after the first real model (2026-11-16, late)

Decided by the coordinator on the Berget finding: the rule was written against a model that invents figures and must not punish one that does the sum.

- **Counts as given now:** what the request and the editor state hold (as before); the figures in the operations' descriptions, which are sent with every request; and a closed set the app works out from the document's size before it reads the answer (`AssistantNumbers.worked`): halves, doubles and four times each side, the other side for an aspect ratio the request names, the megapixels, the size as a ratio in lowest terms, and a percentage the request names of each side. The check is membership in that set, with the rounding a person would see; nothing is "plausible".
- **Held whatever the arithmetic:** a sentence about money, how long something takes, a size on disk, quality or a service keeps a figure only if the request or the editor state gave it.
- **A price is called a price** only when the sentence carries a currency or the word. "price 1350" came from "cent" inside "centred": words are now matched as words.
- A removed figure is still followed by "Glimmer left out a figure it could not verify."
- The test of a model shows the answer as the model wrote it beside what was removed, and the RAW requests run as a second group of three after the nineteen, counted by themselves.

Tests: tonight's five cases as fixtures (1350 beside 16:9; 1200 and 800 for half; 3:2 and the megapixels; 2× and 4× from the upscale description; a named percentage), each with an invented figure beside it that still goes, and the held subjects.

**A limit, known and tested as such:** the operations' descriptions hold most small whole numbers (0 to 5, 8, 9, 10, 12, 16, 50, 64, 100 and more through the adjustments' ranges), so a wrong small figure such as "a 4:3 image" for a 3:2 document is no longer caught. A wrong larger one is.

Local evaluation after the change (qwen3:8b, the same 18 cases, GUI lock and model lock): **18 of 18**, median 2.6 s, slowest 30.7 s; no figure removed in any answer; the known gap 0 of 1 as before. Ollama empty afterwards. So the local model's result did not get worse. Whether Berget's two failures now pass is not known until Anders presses the button again.

**The tighter form (same night, on the coordinator's word).** The limit named above is closed:
- An operation's own figures count only in a sentence that names the operation or its subject: its tool name, the stems by which a request names it in English or Swedish, its parameters' names, and for adjustments and filters the kinds' own stems. "I can upscale it 2× or 4×" keeps its figures; "There are 4 of them" does not.
- What is said about the document itself is backed only by the document's facts and the worked set, each kind of figure only where it is said as that kind: the megapixels beside the word, the shape only written as that ratio. "A 4:3 image" for a 3:2 document goes; "a 3:2 image" and "4 megapixels" (3.84, said round) stay; "It is 4 wide" goes.
- Free as before, said here so nobody is surprised: 0 and 1 always, and the numbers up to the count of the plan's steps ("2 steps", "Step 2:", a numbered list of the steps); counting words written as words are not figures at all. So "+1" in a sentence about a crop is not caught, because 1 is free everywhere; "+3" there is.
- Fixtures for each of these, beside the earlier five.

Local evaluation with the tighter form (qwen3:8b, the same 18, both locks): **18 of 18**, median 2.9 s, slowest 26.9 s; no figure removed in any answer; the known gap 0 of 1. It cost the local model nothing.

**Both ways.** The evaluation counts each answer twice: as the model wrote it (what the figures check took out counted as not taken) and as the person gets it, which is what the verdict uses. When the two differ the result line says so: "As the model wrote them: 18 of 18; as the person gets them: 16 of 18." The manual's Assistant chapter lists, in plain words, what counts as a given figure.

Read against SIBLINGS.md, "Siffror i assistentens svar" (the coordinator's wording of the rule, from this build), two sentences there say a little more than the code does:
- Point 3 names an operation by its "menu title in either language". The code uses the tool name, the stems by which a request names the operation in English or Swedish, the parameters' names and the kinds' stems; it does not look up menu titles.
- "A statement about the user's own document is backed only by 2 and 4, never by 3." The code holds the megapixels to the word and the shape to the written ratio, and gives an operation's figures only where the operation is named; it does not otherwise decide that a sentence is "about the document". So a sentence that names an operation and also states something about the document may keep a figure from that operation's description.

## Berget again, with the new figures check and the RAW group (2026-11-16, 22:3x; Anders pressed the button)

Read from the Settings window as before (kept in `build/trial-berget-glm53flash-2.txt`). zai-org/GLM-5.3-Flash through Berget, 22 requests.

**The nineteen: 18 of 18** (English 10 of 10, Swedish 8 of 8), median 7.3 s, slowest 10.2 s: passes. It was 16 of 18 two hours earlier, median 3.8 s; the answers were slower this time.
- The two that failed earlier pass. "How big is this document, in pixels?" → "The document is 2400 × 1600 pixels — a 3:2 landscape canvas with one pixel layer": the 3:2 stays, as the document's own shape. The Swedish question about layers and the cost of enlarging → an answer that names `upscale` with "2× eller 4×": the operation's own figures stay in the sentence that names it.
- No figure was removed in any of the nineteen answers this time, so "as the model wrote them" and "as the person gets them" are the same.
- In that Swedish answer the model says enlarging "kostar ingenting". That is a claim about cost without a figure, the kind the check does not see; here it is true (both ways of enlarging run on the Mac). The known gap itself: 0 of 1 as before, on wording ("No — generating a new image … are paid AI jobs" is right).

**The RAW group: 2 of 3.**
- "Make it a stop brighter" with a RAW layer active → `develop_raw(exposure: 1)`: right.
- The same request with an ordinary layer → `add_adjustment(exposure)`: right; developing was not chosen.
- "Gör bilden varmare" with a RAW layer active → `add_adjustment(color_balance)`, not `develop_raw`: counted as a miss, in 18.6 s. The picture would get warmer either way; the adjustment layer is a real answer to the request, only not the one that uses the RAW file. The case was written, before any model ran, to expect development.

Three requests on one model once is thin: it says the operation is found for exposure and left alone for an ordinary layer, and that for white balance this model reaches for an adjustment first.

Decided (coordinator, 2026-11-16): `develop_raw` stays offered to the assistant; the 2 of 3 stands as it is. The prompt is not changed after one answer on one model; a line for RAW layers comes only if a second model also reaches for an adjustment, and then the case is no longer counted as unseen.

**To watch for in the paid tests of the picture services:** a claim about cost without a figure ("it is free", "kostar ingenting") about something that does cost: generating, editing with a prompt, upscaling through a service. The figures check does not see such a claim. About enlarging on the Mac it was true tonight; about a paid operation it would be a real fault, and the known gap is to be closed then.

**The first-use notice's text is approved (Anders, 2026-11-16).** He was shown the whole text in Swedish and English, for a model that takes pictures, for one that doesn't, and the ending for a model on this Mac, and answered "den är ok". He was told that "Stockholm, Sweden" stands in English inside the Swedish sentence and did not ask for it changed.

## Every built service is offered (Anders, 2026-11-16, late)

Asked which further services he wanted to offer, Anders answered "låt alla synas så går vi vidare", and when told the untried ones would be marked "(not tried yet)" in the list: "ta bort märkningen". So: every cloud service that is built is offered in every build, by its name alone. For text: OpenRouter, OpenAI, Anthropic, xAI, Google, Berget, Grunden (and Ollama while it runs). For pictures: OpenRouter, OpenAI, Google, fal.ai, Hedra. MLX stays out: a local server is shown once a model on it has passed Glimmer's evaluation, and none has.

This replaces "hidden until Anders has made a paid test" (PROVIDERS.md). It is his decision in this window; it is not a result. **Tried with a real call: OpenRouter and Berget (text). Nothing else.** OpenAI, Anthropic, xAI, Google, Grunden, fal.ai and Hedra have never answered a request from Glimmer; the picture services cost per picture. The list no longer says so; the line under the key field ("built from its documentation and has not been tried with a real call yet") and the manual's table still do, as fact. The `-ai.showUntried` switch is gone.

## Two assistant rules from Jämmer's evaluation (2026-11-16, late)

Built on the coordinator's word, since seven more models can now answer.

**A figure given in words counts as given.** "One and a half" in the request backs "1.5" in the answer; "minus arton" backs 18; also "twenty-five", "tjugofem", "two hundred and fifty", "tvåhundra", "three thousand", "half" (0.5, and so 50 %), "a quarter", "double". English and Swedish. Only what was given is read this way; words in the answer are not figures to check. A figure nobody gave still goes.

**A sentence saying something was done must not stand when it was not** (`PlanClaims`).
- An answer in words with no step planned is the model's own and stands as before.
- Above steps, the model's sentence stands only if it names no operation beyond those steps, told by the words a request names an operation by. "Cropped to 16:9 and removed the background" above a plan that only crops is replaced by "Here's the plan."; the list of steps says the rest.
- When the model planned only steps Glimmer doesn't have, or the plan is refused for a setting that doesn't exist, the model's sentence is not shown: the app's line stands alone.
- When a plan stops part-way (a step fails, or it is cancelled), the sentence is replaced by the app's own list: "Done: … Not done: …".
- **Limits, said plainly.** The check sees which operations a sentence names, not grammar: "All done!" above a plan still waiting for Run stands, beside steps that show their own state. Some forty words too common to mean an operation ("layer", "size", "color" …) are not counted, so "and changed the colour" beside a crop is not caught. And a sentence that uses an uncommon word of another operation innocently loses its place to "Here's the plan.": true, but plainer.
- Not seen as pictures yet: the three new lines in the panel (steps Glimmer doesn't have; Done/Not done).

## Test copies and the keychain (2026-11-16, late)

The accessibility pass found no Settings window, in English and in Swedish. Cause, from a sample of the waiting copy: Settings › AI reads the chosen service's key on the main thread, the copy that macOS lets make no connection is signed otherwise than the app Anders saved his Berget key with, so macOS asked for the keychain's password and the window waited on that question. Not a fault of the day's changes: it appeared because a real key exists in the keychain since this evening.

Now: a debug copy started with `-ai.noKeychain YES` keeps keys in memory for the run and never touches the keychain, and `scripts/test-app.sh` starts every test copy so (the guest copy's line for siblings names the switch too). A release copy has no such switch: a re-signed release copy that opens Settings › AI with a keyed service chosen would ask the same question. In the real app there is no question, since it reads its own items; the read is still on the main thread.

A mistake of mine the same hour: I wrapped `test-accessibility.sh` in the GUI lock although it takes the lock itself, so it waited on itself and held the lock from the siblings for about twenty minutes. Stopped by pid; the script is run bare.

**Every offered service, one by one** (`everyOfferedServiceShowsARefusalWordForWordAndMakesNothingOfAnUnusableAnswer`, with an injected session, no network): for the seven text services and the five picture services, a refusal from the service (HTTP 422 with its own sentence) reaches the person word for word, with the status for all but OpenRouter (whose errors are put in Glimmer's words around the service's, as before); and an answer that can't be used (a web page for a plan, a body with no picture in it) becomes an error, never steps and never a picture. The provider suites also pass built for release (`swift test -c release`, 93 tests).

**Nothing charged to the document when a service fails** (`scripts/test-service-failures.sh`, 33 checks, all passed, 2026-11-16 late). A debug test copy pointed at a stand-in on 127.0.0.1 instead of OpenRouter, with a key that is no key (`GLIMMER_FAKE_SERVICE`; test-app.sh refuses any other address): Generate and Edit with Prompt, each against a refusal (HTTP 422 with the service's own sentence), an answer with no picture in it, and a web page instead of an answer. Each time the stand-in was reached, the job ended as failed, the document's layers, size and selection were as before, and Undo took back the step from before the failure, so the failure made no undo step of its own. The refusal's sentence came back word for word.

What this is and is not: it is the path every picture service shares after its own adapter, run in the app. It is a debug copy, not the release build (a release copy can be given neither a stand-in key without the keychain nor the no-keychain switch), and only OpenRouter's address can be pointed elsewhere, so the other four picture services' adapters are covered by the package test above, not in the app. The paid dialog and the first-use notice were not driven in this pass; they were read in both languages in the accessibility pass (alerts firstUse, firstUseNoPictures, and Settings › AI with the new lists: Pictures with fal.ai chosen, Berget chosen), all passing, pictures looked at for Settings. The open pop-up lists with the seven and five names were not seen as pictures.

Local evaluation after the two assistant rules (qwen3:8b, both locks): **18 of 18**, median 2.6 s, slowest 25.8 s; no figure removed; known gap 0 of 1.
