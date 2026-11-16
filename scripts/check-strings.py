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
CALLS = r'(?:String\(localized: |Text\(|Button\(|Label\(|Toggle\(|Picker\(|Section\(|\.help\(|\.accessibilityLabel\(|\.navigationTitle\(|Menu\()"((?:[^"\\]|\\.)*)"'

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
numbered = [k for k in keys if re.search(r"%\d+\$", k)]
for k in numbered: missing.append(f"catalogue key with a numbered placeholder (never found at run time): {k[:90]}")
for line in sorted(set(missing)): print("✘", line)
print(f"{len(set(missing))} text(s) without Swedish." if missing else "Every text found has Swedish.")
sys.exit(1 if missing else 0)
