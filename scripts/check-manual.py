#!/usr/bin/env python3 -I
"""Every menu path and shortcut the manual and the FAQ name exists in the app.

    scripts/check-manual.py [<menus file>]        exit 0 = holds

The menus file is what the running English app says its menus are: one "Menu › Submenu › Item<TAB>shortcut"
per line (`build/axread <pid> --menus`). Config/menus-en.txt is the kept copy; scripts/test-accessibility.sh
reads the menus again on every English pass and fails when they differ from it, so the copy cannot go stale
unnoticed.

Checked in site/manual/*.md and site/faq.md:
  - a bold path that starts at a menu (**File › Batch Process…**) names an item that exists at that path
  - a shortcut in brackets right after such a path (**File › Open…** (⌘O)) is that item's shortcut
  - every ⌘ shortcut in the tables of the keyboard chapter belongs to some menu item
"""
import glob, os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
menus = {}
for line in open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "Config/menus-en.txt"), encoding="utf8"):
    path, _, key = line.rstrip("\n").partition("\t")
    if path: menus[path] = key
tops = {p.split(" › ")[0] for p in menus}
# Not menu items, though written with ›: Settings' tabs, items whose title carries a name, and what only a release build has.
def excused(path):
    parts = path.split(" › ")
    if len(parts) > 1 and parts[0] == "Glimmer" and parts[1] in ("Settings", "Settings…") and len(parts) > 2: return True   # Glimmer › Settings › AI
    if path == "File › Save Back to": return True                    # "Save Back to <the file's name>"
    if path == "Glimmer › Check for Updates…": return True           # release builds only (Sparkle is off in a Debug build)
    if path == "File › Export… › Photoshop File…": return True       # a choice inside the Export sheet
    if path == "File › Save a Glimmer Copy…": return True            # only in a window that edits a linked file
    if path in ("Edit › Undo", "Edit › Redo"): return True           # the item names the step ("Undo Brush Stroke")
    return False
# Keys that are not letters or digits sit in different places on different keyboards, and the app reports them as
# this Mac's layout has them (⌘' is read as ⌘¨ on a Swedish keyboard): they are not compared.
def comparable(key): return bool(re.fullmatch(r"[⌃⌥⇧]*⌘[A-Z0-9]", key))
# Shortcuts that belong to no menu item: handled by the canvas or by one window (checked in the source 2026-11-17).
NOT_IN_MENUS = {"⌘Y": "a second Redo (CanvasView)", "⇧⌘C": "Copy in the Agent Access window",
                "⌘Z": "Undo, whose menu item carries the step's name and is left out of the kept copy"}
def norm(s): return s.replace("...", "…").strip()
found = []
keys_in_menus = {k for k in menus.values() if k}
for path_ in sorted(glob.glob(os.path.join(root, "site/manual/*.md"))) + [os.path.join(root, "site/faq.md")]:
    name = os.path.basename(path_)
    for number, line in enumerate(open(path_, encoding="utf8"), 1):
        for m in re.finditer(r"\*\*([^*]+?›[^*]+?)\*\*(?:\s*\(([^)]{1,12})\))?", line):
            item = " › ".join(norm(p) for p in m.group(1).split("›"))
            if item.split(" › ")[0] not in tops or excused(item): continue
            if item not in menus:
                found.append(f"{name}:{number}: no menu item “{item}”")
                continue
            said = (m.group(2) or "").strip()
            if said and re.search(r"[⌘⌥⇧⌃]", said) and " " not in said:
                if comparable(said) and comparable(menus[item] or "⌘0") and menus[item] != said: found.append(f"{name}:{number}: “{item}” is said to be {said}; the app has {menus[item] or 'no shortcut'}")
        if name.startswith("15-") and line.startswith("|"):
            for key in re.findall(r"(?<![A-Za-z0-9])([⌃⌥⇧]*⌘[A-Z0-9,.;'\[\]/\\=+\-⌫↩⇥]|[⌃⌥⇧]*⌘(?:Space))(?![A-Za-z0-9])", line.split("|")[1] if line.count("|") > 2 else ""):
                if comparable(key) and key not in keys_in_menus and key not in NOT_IN_MENUS: found.append(f"{name}:{number}: the shortcut {key} belongs to no menu item")
for f in found: print("✘ " + f)
print(f"{len(found)} place(s) where the manual and the menus differ." if found else f"Every menu path and shortcut in the manual and the FAQ is in the app ({len(menus)} menu items read).")
sys.exit(1 if found else 0)
