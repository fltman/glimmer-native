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

Text, one service at a time: `-ai.showUntried YES`, then Settings › AI › Service lists the untried ones as "(not tried yet)". Save the key, choose a model from the service's own list, and press **Run Glimmer's Test of This Model…**. It asks first, sends fourteen requests (each carries the list of operations, a few thousand tokens, and gets a short answer), and shows each outcome and the verdict by the same rule as for local models (five in six overall and per language: 12 of 14 and 6 of 7; none over 60 s). That result decides whether the service is offered.

| Service | Built on | Notes for the test |
|---|---|---|
| Berget, Grunden | chat completions | Already offered by Anders's decision; the same button works for them and would be their first real call. |
| Google | its OpenAI-compatible route | |
| OpenAI, xAI | the Responses API | The reply arrives whole, not streamed. |
| Anthropic | the Messages API, version `2026-10-21` (as on platform.claude.com on 2026-11-16) | |

The first-use notice ("Send this to <service>?") shows at the first request to each cloud service and has not been seen in the running app, because no key has ever been saved in a test copy: look at it at the first test and say if the text is right.

Images, one service at a time, by launch arguments (there is no picker for them yet): `-ai.imageProvider <slug> -ai.imageModel.<slug> <model id as the service's documentation shows it>`; for fal also `-ai.imageEditModel.fal <id of the model's edit endpoint>` when it isn't `<id>/edit`. Then one **Generate** and one **Edit Image with Prompt** (or Generative Fill) in the AI panel.

| Service | How the pictures travel | What to watch for |
|---|---|---|
| OpenRouter, new route (`-ai.openRouterImageRoute images`) | data URLs in the request; base64 back | After one generation and one edit, the new route becomes the default and the old one is removed. |
| OpenAI | data URLs in the request; base64 back | The account may need OpenAI's organisation verification for image models. |
| Google | inline base64 parts; the picture inline in the answer | |
| fal | data URIs in the request, the result asked for as a data URI | If fal answers with a link instead, Glimmer refuses to fetch it and says so: then that model can't be used this way. |
| Hedra | bytes uploaded to Hedra (private handle, one hour), a job, a signed download | Only pictures of yourself, by Hedra's rules. |

Costs: Berget's and Grunden's lists give prices per million tokens (about €0.15–0.50 in), so a fourteen-request run is a fraction of a euro cent. For the others no figure is given here, because their text prices were not read; the image prices per service are in `the-apps/research/providers-glimmer.md` and Flimmer's notes.

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
