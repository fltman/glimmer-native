# For the next version's release notes

Collected here as things are merged; moved into `docs/release-notes/<version>.html` when the version is made (docs/RELEASE.md, step 6). Not shipped by itself.

- Photoshop files open with their layers, and a document can be exported as a Photoshop file. (What was verified and what was not: the manual, "Photoshop files".)
- Two new blend modes: Darker Color and Lighter Color.
- **A correction that changes how some existing documents look:** in a document that blends colours in gamma space (Image › Blend Colors in Gamma Space), an adjustment layer with a mask or with opacity below 100 % now mixes the way Photoshop does. Such documents look slightly different than before; documents that blend in linear light, the default, are unchanged.
