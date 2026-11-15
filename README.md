# Glimmer Native

[![Support me on Patreon](https://img.shields.io/badge/Patreon-Support%20my%20work-FF424D?style=flat&logo=patreon&logoColor=white)](https://www.patreon.com/AndersBjarby)

A native macOS (Swift, Metal, SwiftUI) port of [Glimmer](https://github.com/fltman/glimmer), the AI-first, layer-based image editor.

- **Standalone.** AI features call OpenRouter directly with your own API key, stored in the Keychain. No server.
- **On-device where possible.** Cutout, Select Subject, Magic Select, depth and Real-ESRGAN upscaling run locally with Vision and Core ML; Apple Intelligence handles simple assistant requests without a paid call. Auto Enhance and Auto Color (as editable adjustment layers), Auto Straighten, Suggest Crop, Select People, Select Sky, Straighten Document, photo rating in Batch Process and turning the text in a photo into editable text layers come from local image analysis, which also drives the omnibar's suggestions for the open photo.
- **Requires** macOS 27 and Xcode 27.

Architecture and roadmap: [docs/PLAN.md](docs/PLAN.md) (in Swedish).

## Build and test

```sh
brew install xcodegen          # the .xcodeproj is generated from project.yml
scripts/test.sh                # package tests + app build (build/DerivedData)
open Glimmer.xcodeproj         # after `xcodegen generate`
```

**No test spends money.** Start test copies of the app with `env -u OPENROUTER_API_KEY open …` (debug builds read the key from the environment), and never send `"allowPaid": true` to a real provider from a test. `scripts/test.sh` and `scripts/uitest.sh` clear the key for you. `scripts/test-app.sh <command>` starts a test copy without the key under the series' shared GUI lock (`the-apps/tools/with-gui-lock.sh`, exit 75 when it isn't free), runs the command with `GLIMMER_PORT` set, and quits that copy (by its pid) when the command ends.

Opt-in suites: `GLIMMER_LIVE_AI=1` (real OpenRouter calls, the only deliberate exception) and `GLIMMER_MODELS_DIR=<dir>` (on-device Core ML models). Golden-image references live in `Packages/GlimmerKit/Tests/GlimmerRenderTests/Golden`; re-record them with `GLIMMER_RECORD_GOLDEN=1`.

`scripts/uitest.sh` runs the UI tests against the real app (new document, paint, undo, save, export). macOS asks once to allow UI automation. The same tests run on the self-hosted Mac with `gh workflow run "UI tests"`; they take over the mouse and keyboard for about a minute, so they're started by hand.

## CI

`.github/workflows/ci.yml` runs the package tests and builds the app on every push to `main`. The app targets macOS 27, which GitHub's hosted machines don't offer yet, so the job runs on a self-hosted Mac: `scripts/setup-runner.sh` registers this one (`scripts/setup-runner.sh remove` undoes it).

## Release

`scripts/release.sh [<version>] [--publish]` runs the tests, sets the version and raises the build number, archives a Release build, has Xcode export it with the Developer ID certificate (Brattoo AB) and notarize it with the account signed in under Xcode › Settings › Accounts, packs the stapled app into a signed DMG and writes a Sparkle appcast. `--publish` also commits the version, tags it, pushes and creates a GitHub release with the DMG and `appcast.xml`.

One-time setup:

1. The first run creates the Sparkle EdDSA signing key in your login keychain and builds its public key into the app. Back the key up (`generate_keys -x <file>`, in `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin`): updates can't be signed without it.
2. Sparkle reads the feed from `https://github.com/fltman/glimmer-native/releases/latest/download/appcast.xml`. The repository has to be public (or the feed hosted elsewhere, via `SUFeedURL` in `project.yml`) for users to receive updates.

`SKIP_SPARKLE=1 scripts/release.sh` builds without the update key and appcast.

## Shortcuts

Glimmer adds Shortcuts actions that work on files without opening a window: Auto Enhance Image and Remove Background (both on-device), Apply Glimmer Preset, Apply Glimmer Filter, Run Glimmer Action (an action saved from the assistant, for editing many photos the same way) and Export Glimmer Document (PNG, JPEG, HEIC, TIFF or WebP).

In the app, **File › Batch Process…** runs the same recipes (Auto Enhance, Remove Background, a preset or a saved action) over many images or folders and writes the results to a folder you choose.

## Projects from Glimmer for the web

File › Open reads `.aips` projects from the web app, with layers, masks, effects, editable text, paths, guides and the grid. File › Export Web Project (.aips)… writes one. The web app has no fill layers, shapes, smart filters or perspective transforms, so those layers are written as pixels.

## WebP

ImageIO can't write WebP, so Glimmer has its own encoders in `GlimmerRender`: lossless (VP8L) at 100 % quality and lossy (VP8 key frames) below. The constant tables in `VP8Tables.swift` come from the VP8 specification (RFC 6386).

## License

MIT, see `LICENSE`. Third-party code and models, all permissively licensed, are listed in `THIRD_PARTY_NOTICES.md`.

## Third-party code

Real-ESRGAN (BSD-3-Clause) and Sparkle (MIT); see `App/Credits.html`, shown in the About panel. `scripts/convert-models/realesrgan.py` rebuilds the bundled model from the official weights.

## Localization

English and Swedish via String Catalogs (`App/Localizable.xcstrings`). Strings shown through runtime values (menu titles from the command registry, tool, filter and adjustment names, undo action names) are catalog entries marked "manual".
