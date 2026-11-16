# Patents: what is known and what isn't

Looked up 2026-11-15 and 2026-11-16. **Nothing here is a legal conclusion**, and none of it has been checked by a lawyer. It records what a search found and the rules the code keeps to, so that the person deciding (Anders) and a lawyer have somewhere to start, and so that the same questions don't have to be researched twice.

How to read it:

- "Read here" means the page was fetched and read for this document on 2026-11-16: the claims on Google Patents, the expiry notices in the USPTO Official Gazette. Everything else, marked "as listed", is from a search on 2026-11-15 through a summarising tool that read Google Patents; treat those numbers and dates as leads, not facts.
- Google Patents calls its own status and expiry dates "an assumption and not a legal conclusion".
- USPTO Patent Center and the USPTO maintenance-fee lookup could not be opened (403; the API wants a key). Espacenet and the EP Register were not consulted. No exhaustive assignee or inventor search was made. Other patents may exist.
- Only United States patents were looked at in any depth. The core Adobe families below showed no EP, DE or GB members on Google Patents; some later Adobe families have GB patents (GB2580596, GB2589389, GB2555168, GB2555673, GB2606836, as listed).

## Decisions

- 2026-11-16, Anders: build the classic fill (Heal Selection) now, with the rules below as hard rules; keep researching whether a learned model may ship. The model is parked until he says otherwise (`FILL-MODEL-RESEARCH.md`).
- 2026-11-16, coordinator for Anders: fast marching only for the smooth fill; no biharmonic fill for now (see US 7,840,086 below). No Poisson seam in the first version (rule 3b). The priority of the texture fill is the 2004 paper's, unchanged (rule 4). The rules stay as they are although two of the patents behind them are listed as expired.
- Heal Selection is **off in release builds** (`Config/Features.xcconfig`, `GLIMMER_HEAL = NO`) until Anders has seen results. Debug builds always have it. With `NO` the code is not compiled into a release at all, and the menu, `/operations`, the guide, the manual and the FAQ don't mention it.

## Heal Selection: the rules

The code is `Packages/GlimmerKit/Sources/GlimmerHeal` (three files). It was written from two papers, with no code copied or ported from anywhere:

- Smooth fill: A. Telea, "An Image Inpainting Technique Based on the Fast Marching Method", Journal of Graphics Tools 9(1), 2004. No patent on it was found.
- Texture fill: A. Criminisi, P. Pérez and K. Toyama, "Region Filling and Object Removal by Exemplar-Based Image Inpainting", IEEE Transactions on Image Processing 13(9), 2004. Microsoft's patents on it, US 6,987,520, US 7,551,181 and US 7,088,870, are listed as lapsed 2014–2018 with terms ended 2023 (as listed).

The same rules stand as a comment at the top of `Heal.swift`. `HealSourceRulesTests` checks what source text can show: nothing random is called, no smaller or resampled copy of the image is made, no patch is transformed, pixels are copied one for one in a single place, and the target imports only Foundation.

| # | Rule | Stays clear of |
|---|---|---|
| 1 | Every patch is searched from scratch over the whole window. No match is ever derived from a neighbour's match, and nothing is randomised. | Adobe, PatchMatch: US 8,811,749, US 8,285,055, US 8,571,328 (with Princeton), US 8,861,869, US 8,625,927 |
| 2 | Everything runs at full resolution. No reduced-size copy of the image, no pyramid, no matching at low resolution to fetch full-resolution patches. | Adobe: US 8,818,135, US 9,305,329, US 9,396,530 |
| 3 | Patches are axis-aligned and 1:1 and copied as they are: never rotated, scaled, mirrored or otherwise transformed. Overlapping patches are never voted or blended. | Adobe: US 8,861,868, US 9,317,773 |
| 3b | No gradient-domain (Poisson) seam. The join is the selection's own soft edge, nothing else. If a seam shows on real photos, that is a decision to take with pictures, not a thing to add. | Same as rule 3. (Poisson editing itself, Microsoft US 6,856,705, is listed as lapsed 2017.) |
| 4 | The fill order is the 2004 paper's priority, unchanged: confidence × data term at the front pixel, the data term being the isophote at that pixel against the front's normal, divided by 255. No map of structure strength is computed over the image, and nothing from later variants is added. It must not be "improved". | CyberLink US 8,731,324 (a structure-strength map as the priority, to 2033, as listed) |
| 5 | The smooth fill is fast marching. No differential-equation solve: no Cahn–Hilliard, no biharmonic, no Navier–Stokes. | University of California US 7,840,086 |
| 6 | Where to sample is fixed by the hole (a window around it). There is no "sample from here" or "don't sample there" input. | Adobe: US 8,355,592, US 9,330,476 |
| 7 | Own implementation from the papers. No code copied or ported from OpenCV, scikit-image, G'MIC or anyone else. | Licences rather than patents (Adobe's PatchMatch reference code is non-commercial) |

Two things the 2004 paper leaves to whoever implements it are done the plain way and said in `ExemplarFill.swift`: the image gradient "at" a front pixel, which has no value yet, is the strongest gradient among the patch's known pixels; equal priorities go to the higher confidence, then to the first pixel in reading order.

Two departures from the Telea paper, both to stop the fill running away on noisy pictures, and neither taken from other code: only pixels of the picture itself are extended along their gradient (pixels already filled in are used as they are), and a filled pixel is never brighter or darker than the pixels it was made from.

### US 8,811,749 and US 8,818,135: listed as expired, rules unchanged

Read here, in the USPTO Official Gazette ("Notice of Expiration of Patents Due to Failure to Pay Maintenance Fee"):

- Gazette of October 13, 2026, list "PATENTS WHICH EXPIRED ON August 19, 2026 DUE TO FAILURE TO PAY MAINTENANCE FEES": `8,811,749 13/607,965 08/19/2014`.
- Gazette of October 20, 2026, list "PATENTS WHICH EXPIRED ON August 26, 2026 DUE TO FAILURE TO PAY MAINTENANCE FEES": `8,818,135 13/652,548 08/26/2014`.
- Neither is in "Patents Reinstated Due to the Acceptance of a Late Maintenance Fee" in the gazettes of October 13 to November 10, 2026 (weeks 41–45; later ones weren't out).

Caveats: an expired patent can be reinstated on petition when the delay was unintentional (37 CFR 1.378), so "expired" is not "gone for good". Google Patents still showed both as active on 2026-11-16 (its last event for each is the fee reminder of April 2026). The rest of both families is unaffected. So rules 1 and 2 stay exactly as they are.

Their first claims, read here on Google Patents, for the record:

- US 8,811,749, claim 1: "A method comprising: identifying a mapping assigned to a first patch by one or more processor-based devices; propagating the identified mapping to a second patch to generate a propagated mapping by the one or more processor-based devices; perturbing the propagated mapping to generate a perturbed mapping by the one or more processor-based devices; and assigning one of the propagated mapping and the perturbed mapping to the second patch by the one or more processor-based devices."
- US 8,818,135, claim 1: "A method performed by data processing apparatus, the method comprising: receiving a first image at a first resolution, the first image having a first hole therein; generating, based on the first image, a second image at a second resolution lower than the first resolution, the second image having a second hole therein corresponding to the first hole; identifying, in the second image, one or more second-image source patches for the second hole; identifying at least one first-image source patch in the first image based on a location of the identified second-image source patch; storing the identified at least one first-image source patch in memory; identifying fill content in the at least one first-image source patch stored in the memory; and placing the identified fill content in the first hole."

### US 7,840,086 (University of California): why there is no biharmonic fill

Google Patents on 2026-11-16: active, 12th-year fee paid 2022-05-23, expiry shown 2029-08-29. It has one independent claim, read here:

> 1. A computer, comprising: a processor; programming executable on said processor for carrying out a method for filling in of damaged or missing regions of an image by way of information from surrounding areas, said image being defined in a first domain, said filling in being defined in a second domain contained in the first domain, the method comprising: representing the image as an image function; and solving a differential equation related to the image function, said differential equation comprising a fidelity term and a parameter to measure a transition region between states.

Claim 7 names the equation: the modified Cahn–Hilliard equation, with ε, a nonlinear potential W and the fidelity term λ(x)(f − u).

A plain reading, not a legal one: a biharmonic fill solves Δ²u = 0 inside the hole with the surrounding pixels as fixed boundary values. It has no fidelity term (nothing in the equation pulls u toward the image; the known pixels are boundary data) and no parameter measuring a transition region between states. Two elements of the claim are absent. But "a fidelity term" is broad wording, and a solver written in penalty form (a λ-weighted data term) would have one.

Decision 2026-11-16: not built. The claim runs to 2029 and the gain over fast marching is small. If it is ever reconsidered: only the pure boundary-value form, and the question goes to Anders first.

### In force, as listed, and not relied on being avoided by more than the rules above

- Adobe PatchMatch core: US 8,285,055 (to 2031-04-09), US 8,571,328 (to 2031-10-19), US 8,861,869 (to 2030-08-16), US 8,625,927 (to 2032-03-07).
- Adobe patch-based fill: US 8,861,868 and US 9,317,773 (to 2032), US 9,305,329 and US 9,396,530 (to 2032–2034), US 8,355,592 and US 9,330,476 (to 2031–2032), and refinements filed 2016–2019 running to 2037–2041 (sampling-region synthesis, oracle sampling, previews).
- The patents on learned fill (Nvidia, Adobe, Samsung, Google) are in `FILL-MODEL-RESEARCH.md`; Heal Selection uses no network.

## Already in the app before Heal Selection

- Healing Brush (`FilterEngine.healed`): a clone whose low frequencies (a Gaussian blur of the difference) are taken from the destination. Adobe's Healing Brush patents US 6,587,592 and US 6,985,263 are listed as expired 2021–2022 (EP 1459259 expired 2022), and its gradient-domain healing patents US 7,558,433 and US 8,041,140 as expired 2024–2026 (as listed; not re-read). The brush does no gradient-domain solve.
- Clone Stamp, Pattern Stamp, Liquify, filters: nothing was searched for these.
- Image quilting (US 6,919,903, listed as expired 2021) is not used.
