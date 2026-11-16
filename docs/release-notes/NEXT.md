# For the next version's release notes

Collected here as things are merged; moved into `docs/release-notes/<version>.html` when the version is made (docs/RELEASE.md, step 6). Not shipped by itself.

- Photoshop files open with their layers, and a document can be exported as a Photoshop file. (What was verified and what was not: the manual, "Photoshop files".)
- Two new blend modes: Darker Color and Lighter Color.
- **A correction that changes how some existing documents look:** in a document that blends colours in gamma space (Image › Blend Colors in Gamma Space), an adjustment layer with a mask or with opacity below 100 % now mixes the way Photoshop does. Such documents look slightly different than before; documents that blend in linear light, the default, are unchanged.
- Camera RAW files open as a layer that keeps the RAW file: Layer › Develop… develops it again at any time (exposure, white balance, shadows and more), without loss. Which cameras work is decided by macOS.
- Agents: a parameter an operation doesn't have is refused by name instead of being passed over, and the published schemas say so. An agent that sent unknown names gets a 400 where it used to get a 200 that had not done what it asked.
- The glow behind the app's icon breathes slowly (still with Reduce Motion on).
