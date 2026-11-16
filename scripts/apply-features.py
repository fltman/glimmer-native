#!/usr/bin/env python3
"""Makes the site's manual and FAQ say what the release build has: for every feature in
Config/Features.xcconfig, puts the "on" or the "off" wording from Config/site-features.json
into the files it names. With --check it changes nothing and fails when a file is out of step.
Run by scripts/export-agents-guide.sh; the package tests run the check."""
import json, os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
flags = dict(re.findall(r"^GLIMMER_(\w+)\s*=\s*(YES|NO)\s*$", open(os.path.join(root, "Config/Features.xcconfig")).read(), re.M))
check, stale = "--check" in sys.argv, []
for feature, pairs in json.load(open(os.path.join(root, "Config/site-features.json"))).items():
    on = flags.get(feature.upper()) == "YES"
    for p in pairs:
        path = os.path.join(root, p["file"])
        text = open(path).read()
        want, other = (p["on"], p["off"]) if on else (p["off"], p["on"])
        # "off" is always the start of "on" here, so finding the shorter one proves nothing by itself.
        if want in text and (other not in text or len(want) > len(other)): continue
        if other not in text: sys.exit(f"apply-features: can't find the {feature} wording in {p['file']}.")
        if check: stale.append(p["file"])
        else:
            # The wording in the file is neither of the two here: it was changed in the JSON alone.
            # Putting the new text in beside the old would double a whole section (it did once).
            heading = want.strip().split("\n")[0]
            if heading.startswith("#") and heading in text and heading not in other:
                sys.exit(f"apply-features: {p['file']} already has “{heading}” in another wording. Change the file and Config/site-features.json together.")
            open(path, "w").write(text.replace(other, want, 1))
# The package manifest carries the switches as a comment, so that its text changes when they do
# (Xcode re-reads a manifest only then).
manifest = os.path.join(root, "Packages/GlimmerKit/Package.swift")
text = open(manifest).read()
line = "// features: " + " ".join(f"{k}={flags[k]}" for k in sorted(flags))
now = re.sub(r"^// features: .*$", line, text, count=1, flags=re.M)
if line not in now: sys.exit("apply-features: Package.swift has no '// features:' line.")
if now != text:
    if check: stale.append("Packages/GlimmerKit/Package.swift")
    else: open(manifest, "w").write(now)
if stale: sys.exit("The site is out of step with Config/Features.xcconfig: run scripts/export-agents-guide.sh (" + ", ".join(sorted(set(stale))) + ")")
