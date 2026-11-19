# Third-party notices

Glimmer is released under the MIT license (see `LICENSE`). It uses the following third-party code and models. All of them allow commercial use; none is GPL or non-commercial.

<!-- requirements:begin (made from Requirement.all in GlimmerAI/Requirements.swift; run scripts/export-agents-guide.sh) -->
## Bundled in the app

| Component | Version | License | Use |
|---|---|---|---|
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.10.1 | [MIT](https://github.com/sparkle-project/Sparkle/blob/2.10.1/LICENSE) | Software updates |
| [Real-ESRGAN realesr-general-x4v3 (Core ML)](https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0) | v0.2.5.0, realesr-general-x4v3.pth (4,885,111 bytes) | [BSD-3-Clause](https://github.com/xinntao/Real-ESRGAN/blob/v0.2.5.0/LICENSE) | On-device upscaling |

## Downloaded by Glimmer when you click Download (not bundled)

Glimmer downloads these at the pinned commit and checks every file's checksum before it uses them.

| Model | Source | License | Use |
|---|---|---|---|
| Depth Anything V2 Small (Core ML) | [apple/coreml-depth-anything-v2-small](https://huggingface.co/apple/coreml-depth-anything-v2-small) at `cfef6f6f2a70783dedc0bfae40cecbc2052285d3` | [Apache-2.0](https://huggingface.co/apple/coreml-depth-anything-v2-small/blob/cfef6f6f2a70783dedc0bfae40cecbc2052285d3/README.md) | Lens Blur depth map, Select Sky |
| SAM 2.1 Tiny (Core ML) | [apple/coreml-sam2.1-tiny](https://huggingface.co/apple/coreml-sam2.1-tiny) at `39ae0a8a83e5e6cd196e804bf7cccc5f8171f306` | [Apache-2.0](https://huggingface.co/apple/coreml-sam2.1-tiny/blob/39ae0a8a83e5e6cd196e804bf7cccc5f8171f306/README.md) | Magic Select, Select Sky |

## Installed by you, if you want it

| Tool | Version | License | Use |
|---|---|---|---|
| [Ollama](https://github.com/ollama/ollama) | 0.6.4 or later (0.40.16 checked) | [MIT](https://github.com/ollama/ollama/blob/v0.40.16/LICENSE) | Text and the Assistant on a local model (optional) |

<!-- requirements:end -->

The full license texts of what is bundled are in `App/Credits.html`, which the app shows in its About panel. Of Depth Anything V2 only the Small model is used; the larger variants have a non-commercial license and are not used. The models' checksums, and how to install each one, are in the agent guide (`site/agents.md`, "What Glimmer may need installed") and in `GET /api/v1/requirements`.

## Written for Glimmer

- The WebP encoder (`GlimmerRender/WebPEncoder.swift`, `VP8Encoder.swift`, `VP8Tables.swift`) is Glimmer's own code, written from the WebP and VP8 specifications (RFC 6386). Its constant tables are the format's standard tables.

## System frameworks

Apple frameworks that ship with macOS (Vision, Core Image, Core ML, Metal, Foundation Models, App Intents and others) are used through their public APIs and are not redistributed.

## Services

OpenRouter (openrouter.ai) is an optional online service the user connects with their own API key. No key or account is bundled with Glimmer.
