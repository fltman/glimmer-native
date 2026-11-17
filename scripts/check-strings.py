#!/usr/bin/env python3
"""Every text the app shows must be in App/Localizable.xcstrings with a Swedish translation.

    scripts/check-strings.py        exit 0 = nothing missing

Looks up the string literals of SwiftUI views and String(localized:) in App/*.swift.
Interpolations are matched against the catalog's placeholders (%@, %lld, %1$@ …). Debug-only
files and literals that are symbols, units or contain quoted code are skipped. It reads source
text, so a string built in some other way is not seen.
"""
import glob, json, os, re, sys

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
catalog = json.load(open(os.path.join(root, "App/Localizable.xcstrings")))["strings"]
keys = list(catalog)
SKIP_FILES = {"DebugFixtures.swift"}
# Debug-only texts (the paid test of a model) and literals that are not prose.
SKIP = ("Run Glimmer's Test of This Model…", "Running the test", "Send \\(", "Each request carries the list", "sk-or-v1-…", "sRGB")
CALLS = r'(?:String\(localized: |stepName\(|Text\(|Button\(|Label\(|Toggle\(|Picker\(|Section\(|\.help\(|\.accessibilityLabel\(|\.navigationTitle\(|Menu\()"((?:[^"\\]|\\.)*)"'

def parts(literal):
    out, i = [], 0
    while i < len(literal):
        if literal.startswith("\\(", i):
            depth, i = 1, i + 2
            while i < len(literal) and depth:
                depth += {"(": 1, ")": -1}.get(literal[i], 0)
                i += 1
            if depth: return None          # the interpolation holds a quoted string: the regex cut it short
            out.append(None)
        else:
            if not out or out[-1] is None: out.append("")
            out[-1] += literal[i]; i += 1
    return out

missing = []
for path in sorted(glob.glob(os.path.join(root, "App/*.swift"))):
    name = os.path.basename(path)
    if name in SKIP_FILES: continue
    for match in re.finditer(CALLS, open(path).read()):
        literal = match.group(1)
        if literal.startswith(SKIP): continue
        pieces = parts(literal)
        if pieces is None or not re.search(r"[A-Za-z]{3}", "".join(p or "" for p in pieces)): continue
        if "." in literal and " " not in literal: continue      # an SF Symbol name
        # The key the app looks up at run time has plain placeholders (%@, %lld), never numbered ones:
        # a key written "%1$@ … %2$@" is not found, and the text stays English. (Fourteen such keys
        # were in the catalogue until 2026-11-16, and this check let them through.) Numbered
        # placeholders belong in the translation, not in the key.
        pattern = "^" + "".join(r"%(?:@|lld|lf|d|ld)" if p is None
                                else re.escape(p.replace('\\"', '"').replace("\\n", "\n").replace("%", "%%" if None in pieces else "%")) for p in pieces) + "$"
        hits = [k for k in keys if re.match(pattern, k)]
        if not any("sv" in (catalog[k].get("localizations") or {}) or catalog[k].get("shouldTranslate") is False for k in hits):
            missing.append(f"{name}: {literal[:100]}")
# The package's refusals about Photoshop and RAW files reach a person through the catalogue
# (App/PersonMessage.swift): each one needs Swedish there, a figure or a name in it written as %@.
for path in sorted(glob.glob(os.path.join(root, "Packages/GlimmerKit/Sources/GlimmerRender/Raw*.swift")) + glob.glob(os.path.join(root, "Packages/GlimmerKit/Sources/GlimmerCore/PSD/*.swift"))
                   + glob.glob(os.path.join(root, "Packages/GlimmerKit/Sources/GlimmerRender/PSD*.swift"))):
    for match in re.finditer(r'Problem\((?:message: )?"((?:[^"\\]|\\.)*)"', open(path).read()):
        text = match.group(1)
        # A figure or a name in the message is "%@" in its catalogue entry (PersonMessage finds it by its fixed words).
        text = "".join("%@" if piece is None else piece for piece in (parts(text) or [text]))
        if "sv" not in (catalog.get(text, {}).get("localizations") or {}): missing.append(f"{os.path.basename(path)} (a refusal shown to a person): {text[:90]}")
# What Settings says about a service (its note about terms and where pictures go) and what a picture service's
# adapter says when an answer is not usable: shown to a person, so each needs Swedish, also for the services that
# are still hidden until they have been tried.
for name, pattern in (("Providers.swift", r'termsNote\s*=\s*"((?:[^"\\]|\\.)*)"'), ("ImageProviders.swift", r'message:\s*"((?:[^"\\]|\\.)*)"')):
    for match in re.finditer(pattern, open(os.path.join(root, "Packages/GlimmerKit/Sources/GlimmerAI", name)).read()):
        text = "".join("%@" if piece is None else piece for piece in (parts(match.group(1)) or [match.group(1)]))
        if "sv" not in (catalog.get(text, {}).get("localizations") or {}): missing.append(f"{name} (said about a service): {text[:90]}")
numbered = [k for k in keys if re.search(r"%\d+\$", k)]
for k in numbered: missing.append(f"catalogue key with a numbered placeholder (never found at run time): {k[:90]}")
# American English throughout, as Apple's (the-apps/SIBLINGS.md, "Språk"): Color, Center, Gray, Canceled.
# Read in every English text of the catalogue and in every quoted text of the sources (what an agent is told is English too).
# Left alone: the API's status word "cancelled" (a word of the protocol, not prose) and the lists of words a person may
# type (PlanCheck, PlanClaims), which must know both spellings.
BRITISH = re.compile(r"(?<![A-Za-z])\w*(?:colour|centre|centring|grey|cancell|analys(?!is|es\b)|licence|neighbour|recognis|behaviour|normalis|labell|travell|minimis|maximis|organis|customis|optimis|summaris|neutralis|harmonis|favourite|rasteris|visualis|synchronis|initialis|judgement|artefact|catalogue|dialogue|programme)\w*", re.I)
british = []
for k in keys:
    hit = BRITISH.search(k)
    if hit: british.append(f"catalogue: “{hit.group(0)}” in: {k[:80]}")
quoted = re.compile(r'"(?:[^"\\\n]|\\.)*"')
for path in sorted(glob.glob(os.path.join(root, "App/**/*.swift"), recursive=True) + glob.glob(os.path.join(root, "Packages/GlimmerKit/Sources/**/*.swift"), recursive=True)):
    if os.path.basename(path) in ("PlanCheck.swift", "PlanClaims.swift"): continue
    for number, line in enumerate(open(path, encoding="utf8"), 1):
        for m in quoted.finditer(line.split("//")[0]):
            text = re.sub(r"\\\((?:[^()]|\([^()]*\))*\)", "X", m.group(0))
            hit = BRITISH.search(text)
            # The reader of a sibling's job still accepts the series' old spelling of a stopped job.
            if hit and not (text == '"cancelled"' and os.path.basename(path) == "Siblings.swift"): british.append(f"{os.path.relpath(path, root)}:{number}: “{hit.group(0)}” in {text[:70]}")
for line in sorted(set(missing)): print("✘", line)
for line in british: print("✘ British spelling:", line)
print(f"{len(set(missing))} text(s) without Swedish." if missing else "Every text found has Swedish.")
if british: print(f"{len(british)} British spelling(s) in English texts; the series writes American English.")
sys.exit(1 if missing or british else 0)
