#!/usr/bin/env python3
"""What a text of the app reads as in a given language, for scripts that look for it on screen:
    scripts/catalog-text.py <lang> <English text>     → a pattern for grep -E
    scripts/catalog-text.py --exact <lang> <title>    → the same for a menu title (a whole key or nothing)
So one script serves every language: it names texts as the source does, and looks for what the
catalogue (App/Localizable.xcstrings) makes of them in the test copy's language.
The English text may be: a catalogue key as it is; a sentence with values filled in ("Send this to
Berget?" for the key "Send this to %@?": the values are carried over, translated when they are
texts of the app themselves); or a part of one key (the pattern is then that key's translation,
with anything where its values go). A text the catalogue doesn't have is data (a layer's name,
a file's name, a service's own words) and is looked for as it is.
A few menu titles belong to macOS, not to the catalogue; they are listed here."""
import json, os, re, sys
exact = "--exact" in sys.argv          # a menu title: the key as it is, or the words as they are; never a part of another text
lang, text = [a for a in sys.argv[1:] if a != "--exact"][:2]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
catalog = json.load(open(os.path.join(root, "App/Localizable.xcstrings")))["strings"]
SYSTEM = {"sv": {"File": "Arkiv", "Edit": "Redigera", "View": "Innehåll", "Window": "Fönster", "Help": "Hjälp", "Settings…": "Inställningar…"}}
PLACE = r"%(?:\d+\$)?(?:@|lld|ld|d|lf)"

def said(key):
    """The key in the language asked for (the key itself for English, or when it has no translation)."""
    if lang == "en": return key
    unit = (catalog.get(key, {}).get("localizations") or {}).get(lang, {}).get("stringUnit", {})
    return unit.get("value", key)

def fill(translation, values):
    """The translation with its values put in; numbered placeholders take the value of that number."""
    order = iter(values)
    def one(m):
        n = re.match(r"%(\d+)\$", m.group(0))
        return values[int(n.group(1)) - 1] if n else next(order, "")
    return re.sub(PLACE, one, translation).replace("%%", "%")

def pattern_of(key_or_translation, loose):
    """A regular expression for a text with placeholders: each placeholder is a group (strict) or anything (loose)."""
    pieces = re.split(PLACE, key_or_translation)
    return ("(.*)" if loose else "(.+?)").join(re.escape(p.replace("%%", "%")) for p in pieces)

if lang != "en" and text in SYSTEM.get(lang, {}) and text not in catalog:
    print(re.escape(SYSTEM[lang][text])); sys.exit()
if text in catalog:                                   # 1. a key as it is
    print(pattern_of(said(text), True).replace("(.*)", ".*")); sys.exit()
if exact: print(re.escape(text)); sys.exit()
best = None                                           # 2. a key with values filled in: the one with the most words of its own
for key in catalog:
    if not re.search(PLACE, key): continue
    own = len(re.sub(PLACE, "", key).strip())
    if own < 4 or (best and own <= best[0]): continue   # ("%@" alone would match anything)
    m = re.match("^" + pattern_of(key, False) + "$", text, re.S)
    if m: best = (own, key, m.groups())
if best:
    values = [said(v) if v in catalog else v for v in best[2]]
    print(re.escape(fill(said(best[1]), values))); sys.exit()
part = [k for k in catalog if text in k and len(text) >= 8]   # 3. a part of one key
if part:
    print(pattern_of(said(min(part, key=len)), True).replace("(.*)", ".*")); sys.exit()
print(re.escape(text))                                # 4. data
