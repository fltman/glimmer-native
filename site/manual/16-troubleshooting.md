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

### Filters are grayed out

Filters change pixels, so they need a pixel layer or a smart object. Select one in the Layers panel.

## On-device features

### A feature asks to download a model

Select Sky, Magic Select and Lens Blur use models that you download once (about 50 and 80 MB). Glimmer asks before it downloads one; click **Download** to get it. If the download fails, make sure the Mac is online, then try again. **Settings › Models** shows which models are installed, and lets you download or remove them.

### The download didn't match its checksum

Glimmer checks every downloaded file against the checksum its source publishes. When one doesn't match, the model is not installed and nothing of the download is kept. Try again later. If you have set **Settings › Models › Download from** to a mirror, the mirror may have other files: leave the field empty to use Hugging Face.

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

## Paid AI features

### "Add your OpenRouter key"

Paid features need a key for the service they use: OpenRouter, unless you chose another service in **Settings › AI**. Paste it there.

### A job fails

The AI panel's job list shows the error. Common causes:

- The account at the service has no credit left. For OpenRouter, add credit at openrouter.ai.
- The model you chose in **Settings › AI** is unavailable or doesn't accept images. Pick another model.
- The Mac is offline. Glimmer says it couldn't reach the AI service. The tools that run on your Mac keep working.

A job you cancel stops waiting for the result; the service may still bill a request that it already started. A job that failed after its request was sent says **May have been charged** in the job list for the same reason.

## Files and export

### "The document couldn't be saved"

The disk doesn't have room for the document, or it can't be written to. macOS first says that the document could not be saved; when you close that message, Glimmer says how much room the document needs and how much is free. Your document is still open and nothing was lost: free up space, or save it on another disk. Glimmer explains this once per document, also when an automatic save fails, and leaves no half-written file behind.

### "Your disk is almost full, so Glimmer keeps fewer undo steps"

Glimmer keeps older undo steps on disk when they outgrow their share of memory. When the disk has too little room for that, it forgets the oldest steps instead of filling the disk. The document itself is not affected. Free up space and the full history is kept again for new changes.

### "The image file is damaged or incomplete"

The file starts like an image but is cut short or broken inside, often after an interrupted download or copy. Glimmer doesn't open half a picture. Get the file again from where it came from.

### "This document needs about … of memory"

The document has grown past what your Mac holds comfortably. Nothing is wrong with it and you can keep working, but Glimmer may get slow. Merge layers you no longer need apart (put them in a group and choose **Layer › Rasterize Layer**, which the Layers panel's menu calls **Merge Group** for a group, or rasterize smart objects you are done with), or make the image smaller with **Image › Image Size…**. See [How large a document can be](02-documents-and-files.md#how-large-a-document-can-be).

### "A canvas of … pixels needs … for a single layer"

The new document or the new size is too large for this Mac's memory. The message says how large a canvas this Mac can hold. Choose a smaller size.

### "The image is too large"

Glimmer opens images up to 256 megapixels (for example 16,000 × 16,000) and 32,768 pixels a side. Make the image smaller in another app first.

### The exported file is bigger than the size limit

**Limit file size** only applies to JPEG, HEIC and WebP. PNG and TIFF are lossless and ignore it. Choose a lossy format, or set **Limit longest side**.

### Colors look different after export

Check **Color profile** in the Export sheet. Display P3 keeps more saturated colors, but some web browsers and apps show it less accurately than sRGB. Export for Web always uses sRGB.

### A Photoshop file opened as a single layer

Glimmer reads the layers of RGB and grayscale Photoshop files with 8 or 16 bits per channel. A file in another color mode (CMYK, Lab, indexed color and others) or with 32 bits per channel opens as one layer, the flattened picture saved in the file. **File › Import Report…** says which it was. See [Photoshop files](02-documents-and-files.md#photoshop-files).

### Batch Process skipped steps or failed on some files

Batch Process runs the same code as Shortcuts, without a window. Steps from a saved action that need the window or a paid AI job are not run. The list shows the error sign, a cross in a square, with the reason for each file that failed.

## Memory and speed

### Glimmer uses a lot of memory

Undo history keeps the pixels that each step changed. Lower **Settings › Performance › History memory** to keep less history. Large documents with many layers also need more memory.

### The app feels slow on very large images

Close other documents, hide layers you are not working on, and use **Fit on Screen** (⌘0) while you work.

## Agents

### An agent can't connect

- Glimmer must be running.
- Use the address shown under **Help › Agent Access…**. If port 9001 is taken by another program, Glimmer uses the first free port from 9101 to 9119, and the window shows the real address.
- If the window says all ports are in use, quit the programs that use port 9001 and ports 9101–9119, then restart Glimmer.
- Another program may hold a port in that range. Docker containers often do: a MinIO server, for example, uses 9100 and 9101. Glimmer then uses the next free port, so this is harmless; just use the address the window shows. An agent that checks that `app.name` in `GET /api/v1/status` is `"Glimmer"` never mistakes the other program for Glimmer.
- Glimmer finds Jämmer and Flimmer the same way, and skips ports where another program answers.

### A copy built from source behaves like a different app

A Debug build made from the source code is its own app to macOS: its identifier is `com.brattoo.glimmer.debug`, so it has its own settings, its own folder under `~/Library/Containers`, its own saved windows and its own Keychain item for the OpenRouter key. Nothing you do in it changes the Glimmer you installed. `GET /api/v1/status` shows which copy answered, under `app.bundleID`. A Debug build also looks for the Debug builds of Flimmer and Jämmer, not the installed ones.

### The assistant says "Jämmer is not running"

The assistant needed Jämmer (or Flimmer) for your request, but couldn't find it on this Mac. Click **Open Jämmer**, wait until it has opened your document, and ask again. If Jämmer is open but still not found, quit and reopen it so that it starts its local server again.

### The agent gets 403 forbidden

Every POST needs the header `X-Glimmer-Agent: 1`. Requests with an `Origin` header (from web pages) are refused, and so are requests that don't address the server as `127.0.0.1` or `localhost`.

### The agent gets 402 paid_not_allowed

The step goes to the picture service chosen in **Glimmer › Settings › AI** (OpenRouter unless you chose another); the message names it. The agent must send `"allowPaid": true`, and a key for that service must be saved in Glimmer.

### The agent gets 422 with the reason unknown_price

The step is paid and Glimmer does not know its price in advance, which today is true of every paid step. `allowPaid` alone does not mean "whatever it costs": the agent must also send `"allowUnknownPrice": true`, on every call. Nothing was run.

### A button that makes a picture is gray

Tick **<service> does not state a price in advance; I know**, under the line **Price not known in advance** beside the button, or in **Glimmer › Settings › AI** under **Pictures**. See [What costs money](11-ai-with-openrouter.md#what-costs-money).

## Updates

Choose **Glimmer › Check for Updates…**. Glimmer downloads and installs new versions for you, after you confirm.
