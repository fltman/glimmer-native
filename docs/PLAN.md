# Glimmer Native — arkitektur och fasplan

> Native macOS-port av [fltman/glimmer](https://github.com/fltman/glimmer) (React + WebGL2 + Fastify + Python-workers).
> Status: **godkänd 2026-11-13**. Öppna frågor besvarade (§7).
> Underlag: genomläsning av webbrepot @ `5ca9e64` (motor, AI-lager, UI). Referenser till webbkoden skrivs `web/src/...:rad`.

## 0. Fastslagna beslut

| Beslut | Val |
|---|---|
| AI-backend | **Standalone.** Appen anropar OpenRouter direkt med användarens egen nyckel (Keychain). Ingen server, inga konton, inga credits. |
| Lägsta OS | **macOS 27**. Swift 6.4 med strict concurrency, Xcode 27. |
| Distribution | **Developer ID + notarisering**, DMG, automatiska uppdateringar. |
| Arbetsordning | Planen först, sedan kärneditorn (fas 0–2), sedan **AI direkt efter lagerträdet**. |
| Layout | **En adaptiv layout.** Omni och Classic slås ihop (§2.6). |
| Blend-färgrymd | **Linjärt ljus som default**, med gamma som dokumentval. |
| Identitet | Appen heter `Glimmer`, bundle-ID `com.brattoo.glimmer`, Developer ID-team **Brattoo AB (V783A2L763)**. |
| Repo | Git, pushat till GitHub `fltman/glimmer-native` (privat tills vidare). |

## 1. Vad webbversionen är, och vad vi *inte* ska kopiera

Webbversionen har ~61k rader, och nästan allt bor i en 9,5k-raders `EditorEngine.ts`. Funktionsytan är stor: 18 blend modes, 14 justeringslager, 14 filter, layer styles, smart objects, masker, clipping, grupper, penna/paths, text med warp och text på path, brush med dynamik, clone/heal/dodge/burn/smudge, liquify, lens blur samt 12 AI-verktyg och en chattassistent.

Kartläggningen visade att flera grundval i motorn är workarounds för WebGL/ANGLE eller ofärdiga faser. **De ska inte porteras rakt av:**

| Webbversionen gör | Native gör i stället |
|---|---|
| Compositar i **viewport-space**. Varje bildruta ritar varje lager över hela skärmen, så resultatet beror på zoomnivån och aliasar vid utzoomning (inga mipmaps). | Compositar i **dokument-space** på tiles, cachar per lager och grupp, och har en mip-pyramid. Presentation sker i ett separat pass. |
| En textur per lager, trots att README säger "tiles är enheten för allt" (tiling kom aldrig). | **256×256-tiles** för allt: rendering, minne, undo, AI-regioner. |
| 8-bitars sRGB-lager. RGBA8-intermediärer vid transform-bake och export, och 8-bitars LUT:ar, vilket ger banding i skuggor. | Lager i **RGBA16Float, linjärt och premultiplicerat**. Hela kedjan är 16F, och LUT:ar är float. |
| Undo sparar **hela lagrets ImageData** vid varje penseldrag. | **Copy-on-write-tiles.** Undo behåller bara de tiles som ändrats och kan spilla till disk. |
| Allokerar gruppbuffertar och effekt-intermediärer per frame, saknar dirty rects och gör en fullskärms-blit per lager. | Dirty-tile-spårning och cachade lager- och gruppresultat. Bara synliga och ändrade tiles renderas. |
| Retusch kör ett helt lagerpass per dab. Selektionens bounds kräver full readback vid varje ändring. | Dabs påverkar bara berörda tiles, och bounds hålls inkrementellt. |
| Gaussian, morfologi, stroke och effekt-blur är begränsade till 32 px. | MPS (`MPSImageGaussianBlur`, `MPSImageAreaMax/Min`) och avståndstransform, utan tak. |
| Text, lasso, paths, mönster och former går via Canvas2D. | Core Text och Core Graphics, eller GPU-rasterisering. |
| Ingen färghantering: allt tvingas till sRGB och ICC ignoreras. | ICC-medveten import och export, wide gamut (P3) och EDR-presentation. |

**Semantiska buggar att rätta i stället för att kopiera** (alla verifierade i koden):

- Justeringslagrets blend mode ignoreras. Color Overlay ignorerar också sin blend mode.
- Effekter ignorerar lagermasken, och placeras fel på roterade smart objects.
- Clipping-kedjor klipper mot föregående klippta lager i stället för kedjans bas. Basens mask ignoreras.
- Crop flyttar och beskär inte lager inuti grupper.
- Liquify adderar förskjutningar i stället för att komponera dem, så resultatet driver vid tungt bruk.
- Curves är styckvis linjär, inte en spline. Levels saknar per-kanal-läge.
- Paint bucket saknar flood fill.
- Cropens aspect-presets är inte kopplade.
- Osparat arbete försvinner utan varning, och det finns ingen autosave.
- AI: inpaint och cleanup skickar en tight ROI utan kontextpadding. Whole-image edit skalas inte tillbaka till dokumentstorleken. Upscale-tiles klistras med hårda kanter.

## 2. Övergripande arkitektur

```
┌────────────────────────── Glimmer.app (SwiftUI + AppKit) ───────────────────────────┐
│  DocumentGroup · menyrad · inspektor · omnibar/⌘K · verktygspalett · inställningar  │
│                                      │                                              │
│                         CanvasView (NSView + CAMetalLayer)                          │
│              input: mus, trackpad-gester, ritplatta (tryck/lutning)                 │
└───────────────┬───────────────────────────────┬──────────────────────────┬──────────┘
                │                               │                          │
       ┌────────▼────────┐            ┌─────────▼─────────┐       ┌────────▼────────┐
       │  GlimmerTools   │            │   GlimmerRender   │       │    GlimmerAI    │
       │ brush, retusch, │───────────▶│ Metal-compositor, │◀──────│ OpenRouter,     │
       │ selektion, pen, │            │ tiles, pyramid,   │       │ pipelines,      │
       │ text, transform │            │ blend, adj, fx,   │       │ Vision, Core ML,│
       │ liquify         │            │ filter (CI/MPS)   │       │ agent           │
       └────────┬────────┘            └─────────┬─────────┘       └────────┬────────┘
                └───────────────────────────────┼──────────────────────────┘
                                      ┌─────────▼─────────┐
                                      │    GlimmerCore    │
                                      │ dokumentmodell,   │
                                      │ tile store/COW,   │
                                      │ kommandon/undo,   │
                                      │ .glimmer-format,  │
                                      │ .aips-import      │
                                      └───────────────────┘
```

### 2.1 Projektstruktur

```
glimmer-native/
  project.yml                 # XcodeGen. .xcodeproj genereras och checkas inte in
  App/                        # app-target: SwiftUI-scener, vyer, menyer, inställningar
  Packages/GlimmerKit/       # ett lokalt paket med fyra targets:
    Sources/GlimmerCore/      #   ren Swift, ingen Metal. Modell, tiles, undo, format
    Sources/GlimmerRender/    #   Metal + MSL-shaders + Core Image/MPS
    Sources/GlimmerTools/     #   interaktiva verktyg (beror på Core + Render)
    Sources/GlimmerAI/        #   OpenRouter-klient, pipelines, on-device-modeller
    Tests/                    #   Swift Testing per target, golden images för render
  docs/
  scripts/                    # notarize.sh, make-dmg.sh, convert-models/ (coremltools)
```

- **XcodeGen** finns redan installerat. Det håller projektfilen diffbar och undviker merge-konflikter.
- Modulerna är fyra targets i **ett lokalt Swift Package** (`GlimmerKit`). Det ger tydliga beroendegränser och snabba unit-tester. `GlimmerCore` använder Metal för pixellagring (se fas 1-besluten).
- **Swift Testing** används för alla nya tester.

### 2.2 Dokumentmodell (`GlimmerCore`)

- **Lagerträd.** `Document` håller ett träd av `LayerNode`. `enum LayerContent` har fallen `.raster`, `.adjustment`, `.text`, `.group`, `.smart` och `.fill` (solid, gradient eller pattern). `.fill` är nytt och ersätter webbens bakade bucket- och gradient-lager.
- **Gemensamt för alla lager:** id (UUID), namn, synlighet, opacity, fill opacity, blend mode, mask, clipping och effekter.
- **Blend modes.** Webbens 18 behålls, plus **pass-through** för grupper. Fler (vivid light, linear light, pin light, hard mix, subtract, divide) kan läggas till billigt senare.
- **Rasterdata** ligger i en `TileStore`: gles mappning från tile-koordinat till `Tile`, där en tile är ett referensräknat 256×256-block i RGBA16F. Tomma tiles lagras inte. Lager kan ligga utanför canvasen.
- **Masker** ligger också i en `TileStore`, i R16Unorm. De har density och feather (icke-destruktivt), och kan vara vektormasker senare.
- **Justeringsparametrar** är typade Swift-structs (`enum Adjustment { case curves(Curves) ... }`), inte en lös dictionary. Avkodningen är tolerant så att `.aips` med saknade eller okända fält fungerar.
- **Färger** lagras som linjärt **extended sRGB** (Float16). Det täcker P3 och mer. Varje dokument har en arbetsfärgrymd (default sRGB, P3 som alternativ).
- **Modellen är värdetypad** där det går, så snapshots för undo blir billiga: trädet är structs och pixeldatan delade COW-tiles. Det `@Observable` objekt som UI:t binder mot är en tunn fasad ovanpå.

### 2.3 Undo och kommandon

- Varje redigering är ett `EditCommand` som registreras i dokumentets `UndoManager`. Då fungerar ⌘Z, menyn "Undo Brush Stroke", dirty-markering och autosave via `DocumentGroup` automatiskt.
- **Pixelredigering:** kommandot behåller de *gamla* tile-referenserna för de tiles som rördes. Eftersom tiles är COW kostar det bara de ändrade blocken.
- Historiken har en minnesbudget (default 2 GB) och spiller äldre steg till en temporär fil innan de släpps.
- Undo-gruppering används för slider-drag (en drag blir ett steg) och för agentkörningar (en plan blir ett steg).
- History-panelen läser kommandostacken och kan hoppa till godtyckligt steg.

### 2.4 Rendering (`GlimmerRender`)

- **Compositor** i dokument-space, per tile:
  - Varje lager har en cache av sitt *effektiva* innehåll, där mask, effekter och smart-transform redan är applicerade.
  - Varje grupp har en cache av sitt isolerade resultat.
  - Ändringar markerar dirty tiles som propagerar uppåt i trädet.
  - Blend modes skrivs i **egna Metal-kernels** med W3C-formlerna, så beteendet blir exakt. Eftersom Metal stöder programmable blending och läser backdropen direkt försvinner webbens ping-pong mellan accumulators.
- **Blend-färgrymd.** Webben blandar i linjärt ljus, vilket inte matchar Photoshop som blandar i gamma. Default är **linjärt** (beslutat), så att `.aips`-filer ser likadana ut. Ett dokumentval "Blanda i gamma (Photoshop-kompatibelt)" läggs till i fas 2.
- **Pyramid.** För varje sammanslagen tile hålls mipnivåer, och vid utzoomning hämtas rätt nivå. Det ger ingen aliasing, och panorering på 8k-dokument är bara en textur-lookup.
- **Presentation:**
  - Ett `CAMetalLayer` med `extendedLinearDisplayP3` och EDR, så att P3 och HDR visas rätt.
  - Checkerboard och dither i presentationspasset.
  - Vyns transform (zoom, pan, rotation) gäller *bara* här.
- **Justeringar.** Alla 14 porteras som Metal-kernels. GLSL-funktionerna `adjust()` i `web/src/engine/adjustments.ts` översätts nästan rad för rad, med float-LUT:ar. Curves blir monoton kubisk spline, och Levels får per-kanal-läge.
- **Filter.** Där de räcker används Core Image och MPS (gaussian, motion, unsharp, noise, pixelate, edges, vignette, halftone, clarity). Egna kernels behövs för oil paint (Kuwahara), lens blur och chromatic aberration.
- **Smart filters.** Filterstacken lagras på lagret och appliceras i lagercachen. Webben marknadsför smart filters men bakar dem i själva verket. *Fas 5, tillval.*
- **Layer styles** (drop shadow, inner shadow, stroke, outer glow, color overlay) beräknas från lagrets effektiva alfa, alltså efter masken. Blur går via MPS, stroke via avståndstransform. Resultatet cachas tills lagret ändras.
- **Texturminne.** En LRU-pool av MTLTextures för tiles. CPU-sidan (`TileStore`) är sanningen, och GPU-texturer laddas upp lazy.

### 2.5 Canvas och input (App + `GlimmerTools`)

- `CanvasView: NSView` har ett `CAMetalLayer` och är inbäddad i SwiftUI via `NSViewRepresentable`. Overlays (marching ants, transform-handtag, crop-guider, pen-handtag, linjaler, guider, grid) ritas i Metal eller i ett CALayer-lager ovanpå, inte i SVG.
- **Gester.** Webben saknar dessa helt:
  - Scroll panorerar och pinch zoomar runt markören.
  - Rotationsgesten roterar vyn och snäpper vid 0°.
  - ⌥-scroll zoomar och mellanknappen panorerar.
- **Ritplatta.** `NSEvent.pressure`, tilt, rotation och tangentialt tryck läses, och tablet-events används för hög samplingstakt. Brushmotorn tar emot tid, position, tryck och tilt.
- **Verktygsprotokoll.** Varje verktyg implementerar `protocol Tool { func begin/drag/end/hover/key, overlay, options }`. En `ToolSession` hanterar modala lägen (liquify, transform, crop, pen, Magic Select) med ⏎ och Esc.
- **Textredigering** görs i en riktig `NSTextView` placerad över lagret. Den ger IME, stavning, typsnittspanel och tracking.

### 2.6 UI (SwiftUI, macOS 27)

**Beslutat:** webbens två layouter, Omni och Classic, slås ihop till **en adaptiv layout**. På Mac finns menyraden alltid, och den ersätter Classic-lägets menyer gratis.

- **Fönster:** canvas i full bredd plus en flytande **omnibar** i glass längst ner. Den kombinerar AI-prompt och ⌘K-kommandopalett, precis som i webben.
- **Verktygspalett** till vänster och **inspektor** (`.inspector`) till höger. Inspektorn har flikarna Lager, Justering, Assistent, Historik, Paths, Färgrutor och Kanaler. Båda kan döljas, och **Tab** döljer all chrome.
- **Verktygsalternativ** visas i fönstrets toolbar. Det motsvarar webbens options-strip.
- **Menyrad:** Arkiv, Redigera, Bild, Lager, Markering, Filter, AI, Visa, Fönster, Hjälp. Allt i menyraden går också att nå via ⌘K.
- **Dokumenthantering:** flikar och fönster kommer från `DocumentGroup` och systemets fönsterflikar. Osparat-varningar, autosave, versioner och "Revert To" följer med automatiskt.
- **Ett kommandoregister** (`CommandRegistry`) driver menyrad, ⌘K, omnibar, kortkommandon, agentens operationer och App Intents (Genvägar). Då blir webbens buggar med felaktiga kortkommandotips och kommandon som bara finns i ena layouten omöjliga.
- **Övrigt:**
  - Lager-panelen får miniatyrer, drag-och-släpp-omordning, multival och namnbyte, som webben saknar.
  - Webbens Navigator ersätts av en minikarta i hörnet.
  - Färgväljaren använder `NSColorPanel` plus webbens HSV-kvadrat för snabbval.
  - Inställningsfönstret har flikarna AI (nyckel, modeller, kostnadsvisning), Prestanda (minnesbudget, GPU) och Ritplatta.

### 2.7 Filformat

- **`.glimmer`** är ett dokumentpaket (en katalog som visas som fil):
  ```
  Bild.glimmer/
    manifest.json        # version, storlek, färgrymd, lagerträd, paths, guider, grid
    layers/<uuid>/tiles.bin   # tiles: Float16 RGBA, LZFSE-komprimerade, med index
    layers/<uuid>/mask.bin
    smart/<uuid>.png|tiff     # smart objects originalkälla
    thumbnail.png        # QuickLook/Finder
  ```
  Paketet skrivs inkrementellt med `FileWrapper`, så att bara ändrade lager skrivs om. Formatet versioneras från dag ett, och läsaren kontrollerar versionen.
- **`.aips`-import** (webbens format): en JSON-fil med `magic: "aips"`, en nodlista och PNG-pixlar i base64 (`web/src/engine/serialize.ts`). Formatet är enkelt att läsa, och importern översätter CSS-fontfamiljer till systemets typsnitt.
- **Export:**
  - PNG (8/16-bit), JPEG, HEIC, WebP och TIFF (8/16/32-bit), med inbäddad ICC och matte för format utan alfa.
  - Exporten går via ImageIO från en 16F-composite och kvantiseras inte till 8-bit innan den är klar.
- **Import:** allt ImageIO kan läsa, inklusive RAW (via Core Image RAW-filter, basläge), HEIC och PSD (bara den platta bilden). Riktig PSD-import och -export med lager är en möjlig senare fas.
- **QuickLook-tillägg** för `.glimmer`-miniatyrer. *Fas 9.*

### 2.8 AI (`GlimmerAI`)

**Transport (`OpenRouterClient`):**

- Ett `actor` över URLSession som stöder `chat/completions` med `modalities: ["image","text"]`. Bilder skickas och tas emot som base64-PNG-data-URL:er.
- Svar tolkas i alla tre format som webbens worker hanterar (`workers/aips/providers/openrouter.py:307`).
- **Retry och backoff:** exponentiell backoff, `Retry-After` respekteras, och en circuit breaker används. Webbens policy porteras, med två ändringar:
  - **401 (fel nyckel) och 402 (slut på kredit) är fatala** och visas direkt för användaren. Webben försöker igen på dem.
  - `usage: {include: true}` skickas, så att kostnaden per operation kan visas i UI:t.
- **Diskcache** för råsvar, nycklad på sha256 av (förmåga, modell, bilder, instruktion, seed). En retry eller ett ångra-och-gör-om betalar inte två gånger.
- **Modell-ID:n** är inställningar. Defaults: `google/gemini-3-pro-image-preview` för bild och `google/gemini-2.5-flash` för text.
- **API-nyckeln** ligger i Keychain och kan valideras med ett testanrop.

**Bildprimitiver** (från `workers/aips/pipelines/imaging.py`, som bara använder Pillow och numpy, alltså ingen OpenCV att ersätta):

| Primitiv | Swift |
|---|---|
| `resize_to` (Lanczos) | `CILanczosScaleTransform` / vImage |
| `feather_mask(erode, blur)` | `CIMorphologyMinimum` + `CIGaussianBlur` |
| `color_match` (viktad minsta-kvadrat, gain/offset per kanal) | vDSP |
| `blend_masked` | `CIBlendWithMask` |
| `lab_color_transfer` (Reinhard) | egen Metal-kernel eller vDSP |
| `clamp_roi` (+30 % padding) | ren Swift |

**Förmågor:**

| Förmåga | Källa | Native-implementation |
|---|---|---|
| Generate | OpenRouter-bild | Som webben, plus storleksval och en eller flera varianter. |
| Edit (hela bilden) | OpenRouter-bild | **Fix:** skala tillbaka till dokumentstorleken och färgmatcha. |
| Inpaint / fill / remove / referens | OpenRouter-bild | Pipeline: crop + **padding (fix)** → dual-signal → re-align → färgmatch → mjuk inblandning. Prompterna porteras ordagrant. |
| Content-Aware Fill | = inpaint remove | Samma pipeline. |
| Expand / outpaint | OpenRouter-bild | Som webben: grå canvas, sömmask, färgmatch, original-inset ovanpå. |
| Relight | OpenRouter-bild | Frastabeller porterade. |
| Reflections | OpenRouter-bild | Som webben. |
| Harmonize | OpenRouter-bild | Som webben. |
| Cleanup / distractions | OpenRouter-text (multimodal) | Bounding boxes → selektioner → inpaint remove **med padding (fix)**. |
| Color Match | **Lokalt** | Lab-transfer, ingen modell. |
| Cutout / Select Subject | **Vision**, on-device | `VNGenerateForegroundInstanceMaskRequest`, gratis och offline. Ersätter RMBG-1.4. |
| Magic Select (klicka på objekt) | **Core ML**, on-device | SlimSAM eller EfficientSAM konverterad med coremltools, delad i encoder och decoder. Tills den finns: Vision-instansen under klicket. |
| Depth / Lens Blur | **Core ML**, on-device | Depth Anything V2 Small (Apple publicerar en Core ML-version). |
| Upscale | Lokalt + OpenRouter | Core ML Real-ESRGAN (konverterad) eller Lanczos, plus valfri Gemini-"enhance"-pass i tiles med **mjuka skarvar (fix)**. fal och Replicate tas bort. |
| Presets | Lokalt | Tio planer (`presetDefs.ts`) som körs av agent-executorn. |

**Assistent och agent:**

- Webben gör ett enda JSON-anrop utan historik, med operationerna beskrivna som text i systemprompten.
- Native använder **riktig tool calling** via OpenRouter: varje agentoperation blir ett tool-schema som genereras från `CommandRegistry`. Konversationshistoriken behålls i dokumentets assistentpanel.
- Planen visas innan den körs. Auto-edit kan slås på för att köra direkt. Hela planen är *ett* undo-steg.
- Operationerna är samma som webbens `AGENT_OPS` (`add_adjustment`, `apply_filter`, `add_layer_effect`, `image_edit_composite`, `generate_layer`, `remove_background`, `inpaint_selection`, `fill`, `select_all`, `deselect`, `invert_selection`, `set_foreground`). Fler kan läggas till via registret.
- **Tillval:** Apples on-device Foundation Models kan användas för gratis och snabb routning av omnibar-text (kommando, generera eller redigera) innan något betalt anrop görs.

**Utan nyckel** fungerar allt som inte är generativt: hela editorn, Cutout, Select Subject, Magic Select, Lens Blur, Color Match och Presets. AI-funktionerna visar då en tydlig "lägg in OpenRouter-nyckel"-vy.

### 2.9 Concurrency

- UI-modellen är `@MainActor`.
- Rendering och tile-arbete körs i ett `RenderActor` med egen `MTLCommandQueue`. Canvasen ritas på displayens vsync (`CADisplayLink` för NSView).
- AI-jobb är `Task` med progress-ström och avbryts med Esc. Resultatet blir alltid ett nytt lager.
- Tunga CPU-jobb (flood fill, färgmatchning, kodning) körs i `Task.detached` med prioritet.

### 2.10 Distribution och säkerhet

- Hardened Runtime och Developer ID, notarisering via Xcodes inloggade konto, DMG via script. Automatiska uppdateringar via **Sparkle 2**.
- **App Sandbox slås på från start** trots att den inte krävs för direktdistribution. Med `DocumentGroup` kostar den nästan inget, och den håller dörren öppen till Mac App Store. Entitlements: `network.client` och användarvalda filer.
- API-nyckeln skickas bara till `openrouter.ai`. Inga egna referer- eller user-agent-uppgifter som identifierar användaren.

## 3. Fasplan

Storlek är relativ: **S** < **M** < **L** < **XL**. Varje fas avslutas med en körbar app och gröna tester.

### Fas 0 — Grund · S ✅ (2026-11-13)
- XcodeGen-projekt, fyra lokala paket, app-target och testtargets. Ett script bygger och testar via `xcodebuild`.
- `DocumentGroup` med en tom `.glimmer`-typ (UTType-deklaration) och ett inställningsfönster med Keychain-lagrad nyckel.
- Metal-pipeline: `CanvasView` visar en textur med zoom, pan och rotation, inklusive trackpad-gester.
- `CommandRegistry` med Undo och Redo som första kommandon, kopplade till menyn.
- **Klart när:** appen öppnar ett tomt dokument, zoom och pan känns native, och testerna körs i CI-scriptet.

### Fas 1 — Vertikal slice: rasterlager · L ✅ (2026-11-13)
- Öppna bild via ImageIO och ICC till linjär 16F, med drag-och-släpp och klistra in.
- `TileStore` med COW-tiles. Compositor med de 18 blend modes, opacity och synlighet. Mip-pyramid.
- Lagerpanel: lägg till, ta bort, duplicera, flytta, döp om, miniatyrer, blend och opacity.
- Undo och redo med tile-snapshots. Spara och öppna `.glimmer`, autosave.
- Export till PNG, JPEG, HEIC och TIFF med 16-bit och ICC.
- Move-verktyget (flytta lager).
- **Tester:** golden-image-tester för varje blend mode, mot analytiska förväntade värden från W3C-formlerna. Rundtur spara→öppna→bit-exakt. Prestandabudget: 8k×8k med 20 lager panoreras i 120 fps på M5.

### Fas 2 — Komplett lagerträd · L ✅ (2026-11-13)
- Grupper (isolerade och pass-through), masker (måla, slå av/på, density, feather) och clipping med korrekt kedjesemantik.
- De 14 justeringslagren med inspektorer. Curves med spline, Levels per kanal och histogram, Gradient Map-editor.
- Layer styles med live-preview.
- Smart objects: konvertera, transform utan förlust, rasterisera.
- Fill-lager (solid, gradient, pattern).
- `.aips`-import.
- Dokumentval för blandning i linjärt ljus eller gamma.

### Fas 3 — AI, grund · L ✅ (2026-11-13)
- **Grundselektion** (krävs för inpaint): rektangel- och ellipsmarkering, selektionsmask som tile-store, marching ants, invert. Add, subtract och intersect via modifierare.
- `OpenRouterClient` med retry, cache, kostnadsvisning och nyckelhantering.
- Bildprimitiverna från §2.8, med enhetstester mot referensvärden från Python-koden.
- Generate, Edit (hela bilden), Inpaint/fill/remove/referens, Content-Aware Fill och Expand.
- Cutout och Select Subject via Vision. Color Match.
- En AI-jobbkö i UI:t med progress, avbryt och resultat som lager.
- En enkel assistentpanel: fri text routas till Generate eller Edit. Agenten med tool calling kommer i fas 8.

### Fas 4 — AI, avancerat · L ✅ (2026-11-13)
- Relight, Reflections, Harmonize, Upscale (Core ML plus enhance) och Cleanup/distractions.
- Magic Select via Core ML SAM, med konverteringsscript i `scripts/convert-models/`.
- AI Lens Blur med Depth Anything V2.
- Presets. De kräver justeringar (fas 2) och filter; filtren som används byggs här och resten i fas 7.

### Fas 5 — Selektion och målning · XL ✅ (2026-11-13)
- Lasso, polygonlasso och trollstav med **riktig flood fill** (contiguous och global, sampla alla lager).
- Feather, grow och shrink utan 32 px-tak.
- Brushmotor: dabs med spacing, hardness, flow, roundness, angle, scatter, jitter och textur. Tryck och tilt från ritplatta. Brush-presets (webbens sex plus egna).
- Eraser, målning på mask, paint bucket (flood fill) och gradientverktyg (linear, radial och fler) med stop-editor.
- Pipett, pattern stamp, färgväljare, X/D och färgrutor.
- Kopiera, klipp ut och klistra in med selektion, ⌘J och ⌫.
- **Prestandabudget:** penseldrag med under en frames latens på 8k-lager.

### Fas 6 — Transform, crop, text, paths, former · L ✅
- Free transform (skala, rotera, numeriska fält; skew och perspektiv som tillval) och crop med fungerande aspect-presets, rotate-crop och korrekt hantering av grupper.
- Textlager via Core Text: alla vikter, tracking, kerning, radavstånd, fri text och textruta, warp och text på path. Redigering i `NSTextView`.
- Pennverktyg med **redigerbara** ankarpunkter (webben kan inte redigera efter commit) och Paths-panel: selektion, fyll, stroke.
- Former (rektangel, ellips, linje, rundad rektangel), först som rasterlager och senare som vektorformlager.
- Linjaler, guider, grid och snapping.

### Fas 7 — Retusch och filter · L ✅
- Clone, heal, dodge, burn, smudge, blur och sharpen, alla tile-lokala.
- De 14 filtren med dialog och live-preview på den synliga regionen. Filtren **respekterar selektionen**, vilket webben inte gör.
- Liquify med korrekt komponerade deformationsfält.
- Smart filters (tillval).
- Kanaler-panelen.

### Fas 8 — Omnibar, ⌘K och assistent · M ✅
- Omnibar och kommandopalett med fuzzy-sök över registret, och routning mellan kommando och assistent.
- Agent med tool calling, historik, förhandsvisning av planen och auto-edit.
- App Intents: "Ta bort bakgrund", "Exportera" och liknande i Genvägar.

### Fas 9 — Polish och release · M ✅
- Historik-panelen, navigator och minikarta, inställningar.
- Prestandapass med xctrace. Minnesbudgetar och avlastning.
- Tillgänglighet (VoiceOver på paneler, Dynamic Type där det är relevant). Lokalisering till svenska och engelska via String Catalogs.
- QuickLook-tillägg, Sparkle, notarisering, DMG, ikon och onboarding.

**Kritisk väg:** 0 → 1 → 2 → 3 (AI). AI ligger direkt efter lagerträdet för att få wow-effekten tidigt. Fas 5–7 kan delvis köras parallellt efter fas 4.

### Beslut och lärdomar under bygget

- **Tiles är delade Metal-texturer** (`.shared`, unified memory) med en unik id per tile. Därför importerar `GlimmerCore` Metal; en ren CPU-modell hade krävt dubbla kopior. Enfärgade tiles lagras som en färg.
- **Dirty tracking sker via signaturer.** Varje dokument-tile får en hash av de bidragande lagrens tile-id:n och parametrar, så explicit invalidering behövs inte.
- **Bilder öppnas aldrig som dokument.** En öppnad JPEG skrevs över av autosave med ett `.glimmer`-paket. Nu blir bilder nya, namnlösa dokument (`DocumentOpener`); `GlimmerDocument` läser bara `.glimmer`.
- **`makeDocument` anropas även när en fil öppnas** och kan inte skilja det från "ny" på macOS. Därför blockerar den aldrig; dialogen New Document köar ett tillstånd som `makeDocument` hämtar.
- **Mätt prestanda (M5):** 8k × 8k × 20 lager compositas på 0,15 s, och en omkontroll utan ändringar tar 8 ms.
- **Fas 2:** compositorn renderar trädet rekursivt per tile (isolerade grupper i eget pass, pass-through via backup och mix) med programmable blending. Clipping klipper mot kedjans bas. Masker ligger i dokumentkoordinater och följer med lagret. Effekter, smart objects och fjädrade masker behöver grannpixlar, så de renderas per lager över en sammanfogad region (MPS-blur och avståndstransform) och cachas.
- **Justeringar** använder en schema-plus-parameter-modell (`Adjustment`) i stället för typade structs per typ. Samma schema driver UI, shader-packning och `.aips`-import, och kommer att driva agentens verktyg.
- **Nya dokument skapas via SwiftUI:s `newDocument(_:)`** med en färdig instans. Kön genom `makeDocument` kolliderade med fönsteråterställning vid kallstart.
- **Kvar från fas 2:** histogram i Levels-editorn, transform-UI för smart objects (fas 6) och maskmålning (fas 5).
- **Fas 3:** pipelinerna (generate, edit, inpaint/fill/remove/referens, expand) är porterade med webbens prompter ordagrant och med fixarna: 30 % kontextpadding, omskalning efter whole-image edit och nedskalning av indata till max 2048 px. Resultat blir nya lager vars alfa är den fjädrade masken. Remove Background lägger en lagermask via Vision. Ett live-test mot OpenRouter (`GLIMMER_LIVE_AI=1`) verifierar transport och tolkning av svaren.
- **Whole-image edit färgmatchas inte.** Det skulle motverka avsiktliga färgändringar ("gör himlen till solnedgång").
- **Marching ants:** kanten hittas genom grannsampling med uv-derivator. `fwidth` på det samplade värdet missar kanter mellan 2×2-pixelblock.
- **Fas 4:** on-device-modellerna är Apples egna Core ML-konverteringar på Hugging Face (`apple/coreml-sam2.1-tiny` och `apple/coreml-depth-anything-v2-small`). De laddas ner vid första användningen till Application Support, kompileras och kan tas bort under Inställningar › Models. Egen konvertering med coremltools behövdes inte. Upscale öppnar ett nytt dokument (Lanczos i 16-bit via MPS eller, sedan kompletteringen, Real-ESRGAN på datorn; valfri AI-detaljpass i tiles med mjuka skarvar). Presets blir en grupp av justeringslager; deras filtersteg väntar på fas 7.
- **Fas 5:** penseln stämplar dabs instansierat i "våta" täckningstexturer per tile, där flow bygger upp inom ett drag. Efter varje händelse räknas bara berörda tiles om från originalet, med opacitet som tak, markering och maskmål. Samma apply-pass driver sudd, maskmålning, färgburk, Clear, Copy och New Layer via Copy. Gradientverktyget skapar ett gradient-fill-lager (icke-destruktivt), maskat av markeringen. Pattern stamp och färgrutepanelen är inte gjorda; de kommer i fas 9.
- **Fas 6:** Free transform (⌘T) arbetar på en box (position, skala, rotation runt centrum). Rasterlager förhandsvisas genom att källan renderas med `SmartObjectRenderer` till overrides; smarta objekt får sin transform skriven direkt. Commit, Esc och ett enda undo-steg. Crop flyttar alla lager, paths och guider men behåller pixlar utanför (icke-destruktivt). Den roterade crop-varianten är inte gjord. Textlager renderas med Core Text i compositorn och redigeras i en `NSTextView` ovanpå canvasen, med lagrets pixlar dolda under redigering. Paths lagras i dokumentet och har en Paths-flik (fyll, stroke med penseln, till selektion); ankare och handtag går att dra efter commit. Former blir färgfyllnadslager med formen som mask, så de går att färga om. Linjaler, guider (dras ut från linjalerna och tas bort genom att dras tillbaka), grid och snap sparas i dokumentet. **Lärdom:** AppKit sätter `geometryFlipped` på backing-lagret till en flippad vy, så overlay-sublager ska inte flippas manuellt. Det gamla lasso-overlayet var spegelvänt utan att det märktes. Skew och perspektiv, warp, text på path, rundad rektangel och vektorformlager är kvar som tillval.
- **Fas 7:** `FilterEngine` kör webbens 14 filter som Metal-kernels. Lagret sätts ihop till en textur över ändringsområdet plus filtrets räckvidd, beskuret till dokumentet så att kanterna clampas och inte tonar ut. Resultatet blandas tillbaka via markeringen och bara berörda tiles skrivs om. Oskärpefilter körs i linjärt premultiplicerat (MPS Gaussian), "look"-filtren i display-sRGB som webben. Brus och halftone är förankrade i dokumentkoordinater, så förhandsvisning och resultat blir identiska. Filterdialogen är en flytande glaspanel (inte ett modalt ark) så att live-förhandsvisningen syns. Retuschverktygen återanvänder penselmotorn: clone, heal, blur och sharpen målar mot ett förberäknat resultat (förskjutet, heal = klon + lågfrekvensskillnad, Gaussian, unsharp), dodge/burn räknas direkt i apply-shadern och smudge har en egen arbetstextur. Liquify använder ett förskjutningsfält som komponeras semi-Lagrangiskt (D′(p) = D(p−o) − o), så upprepade drag driver inte iväg som additiva fält gör. Kanalpanelen visar R/G/B i grått och kan ladda en kanal som markering. Presetens filtersteg körs nu på det aktiva pixellagret. Smart filters är kvar som tillval.
- **Fas 8:** ⌘K-paletten fuzzy-söker över hela registret plus verktyg och presets. Sammanhängande träffar rankas över utspridda initialer. Text som ser ut som en begäran (flera ord, eller ingen övertygande träff) hamnar överst som "Ask the assistant". Omnibaren är en diskret kapsel längst ner på canvasen som öppnar paletten. Agenten porterar webbens planner: systemprompten genereras ur `AgentPlanner.ops`, så modellen och executorn inte kan glida isär. Den använde först JSON-läge; numera tool calling (se kompletteringen nedan). Påhittade operationer slängs. Förutom webbens operationer finns `apply_preset`, `add_text`, `select_subject`, `upscale`, `feather_selection`, `new_layer` och `run_command` (en vitlista ur registret). Planen visas som en checklista. Planer med bara redigeringssteg körs direkt, medan planer med AI-jobb väntar på Run om inte "Run AI steps without asking" är på. Executorn väntar ut varje AI-jobb innan nästa steg och stannar vid första felet. I DEBUG-byggen körs en rå JSON-plan utan nätverk, för test. App Intents: Remove Background (Vision, på enheten), Apply Preset, Apply Filter och Export, alla headless med fil in och fil ut. **Lärdom:** App Intents metadata-extraktor accepterar bara systemets UTTypes i `supportedContentTypes`, så `.glimmer` anges som `.package`.
- **Fas 9:** Historikpanelen bygger på dokumentets egen logg över ångra-steg. Den följer ångra och gör om via `UndoManager.isUndoing`/`isRedoing`, och ett klick stegar till valt steg. Ångra-historiken har ett tak (100 steg, ändras i Inställningar › Allmänt). Eftersom ögonblicksbilderna delar oförändrade tiles kostar varje steg bara de tiles det ändrade. Navigatorn visar en nedskalad platt förhandsvisning som renderas i bakgrunden när redigeringen pausar, med visningsrutan som går att dra. QuickLook: varje sparat paket innehåller `QuickLook/Thumbnail.png` och `Preview.png`, som två små extensions (thumbnail och data-baserad preview) läser, så Finder renderar inget själv. Ikonen ritas med Core Graphics (`docs/icon-1024.png`). Svenska via String Catalogs. Extraherade strängar importeras via XLIFF (`-exportLocalizations`/`-importLocalizations`). Strängar som visas genom variabler (registret, verktyg, filter, justeringar, ångra-namn) är manuella katalognycklar och visas via `LocalizedStringKey`. VoiceOver beskriver canvasen (storlek, lager, zoom, aktivt lager, markering, verktyg), och lagerrader har egna åtgärder. Sparkle är integrerat men inaktivt tills `SUPublicEDKey` sätts av `scripts/release.sh`, som arkiverar, exporterar med Developer ID, notariserar, staplar, bygger DMG och appcast. En torrkörning har gett en Developer ID-signerad DMG som Gatekeeper godkänner. Notariseringen sköts av Xcode med kontot under Xcode › Settings › Accounts. Version 0.1.0 är notariserad. Välkomstfönster vid första start, mönsterstämpel och färgrutor (popover vid färgväljaren) är också på plats. **Prestanda (M5, uppmätt i testerna):** komposit av 8k × 8k × 20 lager tar 0,16 s, och omkontroll 9 ms. Gaussian på 8k-lager tar 0,2 s, 12 dabs på 8k-lager under 1 ms, och liquify-dab plus rendering på 4k 11 ms.
- **Tillval efter fas 9 (gjorda 2026-11-13):**
  - **Straighten i crop** med auto-anpassning så att inga genomskinliga hörn blir kvar. Lagren samplas om via smart-objekt-renderaren, och textlager rastreras.
  - **Free transform** med distort, skew och perspektiv. `AffineTransform` har en projektiv rad (g, h), och shadern sätter w så att uv interpoleras perspektivkorrekt.
  - **Text längs en bana:** glyferna läggs ut per båglängd och roteras efter tangenten.
  - **Smarta filter:** listas under lagret, och kan slås av, redigeras och tas bort. Compositorn cachar dem ihop med smart-objektet.
  - **Vektorformlager:** formen sparas som Bézier-`vectorMask`, och masken rastreras om när banan ändras. Formen går att redigera med pennan och skalas utan omsampling.
  - **Rundad rektangel.**
  - **Detaljnivå i komposit-cachen:** vid utzoomning behålls bara den mip-nivå som visas (för 8k × 8k vid 25 % blir det cirka 1/16 av minnet), och tiles komponeras om i full upplösning vid inzoomning.
  - **Svenska ångra-namn** även för sammansatta namn.

- **Komplettering efter genomgång mot planen och webbappen (2026-11-13, kväll):**
  - **Tool calling i assistenten.** Varje agentoperation är ett function-verktyg som genereras ur `AgentPlanner.ops`; historiken skickas som riktiga turer. En modell som ändå skriver en JSON-plan fungerar fortfarande. Verifierat live mot OpenRouter (gemini-2.5-flash).
  - **En plan = ett ångra-steg.** `GlimmerDocument.beginTransaction`/`endTransaction` samlar alla redigeringar under en körning i ett steg som heter efter förfrågan.
  - **Routning på enheten.** `OnDeviceRouter` (Apple Foundation Models, guided generation) avgör om en förfrågan är ett enda kommando (körs direkt, gratis), en ny bild (Generate) eller något för planeraren. Kandidater tas från fuzzy-träffar för hela texten och varje ord.
  - **Warp Text** (arc, arch, bulge, wave, flag, rise) med webbens formler, men på glyfernas vektorkonturer så kanterna förblir skarpa. `.aips` tar med förvrängningen.
  - **Histogram i Levels** med dragbara svart-, gamma- och vitreglage, beräknat på det lagret får in (dokumentet med lagret och allt ovanför dolt).
  - **Export:** WebP (förlustfri VP8L-kodare skriven i Swift, eftersom ImageIO inte kan skriva WebP och ett externt bibliotek inte tilläts) och 32-bitars flyttals-TIFF (linjär, HDR bevaras).
  - **Ritplatta:** lutning och rotation styr penselns vinkel och rundhet; tryckkurva i Inställningar › Ritplatta.
  - **Ångra-historik med minnesbudget** (Inställningar › Prestanda, standard 2 GB): varje steg belastas för de tiles bara det håller vid liv, och de äldsta släpps när budgeten överskrids. Äldre steg flyttas numera till disk (se förnyelsen nedan).
  - **Real-ESRGAN på datorn** (realesr-general-x4v3, BSD-3) konverterad med `scripts/convert-models/realesrgan.py`, 2,4 MB i appen. 4K → 2× tar ~24 s i debug-bygget. Licenser i `Credits.html`.
  - **Golden images:** 51 referenser (alla blend modes, justeringar, filter och effekter), jämförda i CIELAB (medel-ΔE < 0,5, 99 % < 2).
  - **UI-tester** (`scripts/uitest.sh`): nytt dokument, måla, ångra, spara, exportera. Kräver att macOS får slå på automationsläget (lösenord eller Touch ID en gång).
  - **Profilering med xctrace** (Time Profiler på release-byggda prestandatester): CPU-tiden domineras av processladdning; komposit och filter körs på GPU:n och Real-ESRGAN i Core ML. Inga CPU-hotspots i redigeringskoden.

- **Förnyelse (2026-11-13, sent):**
  - **Assistenten ser bilden** (JPEG, 1024 px) och känner alla reglage (namn, intervall, standardvärden genereras ur schemat). Svaren strömmas. Efter en plan jämför modellen före och efter och får justera en gång med redigerarens egna verktyg; rättelsen hamnar i samma ångra-steg.
  - **Åtgärdsrad vid markeringen** (beskriv och generera, ta bort, invertera, fjädra, avmarkera), **sparade åtgärder** (en färdig plan körs om utan planerare, även från ⌘K) och **senaste kommandon** i ⌘K.
  - **Vänd och rotera bild** (Image-menyn), byggt på samma kanvas-transform som rak beskärning.
  - **Real-ESRGAN:** vektoriserade kopior, 4K → 2× går från 26 s till 6 s. **WebP:** kvalitet under 100 % avrundar färgerna (20–40 % mindre fil). Appstart profilerad: inget att hämta.
  - **Kod och arbetssätt:** Phase6/Phase7-filerna uppdelade per funktion, CI (`.github/workflows/ci.yml`), `release.sh <version> --publish` höjer byggnumret (Sparkle jämför byggnummer), testar, taggar och publicerar.
  - **Ångra-historik till disk:** varje steg är en `UndoSnapshot`; när historiken överskrider minnesbudgeten skrivs de äldsta som paket i temp-katalogen (i bakgrunden) och läses in igen vid ångra. Markeringen ligger kvar i minnet. Filerna tas bort när steget släpps och vid nästa start.
  - **Förlustkomprimerad WebP:** en egen VP8-kodare (`VP8Encoder.swift`, RFC 6386) med 16 × 16-prediktion (DC, V, H, TM), anpassade koefficientsannolikheter i två pass och alfa som förlustfri `ALPH`-chunk. Rekonstruktionen är bitexakt mot libwebps dekoder. Sedan tillkom 4 × 4-prediktion (tio lägen) med val per makroblock efter fel plus uppskattade bitar; filerna är nu i nivå med cwebp vid samma PSNR. 100 % kvalitet ger fortfarande förlustfri VP8L.

- **Andra förnyelseomgången (2026-11-13, natt):**
  - **Förslag utifrån bilden:** "Suggest Edits" låter textmodellen titta på fotot och föreslå tre redigeringar (titel + mål) på användarens språk; ett klick skickar målet till planeraren.
  - **Sparade åtgärder i Genvägar:** `RunActionIntent` kör en sparad åtgärd utan fönster (`HeadlessEditor.run`). Justeringar, filter, presets, lagerstilar, text och bakgrundsborttagning stöds; steg som kräver fönstret eller betalda AI-jobb ger ett tydligt fel.
  - **CI** körs på den här Macen som self-hosted runner (`scripts/setup-runner.sh`).

- **Gränssnitt efter webbversionen (2026-11-14):** mörkt tema med webbens färger (`Theme.swift`: bakgrund #0c0d11, panel #16171c, accent #6d7dff), dold titelrad och arbetsytan kant i kant. Sidopanelen (`.inspector`) är ersatt av en flytande panel under knappraden uppe till höger (AI, Tools, Layers, Export, ⌘K). Namn, storlek och zoom visas i en bricka uppe till vänster. Omnibaren är en riktig textrad: ↩ kör bästa träff, ⌘↩ frågar assistenten, träffar visas ovanför. Paletten och omnibaren delar logik i `Palette`. Tomma dokument visar ett startkort med logotypen. "Classic Layout" (Visa-menyn) dockar panelen vid högerkanten med alla flikar, som webbens klassiska läge; lagerpanelen har webbens textknappar.

- **Paritetsgenomgång mot webben (2026-11-14):** en ny genomgång av webbens kod hittade sex funktioner utan motsvarighet och ett antal med färre val. Allt är byggt:
  - **Webbprojekt:** `AipsExporter` (GlimmerRender) skriver `.aips`, och importen läser nu även paths, guider, grid och text på path. Fyllningslager, former, smarta filter och perspektivtransformer skrivs som pixlar eftersom webben saknar dem. Rundresan export → import är testad, och en provfil med ett lager av varje sort (`GLIMMER_AIPS_OUT=… swift test --filter AipsSampleTests`) öppnades utan fel i webbappen (2026-11-14). Webben ritar skuggan från lagrets hela yta, inte från masken, så maskade lager med skugga ser olika ut.
  - **Text på path** bär nu pathens id (`TextLayer.onPathID`) och följer pathen när den redigeras. Väljaren "On path" binder eller lossar en befintlig text.
  - **Markering:** feather när markeringen görs, ⇧/⌥ under dragning (kvadrat, från mitten) när de släppts efter nedtrycket, snap för markeringsramen. Crop har ⌥ från mitten.
  - **Snap** mot canvasens mitt, och flyttverktyget snappar lagrets kanter och mitt (`snapOffset(forBoxAt:size:)`).
  - **Fyllning:** ⌥⌫ och ⌘⌫ fyller markeringen eller lagret med förgrund respektive bakgrund; "Fill with Pattern" målar mönstret destruktivt.
  - **Former** får kontur som lagerstil. **Lärdom:** lagerstilar ritades aldrig på fyllningslager; kompositorn renderar dem nu från maskens form (`effectsOnly`-noder runt fyllningen).
  - **Pensel:** egna förinställningar (`BrushPresetStore`, UserDefaults) och reglage för spacing, rundhet, vinkel, spridning och storleksvariation.
  - **Gradientverktyget** ritar med egna stopp, färdiga ramper och Reverse.
  - **Kanaler:** `channelMask` (bitar R, G, B, alfa) ersätter enkanalsvisningen; ögonen kombinerar kanaler och alfa kan visas och läsas in som markering.
  - **Lens Blur** förhandsvisas live i ett lager utanför ångra-historiken tills Apply, med visning av djupkartan.
  - **Övrigt:** Tab gömmer gränssnittet, vinkelfält för vyrotation i navigatorn, Liquify "Restore All", förslagschips i omnibaren, valfri prompt i Remove-läget, släpp referensbild på Match Color, ⇧O för Burn, U växlar form, och en bild som placeras i ett orört tomt dokument blir dokumentet.
  - **Lärdom:** när ⌘K-paletten stängdes hamnade tangentbordet ingenstans, så verktygstangenterna fungerade inte förrän man klickat i bilden. Canvasen tar nu tillbaka fokus.
  - **Lärdom (test):** macOS 27 sparar fönsteråterställning i `~/Library/Daemon Containers/…/Saved Application State/<UUID>.savedState`, inte i appens container. Efter många `pkill` öppnade appen 37 gamla fönster.

- **Andra paritetsgenomgången (2026-11-14):** de delar av webben som bara stickprovats lästes i sin helhet (motorfilen, lagerpanelen, textredigering, färgväljare, kurvor). Byggt: Free Transform på text (blir pixlar vid Apply), dubbelklick på text med flyttverktyget, Liquify som håller sig inom markeringen, knappar för att byta och återställa färger, crop-gester (ny ruta i en helbildscrop, klick återställer, ⇧ låser proportioner), kopiera och klipp ut hela lagret utan markering, text till smart objekt, pennans tryck i Liquify, hjälplinjer mellan gridlinjerna (och snap mot dem), guider som släpps utanför bilden tas bort, Esc i Magic Select återställer den tidigare markeringen, ⌘Y och ⌘=, samt paletten hittar panelerna, New och Open.
  - **Även byggt efteråt:** rotation bara strax utanför ett hörn och klick utanför verkställer, vinkelvisning på bilden medan man roterar, guider flyttas med alla verktyg och snappar, alfa på förgrunds- och bakgrundsfärg (pensel, fyllning, gradient), Magic Select med Apply och Clear Points, alla sparade paths ritas svagt, kurveditorn visar övriga kanaler och Reset gäller bara kanalen, crop tar bort pixlar utanför som standard (av/på i verktygsraden) och behåller zoomen, egen fyllnadsfärg för former, ⌥-markör för klonkälla, "Export PNG…" och Esc med pennan slänger den påbörjade delen.

- **Smartare och snabbare (2026-11-15):** det mesta i webbens `INNOVATION_ROADMAP.md` fanns redan. Den här omgången lade till bildanalys på enheten (Core Image och Vision, gratis och privat) i `GlimmerAI/SmartAnalysis` och byggde arbetsflöden på den.
  - **Auto Enhance (⇧⌘L):** Core Images automatiska korrigering översätts till redigerbara lager (Curves och Vibrance i en pass-through-grupp) i stället för bakade pixlar. CIToneCurve arbetar på sRGB-värden precis som Curves, så punkterna förs över rakt. Skugg- och högdagerjusteringen (lokal i CI) viks in i kurvan som en global approximation.
  - **Auto Straighten:** Visions horisontdetektering öppnar Crop med rutan vriden och med största möjliga ruta, så att man ser resultatet innan man verkställer.
  - **Suggest Crop:** saliency-ruta med rutan i cropens bildformat (glider över motivet), eller en tajtare ruta i bildens egna proportioner. Knapparna Suggest och Level finns i crop-raden.
  - **Omnibaren föreslår utifrån bilden:** analysen körs när omnibaren får fokus (utplattning och analys sker utanför huvudtråden och cachas per dokumentversion). Förslagen visas bara när de har något att göra, till exempel "Straighten 4.0°".
  - **Paletten lär sig:** användningsfrekvens med halveringstid två veckor höjer det man brukar använda, utan att slå en klart bättre träff.
  - **Batch Process…:** kör Auto Enhance, Remove Background, ett preset eller en sparad Action på många bilder (släpp filer eller mappar) och skriver till en vald mapp. Använder samma huvudlösa kod som Shortcuts. Shortcuts har fått "Auto Enhance Image", och assistentens plan har steget `auto_enhance`.
  - **Diskreta notiser:** besked som "ingen lutande horisont" visas som en notis som försvinner, inte som en modal dialog.
  - **Lärdom:** Vision rapporterar horisontens vinkel med omvänt tecken (stigande åt höger är negativt). Ett test med en syntetisk lutande horisont låser tecknet.
  - **Lärdom (router):** routern på enheten valde "Blend Colors in Gamma Space" för "fix the colors" eftersom ordet matchade. Inställningar, visningar och filkommandon är nu aldrig kandidater, och allmänna "fixa/förbättra"-förfrågningar går till Auto Enhance. Det är verifierat med Apples modell på enheten.
- **Fler smarta funktioner (2026-11-15):**
  - **Auto Color (⇧⌘B):** färgsticket mäts på bildens nästan neutrala pixlar (mättade färger räknas inte, så en röd bil eller blå himmel blir inget stick) och tas bort med ett Color Balance-lager till 80 %. Auto Enhance gör det också när sticket är tydligt (över 0,03).
  - **Select People:** Visions personsegmentering i noggrant läge, med finare hår och kanter än Select Subject.
  - **Bildens text:** "Copy Text in Image" kopierar texten. "Image Text to Layers" gör varje rad till ett redigerbart textlager över originalet, med bredden matchad och färgen hämtad från de pixlar som skiljer sig mest från bakgrunden.
  - **Export for Web… och storleksgränser:** längsta sida och maxstorlek i kB finns i Export och Batch. Kvaliteten hittas genom bisektion, och bilden skalas ner bara om inte ens låg kvalitet ryms. Exporten bekräftar med filnamn och storlek.
  - **Smarta lagernamn:** placerade och inklistrade bilder med kamera- eller urklippsnamn ("IMG_1234", "Pasted Layer") får namn efter innehållet från Visions klassificering.
  - **Assistenten** har fått stegen `auto_color` och `select_people`, och omnibaren föreslår Select People, Image Text to Layers och Auto Color när bilden har det.
  - **Lärdom:** den snabba textigenkänningen missar stiliserad text som affischrubriker. Analysen använder den noggranna nivån med en minsta texthöjd, vilket fortfarande tar under en sekund.
- **Tredje smarta omgången (2026-11-15):**
  - **Select Sky:** heuristiken (långt bort enligt djupkartan, jämn, ljusare än det som står mot himlen, färgkontinuitet, odlad från överkanten) väljer bara *punkter*: positiva djupt inne i himlen och negativa där utseendet ändras. Segment Anything (samma kodning som Magic Select) ritar sedan konturen. Regionväxning ensam tog med disiga, solbelysta berg. Med SAM blir bergskammar, brokablar och text rätt även på en disig bild.
  - **Straighten Document:** Visions dokumentsegmentering (med rektangeldetektering som reserv) hittar dokument, skylt, whiteboard eller skärm. CIPerspectiveCorrection rätar upp den i linjärt flyttal, och resultatet öppnas som ett nytt dokument så att originalet lämnas orört.
  - **Porträttbeskärning:** Suggest Crop ramar in huvud och axlar med ansiktena kring 38 % av höjden, och håller ihop grupper.
  - **Betygsättning i Batch:** Apples estetikbedömning (`VNCalculateImageAestheticsScoresRequest`, inklusive "utility" för dokument och skärmdumpar) plus ett eget skärpemått. Måttet är Laplace-variansen relativt regionens kontrast i den skarpaste av 4×4 regioner, så en skarp huvudperson mot suddig bakgrund räknas som skarp och en disig bild inte som suddig. Grafik med färre än 200 färger kallas aldrig suddig. Listan går att sortera med bäst först och gallra utan oskarpa bilder, utan dokument, med 4 stjärnor och uppåt, eller med bästa hälften eller fjärdedelen. Miniatyrer läses direkt ur filen.
  - **Lärdom (fel hittat):** SAM:s maskavkodare tar högst 15 prompt-tokens, alltså 14 punkter plus utfyllnad. Magic Select gav fel vid den femtonde klickpunkten och behåller nu de 14 senaste.
  - **Lärdom (prestanda):** Select Sky tar runt 0,7 sekunder varmt på en 4K-bild. Första körningen efter start kostar cirka 2 sekunder extra för att Core ML läser in SAM:s prompt- och maskmodeller. Djup och punkter räknas på en kopia med 1 024 pixlar.

## 4. Teststrategi

- **GlimmerCore:** modell, COW-tiles, undo/redo-invarianter, serialisering (rundtur och versionsmigrering) och `.aips`-import mot riktiga filer från webbappen.
- **GlimmerRender:** golden-image-tester per blend mode, justering, filter och effekt, med tolerans ΔE < 0.5. Referenserna genereras en gång och checkas in.
- **GlimmerAI:**
  - Pipelinerna testas med en fejkad `ImageModel` som returnerar deterministiska bilder.
  - Primitiverna testas mot värden beräknade av webbens Python-kod.
  - Riktiga OpenRouter-anrop körs bara i ett separat, manuellt testschema.
- **UI:** ett fåtal UI-tester för de kritiska flödena: öppna, måla, ångra, spara, exportera.
- **Prestanda:** XCTest-metrics eller signposts för panorering, penseldrag och öppning av stora filer, med budgetar som larmar vid regression.

## 5. Risker

| Risk | Hantering |
|---|---|
| Tile-compositorn är det svåraste och mest grundläggande. Fel val här kostar mest senare. | Fas 1 är medvetet en vertikal slice med prestandabudget. Arkitekturen stresstestas innan funktioner läggs ovanpå. |
| Bildmodellernas output varierar (storlek, beskärning, färgdrift). | Pipelinerna litar aldrig på modellens geometri: re-align, färgmatcha och blanda alltid in. Webben har redan bevisat metoden. |
| Core ML-konvertering av SAM och Real-ESRGAN. | Vision-fallback finns för Magic Select, och Lanczos plus enhance för Upscale. Konverteringen är isolerad i script. |
| OpenRouter-modeller byts ut eller försvinner. | Modell-ID:n är inställningar, och svarsparsern är tolerant. |
| Omfånget (webbens funktionsyta är stor). | Varje fas levererar en användbar app. Lägre prioriterade punkter är markerade *tillval*. |

## 6. Medvetet utanför (för nu)

Fal och Replicate, konton, credits och fakturering, multiplayer, plugin-API, PSD med lager, RAW-framkallning utöver grundläget, video, iPad. Allt i `docs/INNOVATION_ROADMAP.md` som inte byggts i webben ligger också utanför, men registret och agentarkitekturen gör dem enkla att lägga till senare.

## 7. Besvarade frågor (2026-11-13)

1. **Layout:** en adaptiv layout. Omni och Classic slås ihop.
2. **Blend-färgrymd:** linjärt ljus som default, gamma som dokumentval.
3. **Identitet:** `com.brattoo.glimmer`, team Brattoo AB (V783A2L763).
4. **Git:** ja, pushat till `fltman/glimmer-native`.
5. **AI flyttas fram:** ja, AI är nu fas 3–4, direkt efter lagerträdet.
