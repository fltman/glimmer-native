#!/usr/bin/env python3 -I
"""States in the window go through one type (the-apps/SIBLINGS.md, "Tillstånd i fönstret").

    scripts/check-status.py        exit 0 = holds

An error, a warning, a notice and a success must be told apart without colour, so no view picks a colour or a
symbol for a state by itself: `StatusLine` and `StatusSymbol` (App/StatusLine.swift) give the symbol, its colour
and the word VoiceOver says. This fails on, anywhere else in App/:
  - .red, .orange, .yellow or .green used as a colour or a style
  - the status symbols (the warning triangle, the cross in a square (and the octagon it replaced), the info circle, the check in a circle, the
    exclamation mark in a circle) written as a symbol name

What is a colour of something else (a colour channel, the navigator's frame) stands in Config/status-exceptions.txt.
That list may only shrink: a line that matches nothing fails, and so does a list longer than in the last commit.
"""
import glob, os, re, subprocess, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIST = "Config/status-exceptions.txt"
def entries(text):
    out = []
    for line in text.splitlines():
        if line.strip() and not line.startswith("#"):
            name, _, needle = line.partition(": ")
            out.append((name.strip(), needle.strip()))
    return out
allowed = entries(open(os.path.join(root, LIST), encoding="utf8").read())
COLOUR = re.compile(r"(?<![A-Za-z0-9_])(?:Color)?\.(red|orange|yellow|green)\b(?!\s*[:,]\s*(?:Double|CGFloat|Float))")
SYMBOL = re.compile(r'"(exclamationmark\.triangle[a-z.]*|xmark\.octagon[a-z.]*|xmark\.square[a-z.]*|info\.circle[a-z.]*|checkmark\.circle[a-z.]*|exclamationmark\.circle[a-z.]*)"')
found, used = [], set()
for path in sorted(glob.glob(os.path.join(root, "App/**/*.swift"), recursive=True)):
    name = os.path.basename(path)
    if name == "StatusLine.swift": continue
    for number, line in enumerate(open(path, encoding="utf8"), 1):
        code = line.split("//")[0]
        # Components of a colour value (c.red, color.green) are not colours chosen for a state.
        code = re.sub(r"\b[a-z][A-Za-z0-9_]*\.(red|green)\b", "", code) if re.search(r"\b(c|color|rgb|\$0|linear|pixel|components)\.(red|green)\b", code) else code
        hit = COLOUR.search(code) or SYMBOL.search(code)
        if not hit: continue
        excused = [e for e in allowed if e[0] == name and e[1] in line]
        if excused: used.update(excused); continue
        found.append(f"App/{name}:{number}: {hit.group(0)} in a view: {line.strip()[:110]}")
stale = [e for e in allowed if e not in used]
for name, needle in stale: found.append(f"{LIST}: “{name}: {needle}” matches nothing any more; take it out (the list only shrinks)")
try:
    before = entries(subprocess.run(["git", "show", f"HEAD:{LIST}"], cwd=root, capture_output=True, text=True, check=True).stdout)
    if len(allowed) > len(before): found.append(f"{LIST} has {len(allowed)} lines, {len(before)} in the last commit: it may only shrink")
except subprocess.CalledProcessError:
    pass   # the list is new in this commit
for f in found: print("✘ " + f)
print(f"{len(found)} fault(s)." if found else f"Every state in the views goes through StatusLine ({len(allowed)} colours that are not states are listed).")
sys.exit(1 if found else 0)
