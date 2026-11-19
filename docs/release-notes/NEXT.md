# For the next version's release notes

Collected here as things are merged; moved into `docs/release-notes/<version>.html` when the version is made (docs/RELEASE.md, step 6). Not shipped by itself.

(Everything collected up to 2026-11-17 is in `0.3.0.html`.)

## 0.3.1 (collected 2026-11-19)

- **Models are downloaded only when you click Download, and checked.** The first time Select Sky, Magic Select or Lens Blur needs a model, a sheet shows its size, publisher, source and license, and nothing is fetched until you click Download. Settings › Models has a Download… button per model. Glimmer fetches each model at a fixed version and checks every file against the checksum its source publishes; a model whose checksum doesn't match is not installed. (0.3.0 downloaded the models on first use from the latest version, without checking a checksum.) Svenska: Modellerna laddas bara ner när du klickar på Ladda ner, och de kontrolleras. Första gången Markera himmel, Magisk markering eller Linsoskärpa behöver en modell visar ett ark storlek, utgivare, källa och licens. Inställningar › Modeller har en knapp Ladda ner… för varje modell. Glimmer hämtar varje modell i en fast version och kontrollerar varje fil mot källans publicerade kontrollsumma.
- **For agents:** `GET /api/v1/requirements` lists what Glimmer may need installed (source, version, checksums, license, size, how to install), and the guide has a section "What Glimmer may need installed". `POST /api/v1/settings/open` with `{"pane": "models"}` opens a Settings pane for the person. A step that needs a model that isn't downloaded (`select_sky`) is refused before anything runs with `422 model_missing` and `requirement`; the API never starts a download. Svenska: För agenter: `GET /api/v1/requirements` och `POST /api/v1/settings/open`; ett steg som behöver en modell som saknas får `model_missing`, och API:t startar aldrig en nedladdning.
