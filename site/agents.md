# Glimmer: guide for agents

Glimmer 0.3.0 is a native macOS photo editor with layers, adjustment layers, filters, selections, text and on-device AI (subject, people and sky selection, auto enhance, perspective correction). This page tells an agent how to drive the running app through its local HTTP API.

- Base URL: `http://127.0.0.1:9001` (this Mac only; the server listens on loopback). Glimmer uses port 9001, or the first free port from 9101 to 9119 when 9001 is taken; the address in Glimmer's **Help › Agent Access…** window is always the real one.
- Check that `app.name` in `GET /api/v1/status` is `"Glimmer"` before you send changes, so you never edit with a different app that happens to listen on the port.
- Every POST needs the header **`X-Glimmer-Agent: 1`**. Without it you get `403 forbidden`.
- Don't send an `Origin` header: requests that look like they come from a web page are refused.
- Images travel in request and response bodies. The API never reads or writes file paths.
- A Photoshop file (PSD or PSB bytes) sent to `POST /api/v1/documents` opens with its layers. The reply's `document.importReport` says what came through: `layersInFile`, `layersKept`, `flattened` (true when only the file's own flattened picture could be used), `notes` (one per thing that did not come through: `layer`, `what`, `changesLook`), `looksTheSame`, and `differenceFromFile` (Glimmer's picture against the one saved in the file: `mean` on a scale of 0 to 255 and `shareVisiblyDifferent` from 0 to 1). Read it before you rely on the layers: text, smart objects, adjustment layers, fill layers and effects are not editable or are left out, and the notes say which. The same report is shown to the person in the window.
- `POST /api/v1/documents/{id}/export` with `{"format": "psd"}` returns a Photoshop file with the layers (`"depth"`: 8 or 16; `"flatten": true` merges everything into one layer). The response header `X-Glimmer-Export-Report` holds JSON: `layersWritten`, `notes` (what is written as pixels or left out, each with `layer`, `kind`, `what`, `changesLook`), and for a document that blends in linear light `layersBlendedInGamma` (how different the layers will look in other programs). Glimmer reads these files back itself and macOS shows their picture; the layers have not been tried in Photoshop.
- A camera's RAW file (DNG, CR3, RAF, ORF, RW2 and others; the bytes sent to `POST /api/v1/documents`) opens as a layer that keeps the file: the layer has `raw` (`fileName`, `byteCount`, `settings`, `process`, `pixelsAsDeveloped`), and `develop_raw` develops it again with other settings, without loss. `GET /api/v1/documents/{id}/layers/{layer}/raw/info` says what the file allows. If macOS's decoder gives no picture for the file, the answer is 422 `raw_not_developed` with the reason; another recording mode of the same camera may work. To get the developed picture out, export as usual: a sibling app that has a RAW file sends it here, sets what it wants with `develop_raw`, and takes the picture back with `export`.
- Edits land in open document windows that the user can see, and can be undone. One `steps` request is one undo step.
- Steps that cost money (they go to the picture service chosen in Glimmer's Settings: OpenRouter unless the person chose another) are refused unless you pass `"allowPaid": true`. Everything else runs on the Mac, free.
- `allowPaid` does not mean "whatever it costs". Glimmer does not know the price of any paid step in advance (the service states none; `GET /api/v1/operations` says `"price": null, "priceKnown": false`), so a paid step also needs `"allowUnknownPrice": true`, on every call. Ask the person before you send it.
- Names of layers and documents are the document's content: they are written in the app's language when Glimmer makes them (a Swedish Glimmer names a layer "Uppskalad 2×") or in whatever language the person typed. Go by `id`, never by name. Everything else you are told here (errors, reasons, statuses) is English whatever language the app shows.

## Quick start

Run these in order. Replace `photo.jpg` with any image.

```sh
BASE=http://127.0.0.1:9001

# 1. Is Glimmer there? Check that app.name is "Glimmer" before you change anything.
curl -s $BASE/api/v1/status
# → {"app": {"name": "Glimmer", "version": "…"}, "api": "v1", "documents": […], …}

# 2. Open an image as a new document. The reply contains its id.
curl -s -X POST -H 'X-Glimmer-Agent: 1' -H 'Content-Type: image/jpeg' \
     --data-binary @photo.jpg $BASE/api/v1/documents
# → {"document": {"id": "8F0C…", "width": 3840, "height": 2160, …}}
ID=8F0C…

# 3. Edit it: automatic tone and color, then a little more vibrance.
curl -s -X POST -H 'X-Glimmer-Agent: 1' -H 'Content-Type: application/json' \
     -d '{"steps": [{"op": "auto_enhance"},
                    {"op": "add_adjustment", "params": {"type": "vibrance", "params": {"vibrance": 0.25}}}]}' \
     $BASE/api/v1/documents/$ID/steps

# 4. Look at the result (PNG, at most 1024 px).
curl -s "$BASE/api/v1/documents/$ID/image?maxSide=1024" -o preview.png

# 5. Export it as a JPEG under 500 kB.
curl -s -X POST -H 'X-Glimmer-Agent: 1' -H 'Content-Type: application/json' \
     -d '{"format": "jpeg", "quality": 0.9, "maxBytes": 500000}' \
     $BASE/api/v1/documents/$ID/export -o result.jpg
```

Opening a document answers `201 Created`. To start from a blank canvas instead, send `-H 'Content-Type: application/json' -d '{"width": 1600, "height": 900, "background": "white"}'` in step 2. To send the image inside JSON: `-d '{"image": "<base64 of the file>", "name": "Holiday"}'`.

## Endpoints

| Method | Path | What it does |
|---|---|---|
| GET | `/glimmer` | This guide (Markdown). |
| GET | `/api/v1/status` | `app.name` (always `"Glimmer"`), `app.version`, the API version, the port, the open documents, the running `jobs`, and `providerKeys`: for each AI service Glimmer can use with a key (`openrouter`, `berget`, `grunden`), whether the user has entered one (true or false, never the key). Paid steps make pictures through the picture service chosen in Glimmer's Settings and need that service's key (for OpenRouter, `openrouter` true). `linkJournal` says what Glimmer keeps of linked files: `entries`, `unreturned` (how many have steps not saved back) and `broken` (kept edits that can't be read; they are never removed by Glimmer). |
| GET | `/api/v1/operations` | Every step operation: `{"operations": [{"name", "description", "params", "paid", "undoable", "startsJob"}]}`. A paid operation also has `"price"` (null when Glimmer doesn't know it) and `"priceKnown"`. `params` is a JSON Schema, so an assistant can use the operations as tools as they are. Steps run through `steps`; the other requests (`export`, `image`, `add_image`, `undo`, `redo`) carry `call: {method, path}`, and their params marked `"x-in": "path"` or `"query"` go there (the rest in the JSON body). `tier` is `"core"` for the everyday operations and `"advanced"` for the rest, for assistants that can offer only a few tools. |
| GET | `/api/v1/requirements` | What Glimmer may need installed (see the section of that name): `{"items": [{"id", "name", "kind", "neededBy", "required", "installed", "installedVersion", "sizeBytes", "license": {"spdx", "url"}, "source": {"publisher", "url", "version", "commit", "sha256"}, "install": {"how": "in_app", "where"} or {"how": "by_user", "steps"}}]}`. Reading it changes nothing and downloads nothing. |
| POST | `/api/v1/settings/open` | Opens Glimmer's Settings at a pane for the person: `{"pane": "models"}` (or `"general"`, `"ai"`, `"performance"`, `"tablet"`). It only opens the pane; it changes no setting and starts no download. Answers `{"opened": "models"}`. |
| GET | `/api/v1/documents` | The open documents. The one whose window is in front has `"frontmost": true`; Glimmer's own empty start document, which the first image you open replaces (keeping its id), has `"startDocument": true`; an image Flimmer or Jämmer handed over to edit has `linkedFile` (`name`, `format`, `requester`, `available`), and ⌘S writes it back. The link survives a restart of Glimmer; `available` is false, with a `reason`, when the file can no longer be reached or written after one. `unreturnedSteps` (when above 0) is how many steps are not saved back yet; `kept: true` means the person left it so at Quit or with Keep for Later and it was opened again, `recovered: true` that Glimmer stopped on its own and the document was brought back. Both go when it is saved back. |
| POST | `/api/v1/documents` | Open an image (raw bytes with `?name=…`, or JSON `{"image": "<base64>", "name": "…"}`) or create a blank document (JSON `{"width", "height", "background": "white"\|"black"\|"transparent", "name"}`). `name` names the document's window and, for an image, its layer. Glimmer's untouched start document is replaced instead of leaving an empty window. |
| GET | `/api/v1/documents/{id}` | Size, layers (top first, each with `bounds` in document pixels when it has content), the active layer and whether there is a selection. |
| GET | `/api/v1/documents/{id}/image` | The flattened image. Query: `format=png\|jpeg`, `maxSide=<px>`. |
| POST | `/api/v1/documents/{id}/steps` | Run steps in order. Body: `{"steps": [{"op": "…", "params": {…}}], "allowPaid": false, "allowUnknownPrice": false, "async": false}`. Answers 200 when done, or 202 with a job (see Long jobs). |
| GET | `/api/v1/jobs` | Recent jobs (see Long jobs). |
| GET | `/api/v1/jobs/{id}` | One job: status, progress and, when finished, the result. |
| DELETE | `/api/v1/jobs/{id}` | Cancel a job that is still running. |
| POST | `/api/v1/documents/{id}/layers` | Add an image as a new layer (`add_image`). Body: the image's bytes, as when you open a document, or JSON `{"fromDocument": "<id>"}` to use another open document's picture. Query: `name`; `fit` against the canvas (`contain`, the default: scaled down to fit inside it, never up; `cover`: scaled to cover it; `none`: its own size); `x`, `y`: where its top-left goes after fitting (default: centered); `smartObject=true\|false`. Answers 201 with `{"layer": {"id", "name", "bounds"}, "document": …}`. One undo step. |
| POST | `/api/v1/documents/{id}/undo` | Undo the last change (a whole `steps` request counts as one; the selection goes back too). Answers `{"undone": "<name of the change>", "document": …}`; a steps request is named `Agent Edit`. |
| POST | `/api/v1/documents/{id}/redo` | Redo. Answers `{"redone": "<name>", "document": …}`. |
| POST | `/api/v1/documents/{id}/export` | The finished image as bytes. Body: `{"format": "png\|jpeg\|heic\|tiff\|webp", "quality": 0.9, "maxSide": 2048, "maxBytes": 500000}`; all optional (PNG by default). `"preset": "podcast-cover"` with `"size": 3000\|1400` gives square cover art (see Export size limits). |

Document ids are stable while the window is open. Use `GET /api/v1/documents` to find documents the user opened.

### Steps

A steps request runs every step in order and stops at the first failure; later steps are reported as `skipped`. The reply lists each step:

```json
{"results": [{"index": 0, "op": "auto_enhance", "status": "done"},
             {"index": 1, "op": "apply_filter", "status": "failed", "error": "There's no pixel layer to work on."}],
 "document": {…}}
```

Which layer a step acts on:

- Most operations act on the **active layer**, inside the **selection** when there is one. Make a selection with `select_subject`, `select_people`, `select_sky` or `select_all`, and clear it with `deselect`.
- New layers (adjustments, text, fills, `new_layer`) become the active layer.
- Filters, `fill` and `remove_background` need a pixel layer. If the active layer isn't one, Glimmer uses the topmost visible pixel layer, so `add_adjustment` followed by `apply_filter` still filters the photo.
- Use `select_layer` with a name or id from `GET /api/v1/documents/{id}` to pick a layer yourself.
- A request with a paid step and no `allowPaid` is refused as a whole (402) before any step runs.
- A request with a paid step whose price Glimmer doesn't know, and no `allowUnknownPrice`, is refused as a whole (422, `error.reason` `unknown_price`) before any step runs. Today that is every paid step.

A step may also return `info`, facts about what it did. `style_text` returns `{"matches": 2, "ranges": [{"from": 6, "length": 5}, …]}`, the ranges it actually styled.

**Styling words:** to make one word stand out, add the text, then style the word in the same request (one undo step):

```json
{"steps": [{"op": "add_text", "params": {"text": "Summer sale today", "position": "center"}},
           {"op": "style_text", "params": {"match": "sale", "bold": true, "color": "#E0303A"}}]}
```

Prefer `match`. `from` and `length` count characters as grapheme clusters (Swift Characters), not code points or UTF-16 units: 👍🏽, 🇸🇪 and an å written as a + ring each count as 1, while JavaScript's `length` counts them as 4, 4 and 2. A text layer with styled words lists them under `styles` in `GET /api/v1/documents/{id}`, in the same units: `[{"from": 7, "length": 4, "fontName": "HelveticaNeue-Bold", "color": "#E0303A"}]`. Without `match` or `from`, the whole text is styled. Refusals come as `step_failed` with `reason` `not_text`, `no_match`, `bad_range` or `unknown_font` (and `bad_color`, `bad_size` or `nothing_to_style` for parameters that don't make sense).

Common requests: black and white is `add_adjustment` with `"type": "black_white"`; a vignette is `apply_filter` with `"type": "vignette"`; a finished look is `apply_preset`.

### Long jobs

Paid steps can take a minute, so a `steps` request that contains a paid step always runs as a job, and so does any request with `"async": true`. Such a request answers `202 Accepted` at once:

```json
{"job": {"id": "C1A2…", "kind": "steps", "document": "8F0C…", "status": "running", "progress": 0}}
```

Poll `GET /api/v1/jobs/{id}` until `status` is `done`, `failed` or `canceled` (it starts as `queued` or `running`; these five are all there are). Changed 2026-11-17: a stopped job and a stopped step were spelled `cancelled` before; accept both if you may meet an older Glimmer, and treat any status you do not know as an end, not as "still running". `progress` goes from 0 to 1 as steps finish. A finished job carries the same `result` a direct request would have returned (`results` and `document`), and a failed one also has `error` (`{"code": "step_failed", "message": "…", "step": 1}`). `DELETE /api/v1/jobs/{id}` cancels a running job; steps that didn't run are reported as `canceled`. Running jobs are also listed under `jobs` in `GET /api/v1/status`. Finished jobs are kept for a while (the 50 most recent).

```sh
JOB=$(curl -s -X POST -H 'X-Glimmer-Agent: 1' -d '{"steps": [{"op": "auto_enhance"}], "async": true}'       $BASE/api/v1/documents/$ID/steps | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["id"])')
curl -s $BASE/api/v1/jobs/$JOB
```

### Requests from other apps

Glimmer's siblings, Flimmer and Jämmer, call this API like any agent and add `X-Sibling: <their slug>` (for example `X-Sibling: flimmer`). Glimmer logs it and shows "Requested by Flimmer" in the window it changes. The header grants nothing extra.

### Export size limits

**Podcast covers:** `POST /api/v1/documents/{id}/export` with `{"preset": "podcast-cover", "maxBytes": 512000}` returns the center square of the image at exactly 3000 × 3000 pixels, as an opaque JPEG (or `"format": "png"`). Only the quality goes down to meet `maxBytes`; when 3000 can't, it's 1400 × 1400, and `"size": 3000` or `1400` fixes the size. If the limit can't be met, the answer is `422 unprocessable` with `reason` `over_byte_limit`.

`maxSide` scales the image down so its longer side fits; it never enlarges. The podcast preset is the exception: it always gives its exact size, enlarging a smaller image. `quality` defaults to 0.9. `maxBytes` (JPEG, HEIC and WebP only; PNG and TIFF ignore it) lowers the quality until the file fits, and scales the image down too if even low quality is too big, so the limit is met.

## Errors

Errors are JSON: `{"error": {"code": "…", "message": "…"}}`. A failed step also gives its index: `{"error": {"code": "step_failed", "message": "…", "step": 1}}`.

A name that an operation or an endpoint doesn't have is never passed over. The message names it and lists what there is, and nothing was applied (in a `steps` request, no step ran). For `{"steps": [{"op": "crop", "params": {"aspect": "16:9", "widht": 800}}]}` the answer is 400 with:

```json
{"error": {"code": "bad_request", "message": "Step 0: crop has no parameter named widht. It has: x, y, width, height, toSelection, aspect, deletePixels. No step of this request was run."}}
```

The same goes for a setting inside `params` of `add_adjustment`, `apply_filter` and `add_layer_effect` ("add_adjustment has no parameter named brightness in params. It has: exposure, offset, gamma."), for a setting put beside `"op"` instead of inside `"params"`, and for query parameters.

| Status | Code | Meaning |
|---|---|---|
| 400 | `bad_request` | The body or a parameter is malformed, or carries a name that isn't one of its parameters. The message says which. |
| 402 | `paid_not_allowed` | A step costs money and `allowPaid` wasn't `true` (or no key is saved in Glimmer for the picture service chosen there; the message names the service). The request is checked before anything runs: no step of it was run. |
| 403 | `forbidden` | Missing `X-Glimmer-Agent: 1`, an `Origin` header, or a Host other than this Mac. |
| 404 | `not_found` | No such document, path or operation. |
| 405 | `method_not_allowed` | Wrong HTTP method for the path. |
| 413 | `too_large` | Body over 256 MB. |
| 422 | `step_failed` | A step ran and failed. `error.step` is its index; `results` has the status of every step. When the step refused for a known reason, `error.reason` says which (`would_rasterize_text`, `bad_corners`, `cannot_transform`, `not_text`, `no_match`, `bad_range`, `unknown_font`, `bad_rect`, `no_selection`, `bad_aspect`, `bad_size`, `too_large`, `bad_anchor`, `bad_color`, `unknown_layer`, `ambiguous_target`, `unknown_blend_mode`, `bad_opacity`, `nothing_to_set`). `group_has_mask` is no longer returned: layer masks now follow a transform. |
| 422 | `model_missing` | A step needs an on-device model that isn't downloaded (today `select_sky`). `error.requirement` is the first missing entry's id, `error.requirements` all of them, `error.step` the step. Checked before anything runs: no step of the request was run. The person downloads the model in Glimmer (`POST /api/v1/settings/open` with `{"pane": "models"}` shows them where); the API never starts a download. |
| 503 | `model_unavailable` | A step needed an on-device model that is installed but couldn't be loaded. `error.requirement` names it and `error.step` the step; the steps before it ran. The person removes the model and downloads it again in Glimmer › Settings › Models. |
| 422 | `unprocessable`, reason `unknown_price` | A step is paid, Glimmer doesn't know its price in advance, and `allowUnknownPrice` wasn't `true`. Checked after `allowPaid` (402 comes first) and before anything runs: no step of the request was run. |
| 422 | `unprocessable` | A request other than steps can't be done right now; `error.reason` says why (`nothing_to_undo`, `nothing_to_redo`, `no_history`, `over_byte_limit`, `bad_image`, `too_large`, `unknown_document`, `same_document`). |
| 500 | `internal` | Glimmer failed unexpectedly. The message has the detail. |

## What Glimmer may need installed

Everything else Glimmer needs is in the app. These are the only things that may have to be added, and none of them is needed for most work. `GET /api/v1/requirements` gives the same list as JSON, with `installed` for each, and for a model `verified`: true when Glimmer checked its files against the checksums below, false when Glimmer 0.3.0 installed it without checking (it keeps working until the person chooses **Download Again** in Settings › Models), null when it isn't installed.

What you may do about them:

- Explain what is missing, and show its source and license from this list.
- Open the right Settings pane for the person with `POST /api/v1/settings/open` and `{"pane": "models"}` (or `"ai"`). It only opens the pane; it changes nothing.
- The API never starts a download. A model is downloaded only when the person clicks **Download** in Glimmer's own window; Glimmer then checks the SHA-256 of every file (and the git blob id of `Manifest.json`) against the list below, and refuses a model whose checksum doesn't match.
- A tool marked "installed by the person" is installed outside Glimmer. Show the person the steps, and run them only after they say yes. Use the versions given; never pipe a download into a shell, never turn Gatekeeper off and never remove the quarantine flag.
- Paid services are not installed: the person adds a key in Glimmer › Settings › AI (`providerKeys` in `GET /api/v1/status` says which keys are there).

A step that needs a model that isn't downloaded is refused before any step of the request runs: `422` with `{"error": {"code": "model_missing", "requirement": "<id>", "requirements": ["<id>", …], "step": <index>}}`. Today that is `select_sky` (and `run_command` with `select.sky`), which needs `depth-anything-v2-small` and `sam2.1-tiny`. A model that is installed but can't be loaded (its files damaged) answers `503` with `{"error": {"code": "model_unavailable", "requirement": "<id>", …}}`: the person removes it and downloads it again in Settings › Models.

### Depth Anything V2 Small (Core ML) (`depth-anything-v2-small`)

- Kind: model, optional. Needed by: select_sky, run_command select.sky, Select Sky, Lens Blur (AI panel).
- Publisher: Apple. Source: https://huggingface.co/apple/coreml-depth-anything-v2-small, version DepthAnythingV2SmallF16, commit `cfef6f6f2a70783dedc0bfae40cecbc2052285d3`.
- License: Apache-2.0 (https://huggingface.co/apple/coreml-depth-anything-v2-small/blob/cfef6f6f2a70783dedc0bfae40cecbc2052285d3/README.md).
- Size: 49,819,122 bytes.
- Files, checked by Glimmer after the download:
  - `DepthAnythingV2SmallF16.mlpackage/Manifest.json`, 617 bytes, git blob `b1ff9c6ab81057143ea82aab2796a7e54e3a8823`
  - `DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/model.mlmodel`, 399433 bytes, SHA-256 `44ac97a3efcfd52113183fb2862ff59cd0368e9ec2e30a90a54980dd11407042`
  - `DepthAnythingV2SmallF16.mlpackage/Data/com.apple.CoreML/weights/weight.bin`, 49419072 bytes, SHA-256 `fa60d9b6a155734f59029ebb882fd54e549bfaee3539c1a9cbd2cbbab64a0fed`
- Checksums read from the Hugging Face file list of the repository at that commit (https://huggingface.co/api/models/<repository>/tree/<commit>), read 2026-11-19.
- Where it goes: ~/Library/Containers/com.brattoo.glimmer/Data/Library/Application Support/Glimmer/Models/DepthAnythingV2SmallF16.mlmodelc. Remove: Glimmer › Settings › Models › Remove.
- Check that it went right: `curl -s http://127.0.0.1:9001/api/v1/requirements` → the item with "id": "depth-anything-v2-small" has "installed": true and "verified": true.
- Installed in Glimmer: Settings › Models › Download, or the question Glimmer asks the first time a feature needs it.

### SAM 2.1 Tiny (Core ML) (`sam2.1-tiny`)

- Kind: model, optional. Needed by: select_sky, run_command select.sky, Magic Select, Select Sky.
- Publisher: Apple. Source: https://huggingface.co/apple/coreml-sam2.1-tiny, version SAM2_1Tiny FLOAT16, commit `39ae0a8a83e5e6cd196e804bf7cccc5f8171f306`.
- License: Apache-2.0 (https://huggingface.co/apple/coreml-sam2.1-tiny/blob/39ae0a8a83e5e6cd196e804bf7cccc5f8171f306/README.md).
- Size: 79,644,968 bytes.
- Files, checked by Glimmer after the download:
  - `SAM2_1TinyImageEncoderFLOAT16.mlpackage/Manifest.json`, 617 bytes, git blob `8f229fc88cb92867e3cbdbbc4341eed62d00f85d`
  - `SAM2_1TinyImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel`, 154372 bytes, SHA-256 `6cbc50301ee3ff4a9366083f9647e1f06762759542d8dd0fac394ebc3682cce7`
  - `SAM2_1TinyImageEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin`, 67069504 bytes, SHA-256 `eab96eb8ff35720c79eedc0cac2a4ef32d685f9c994c39736027078528c48a97`
  - `SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Manifest.json`, 617 bytes, git blob `9d23f523f25e7808a78839e24224478e90a1e886`
  - `SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel`, 20618 bytes, SHA-256 `3a83c167d8bd63e80f86349a78c2ab0527ce97eca1f848a4ce57fe5351241fa3`
  - `SAM2_1TinyPromptEncoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin`, 2101056 bytes, SHA-256 `af466cf28ef8838f409c2bfd8cc0049b9efbf9db335d60a57dbfc5160af883f2`
  - `SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Manifest.json`, 617 bytes, git blob `329fc398baacb99b8975bf899f74852a684c3cd6`
  - `SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/model.mlmodel`, 75167 bytes, SHA-256 `4601f302d4c6936e15de3a22089c2afe1fa009ef703f82147ff829b4be677577`
  - `SAM2_1TinyMaskDecoderFLOAT16.mlpackage/Data/com.apple.CoreML/weights/weight.bin`, 10222400 bytes, SHA-256 `f5a8635981199fa1199007ed6798c61a326288548b74553b3c2ddb932fcdc8de`
- Checksums read from the Hugging Face file list of the repository at that commit (https://huggingface.co/api/models/<repository>/tree/<commit>), read 2026-11-19.
- Where it goes: ~/Library/Containers/com.brattoo.glimmer/Data/Library/Application Support/Glimmer/Models/SAM2_1Tiny*.mlmodelc. Remove: Glimmer › Settings › Models › Remove.
- Check that it went right: `curl -s http://127.0.0.1:9001/api/v1/requirements` → the item with "id": "sam2.1-tiny" has "installed": true and "verified": true.
- Installed in Glimmer: Settings › Models › Download, or the question Glimmer asks the first time a feature needs it.

### Ollama (`ollama`)

- Kind: tool, optional. Needed by: The Assistant and text features, when Ollama is chosen in Settings › AI.
- Publisher: Ollama. Source: https://github.com/ollama/ollama, minimum version 0.6.4 (the steps below install 0.40.16).
- License: MIT (https://github.com/ollama/ollama/blob/v0.40.16/LICENSE).
- Size: 229,996,388 bytes.
- SHA-256: `b48d74a2d8c6a0592c816a4f85643d8d8608ad592abafbe95c04128a73c398c6`.
- The SHA-256 is of Ollama.dmg 0.40.16, the release the steps name; any version from minVersion on works.
- Checksums read from the release's asset list, Ollama.dmg digest (https://api.github.com/repos/ollama/ollama/releases/tags/v0.40.16), read 2026-11-19.
- Where it goes: /Applications/Ollama.app, and the models it pulls in ~/.ollama/models. Remove: Quit Ollama, move /Applications/Ollama.app to the Trash, and delete ~/.ollama if its models should go too.
- Check that it went right: `ollama --version` → a version of 0.6.4 or later ("ollama version is 0.40.16" for the release the steps name).
- Installed by the person, outside Glimmer:
  1. Download Ollama.dmg of version 0.40.16 from https://github.com/ollama/ollama/releases/tag/v0.40.16.
  2. Check it: `shasum -a 256 ~/Downloads/Ollama.dmg` must print b48d74a2d8c6a0592c816a4f85643d8d8608ad592abafbe95c04128a73c398c6.
  3. Open the disk image, drag Ollama to Applications and open it from there. Gatekeeper checks its signature: if macOS refuses to open it, stop; don't override the warning.
  4. Check the signature and the version: `codesign -dv /Applications/Ollama.app` names the TeamIdentifier, and `ollama --version` must be 0.6.4 or later.
  5. Pull a model that can call tools, one the person chooses (`ollama pull <model>`; Ollama's library marks such models "tools").
  6. In Glimmer › Settings › AI, choose Ollama as the text service and pick the model.
- Check: `codesign -dv /Applications/Ollama.app; ollama --version`. Team ID: null (not read: not installed on the test Mac; the Team ID is read from the signature after the user installs it). Minimum version 0.6.4: Glimmer reads a model's tools and vision from `capabilities` in /api/show, which Ollama added in commit e172f095ba4af2c98d7744ce4ffcf4cd3a8e123c ("api: return model capabilities from the show endpoint (#10066)", docs/api.md, 2025-04-01); the first release with it is v0.6.4 (https://github.com/ollama/ollama/releases/tag/v0.6.4, 2025-04-02). Read 2026-11-19.

## Operations

These are the `op` values for `steps`, with their `params`. The same list is available as JSON from `GET /api/v1/operations`.

### `add_adjustment`

Add a non-destructive adjustment layer above the active layer (contrast, hue, black & white, curves …).

| Param | Type | Description |
|---|---|---|
| `type` | string | Required. Which adjustment. One of: `brightness_contrast`, `levels`, `curves`, `exposure`, `hue_saturation`, `vibrance`, `color_balance`, `black_white`, `photo_filter`, `channel_mixer`, `invert`, `posterize`, `threshold`, `gradient_map` |
| `params` | object | Required. Settings by key; omitted keys keep their default, {} is neutral. Keys (range, default) per type — brightness_contrast: brightness (-1…1, 0), contrast (-1…1, 0); exposure: exposure (-5…5, 0), offset (-0.5…0.5, 0), gamma (0.1…3, 1); hue_saturation: hue (-180…180, 0), saturation (-1…1, 0), lightness (-1…1, 0); vibrance: vibrance (-1…1, 0), saturation (-1…1, 0); color_balance: shadowsR (-1…1, 0), shadowsG (-1…1, 0), shadowsB (-1…1, 0), midtonesR (-1…1, 0), midtonesG (-1…1, 0), midtonesB (-1…1, 0), highlightsR (-1…1, 0), highlightsG (-1…1, 0), highlightsB (-1…1, 0), preserveLuminosity (true/false); black_white: red (-2…3, 0.4), yellow (-2…3, 0.6), green (-2…3, 0.4), cyan (-2…3, 0.6), blue (-2…3, 0.2), magenta (-2…3, 0.8); photo_filter: density (0…1, 0.25), preserveLuminosity (true/false), color (#RRGGBB); channel_mixer: rr (-2…2, 1), rg (-2…2, 0), rb (-2…2, 0), rc (-2…2, 0), gr (-2…2, 0), gg (-2…2, 1), gb (-2…2, 0), gc (-2…2, 0), br (-2…2, 0), bg (-2…2, 0), bb (-2…2, 1), bc (-2…2, 0), monochrome (true/false); posterize: levels (2…255, 4); threshold: level (0…1, 0.5). Moderate values look natural: exposure is in stops (±0.3–1), most −1…1 sliders are strong beyond ±0.4. For a color cast use color_balance (positive B = bluer, positive R = redder) or photo_filter. |

### `apply_filter`

Apply a destructive pixel filter to the active pixel layer (inside the selection if there is one).

| Param | Type | Description |
|---|---|---|
| `type` | string | Required. Which filter. One of: `gaussian_blur`, `lens_blur`, `motion_blur`, `sharpen`, `unsharp_mask`, `clarity`, `add_noise`, `pixelate`, `find_edges`, `emboss`, `oil_paint`, `halftone`, `vignette`, `chromatic_aberration` |
| `params` | object | Required. Settings by key; {} uses the defaults. Keys (range, default) per type — gaussian_blur: radius (0…100, 4); lens_blur: radius (0…60, 8), brightnessBoost (0…1, 0.3); motion_blur: angle (-180…180, 0), distance (0…200, 20); sharpen: amount (0…5, 1); unsharp_mask: amount (0…5, 0.8), radius (0.5…10, 2), threshold (0…1, 0); clarity: amount (-1…1, 0.4); add_noise: amount (0…1, 0.1), monochrome (0/1); pixelate: cell (2…200, 10); find_edges: no settings; emboss: angle (-180…180, 135), amount (0…5, 1); oil_paint: radius (1…10, 4), intensity (0…1, 1); halftone: cellSize (2…40, 8), angle (0…90, 45), monochrome (0/1); vignette: amount (0…1, 0.5), midpoint (0…1, 0.5), roundness (0…1, 0.5), feather (0.01…1, 0.5); chromatic_aberration: amount (0…40, 6), edgeOnly (0/1). |

### `add_layer_effect`

Add or update a layer style on the active layer. Only the keys you give change. Keys: dropShadow and innerShadow take color (#RRGGBB), opacity (0…1), angle (degrees), distance (px), size (px, the blur), spread (0…1); outerGlow takes color, opacity, size (px), spread (0…1); stroke takes color, opacity, width (px), position (outside, inside or center); colorOverlay takes color, opacity. All take blendMode (a blend mode id) and enabled (false turns the effect off). A new effect starts from: shadows black, opacity 0.75, angle 120, distance 10, size 10; glow pale yellow, opacity 0.75, size 10; stroke red, width 3, outside; overlay red, opacity 1.

| Param | Type | Description |
|---|---|---|
| `type` | string | Required. Which effect. One of: `dropShadow`, `innerShadow`, `outerGlow`, `stroke`, `colorOverlay` |
| `params` | object | Required. Patch, e.g. {"distance": 8, "opacity": 0.5, "size": 12} for dropShadow, {"width": 4, "color": "#ffffff"} for stroke, or {}. |

### `apply_preset`

Apply a finished photo look (adjustment group plus grain/vignette).

| Param | Type | Description |
|---|---|---|
| `name` | string | Required. Preset name. One of: `Cinematic Teal & Orange`, `Vintage Film`, `B&W Noir`, `HDR Pop`, `Golden Hour`, `Cool Cyberpunk`, `Matte Fade`, `Bleach Bypass`, `Cross Process`, `Dreamy Soft` |

### `add_text`

Add a one-line text layer above the active layer (it doesn't wrap: a long text at a big size runs past the canvas, so check the bounds in the step's info and lower size if needed). Place it with position, or exactly with x and y; move it later with transform_layer (moveX, moveY). The step's info gives the new layer's id and bounds.

| Param | Type | Description |
|---|---|---|
| `text` | string | Required. The text. |
| `color` | string | #RRGGBB color (optional, default the foreground color). |
| `size` | number | Font size in pixels (optional; default ~8% of the image height). |
| `bold` | boolean | Optional. true for bold text. |
| `fontName` | string | Optional. PostScript font name, e.g. Georgia-Bold (default Helvetica Neue). |
| `position` | string | Optional. Centered horizontally; top and bottom leave 8 % of the image height to the edge; center is the default. One of: `top`, `center`, `bottom` |
| `x` | number | Optional. Left edge of the text in document pixels (instead of position). |
| `y` | number | Optional. Top edge of the text in document pixels (instead of position). |

### `image_edit_composite` (paid)

Edit the WHOLE visible image with a natural-language instruction (content-aware: "make it snowy", "change the car to red"). The result lands as a new layer.

| Param | Type | Description |
|---|---|---|
| `instruction` | string | Required. The change to make. |

### `generate_layer` (paid)

Generate a new image from a text prompt as a new layer.

| Param | Type | Description |
|---|---|---|
| `prompt` | string | Required. What to generate. |

### `auto_enhance`

Automatic tone and color correction (on-device, free, instant) as editable adjustment layers. A good first step for "fix", "improve" or "make it look better" before any creative changes.

No params: `{"op": "auto_enhance"}`

### `auto_color`

Neutralize a color cast (on-device, free) with a Color Balance layer. For "too yellow/blue/green", "fix the white balance".

No params: `{"op": "auto_color"}`

### `select_sky`

Select the sky (on-device, free). Use before replacing or adjusting the sky.

No params: `{"op": "select_sky"}`

### `select_people`

Select every person in the image (on-device, free, more precise than select_subject for people).

No params: `{"op": "select_people"}`

### `remove_background`

Cut the main subject out of the active layer onto transparency (adds a mask; on-device, free). Works on a pixel layer or a smart object, such as an image just added with add_image.

No params: `{"op": "remove_background"}`

### `select_subject`

Select the main subject (on-device, free).

No params: `{"op": "select_subject"}`

### `inpaint_selection` (paid)

Regenerate or erase the SELECTED region. Requires a selection.

| Param | Type | Description |
|---|---|---|
| `prompt` | string | Required. What to fill the selection with (may be empty for remove). |
| `mode` | string | Required. fill replaces with the prompt; remove erases an object. One of: `fill`, `remove` |

### `upscale`

Upscale the whole image.

| Param | Type | Description |
|---|---|---|
| `scale` | number | Required. 2 or 4 (on-device Real-ESRGAN, free). |

### `fill`

Fill the selection (or the whole active layer) with a color.

| Param | Type | Description |
|---|---|---|
| `color` | string | Required. #RRGGBB or #RRGGBBAA. |

### `set_foreground`

Set the foreground (paint) color.

| Param | Type | Description |
|---|---|---|
| `color` | string | Required. #RRGGBB. |

### `select_all`

Select the whole canvas.

No params: `{"op": "select_all"}`

### `deselect`

Clear the selection.

No params: `{"op": "deselect"}`

### `invert_selection`

Invert the selection.

No params: `{"op": "invert_selection"}`

### `feather_selection`

Soften the selection edge.

| Param | Type | Description |
|---|---|---|
| `radius` | number | Required. Pixels. |

### `select_layer`

Make a layer the active one, so the following steps act on it. New layers become active by themselves.

| Param | Type | Description |
|---|---|---|
| `name` | string | Required. The layer's name (not case-sensitive; the topmost match wins) or its id. |

### `new_layer`

Add an empty pixel layer.

| Param | Type | Description |
|---|---|---|
| `name` | string | Optional layer name. |

### `transform_layer`

Move, scale, rotate, skew or distort a layer or a group, like Free Transform. To only move a layer, give moveX and/or moveY. The step's info gives the layer's bounds afterwards. Text stays editable for scale, rotation and skew; corners (distort or perspective) would turn text into pixels and are refused unless allowRasterize is true. One undo step.

| Param | Type | Description |
|---|---|---|
| `target` | string | Optional. The layer's or group's name or id; default the active layer. |
| `scaleX` | number | Optional. Width in percent of the current size (default 100). |
| `scaleY` | number | Optional. Height in percent of the current size (default 100). |
| `degrees` | number | Optional. Rotation about the center, clockwise. |
| `moveX` | number | Optional. Move right by this many document pixels (negative: left). |
| `moveY` | number | Optional. Move down by this many document pixels (negative: up). |
| `skewX` | number | Optional. Horizontal skew in degrees. |
| `skewY` | number | Optional. Vertical skew in degrees. |
| `corners` | points | Optional. Four corners in document pixels, top-left, top-right, bottom-right, bottom-left, for distort or perspective (replaces move, scale, rotation and skew). They say where the corners of the layer's bounds (as GET document reports them) end up. |
| `allowRasterize` | boolean | Optional. Let corners turn text layers into pixels (default false). |

### `style_text`

Give words in a text layer their own font, boldness, size or color (the rest of the text keeps its style). Find the words with match (preferred), or give from and length in characters; with neither, the whole text is styled. Stays editable text; one undo step. The step's info says which ranges changed.

| Param | Type | Description |
|---|---|---|
| `target` | string | Optional. The text layer's name or id; default the active layer. |
| `match` | string | Optional. The word or phrase to style (exact text, or ignoring case if the exact text isn't there). Preferred over from/length. |
| `occurrence` | string | Optional. Which matches to style (default all). One of: `all`, `first` |
| `from` | number | Optional, instead of match. Start, in characters from 0. Characters are grapheme clusters: 👍🏽 or å counts as 1. |
| `length` | number | Optional, with from. How many characters (grapheme clusters). |
| `fontName` | string | Optional. PostScript font name, e.g. HelveticaNeue-Bold. |
| `bold` | boolean | Optional. true for the bold member of each word's font family, false for the regular one. |
| `size` | number | Optional. Font size in document pixels. |
| `color` | string | Optional. #RRGGBB. |

### `crop`

Crop the canvas for every layer, like the Crop tool. Give exactly one of: a rectangle (x, y, width, height), toSelection, or aspect. A rectangle partly outside the canvas is clipped to it; the step's info says which box was used. One undo step.

| Param | Type | Description |
|---|---|---|
| `x` | number | Optional. Left edge of the box in document pixels (default 0). |
| `y` | number | Optional. Top edge of the box in document pixels (default 0). |
| `width` | number | Optional, with a rectangle. Width of the box in pixels. |
| `height` | number | Optional, with a rectangle. Height of the box in pixels. |
| `toSelection` | boolean | Optional, instead of a rectangle. true crops to the bounds of the selection. |
| `aspect` | string | Optional, instead of a rectangle. W:H, like 16:9 or 1:1: the largest centered box of that shape. |
| `deletePixels` | boolean | Optional. true throws away what is outside the box; false (default) keeps it outside the canvas. |

### `resize_image`

Resample the whole image to a new size, like Image › Image Size: every layer, mask, path and guide is scaled. Give width or height alone to keep the proportions; give both for exactly that size (the proportions may change); or give scale. Text and smart objects stay editable. One undo step.

| Param | Type | Description |
|---|---|---|
| `width` | number | Optional. New width in pixels. |
| `height` | number | Optional. New height in pixels. |
| `scale` | number | Optional, instead of width and height. 0.5 halves both sides, 2 doubles them. |

### `resize_canvas`

Give the image more room, or less, without scaling it, like Image › Canvas Size. Give width and/or height (one alone keeps the other side), or aspect. New room is transparent unless fill is given; what a smaller canvas cuts off is kept outside it. The step's info says which box was used. One undo step.

| Param | Type | Description |
|---|---|---|
| `width` | number | Optional. New canvas width in pixels. |
| `height` | number | Optional. New canvas height in pixels. |
| `aspect` | string | Optional, instead of width and height. W:H, like 16:9: the smallest canvas of that shape that holds the whole image. |
| `anchor` | string | Optional. Where the image stays (default center); new room goes on the other sides. One of: `top-left`, `top`, `top-right`, `left`, `center`, `right`, `bottom-left`, `bottom`, `bottom-right` |
| `fill` | string | Optional. #RRGGBB: adds a color fill layer at the bottom so the new room isn't transparent. Ignored when no room is added. |

### `select_rect`

Select a rectangle or an ellipse. A box partly outside the canvas is clipped to it.

| Param | Type | Description |
|---|---|---|
| `x` | number | Required. Left edge in document pixels. |
| `y` | number | Required. Top edge in document pixels. |
| `width` | number | Required. Width in pixels. |
| `height` | number | Required. Height in pixels. |
| `shape` | string | Optional. rect (default) or ellipse (inscribed in the box). One of: `rect`, `ellipse` |
| `mode` | string | Optional. How it combines with the selection there is (default replace). One of: `replace`, `add`, `subtract`, `intersect` |
| `feather` | number | Optional. Soften the edge by this many pixels. |

### `set_layer`

Change a layer's opacity, blend mode, visibility or name. One undo step.

| Param | Type | Description |
|---|---|---|
| `target` | string | Optional. The layer's id or name; default the active layer. A name two layers share is refused: use the id. |
| `opacity` | number | Optional. 0…1, as GET document reports it. |
| `blendMode` | string | Optional. The blend mode id, as GET document reports it (pass-through for groups only). One of: `pass-through`, `normal`, `darken`, `multiply`, `color-burn`, `linear-burn`, `darker-color`, `lighten`, `screen`, `color-dodge`, `linear-dodge`, `lighter-color`, `overlay`, `soft-light`, `hard-light`, `vivid-light`, `linear-light`, `pin-light`, `hard-mix`, `difference`, `exclusion`, `subtract`, `divide`, `hue`, `saturation`, `color`, `luminosity` |
| `visible` | boolean | Optional. Show or hide the layer. |
| `name` | string | Optional. The new name. |

### `add_waveform`

Draw the waveform of the sound open in Jämmer (the series' audio editor, a separate app) as a new shape layer, for a cover or poster. It stays a vector shape the user can recolor, move and style.

| Param | Type | Description |
|---|---|---|
| `style` | string | Optional. bars (default) or wave (one outline). One of: `bars`, `wave` |
| `bars` | number | Optional. How many bars, 16–400 (default 64). |
| `color` | string | Optional. #RRGGBB; default the foreground color. |
| `height` | number | Optional. Share of the canvas height, 0.05–1 (default 0.3). |
| `width` | number | Optional. Share of the canvas width, 0.1–1 (default 0.8). |
| `position` | string | Optional. center (default), top or bottom. One of: `center`, `top`, `bottom` |
| `document` | string | Optional. The Jämmer document id or name; default the one in front. |

### `run_command`

Run an editor menu command.

| Param | Type | Description |
|---|---|---|
| `id` | string | Required. Command id. One of the ids in the table below. |

| Command id | What it does |
|---|---|
| `view.zoomIn` | Zoom In |
| `view.zoomOut` | Zoom Out |
| `view.fit` | Fit on Screen |
| `view.actualSize` | Actual Pixels (100%) |
| `view.rotateLeft` | Rotate View Left 15° |
| `view.rotateRight` | Rotate View Right 15° |
| `view.resetRotation` | Reset View Rotation |
| `view.rulers` | Rulers |
| `view.grid` | Grid |
| `view.snap` | Snap |
| `view.clearGuides` | Clear Guides |
| `view.palette` | Command Palette |
| `view.classicLayout` | Classic Layout |
| `view.hideInterface` | Hide Interface |
| `view.navigator` | Navigator |
| `view.toggleLayers` | Show/Hide Layers |
| `layer.new` | New Layer |
| `layer.duplicate` | Duplicate Layer |
| `layer.delete` | Delete Layer |
| `layer.forward` | Bring Forward |
| `layer.backward` | Send Backward |
| `layer.front` | Bring to Front |
| `layer.back` | Send to Back |
| `layer.newGroup` | New Group |
| `layer.group` | Group Layer |
| `layer.ungroup` | Ungroup |
| `layer.clip` | Create/Release Clipping Mask |
| `layer.mask.revealAll` | Add Layer Mask (Reveal All) |
| `layer.mask.hideAll` | Add Layer Mask (Hide All) |
| `layer.mask.toggle` | Enable/Disable Layer Mask |
| `layer.mask.delete` | Delete Layer Mask |
| `layer.mask.edit` | Edit Layer Mask |
| `layer.smart.convert` | Convert to Smart Object |
| `layer.rasterize` | Rasterize Layer |
| `select.all` | All |
| `select.none` | Deselect |
| `select.invert` | Inverse |
| `select.subject` | Subject |
| `select.people` | People |
| `select.sky` | Sky |
| `layer.textToLayers` | Image Text to Layers |
| `layer.viaCopy` | New Layer via Copy |
| `image.autoEnhance` | Auto Enhance |
| `image.autoColor` | Auto Color |
| `image.autoStraighten` | Auto Straighten |
| `image.straightenDocument` | Straighten Document |
| `image.suggestCrop` | Suggest Crop |
| `image.flipHorizontal` | Flip Horizontal |
| `image.flipVertical` | Flip Vertical |
| `image.rotateRight` | Rotate 90° Clockwise |
| `image.rotateLeft` | Rotate 90° Counterclockwise |
| `image.rotate180` | Rotate 180° |
| `image.gammaBlending` | Blend Colors in Gamma Space |

### `develop_raw`

Develop a RAW layer again from its camera file with other settings (on-device, free): brighter or darker, warmer or cooler, lifted shadows. Only for a layer that was opened from a RAW file (its `raw` in the document's layers); for any other layer use add_adjustment. Only the values given change. One undo step. Refused with the allowed range when a value is outside it, and by name for a control the file doesn't have: `GET /documents/{id}/layers/{layer}/raw/info` says what the file allows and what the settings are now.

| Param | Type | Description |
|---|---|---|
| `target` | string | Optional. The RAW layer's id or name (default: the active layer). |
| `exposure` | number | Optional. Stops added to the file's own exposure, -5…5; 1 is twice as bright. |
| `temperature` | number | Optional. White balance in kelvin, 2000…50000. A higher number makes the picture warmer (more yellow), a lower one cooler (more blue). |
| `tint` | number | Optional. -150…150; negative is greener, positive more magenta. |
| `shadows` | number | Optional. 0…2; 1 leaves the shadows as they are, more lifts them. |
| `contrast` | number | Optional. 0…1, where the file has the control. |
| `sharpness` | number | Optional. 0…1, where the file has the control. |
| `luminanceNoise` | number | Optional. Noise reduction, 0…1, where the file has the control. |
| `colorNoise` | number | Optional. Color noise reduction, 0…1, where the file has the control. |
| `highlightRecovery` | boolean | Optional. Recover detail in blown highlights (on by default), where the file has the switch. |
| `lensCorrection` | boolean | Optional. Use the lens correction stored in the file, where there is one. It reshapes the whole picture a little, not only the corners. |
| `asShot` | boolean | Optional. true first goes back to the camera's white balance and the standard values; other values given in the same step are then applied. |
| `replaceChanges` | boolean | Optional. A layer that was painted on or filtered after it was developed is refused (replaces_changes) unless this is true: developing again replaces those changes. |

### `heal_selection`

Fill the SELECTED area from what surrounds it, to take out a blemish, a wire or a small object (on-device, free, no model). Requires a selection. Copies existing image, so it suits areas up to about 120 px across on texture or even surfaces; larger areas are refused with reason area_too_large unless allowLarge is true. The step's info gives the method used, the pixels filled, the area's width at its thickest and the layer. One undo step; the selection stays.

| Param | Type | Description |
|---|---|---|
| `method` | string | Optional. auto (default) picks; smooth suits thin lines and even areas; texture copies patches of the surroundings. One of: `auto`, `smooth`, `texture` |
| `expand` | number | Optional. Pixels the selection is grown by first, 0–50 (default 3), so the object's edge and halo go with it. |
| `sampleAllLayers` | boolean | Optional. true (default): reads what is visible and puts the fill in a new layer named Heal above the active layer. false: reads and changes the active pixel layer itself. |
| `allowLarge` | boolean | Optional. true fills an area over about 120 px across anyway; the result may smear or repeat (info.quality is then may_repeat). |

## Good to know

- A parameter an operation or an endpoint doesn't have is refused by name with 400, and nothing is applied: in a `steps` request no step runs. Settings go inside a step's `params`; the settings of `add_adjustment`, `apply_filter` and `add_layer_effect` are checked against their `type`. So a 200 means every value you sent was used.
- Adjustment layers are non-destructive; filters change pixels. Prefer `add_adjustment` for tone and color.
- `auto_enhance` and `auto_color` add editable adjustment layers, worked out on the Mac.
- After a step, `GET /api/v1/documents/{id}/image` shows you what the user sees.
- To combine two images: open the first as a document, then send the second to `POST /api/v1/documents/{id}/layers` (its bytes, or `fromDocument` if it is already open as a document). Either way works for any caller. Place it with `x` and `y` when you add it, or afterwards with `transform_layer` (`moveX`, `moveY`); blend it with `set_layer`, cut it out with `remove_background`.
- `resize_canvas` adds room around the image (`crop` can only take room away). To get a shape such as 16:9: `crop` with `aspect` cuts the image down to it; `resize_canvas` with `aspect` and `anchor` adds room instead, for example beside a person for a title. Use `crop` when the image has more than you need, `resize_canvas` when it has too little.
- `crop`, `resize_image`, `resize_canvas` and `select_rect` count in document pixels, from the top-left corner. A crop that contradicts itself (a rectangle and an aspect, say) is a 400, not a failed step.
- What leaves the Mac through this API: nothing, except for paid steps. A paid step sends its prompt and the picture it works on (the document, or the selected area) to the picture service chosen in Glimmer's Settings (OpenRouter unless the person chose another; a refusal names it), billed to the user's key there, and only with `allowPaid: true` and `allowUnknownPrice: true`. The API never calls a text model: you are the one planning, so the text service chosen in Glimmer's Settings (OpenRouter, Berget or Grunden) is not used by anything you send here.
- To take something out of a photo: select it (`select_rect`, or `select_subject` when it is the main subject), then `heal_selection` fills the area from what surrounds it, on the Mac and free. It suits dust, scratches, wires and things up to about 120 px across on grass, sky, walls and the like; it copies existing image, it does not invent, so a large object or one in front of a complicated scene needs `inpaint_selection` (paid). An area over about 120 px across is refused with `area_too_large` unless `allowLarge` is true, and over 250 px or too much work always (`hard` is then true). Free steps can cut out a subject (`remove_background`), cover an area with a color (`fill`) or patch it with a copy of another part (`select_rect` with a `feather`, then `run_command` `layer.viaCopy`, which copies the selected, feathered part of the active layer to a new layer, then `transform_layer` with `moveX`/`moveY` to put the copy over the object).
- A layer's `bounds` are where its visible content is, in document pixels, after its mask; they can reach outside the canvas when content hangs over the edge.
- `maxSide` only ever makes an image smaller.
- Size limits: a side is at most 30000 pixels; an opened image at most 256 megapixels; and a canvas may not need more than two fifths of the Mac's memory for one layer (8 bytes a pixel: 800 megapixels on a 16 GB Mac). A new document, `resize_image` or `resize_canvas` beyond that is refused with reason `too_large` and the numbers. Many large layers make a document slow long before that: 60 layers at 6000 × 4000 take about 5.5 GB.
- The user may be editing the same document. Read the document before you act on it, and keep requests small.
