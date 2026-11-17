# For the next version's release notes

Collected here as things are merged; moved into `docs/release-notes/<version>.html` when the version is made (docs/RELEASE.md, step 6). Not shipped by itself.

- Photoshop files open with their layers, and a document can be exported as a Photoshop file. (What was verified and what was not: the manual, "Photoshop files".)
- Two new blend modes: Darker Color and Lighter Color.
- **A correction that changes how some existing documents look:** in a document that blends colors in gamma space (Image › Blend Colors in Gamma Space), an adjustment layer with a mask or with opacity below 100 % now mixes the way Photoshop does. Such documents look slightly different than before; documents that blend in linear light, the default, are unchanged.
- Camera RAW files open as a layer that keeps the RAW file: Layer › Develop… develops it again at any time (exposure, white balance, shadows and more), without loss. Which cameras work is decided by macOS.
- Agents: a parameter an operation doesn't have is refused by name instead of being passed over, and the published schemas say so. An agent that sent unknown names gets a 400 where it used to get a 200 that had not done what it asked.
- The glow behind the app's icon breathes slowly (still with Reduce Motion on).
- Agents: a stopped job and a stopped step are spelled `canceled` (they were `cancelled`), as in Flimmer and Jämmer. An agent that waits for `cancelled` must accept both.
- Agents: `allowPaid` alone no longer runs a paid step. Glimmer does not know the price of a paid step in advance, so the call must also carry `allowUnknownPrice: true`; otherwise it is refused with 422 and the reason `unknown_price`.
- In the window, every panel and plan that makes a picture says that the price is not known in advance, and asks once per service before the first one. The Assistant shows the text model's listed price where the service's list states one.
- What an agent is told (errors, the names of undo steps) is English whatever language Glimmer shows.
- English texts are in American spelling throughout (Color, Center, Gray).
