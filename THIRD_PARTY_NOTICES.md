# Third-party notices

Glimmer is released under the MIT license (see `LICENSE`). It uses the following third-party code and models. All of them allow commercial use; none is GPL or non-commercial.

## Bundled in the app

| Component | Version | License | Use |
|---|---|---|---|
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.1 (Swift Package) | MIT | Software updates |
| [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN), model `realesr-general-x4v3` | converted to Core ML by `scripts/convert-models/realesrgan.py` | BSD 3-Clause | On-device upscaling |

The full license texts are in `App/Credits.html`, which the app shows in its About panel.

## Downloaded on first use (not bundled)

Glimmer downloads these models from Hugging Face the first time a feature needs them (the source can be changed in Settings › Models).

| Model | Repository | License | Use |
|---|---|---|---|
| Depth Anything V2 Small (Core ML) | [apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small) | Apache 2.0 | Lens Blur depth map, Select Sky |
| SAM 2.1 Tiny (Core ML) | [apple/coreml-sam2.1-tiny](https://huggingface.co/apple/coreml-sam2.1-tiny) | Apache 2.0 | Magic Select, Select Sky |

Only the Small Depth Anything V2 model is used; the larger variants have a non-commercial license and are not used.

## Written for Glimmer

- The WebP encoder (`GlimmerRender/WebPEncoder.swift`, `VP8Encoder.swift`, `VP8Tables.swift`) is Glimmer's own code, written from the WebP and VP8 specifications (RFC 6386). Its constant tables are the format's standard tables.

## System frameworks

Apple frameworks that ship with macOS (Vision, Core Image, Core ML, Metal, Foundation Models, App Intents and others) are used through their public APIs and are not redistributed.

## Services

OpenRouter (openrouter.ai) is an optional online service the user connects with their own API key. No key or account is bundled with Glimmer.
