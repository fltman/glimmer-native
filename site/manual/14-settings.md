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
| Run AI steps without asking | When the assistant plans an edit that includes paid AI jobs, it normally shows you the plan first and waits for you to run it. Turn this on to run such plans straight away. Plans that only use the editor's own tools always run straight away. Off by default. The **AUTO-EDIT** button in the assistant does the same thing. Such a plan still waits until you have ticked, under **Pictures** in the AI tab, that the picture service states no price in advance. |
| Let the assistant see the image | Sends a small copy of the image (at most 1024 pixels) with each request, so the assistant can pick settings that suit the photo. On by default. |
| Check the result and adjust once | After a plan has run, the assistant compares the image before and after, and may adjust the result once. On by default. |
| Understand simple requests on this Mac | Lets Apple Intelligence handle requests that need only one command, so they run at once without a call to the text service. Other requests still go to the text service you chose (OpenRouter unless you changed it). On by default. This needs Apple Intelligence. Without it, the setting is dimmed. |

## AI

### OpenRouter

Glimmer's cloud AI tools and the assistant use OpenRouter unless you choose another service below. Glimmer calls the service directly with your own key. The key is stored in your keychain and is only sent to the service set under **Service** (openrouter.ai unless you change it). The footer has a link to the OpenRouter page where you create a key.

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

### Text (the Assistant)

Which service answers when the Assistant plans, suggests edits or looks for distractions. See [Other services](11-ai-with-openrouter.md#other-services) for the list.

| Control | What it does |
| --- | --- |
| Service | OpenRouter, another cloud service, or **Ollama (on this Mac)** while Ollama is running. |
| API key, Save | The key for that service, stored in your keychain and sent only to that service. Each service has its own key. |
| Model, Refresh | The models the service lists now. **Refresh** reads the list again. Under the model Glimmer shows what the list says about it: its price per million tokens and when that was read, and warnings when the model can't call tools or can't take pictures. |
| <service> does not state a price in advance; I know | Shown when Glimmer has read no price for the chosen model. Until it is ticked, the first request to the Assistant asks. Untick it to be asked again. |
| What is sent to … | The same text Glimmer shows before the first request to the service. |

For OpenRouter the text model is typed under **Models** below, and Glimmer reads OpenRouter's list for that id to show its price.

### Pictures

Which service makes and edits pictures: Generate, Edit with Prompt, Generative Fill, Expand and the others.

| Control | What it does |
| --- | --- |
| Service | OpenRouter or another picture service. The first time you choose one, Glimmer shows what is sent to it and asks. |
| API key, Save | The key for that service. |
| Model | The model's id, typed as the service writes it. For fal.ai there is also **Model for editing**. |
| <service> does not state a price in advance; I know | Glimmer cannot say what a picture costs before it is made. Until this is ticked, the buttons that make pictures stay gray. You tick it once per service; untick it to be asked again. See [The price is not known in advance](11-ai-with-openrouter.md#the-price-is-not-known-in-advance). |
| What is sent to … | What the picture features send to the service. |

### Models

| Setting | What it does |
| --- | --- |
| Image model | The OpenRouter model used to generate and edit images. The default is `google/gemini-3-pro-image-preview`. |
| Text model | The OpenRouter model the assistant uses to plan edits. The default is `google/gemini-2.5-flash`. |
| Restore Defaults | Sets both models back to the defaults. |

Type the model name exactly as OpenRouter lists it.

## Models

Some tools use models that run on your Mac. Glimmer downloads one only when you click **Download**, here or in the question it asks the first time you use the tool that needs it.

| Model | Used for | Size |
| --- | --- | --- |
| Depth (Depth Anything V2 Small) | Lens Blur and Select Sky, which need to know how far away each part of the photo is | about 50 MB |
| Magic Select (SAM 2.1 Tiny) | The Magic Select tool and Select Sky | about 80 MB |

Each row shows the model's size, who publishes it, and links to its source and its license, and says whether it is downloaded. Click **Download…** to get a model: Glimmer shows what it will fetch and starts only when you click **Download**. Click **Remove** to delete a downloaded model and free the space.

A model that Glimmer 0.3.0 downloaded was not checked. If the files it downloaded are still on the Mac, Glimmer checks them now and the model counts as checked. Otherwise its row says **Unverified (installed by an earlier version)**. It keeps working as before; click **Download Again…** to replace it with a checked copy, or **Remove** to delete it. The models come from Apple's Core ML conversions on Hugging Face, at a fixed version, and Glimmer checks every file's checksum before it installs one.

| Setting | What it does |
| --- | --- |
| Download from | Where Glimmer downloads the models. Leave it empty for Hugging Face. A mirror must serve the same paths as Hugging Face (`<repository>/resolve/<commit>/<file>`). Every file is checked against the same checksums, wherever it comes from. |

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
