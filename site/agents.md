# Glimmer: guide for agents

Glimmer 0.2.0 is a native macOS photo editor with layers, adjustment layers, filters, selections, text and on-device AI (subject, people and sky selection, auto enhance, perspective correction). This page tells an agent how to drive the running app through its local HTTP API.

- Base URL: `http://127.0.0.1:9001` (this Mac only; the server listens on loopback). Glimmer uses port 9001, or the first free port from 9101 to 9119 when 9001 is taken; the address in Glimmer's **Help › Agent Access** window is always the real one.
- Check that `app.name` in `GET /api/v1/status` is `"Glimmer"` before you send changes, so you never edit with a different app that happens to listen on the port.
- Every POST needs the header **`X-Glimmer-Agent: 1`**. Without it you get `403 forbidden`.
- Don't send an `Origin` header: requests that look like they come from a web page are refused.
- Images travel in request and response bodies. The API never reads or writes file paths.
- Edits land in open document windows that the user can see, and can be undone. One `steps` request is one undo step.
- Steps that cost money (OpenRouter) are refused unless you pass `"allowPaid": true`. Everything else runs on the Mac, free.

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

# 3. Edit it: automatic tone and colour, then a little more vibrance.
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
| GET | `/api/v1/status` | `app.name` (always `"Glimmer"`), `app.version`, the API version, the port, the open documents and the running `jobs`. |
| GET | `/api/v1/operations` | Every step operation: `{"operations": [{"name", "description", "params", "paid", "undoable", "startsJob"}]}`. `params` is a JSON Schema, so an assistant can use the operations as tools as they are. Steps run through `steps`; the other requests (`export`, `image`, `undo`, `redo`) carry `call: {method, path}`, and their params marked `"x-in": "path"` or `"query"` go there (the rest in the JSON body). |
| GET | `/api/v1/documents` | The open documents. |
| POST | `/api/v1/documents` | Open an image (raw bytes with `?name=…`, or JSON `{"image": "<base64>", "name": "…"}`) or create a blank document (JSON `{"width", "height", "background": "white"\|"black"\|"transparent"}`). |
| GET | `/api/v1/documents/{id}` | Size, layers (top first), the active layer and whether there is a selection. |
| GET | `/api/v1/documents/{id}/image` | The flattened image. Query: `format=png\|jpeg`, `maxSide=<px>`. |
| POST | `/api/v1/documents/{id}/steps` | Run steps in order. Body: `{"steps": [{"op": "…", "params": {…}}], "allowPaid": false, "async": false}`. Answers 200 when done, or 202 with a job (see Long jobs). |
| GET | `/api/v1/jobs` | Recent jobs (see Long jobs). |
| GET | `/api/v1/jobs/{id}` | One job: status, progress and, when finished, the result. |
| DELETE | `/api/v1/jobs/{id}` | Cancel a job that is still running. |
| POST | `/api/v1/documents/{id}/undo` | Undo the last step (a whole `steps` request counts as one). |
| POST | `/api/v1/documents/{id}/redo` | Redo. |
| POST | `/api/v1/documents/{id}/export` | The finished image as bytes. Body: `{"format": "png\|jpeg\|heic\|tiff\|webp", "quality": 0.9, "maxSide": 2048, "maxBytes": 500000}`; all optional (PNG by default). |

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

Common requests: black and white is `add_adjustment` with `"type": "black_white"`; a vignette is `apply_filter` with `"type": "vignette"`; a finished look is `apply_preset`.

### Long jobs

Steps that call OpenRouter can take a minute, so a `steps` request that contains a paid step always runs as a job, and so does any request with `"async": true`. Such a request answers `202 Accepted` at once:

```json
{"job": {"id": "C1A2…", "kind": "steps", "document": "8F0C…", "status": "running", "progress": 0}}
```

Poll `GET /api/v1/jobs/{id}` until `status` is `done`, `failed` or `cancelled` (it starts as `queued` or `running`). `progress` goes from 0 to 1 as steps finish. A finished job carries the same `result` a direct request would have returned (`results` and `document`), and a failed one also has `error` (`{"code": "step_failed", "message": "…", "step": 1}`). `DELETE /api/v1/jobs/{id}` cancels a running job; steps that didn't run are reported as `cancelled`. Running jobs are also listed under `jobs` in `GET /api/v1/status`. Finished jobs are kept for a while (the 50 most recent).

```sh
JOB=$(curl -s -X POST -H 'X-Glimmer-Agent: 1' -d '{"steps": [{"op": "auto_enhance"}], "async": true}'       $BASE/api/v1/documents/$ID/steps | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"]["id"])')
curl -s $BASE/api/v1/jobs/$JOB
```

### Requests from other apps

Glimmer's siblings, Flimmer and Jämmer, call this API like any agent and add `X-Sibling: <their slug>` (for example `X-Sibling: flimmer`). Glimmer logs it and shows "Requested by Flimmer" in the window it changes. The header grants nothing extra.

### Export size limits

`maxSide` scales the image so its longer side fits. `maxBytes` (JPEG, HEIC and WebP only; PNG and TIFF ignore it) lowers the quality until the file fits, and scales the image down too if even low quality is too big, so the limit is met.

## Errors

Errors are JSON: `{"error": {"code": "…", "message": "…"}}`. A failed step also gives its index: `{"error": {"code": "step_failed", "message": "…", "step": 1}}`.

| Status | Code | Meaning |
|---|---|---|
| 400 | `bad_request` | The body or a parameter is malformed. The message says which. |
| 402 | `paid_not_allowed` | A step costs money and `allowPaid` wasn't `true` (or no OpenRouter key is saved in Glimmer). |
| 403 | `forbidden` | Missing `X-Glimmer-Agent: 1`, an `Origin` header, or a Host other than this Mac. |
| 404 | `not_found` | No such document, path or operation. |
| 405 | `method_not_allowed` | Wrong HTTP method for the path. |
| 413 | `too_large` | Body over 256 MB. |
| 422 | `step_failed` | A step ran and failed. `error.step` is its index; `results` has the status of every step. |
| 422 | `unprocessable` | A request other than steps can't be done right now; `error.reason` says why (`nothing_to_undo`, `nothing_to_redo`, `no_history`). |
| 500 | `internal` | Glimmer failed unexpectedly. The message has the detail. |

## Operations

These are the `op` values for `steps`, with their `params`. The same list is available as JSON from `GET /api/v1/operations`.

### `add_adjustment`

Add a non-destructive adjustment layer above the active layer (contrast, hue, black & white, curves …).

| Param | Type | Description |
|---|---|---|
| `type` | string | Which adjustment. One of: `brightness_contrast`, `levels`, `curves`, `exposure`, `hue_saturation`, `vibrance`, `color_balance`, `black_white`, `photo_filter`, `channel_mixer`, `invert`, `posterize`, `threshold`, `gradient_map` |
| `params` | object | Settings by key; omitted keys keep their default, {} is neutral. Keys (range, default) per type — brightness_contrast: brightness (-1…1, 0), contrast (-1…1, 0); exposure: exposure (-5…5, 0), offset (-0.5…0.5, 0), gamma (0.1…3, 1); hue_saturation: hue (-180…180, 0), saturation (-1…1, 0), lightness (-1…1, 0); vibrance: vibrance (-1…1, 0), saturation (-1…1, 0); color_balance: shadowsR (-1…1, 0), shadowsG (-1…1, 0), shadowsB (-1…1, 0), midtonesR (-1…1, 0), midtonesG (-1…1, 0), midtonesB (-1…1, 0), highlightsR (-1…1, 0), highlightsG (-1…1, 0), highlightsB (-1…1, 0), preserveLuminosity (true/false); black_white: red (-2…3, 0.4), yellow (-2…3, 0.6), green (-2…3, 0.4), cyan (-2…3, 0.6), blue (-2…3, 0.2), magenta (-2…3, 0.8); photo_filter: density (0…1, 0.25), preserveLuminosity (true/false), color (#RRGGBB); channel_mixer: rr (-2…2, 1), rg (-2…2, 0), rb (-2…2, 0), rc (-2…2, 0), gr (-2…2, 0), gg (-2…2, 1), gb (-2…2, 0), gc (-2…2, 0), br (-2…2, 0), bg (-2…2, 0), bb (-2…2, 1), bc (-2…2, 0), monochrome (true/false); posterize: levels (2…255, 4); threshold: level (0…1, 0.5). Moderate values look natural: exposure is in stops (±0.3–1), most −1…1 sliders are strong beyond ±0.4. For a colour cast use color_balance (positive B = bluer, positive R = redder) or photo_filter. |

### `apply_filter`

Apply a destructive pixel filter to the active pixel layer (inside the selection if there is one).

| Param | Type | Description |
|---|---|---|
| `type` | string | Which filter. One of: `gaussian_blur`, `lens_blur`, `motion_blur`, `sharpen`, `unsharp_mask`, `clarity`, `add_noise`, `pixelate`, `find_edges`, `emboss`, `oil_paint`, `halftone`, `vignette`, `chromatic_aberration` |
| `params` | object | Settings by key; {} uses the defaults. Keys (range, default) per type — gaussian_blur: radius (0…100, 4); lens_blur: radius (0…60, 8), brightnessBoost (0…1, 0.3); motion_blur: angle (-180…180, 0), distance (0…200, 20); sharpen: amount (0…5, 1); unsharp_mask: amount (0…5, 0.8), radius (0.5…10, 2), threshold (0…1, 0); clarity: amount (-1…1, 0.4); add_noise: amount (0…1, 0.1), monochrome (0/1); pixelate: cell (2…200, 10); find_edges: no settings; emboss: angle (-180…180, 135), amount (0…5, 1); oil_paint: radius (1…10, 4), intensity (0…1, 1); halftone: cellSize (2…40, 8), angle (0…90, 45), monochrome (0/1); vignette: amount (0…1, 0.5), midpoint (0…1, 0.5), roundness (0…1, 0.5), feather (0.01…1, 0.5); chromatic_aberration: amount (0…40, 6), edgeOnly (0/1). |

### `add_layer_effect`

Add or update a layer style on the active layer.

| Param | Type | Description |
|---|---|---|
| `type` | string | Which effect. One of: `dropShadow`, `innerShadow`, `outerGlow`, `stroke`, `colorOverlay` |
| `params` | object | Patch, e.g. {"distance": 8, "opacity": 0.5, "size": 12} for dropShadow, {"width": 4, "color": "#ffffff"} for stroke, or {}. |

### `apply_preset`

Apply a finished photo look (adjustment group plus grain/vignette).

| Param | Type | Description |
|---|---|---|
| `name` | string | Preset name. One of: `Cinematic Teal & Orange`, `Vintage Film`, `B&W Noir`, `HDR Pop`, `Golden Hour`, `Cool Cyberpunk`, `Matte Fade`, `Bleach Bypass`, `Cross Process`, `Dreamy Soft` |

### `add_text`

Add a text layer.

| Param | Type | Description |
|---|---|---|
| `text` | string | The text. |
| `color` | string | #RRGGBB colour (optional, default the foreground colour). |
| `size` | number | Font size in pixels (optional; default ~8% of the image height). |
| `position` | string | Where to place it. One of: `top`, `center`, `bottom` |

### `image_edit_composite` (paid)

Edit the WHOLE visible image with a natural-language instruction (content-aware: "make it snowy", "change the car to red"). The result lands as a new layer.

| Param | Type | Description |
|---|---|---|
| `instruction` | string | The change to make. |

### `generate_layer` (paid)

Generate a new image from a text prompt as a new layer.

| Param | Type | Description |
|---|---|---|
| `prompt` | string | What to generate. |

### `auto_enhance`

Automatic tone and colour correction (on-device, free, instant) as editable adjustment layers. A good first step for "fix", "improve" or "make it look better" before any creative changes.

No params: `{"op": "auto_enhance"}`

### `auto_color`

Neutralise a colour cast (on-device, free) with a Color Balance layer. For "too yellow/blue/green", "fix the white balance".

No params: `{"op": "auto_color"}`

### `select_sky`

Select the sky (on-device, free). Use before replacing or adjusting the sky.

No params: `{"op": "select_sky"}`

### `select_people`

Select every person in the image (on-device, free, more precise than select_subject for people).

No params: `{"op": "select_people"}`

### `remove_background`

Cut the main subject out of the active layer onto transparency (adds a mask; on-device, free).

No params: `{"op": "remove_background"}`

### `select_subject`

Select the main subject (on-device, free).

No params: `{"op": "select_subject"}`

### `inpaint_selection` (paid)

Regenerate or erase the SELECTED region. Requires a selection.

| Param | Type | Description |
|---|---|---|
| `prompt` | string | What to fill the selection with (may be empty for remove). |
| `mode` | string | fill replaces with the prompt; remove erases an object. One of: `fill`, `remove` |

### `upscale`

Upscale the whole image.

| Param | Type | Description |
|---|---|---|
| `scale` | number | 2 or 4 (on-device Real-ESRGAN, free). |

### `fill`

Fill the selection (or the whole active layer) with a colour.

| Param | Type | Description |
|---|---|---|
| `color` | string | #RRGGBB or #RRGGBBAA. |

### `set_foreground`

Set the foreground (paint) colour.

| Param | Type | Description |
|---|---|---|
| `color` | string | #RRGGBB. |

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
| `radius` | number | Pixels. |

### `select_layer`

Make a layer the active one, so the following steps act on it. New layers become active by themselves.

| Param | Type | Description |
|---|---|---|
| `name` | string | The layer's name (not case-sensitive; the topmost match wins) or its id. |

### `new_layer`

Add an empty pixel layer.

| Param | Type | Description |
|---|---|---|
| `name` | string | Optional layer name. |

### `run_command`

Run an editor menu command.

| Param | Type | Description |
|---|---|---|
| `id` | string | Command id. One of: `view.zoomIn`, `view.zoomOut`, `view.fit`, `view.actualSize`, `view.rotateLeft`, `view.rotateRight`, `view.resetRotation`, `view.rulers`, `view.grid`, `view.snap`, `view.clearGuides`, `view.palette`, `view.classicLayout`, `view.hideInterface`, `view.navigator`, `view.toggleLayers`, `layer.new`, `layer.duplicate`, `layer.delete`, `layer.forward`, `layer.backward`, `layer.front`, `layer.back`, `layer.newGroup`, `layer.group`, `layer.ungroup`, `layer.clip`, `layer.mask.revealAll`, `layer.mask.hideAll`, `layer.mask.toggle`, `layer.mask.delete`, `layer.smart.convert`, `layer.rasterize`, `select.all`, `select.none`, `select.invert`, `select.subject`, `select.people`, `select.sky`, `layer.textToLayers` … (see /api/v1/operations) |

## Good to know

- Adjustment layers are non-destructive; filters change pixels. Prefer `add_adjustment` for tone and colour.
- `auto_enhance` and `auto_color` add editable adjustment layers, worked out on the Mac.
- After a step, `GET /api/v1/documents/{id}/image` shows you what the user sees.
- The user may be editing the same document. Read the document before you act on it, and keep requests small.
