## What is Glimmer?

Glimmer is a photo editor for the Mac. It has the tools you expect from a serious editor (layers, masks, adjustment layers, filters, selections, brushes, retouching, text, paths and shapes) and adds AI where it saves time. Many AI features run on your Mac for free. The rest use your own OpenRouter key.

## What do I need to run it?

A Mac with Apple silicon and macOS 27 or later. Some on-device features download a model the first time you use them, so you need an internet connection once for those.

## What does Glimmer cost?

Nothing. Glimmer is free, with no accounts, no subscriptions and no ads. The only costs are the optional AI features that use OpenRouter, which you pay to OpenRouter with your own key (see below).

## Is Glimmer open source?

Yes. Glimmer is open source under the MIT license, so you may use it for any purpose, including commercial work, and read, change and share the code. The source code will be published on GitHub when Glimmer is released, with a link here.

## How can I support Glimmer?

If Glimmer is useful to you, you can support the work on [Patreon](https://www.patreon.com/AndersBjarby).

## Do the AI features cost money?

Only the ones that use OpenRouter. Generating images, editing with a prompt, Generative Fill, Remove Object, Expand, Relight, Harmonize, Remove Reflections, Clean Up and the assistant's planning call OpenRouter with your own API key, and OpenRouter bills you for what you use. What a call costs depends on the model you choose in Settings. Glimmer shows the cost of each job in the AI panel's job list when OpenRouter reports it.

Everything that runs on the Mac is free: Auto Enhance, Auto Color, Match Color, Auto Straighten, Suggest Crop, Select Subject, Select People, Select Sky, Magic Select, Remove Background, Lens Blur, Straighten Document, Image Text to Layers, Real-ESRGAN upscaling, Batch Process and photo rating, and simple requests that Apple Intelligence answers.

## How do I get an OpenRouter key?

Create an account at openrouter.ai, add credit, and create a key at openrouter.ai/keys. Paste it into **Glimmer › Settings › AI**. You only need a key for the paid features.

## Where is my OpenRouter key stored, and who sees it?

In your Mac's keychain. Glimmer sends it only to openrouter.ai, with the requests you start. There is no Glimmer server in between.

## Does Glimmer work without the internet?

Yes. Glimmer is a complete app on your Mac: there is no server to run and no account, and it starts and works with the network off. Offline you can open and save, use every tool, layer, adjustment, filter and text feature, Auto Enhance and Auto Color, Select Subject and Select People, Remove Background, Straighten Document, Image Text to Layers, Real-ESRGAN upscaling, Batch Process, export, Shortcuts and the agent API (it lives on your Mac, at 127.0.0.1).

Three things need a connection:

- **Two models that download once.** Select Sky, Lens Blur and Magic Select use models that Glimmer downloads the first time (see [Models downloaded on first use](manual/10-on-device-intelligence.md#models-downloaded-on-first-use)). After that they work offline. If you try one offline before its model is there, Glimmer says that the download didn't work and what to do; nothing else is affected.
- **The OpenRouter features.** Generating, generative fill and the other paid AI features send the image to OpenRouter, so they need the internet and your key.
- **Update checks.**

## What stays private?

Your images stay on your Mac unless you start an OpenRouter feature. Then Glimmer sends the image (or the part it needs) to OpenRouter, which passes it to the model provider. On-device features never send anything anywhere. Glimmer has no accounts, no analytics and no telemetry, and no service of ours sits in between. Update checks read the update feed at glimmer.brattoo.com. You can point the AI features at another OpenRouter-compatible service, and the model downloads at a mirror, in Settings.

## Which file formats can Glimmer open and save?

Glimmer opens the image formats macOS can read, including JPEG, PNG, HEIC, TIFF, WebP, GIF, BMP and camera RAW (basic decoding). It saves its own documents as `.glimmer` files, which keep every layer, mask, adjustment and path. It exports PNG, JPEG, HEIC, TIFF, WebP and Photoshop files, and it can import and export projects from Glimmer for the web (`.aips`).

## Can Glimmer open Photoshop files?

Yes, with their layers, as a new Glimmer document; the Photoshop file is not changed. Layers of pixels, groups, masks, blend modes except Dissolve, solid colour fills, one-colour shapes, and Levels, Curves and Invert adjustment layers come through as they were. Text and smart objects become pixels; layer effects, vector masks and the other adjustment layers are not read. An Import Report lists what did not come through, and says whether Glimmer's picture matches the one saved in the file. Glimmer can also export a Photoshop file with layers (**File › Export… › Photoshop File…**).

This has been tried with eighteen small test files written by Photoshop and with files Glimmer generates itself. Text, smart objects, PSB, CMYK and Lab files, and large files have not yet been tried with files from Photoshop, and exported files have not been opened in Photoshop. See [Photoshop files](manual/02-documents-and-files.md#photoshop-files).

## Is my work saved automatically?

Yes. Glimmer documents use macOS autosave and versions, so you can close a document without losing work and go back to earlier versions with **File › Revert To**. Autosave keeps your Glimmer document, never the image you opened: an image file only changes when you export over it, or when you save back an image that Flimmer handed you to edit.

## Can one word in a text have its own style?

Yes. Edit the text, select the words and change the font, style, size or color in the options bar; only the selection changes. The text stays editable, also after you scale, rotate or skew it with Free Transform. See [Text, paths and shapes](manual/09-text-paths-and-shapes.md).

## How do I resize an image?

Choose **Image › Image Size…** (⌥⌘I), type a new width or height in pixels and click **Resize**. With **Keep proportions** on, the other side follows. Text stays editable and layer styles are scaled along. To add room around the image without scaling it, choose **Image › Canvas Size…** (⌥⌘C). The assistant and agents can do both. See [Transform, crop and image](manual/08-transform-crop-and-image.md).

## Can AI agents control Glimmer?

Yes. Glimmer runs a small web server on your Mac, reachable only from your Mac, at `http://127.0.0.1:9001` (or the first free port from 9101 to 9119). An agent such as Claude can fetch the guide at `/glimmer` and then open, edit and export images in your open windows. Copy the line under **Help › Agent Access** and paste it to your agent. See the [Agent guide](agents.html) for the details. State-changing requests need a special header, requests from web pages are refused, and paid steps are refused unless the agent asks for them explicitly.

## How large can a document be?

Each side can be up to 32,768 pixels, and the canvas must fit your Mac's memory: about 850 megapixels on a Mac with 16 GB. Many large layers matter sooner. A 6000 × 4000 document with 60 layers takes about 5.5 GB of memory; at 12,000 × 8,000 the same document would need about 20 GB (calculated, not measured). Glimmer tells you once when a document outgrows your Mac, and merging layers or lowering the resolution helps. See [Documents and files](manual/02-documents-and-files.md).

## Does Glimmer work with Flimmer and Jämmer?

Yes. The three apps can ask each other for things on your Mac. Glimmer's assistant can use Jämmer's and Flimmer's operations, for example to draw the waveform of an episode in Jämmer as a cover image, or to add an echo in Jämmer. Flimmer can hand Glimmer a picture to edit and pick up the result when you press ⌘S, and can ask Glimmer for cover art in podcast sizes (3000 × 3000 or 1400 × 1400 pixels). Glimmer shows "Requested by Flimmer" when a sibling changes something, and never opens another app unless you click to open it. Everything stays on your Mac, and nothing that costs money happens without your say. See [Automation](manual/13-automation.md).

## Can I use Glimmer with VoiceOver or only the keyboard?

Yes. Tools, layers, sliders and the assistant are read by name and value, layers have VoiceOver actions (hide, rename, edit mask), and every command can be run from the menus or the command palette (⌘K). With keyboard navigation turned on in System Settings, Tab moves between the canvas and the panels, / jumps to the search bar, and Curves takes the arrow keys. See [Accessibility](manual/17-accessibility.md).

## Does Glimmer work with Shortcuts?

Yes. Glimmer adds Shortcuts actions that work on image files without opening a window: Auto Enhance Image, Remove Background, Apply Glimmer Preset, Apply Glimmer Filter, Run Glimmer Action and Export Glimmer Document.

## Can I edit many photos at once?

Yes. **File › Batch Process…** runs Auto Enhance, Remove Background, a preset or a saved action on many images or whole folders, and writes the results to a folder you choose. It can also rate your photos so you keep only the sharp, good ones.

## Does Glimmer support pen tablets?

Yes. Pen pressure can drive brush size and opacity, pen tilt can drive the brush angle and roundness, and pen rotation can drive the angle. Turn these on under **Dynamics** in the brush options, and tune the pressure curve in **Settings › Tablet**.

## Is Glimmer available in other languages?

The app is available in English and Swedish. It follows your Mac's language settings.

## Are the pictures in this documentation real photos?

No. The example pictures in the screenshots are AI-generated, so the documentation shows no real people, places, brands or private photos.

## How do I uninstall Glimmer?

Quit Glimmer and move it from Applications to the Trash. To remove everything it stored as well:

- Its data: `~/Library/Containers/com.brattoo.glimmer` (settings, downloaded on-device models and the cache of AI results).
- Your OpenRouter key: open Keychain Access and delete the item `com.brattoo.glimmer` (account `openrouter-api-key`), or remove the key in **Settings › AI** before you uninstall.

Your own `.glimmer` documents and exported images stay where you saved them.
