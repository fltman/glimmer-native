#!/usr/bin/env python3 -I
"""No behaviour may hang on a text the person sees (the-apps/SIBLINGS.md, "Språk").

    scripts/check-text-logic.py        exit 0 = nothing found

Flimmer found two: "an upload is in progress" was decided by whether the status line began with a
Swedish word, and a missing file counted as film when its word was "Film". A text that is shown is
translated, reworded and renamed; what the program decides must hang on a value (a case, a flag,
an id), never on the words.

In the app and the package sources this fails on:
  - a comparison, hasPrefix, hasSuffix or contains against String(localized:) or a LocalizedStringKey
  - a decision on the words of a message, an error description, a toast or a status line
  - a menu item found or compared by its title
In scripts/ it fails on a script that starts the app itself without saying which language it speaks
(the tests look for the app's words, so the copy's language must not follow the Mac's).

A line that is right as it stands carries `text-logic: ok` with the reason.
"""
import glob, os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OPS = r"(?:==|!=|\.hasPrefix\(|\.hasSuffix\(|\.contains\(|\.localizedCaseInsensitiveContains\(|\.localizedStandardContains\(|\.range\(of:\s*|\.starts\(with:\s*)"
RULES = [
    ("compares against a translated text", re.compile(OPS + r"\s*(?:String\(localized|LocalizedStringKey\(|NSLocalizedString\()")),
    ("compares a translated text", re.compile(r"String\(localized:[^\n]*?\)\s*(?:==|!=)")),
    ("decides on the words of a message", re.compile(r"\.(?:message|errorDescription|localizedDescription|errorMessage|toast|statusLine|statusText|healWarning|failureReason)\??\s*" + OPS + r'\s*"')),
    ("decides on the words of a message", re.compile(r"\.(?:message|errorDescription|localizedDescription|errorMessage|toast|statusLine|statusText)\??\s*(?:==|!=)\s*\"")),
    ("finds or compares a menu item by its title", re.compile(r"item\(withTitle:|indexOfItem\(withTitle:|\.title\s*(?:==|!=)\s*\"|\.title\." + r"(?:hasPrefix|hasSuffix|contains)\(\"")),
]
found = []
sources = glob.glob(os.path.join(root, "App/**/*.swift"), recursive=True) + glob.glob(os.path.join(root, "Packages/GlimmerKit/Sources/**/*.swift"), recursive=True)
for path in sorted(sources):
    for number, line in enumerate(open(path, encoding="utf8"), 1):
        code = line.split("//")[0] if "text-logic: ok" not in line else ""
        if not code.strip(): continue
        for what, rule in RULES:
            if rule.search(code):
                found.append(f"{os.path.relpath(path, root)}:{number}: {what}: {line.strip()[:120]}"); break
# A script that starts the app must say which language the copy speaks, or go through test-app.sh, which does.
for path in sorted(glob.glob(os.path.join(root, "scripts/*.sh"))):
    for number, line in enumerate(open(path, encoding="utf8"), 1):
        code = line.split(" # ")[0]
        if code.lstrip().startswith("#") or "text-logic: ok" in line: continue
        starts = re.search(r'open -n "\$(?:APP|COPY|OUT)"|"\$HANDOVER" "\$APP"', code)
        if starts and "-AppleLanguages" not in code and "GLIMMER_ARGS" not in code:
            found.append(f"scripts/{os.path.basename(path)}:{number}: starts the app without saying its language: {line.strip()[:100]}")
for f in found: print("✘ " + f)
print(f"{len(found)} place(s) where behaviour hangs on a shown text." if found else f"No behaviour hangs on a shown text ({len(sources)} source files and the scripts read).")
sys.exit(1 if found else 0)
