# Releasing Glimmer

A checklist for release day, from a full local rehearsal on 2026-11-15 (0.2.0 → 0.3.0). Everything below marked **Anders** needs his accounts or decisions; the rest is scripted.

## What the rehearsal proved

| Check | Result |
|---|---|
| Archive and export, Release configuration | OK, 0.2.0 (build 2) and 0.3.0 (build 3) |
| Signature | Developer ID Application: Brattoo AB (V783A2L763), hardened runtime, `codesign --verify --deep --strict` passes |
| Version numbers | `release.sh 0.3.0` sets MARKETING_VERSION 0.3.0 and raises the build to 3; the built app says 0.3.0 (3) |
| Sparkle key | Read from the login keychain (Sparkle's default item, account `ed25519`) without a prompt; public key starts `68SC/iBt…` |
| Appcast | Valid: version 3, shortVersionString 0.3.0, minimumSystemVersion 27.0, EdDSA signature, enclosure URL and length |
| Real update | An installed 0.2.0 found 0.3.0 (Glimmer › Check for Updates…), downloaded it, verified it, installed it, relaunched, and the relaunched app reported 0.3.0 through its agent API |
| Notarization | App rehearsed 2026-11-15 with `release.sh 0.3.0 --notarize-only` (Anders' approval): Xcode uploaded and notarized the app, `stapler validate` passes, `spctl -a -vvv` says `accepted, source=Notarized Developer ID`. |
| DMG | Rehearsed 2026-11-15 (Anders' approval): notarytool with the `brattoo-notary` profile, status Accepted; `stapler validate` passes and `spctl -a -vvv -t install` says `accepted, source=Notarized Developer ID`. (The first rehearsal, before this step existed, said `rejected, source=Unnotarized Developer ID`.) |

Problems found and fixed: a version bump made `site/agents.md` (which names the version) fail the tests, so every release stopped at the test step (the script now regenerates it); the dry-run signature check failed falsely (fixed); the script would silently create a **new** Sparkle key on a Mac without the old one, which would lock out every existing user (it now stops instead); the appcast had no release notes (now read from `docs/release-notes/<version>.html`).

Still true and harmless: `hdiutil create` prints a deprecation warning on macOS 27 but works.

## Rehearse again (no publishing)

Full rehearsal with notarization (uploads to Apple, publishes nothing; restore the version afterwards):

```sh
scripts/release.sh 0.3.0 --notarize-only
git checkout project.yml site/agents.md site/app.json
```

Without notarization:

```sh
# 1. Build the current version and the next one, signed, not notarized, nothing uploaded.
SKIP_TESTS=1 DOWNLOAD_PREFIX=http://localhost:8765/ scripts/release.sh --dry-run
mv build/release build/rehearsal/old
SKIP_TESTS=1 DOWNLOAD_PREFIX=http://localhost:8765/ scripts/release.sh 0.3.0 --dry-run
git checkout project.yml            # the dry run bumped the version; the real release bumps it again

# 2. Local update test: patches both apps to read http://localhost:8765/appcast.xml,
#    re-signs them, serves a signed appcast and installs the old app.
scripts/rehearse-update.sh build/rehearsal/old/export build/release/export
env -u OPENROUTER_API_KEY open "$HOME/Applications/Glimmer Update Rehearsal/Glimmer.app"   # then Glimmer › Check for Updates…

# 3. Clean up afterwards: quit the test app, stop the server, trash the test install.
kill $(lsof -tiTCP:8765 -sTCP:LISTEN)
```

Take `/tmp/gui-test.lock` before launching the test app (the update relaunches it), and release it afterwards.

## Release day

### Before

1. **Anders:** decide the version (e.g. 0.3.0) and that the repo goes public now. The appcast's download links point to the GitHub release, and **they only work for users when the repository is public**.
2. Clean working tree, everything committed. `scripts/release.sh --publish` refuses otherwise.
3. Tests: `scripts/test.sh` (package tests and app build); UI tests with the GUI lock:
   `xcodebuild test -project Glimmer.xcodeproj -scheme Glimmer -destination 'platform=macOS'`
4. Sparkle key present and the same as before:
   `$(find build/DerivedData/SourcePackages/artifacts -path "*Sparkle/bin" -type d | head -1)/generate_keys -p`
   must print the key starting `68SC/iBt…`. If it prints nothing, import the backup with `generate_keys -f <file>`. **Never** release with a new key.
5. **Anders:** signed in under Xcode › Settings › Accounts with the Brattoo AB team (notarization uses it).
6. Release notes in `docs/release-notes/<version>.html` (0.3.0's are written, brought up to date 2026-11-17 with everything from `NEXT.md`; the version is 0.3.0 by Anders's decision that day), and in Swedish in `docs/release-notes/<version>.sv.html` (written 2026-11-17 on Anders's yes). The appcast links the Swedish page with `xml:lang="sv"`, and Sparkle shows it to someone whose Mac prefers Swedish. Change both when one changes.
7. `glimmer.brattoo.com` ready to serve `https://glimmer.brattoo.com/appcast.xml` (see After). Until it does, the released app finds no updates.
8. **Anders, once:** the series' notarytool profile, so the DMG is notarized too: `xcrun notarytool store-credentials brattoo-notary --apple-id <apple-id> --team-id V783A2L763` (with an app-specific password from account.apple.com). The script stops before building if it's missing (`NOTARY_PROFILE=<name>` picks another).

9. **Decided by Anders 2026-11-16: yes.** The entitlement `com.apple.security.files.bookmarks.app-scope` (in `project.yml`, from which XcodeGen writes `App/Glimmer.entitlements`; `scripts/check-entitlements.sh` reads it from the signed app) goes into the release. What it is for: an image Flimmer or Jämmer hands over to edit stays linked across a restart of Glimmer, and a sandboxed app can only write that file again after a relaunch through a bookmark it kept. What it grants: the right to keep such bookmarks for files the user or a sibling app has already handed to Glimmer; no access to any other file. Without it a restored linked window can't save back and says so. The debug build has it and was verified (`scripts/test-linked-restart.sh`); a signed release build with it has not been rehearsed yet, so **rehearse the update once more before release day** (the entitlements of 0.2.0 and the next version differ).
10. **Known and accepted by Anders 2026-11-16, without legal review:** fal's terms say a customer will not "develop any scripts or software applications that interact with or integrate with the Services unless first authorized in writing by Company" and will not "expose any of the Services APIs directly to any End Users". Anders decided to go on without asking fal. fal is in the register as an image service, hidden until his paid test; nothing calls it yet. A legal check is recommended before release, with the patent points.
11. **Decided by Anders:** every cloud service Glimmer has an adapter for is offered by name (2026-11-17: "låt alla synas", and the "not tried" mark in the list was taken away). Tried with real calls: OpenRouter, and Berget for text (Anders's paid test, 18 of 18). The other services are built from their documentation and have never been called for real; Settings says so under the key field of each, and the manual's table says which. (2026-11-16 the decision had been Berget and Grunden only, the rest hidden.)
12. **Decided by Anders 2026-11-17: Heal Selection is in the release** ("heal på"; `Config/Features.xcconfig`, `GLIMMER_HEAL = YES`). The rules its code keeps to are in `PATENTS.md`.
13. **For the legal check before release (does not wait for it; the coordinator's decision 2026-11-16):** Glimmer reads Photoshop files (PSD, PSB) with its own code, written from Adobe's published "Adobe Photoshop File Formats Specification" (https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/, dated November 2019, read 2026-11-16). The page says "Copyright © 1991-2019 Adobe Systems Incorporated. All rights reserved.", "The information in this document is furnished for informational use only, is subject to change without notice", and in its preface "This document is provided for 3rd parties to read and write the Photoshop native file format." It carries no licence grant or terms of its own beyond those notices. Nothing is copied from it but facts about the format, no other reader's code was used, and "Photoshop", "PSD" and "PSB" are used only to name the format. The whole page has been read: the last third (read word for word 2026-11-16, before the reader was made reachable from the app) holds the format's remaining tables and no statement about licence, terms, permission or restrictions.

### Run

```sh
scripts/release.sh 0.3.0 --publish
```

This runs the tests, bumps the version, archives, exports and notarizes through Xcode (up to 30 minutes), staples and checks the app, builds and signs the DMG, writes `build/release/updates/appcast.xml`, commits the version, tags `v0.3.0`, pushes, and creates the GitHub release with the DMG and the appcast. The last line runs Gatekeeper's check (`spctl --assess`) on the app.

### After

1. **Anders: host the appcast and the release notes.** Copy `build/release/updates/appcast.xml` to `https://glimmer.brattoo.com/appcast.xml` (the app's SUFeedURL), and `Glimmer-<version>.html` and `Glimmer-<version>.sv.html` from the same folder beside it: generate_appcast links the release notes from the feed's own address (`https://glimmer.brattoo.com/Glimmer-0.3.0.html`), so without them the update window shows no notes. It must be HTTPS. Put it in the site's output (the glimmer site in `the-apps/site/dist/glimmer/`) or upload it beside it, and keep the file at that path for every later release.
2. **Anders: DNS and hosting** for `glimmer.brattoo.com` (and the site), with a valid certificate.
3. Check it from outside:
   ```sh
   curl -sI https://glimmer.brattoo.com/appcast.xml | head -1      # 200
   curl -sI https://glimmer.brattoo.com/Glimmer-0.3.0.html | head -1      # 200
   curl -sI https://glimmer.brattoo.com/Glimmer-0.3.0.sv.html | head -1   # 200
   curl -s https://glimmer.brattoo.com/appcast.xml | grep -E "sparkle:version|enclosure"
   curl -sIL "$(curl -s https://glimmer.brattoo.com/appcast.xml | grep -o 'url="[^"]*"' | cut -d'"' -f2)" | grep -E "^HTTP|content-length"
   ```
4. On a Mac that never had Glimmer: download the DMG from the GitHub release, open it, drag Glimmer to Applications, launch. Gatekeeper must open it without a warning.
5. The site: add the download link and the source link (`app.json`), build and deploy it (the-apps-9c).
6. Afterwards, the next release's update test is real: an installed 0.3.0 should find 0.3.1 through glimmer.brattoo.com.

## If something goes wrong

- **Notarization takes longer than 30 minutes:** the script stops; rerun `xcodebuild -exportNotarizedApp -archivePath build/release/Glimmer.xcarchive -exportPath build/release/export` until it succeeds, then rerun the DMG and appcast steps by hand (see the script).
- **"Bad Sparkle public key" or "isn't in this Mac's login keychain":** import the key; don't create a new one.
- **The app finds no update:** check that the appcast is reachable over HTTPS at exactly `https://glimmer.brattoo.com/appcast.xml`, that its `sparkle:version` is higher than the installed build, and that the DMG link works for someone not signed in to GitHub.
- **"The update is improperly signed":** the DMG was signed with another Sparkle key or modified after `generate_appcast` ran; rebuild the appcast from the final DMG.
