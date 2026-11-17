#!/usr/bin/env python3 -I
"""English buttons and menu items are in Title Case (the-apps/SIBLINGS.md, "Språk"; Apple's guidelines).

    scripts/check-title-case.py <titles file>...     exit 0 = every title passes

The titles are read from the running English app, not from the source: every item of every menu,
and every button in the states scripts/test-accessibility.sh visits (`axread <pid> --titles`,
one "menu<TAB>title" or "button<TAB>title" per line). So a title that comes from a variable,
a register or a package is checked like one written in a view.

Apple's rule: capitalise every word except articles, coordinating conjunctions and prepositions
of four letters or fewer, unless first or last; "to" in an infinitive stays lower case.
"""
import re, sys

SMALL = {"a", "an", "the", "and", "or", "but", "nor", "for", "to", "in", "of", "on", "at", "by", "as", "per", "vs", "via",
         "with", "from", "into", "onto", "over", "off", "out", "up"}   # Apple: prepositions of four letters or fewer
# Words that are never anything but small words, so a capital on one inside a title is a fault (the others can be adverbs: "Zoom In").
ALWAYS_SMALL = {"a", "an", "the", "and", "or", "of", "for", "with", "from"}
# Not titles of Glimmer's own: what the person named or typed, the system's own items, and words that are written their own way.
OWN_WAY = {"px", "pt", "mm", "cm", "in", "dpi", "ppi", "sRGB", "macOS", "iPhone", "iPad", "fal.ai", "x", "×", "e.g."}
SKIP = re.compile(r"^(?:.*\.(?:png|jpe?g|heic|tiff?|webp|psd|glimmer|dng|raw)|Untitled.*|accessibility|walk|.*\d+ ?%.*|[^A-Za-z]*)$", re.I)

def problem(title):
    text = re.sub(r"[“\"].*?[”\"]", "Q", title)           # a quoted name inside a title is the person's
    text = re.sub(r"\(.*?\)", "", text).replace("…", "").strip()   # a parenthesis is a note, not the title
    words = [w for w in re.split(r"[\s/–—]+", text) if w]
    bad = []
    for i, word in enumerate(words):
        core = word.strip(".,:;!?'’›→+-")
        if not core or not core[0].isalpha() or core in OWN_WAY: continue
        if any(c.isupper() for c in core[1:]) and core[0].islower(): continue   # iPhone-like
        first_or_last = i == 0 or i == len(words) - 1
        if core[0].islower() and (core.lower() not in SMALL or first_or_last): bad.append(core)
        if core[0].isupper() and core.lower() in ALWAYS_SMALL and not first_or_last and not (i > 0 and words[i - 1].endswith(":")):
            bad.append(core + " (should be lower case)")
    return bad

seen, fails = {}, 0
for path in sys.argv[1:]:
    for line in open(path, encoding="utf8"):
        kind, _, title = line.rstrip("\n").partition("\t")
        if title and not SKIP.match(title): seen.setdefault((kind, title), path)
for (kind, title), path in sorted(seen.items()):
    bad = problem(title)
    if bad:
        fails += 1
        print(f"✘ {kind}: “{title}” ({', '.join(bad)})")
menus = sum(1 for k, _ in seen if k == "menu"); buttons = len(seen) - menus
print(f"{fails} of {len(seen)} titles are not in Title Case." if fails else f"All {menus} menu items and {buttons} button titles are in Title Case.")
sys.exit(1 if fails else 0)
