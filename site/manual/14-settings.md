# Settings

Choose **Glimmer › Settings…** (⌘,) to open the Settings window. It has five tabs: General, AI, Models, Performance and Tablet. Changes take effect right away. There is no Save button.

## General

### Canvas

| Setting | What it does |
| --- | --- |
| Background | The color around the image on the canvas. **Match System** (the default) uses Glimmer's own near-black. You can also choose **Light Gray**, **Mid Gray**, **Dark Gray** or **Black**. Pick a neutral gray when you judge color and brightness. |
| Transparency grid | The size of the checkerboard that shows transparent areas: **Small**, **Medium** (the default) or **Large**. |
| Show the search bar on the canvas | Shows the omnibar at the bottom of the window. Turn it off if you prefer to use the command palette (⌘K) only. On by default. |
| Show the action bar at the selection | Shows the small bar next to a selection, with Generate, Remove, Invert, Feather and Deselect. On by default. |

### Assistant

| Setting | What it does |
| --- | --- |
| Run AI steps without asking | When the assistant plans an edit that includes paid AI jobs, it normally shows you the plan first and waits for you to run it. Turn this on to run such plans straight away. Plans that only use the editor's own tools always run straight away. Off by default. The **AUTO-EDIT** button in the assistant does the same thing. Such a plan still waits until you have ticked, under **AI › Pictures**, that the picture service states no price in advance. |
| Let the assistant see the image | Sends a small copy of the image (at most 1024 pixels) with each request, so the assistant can pick settings that suit the photo. On by default. |
| Check the result and adjust once | After a plan has run, the assistant compares the image before and after, and may adjust the result once. On by default. |
| Understand simple requests on this Mac | Lets Apple Intelligence handle requests that need only one command, so they run at once without a call to OpenRouter. Other requests still go to OpenRouter. On by default. This needs Apple Intelligence. Without it, the setting is dimmed. |

## AI

### OpenRouter

Glimmer's cloud AI tools and the assistant use OpenRouter. Glimmer calls OpenRouter directly with your own key. The key is stored in your keychain and is only sent to the service set under **Service** (openrouter.ai unless you change it). The footer has a link to the OpenRouter page where you create a key.

| Control | What it does |
| --- | --- |
| API key | Paste your key here. OpenRouter keys look like `sk-or-v1-…`. Press ⏎ or click **Save** to store it. |
| Save | Stores the key in your keychain. Saving an empty field removes the key. |
| Test Key | Asks OpenRouter whether the key works. Glimmer shows **Valid**, and how much credit is left if the key has a limit, or the reason it failed. |
| Remove | Deletes the stored key. Shown only when a key is saved. |

### Service

| Setting | What it does |
| --- | --- |
| Endpoint | The address of the AI service. Leave it empty to use OpenRouter (`https://openrouter.ai/api/v1`). Any service with OpenRouter's API works, for example a server you run yourself. If the text isn't a valid http or https address, Glimmer shows a warning and uses OpenRouter. |

### Models

| Setting | What it does |
| --- | --- |
| Image model | The OpenRouter model used to generate and edit images. The default is `google/gemini-3-pro-image-preview`. |
| Text model | The OpenRouter model the assistant uses to plan edits. The default is `google/gemini-2.5-flash`. |
| Restore Defaults | Sets both models back to the defaults. |

Type the model name exactly as OpenRouter lists it.

## Models

Some tools use models that run on your Mac. Glimmer downloads each one the first time you use the tool that needs it.

| Model | Used for | Size |
| --- | --- | --- |
| Depth (Depth Anything V2 Small) | Lens Blur, which needs to know how far away each part of the photo is | about 48 MB |
| Magic Select (SAM 2.1 Tiny) | The Magic Select tool | about 78 MB |

Each row says whether the model is downloaded. Click **Remove** to delete a downloaded model and free the space. It downloads again the next time you need it. The models come from Apple's Core ML conversions on Hugging Face.

| Setting | What it does |
| --- | --- |
| Download from | Where Glimmer downloads the models. Leave it empty for Hugging Face. A mirror must serve the same paths as Hugging Face (`<repository>/resolve/main/<file>`). |

## Performance

### Undo History

| Setting | What it does |
| --- | --- |
| History states | How many undo steps Glimmer keeps for each document, from 10 to 500, in steps of 10. The default is 100. When you go past the limit, the oldest steps are dropped. |
| History memory | How much memory the undo history may use: 512 MB, 1 GB, 2 GB (the default), 4 GB or 8 GB. |

Undo steps share the pixels that didn't change, so each step only costs the parts of the image it changed. When the history needs more memory than you allow, the oldest steps move to disk. They load back if you undo that far. The newest step always stays in memory.

### Graphics

This section shows facts about your Mac. You can't change them.

| Item | What it shows |
| --- | --- |
| GPU | The name of the graphics processor Glimmer uses. |
| Memory | How much memory your Mac has. |
| Recommended working set | How much memory the GPU can use comfortably. |

## Tablet

### Pen Pressure

| Control | What it does |
| --- | --- |
| Pressure | Drag the slider from **Soft** to **Firm**. Soft reaches full size and flow with a lighter touch. Firm needs more force. The middle is a straight, even response. |
| Curve | The small graph shows how pen pressure (across) turns into brush pressure (up). |
| Reset | Sets the response back to the middle. |

The pressure curve applies to every tool that responds to pressure. A mouse always paints at full pressure.

### Pen tilt

| Setting | What it does |
| --- | --- |
| Use pen tilt | Lets Glimmer read the tilt of your pen. On by default. To shape the brush with the pen, also turn on **Tilt → Angle**, **Tilt → Roundness** or **Rotation → Angle** under Dynamics in the brush options. |

## Choices Glimmer remembers elsewhere

A few choices are not in the Settings window, but Glimmer keeps them between launches:

| Choice | Where you change it |
| --- | --- |
| Show the Agent Access window at launch | **Show at launch** in the Agent Access window (**Help › Agent Access…**). |
| Classic layout | **View › Classic Layout**. |
| Size and background for new documents | The New Document window. It remembers what you used last. |
| Delete cropped pixels | The options bar of the Crop tool. |
| Saved swatches | The swatches popover below the color wells in the tool palette. |
| Brush presets | **Presets › Save Current Brush…** in the options bar of the Brush and Eraser. |
| Upscale method | Real-ESRGAN or Lanczos, in the Upscale section of the AI panel. |
