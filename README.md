# Glimmer Native

A native macOS (Swift, Metal, SwiftUI) port of [Glimmer](https://github.com/fltman/glimmer), the AI-first, layer-based image editor.

- **Standalone.** AI features call OpenRouter directly with your own API key, stored in the Keychain. No server.
- **On-device where possible.** Cutout, Select Subject, Magic Select, depth and Real-ESRGAN upscaling run locally with Vision and Core ML; Apple Intelligence handles simple assistant requests without a paid call.
- **Requires** macOS 27 and Xcode 27.

Architecture and roadmap: [docs/PLAN.md](docs/PLAN.md) (in Swedish).

## Build and test

```sh
brew install xcodegen          # the .xcodeproj is generated from project.yml
scripts/test.sh                # package tests + app build (build/DerivedData)
open Glimmer.xcodeproj         # after `xcodegen generate`
```

Opt-in suites: `GLIMMER_LIVE_AI=1` (real OpenRouter calls) and `GLIMMER_MODELS_DIR=<dir>` (on-device Core ML models). Golden-image references live in `Packages/GlimmerKit/Tests/GlimmerRenderTests/Golden`; re-record them with `GLIMMER_RECORD_GOLDEN=1`.

`scripts/uitest.sh` runs the UI tests against the real app (new document, paint, undo, save, export). macOS asks once to allow UI automation.

## Release

`scripts/release.sh` archives a Release build, has Xcode export it with the Developer ID certificate (Brattoo AB) and notarize it with the account signed in under Xcode › Settings › Accounts, packs the stapled app into a signed DMG and writes a Sparkle appcast. `--publish` also creates a GitHub release with the DMG and `appcast.xml`.

One-time setup:

1. The first run creates the Sparkle EdDSA signing key in your login keychain and builds its public key into the app. Back the key up (`generate_keys -x <file>`, in `build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin`): updates can't be signed without it.
2. Sparkle reads the feed from `https://github.com/fltman/glimmer-native/releases/latest/download/appcast.xml`. The repository has to be public (or the feed hosted elsewhere, via `SUFeedURL` in `project.yml`) for users to receive updates.

`SKIP_SPARKLE=1 scripts/release.sh` builds without the update key and appcast.

## Shortcuts

Glimmer adds Shortcuts actions that work on files without opening a window: Remove Background (on-device), Apply Glimmer Preset, Apply Glimmer Filter and Export Glimmer Document (PNG, JPEG, HEIC, TIFF or WebP).

## Third-party code

Real-ESRGAN (BSD-3-Clause) and Sparkle (MIT); see `App/Credits.html`, shown in the About panel. `scripts/convert-models/realesrgan.py` rebuilds the bundled model from the official weights.

## Localization

English and Swedish via String Catalogs (`App/Localizable.xcstrings`). Strings shown through runtime values (menu titles from the command registry, tool, filter and adjustment names, undo action names) are catalog entries marked "manual".
