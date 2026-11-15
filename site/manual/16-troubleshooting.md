# Troubleshooting

Problems you may run into, and how to fix them.

## Keys and tools

### Single-letter shortcuts do nothing

A text field has the keyboard: the omnibar, the command palette, a layer name or a number field. Press Esc or click the image, then try again. Shortcuts with ⌘ work regardless.

### The first click after closing a panel does nothing

When another window had the focus (the Colors panel, the Agent Access window, an open or save dialog), the first click on the document window only brings it to the front. Click again.

### "This layer can't be painted directly"

The active layer is text, a shape, a fill layer or a smart object. Painting tools need a pixel layer. Choose **Layer › Rasterize Layer** to turn it into pixels, or make a new layer (⇧⌘N) and paint on that.

### "Select a pixel layer, or click a layer mask to paint it"

The active layer is a group or an adjustment layer. Select a pixel layer in the Layers panel, or click the layer's mask thumbnail to paint the mask.

### The brush or eraser leaves no mark

- There is a selection, and you are painting outside it. Press ⌘D to deselect.
- The layer is hidden, or its opacity is 0%.
- The brush opacity or flow is very low, or the foreground color's opacity is 0%. Press D to reset the colors.
- The mask is the paint target (the mask thumbnail is highlighted). Click the layer thumbnail to paint pixels instead.

### Filters are greyed out

Filters change pixels, so they need a pixel layer or a smart object. Select one in the Layers panel.

## On-device features

### A feature asks to download a model

Select Sky, Magic Select and Lens Blur use models that Glimmer downloads the first time (about 50–80 MB each). Make sure the Mac is online, then try again. **Settings › Models** shows which models are installed, and lets you remove and download them again if a download was interrupted.

### Magic Select or Select Sky is slow the first time

The first use after Glimmer starts loads the models, which takes a few seconds. Later uses are much faster. Very large images also take longer.

### "Glimmer found no sky along the top of the image"

Select Sky looks for sky that reaches the top edge. It finds nothing in indoor photos, or when the top of the picture is a wall, trees or a ceiling. Use Magic Select (A) and click the sky instead.

### "Glimmer found no tilted horizon to straighten"

Auto Straighten needs a clear horizon, such as the sea or a flat landscape. Straighten by hand with the **Straighten** slider in the crop tool's options.

### "The whole image already frames the subject well"

Suggest Crop found nothing to cut. Choose an aspect ratio in the crop tool's options (for example 1:1 or 4:5) and press **Suggest** again.

### "Glimmer found no document, sign or screen to straighten"

Straighten Document needs a clear rectangle that covers a good part of the photo, with all four corners in view.

### "The image already looks balanced" or "No color cast to correct"

Auto Enhance and Auto Color found nothing worth changing. Add the adjustment layers yourself if you want a stronger look.

### Simple requests in the omnibar go to the paid assistant

Glimmer answers single-command requests on the Mac with Apple Intelligence. That needs Apple Intelligence to be turned on in System Settings, and the option in **Settings › AI** to be on.

## OpenRouter features

### "Add your OpenRouter key"

Paid features need your key. Paste it into **Settings › AI**.

### A job fails

The AI panel's job list shows the error. Common causes:

- The OpenRouter account has no credit left. Add credit at openrouter.ai.
- The model you chose in **Settings › AI** is unavailable or doesn't accept images. Pick another model.
- The Mac is offline.

A job you cancel stops waiting for the result; OpenRouter may still bill a request that it already started.

## Files and export

### The exported file is bigger than the size limit

**Limit file size** only applies to JPEG, HEIC and WebP. PNG and TIFF are lossless and ignore it. Choose a lossy format, or set **Limit longest side**.

### Colors look different after export

Check **Color profile** in the Export sheet. Display P3 keeps more saturated colors, but some web browsers and apps show it less accurately than sRGB. Export for Web always uses sRGB.

### A Photoshop file opened as a single layer

Glimmer reads the flattened image of a PSD. Layers in PSD files are not imported.

### Batch Process skipped steps or failed on some files

Batch Process runs the same code as Shortcuts, without a window. Steps from a saved action that need the window or a paid AI job are not run. The list shows an orange warning with the reason for each file that failed.

## Memory and speed

### Glimmer uses a lot of memory

Undo history keeps the pixels that each step changed. Lower **Settings › Performance › History memory** to keep less history. Large documents with many layers also need more memory.

### The app feels slow on very large images

Close other documents, hide layers you are not working on, and use **Fit on Screen** (⌘0) while you work.

## Agents

### An agent can't connect

- Glimmer must be running.
- Use the address shown under **Help › Agent Access**. If port 9001 is taken by another program, Glimmer uses the first free port from 9101 to 9119, and the window shows the real address.
- If the window says all ports are in use, quit the programs that use port 9001 and ports 9101–9119, then restart Glimmer.
- Another program may hold a port in that range. Docker containers often do: a MinIO server, for example, uses 9100 and 9101. Glimmer then uses the next free port, so this is harmless; just use the address the window shows. An agent that checks that `app.name` in `GET /api/v1/status` is `"Glimmer"` never mistakes the other program for Glimmer.
- Glimmer finds Jämmer and Flimmer the same way, and skips ports where another program answers.

### The assistant says "Jämmer is not running"

The assistant needed Jämmer (or Flimmer) for your request, but couldn't find it on this Mac. Click **Open Jämmer**, wait until it has opened your document, and ask again. If Jämmer is open but still not found, quit and reopen it so that it starts its local server again.

### The agent gets 403 forbidden

Every POST needs the header `X-Glimmer-Agent: 1`. Requests with an `Origin` header (from web pages) are refused, and so are requests that don't address the server as `127.0.0.1` or `localhost`.

### The agent gets 402 paid_not_allowed

The step uses OpenRouter. The agent must send `"allowPaid": true`, and an OpenRouter key must be saved in Glimmer.

## Updates

Choose **Glimmer › Check for Updates…**. Glimmer downloads and installs new versions for you, after you confirm.
