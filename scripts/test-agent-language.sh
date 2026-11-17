#!/bin/zsh
# What an agent is told is English whatever language the app shows (SIBLINGS.md, "Språk"):
# errors, reasons, statuses and the names of undo steps. Runs the API against a copy started
# in Swedish and fails on any error body, step result or undo name that is not English.
# Names of layers and documents are the document's content and are not checked.
#
#   scripts/test-agent-language.sh
#
# The no-network copy through scripts/test-app.sh (GUI lock, no key). Exit 0 = passed.
set -uo pipefail
cd "$(dirname "$0")/.."
# No error an agent can be given is put into the app's language where it is made (they are
# translated where the window shows them, PersonMessage): checked in the source too, since
# some of them need a saved key to be reached and no test copy has one.
if grep -rnE '(Error|APIError)[A-Za-z]*\([^)]*String\(localized' App --include='*.swift' | grep -v '^App/DebugFixtures.swift'; then
  echo "✘ an error is written in the app's language at the source (above)"; exit 1
fi
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  COPY=$(scripts/offline-copy.sh | tail -1) || exit 1
  GLIMMER_ARGS="-AppleLanguages (sv) -AppleLocale sv_SE -ai.imageProvider fal -ai.imageNoticeShown.fal YES -linkAnyOpen Flimmer" GLIMMER_TEST_LIMIT=240 GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$0"
fi
# A file handed over as by a sibling, then taken away: the document's linkedFile says why it can't be saved back.
LINKDIR="$PWD/build/agent-language-link"; rm -rf "$LINKDIR"; mkdir -p "$LINKDIR"; cp site/source-images/mug.png "$LINKDIR/handed.png"
open -a "$GLIMMER_APP" "$LINKDIR/handed.png"; sleep 4; rm -rf "$LINKDIR"; sleep 3
SHOWN=$(perl -e 'alarm 15; exec @ARGV' osascript -e "tell application \"System Events\" to tell (first process whose unix id is $GLIMMER_PID) to get name of every menu bar item of menu bar 1" 2>/dev/null)
python3 -I - "$GLIMMER_PORT" "$PWD/site/source-images/mug.jpg" "$SHOWN" "$PWD/App/Localizable.xcstrings" <<'PY'
import json, re, sys, urllib.request, urllib.error
port, image, shown, catalog = sys.argv[1:5]
base = f"http://127.0.0.1:{port}/api/v1"
fails = 0
def call(method, path, body=None, content="application/json"):
    data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method, headers={"X-Glimmer-Agent": "1", "Content-Type": content})
    try:
        with urllib.request.urlopen(req, timeout=120) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()
def check(what, ok, detail=""):
    global fails
    print(("✔ " if ok else "✘ ") + what + (f" ({detail})" if detail and not ok else ""))
    if not ok: fails += 1
# Swedish, by its letters and by words that English does not have; and by the catalogue: no text told to an agent may be one of the app's Swedish texts.
strings = json.load(open(catalog))["strings"]
swedish_texts = {v["localizations"]["sv"]["stringUnit"]["value"] for k, v in strings.items() if v.get("localizations", {}).get("sv", {}).get("stringUnit", {}).get("value") not in (None, k) and len(k) > 6 and "%" not in k}
words = re.compile(r"\b(och|inte|är|för|att|ett|eller|välj|lägg|kan|finns|ingen|inget|måste|saknas|bilden|lagret|markering|ångra|steg|på|från|här|det|som|inställningar|nyckel)\b", re.I)
def swedish(text):
    if re.search(r"[åäöÅÄÖ]", text): return "has å, ä or ö"
    m = words.search(text)
    if m: return f"has the word “{m.group(0)}”"
    if text in swedish_texts: return "is one of the app's Swedish texts"
    return None
def told(raw):
    """Every text an answer tells the agent about what went wrong or was done: error messages, step errors, undo names."""
    try: d = json.loads(raw)
    except Exception: return [raw.decode("utf8", "replace")[:200]]
    out = []
    e = d.get("error")
    if isinstance(e, dict): out += [str(e.get(k)) for k in ("message", "code", "reason") if e.get(k)]
    for r in d.get("results", []) + (d.get("job", {}).get("result", {}) or {}).get("results", []):
        if r.get("error"): out.append(r["error"])
        out.append(r.get("status", ""))
    for k in ("undone", "redone"):
        if d.get(k): out.append(d[k])
    return out
check(f"the copy is showing Swedish (its menus: {shown[:60]})", "Arkiv" in shown and "File" not in shown, shown)
linked = [d["linkedFile"] for d in json.loads(call("GET", "/documents")[1])["documents"] if d.get("linkedFile")]
reason = linked[0].get("reason", "") if linked else ""
check(f"a linked file that is gone: its reason is told in English ({reason[:90]})", linked and linked[0].get("available") is False and "no longer where it was" in reason and not swedish(reason), str(linked)[:200])
code, raw = call("POST", "/documents?name=walk", open(image, "rb").read(), "image/jpeg")
doc = json.loads(raw)["document"]["id"]
S = f"/documents/{doc}/steps"
cases = [
    ("an unknown operation", "POST", S, {"steps": [{"op": "no_such_op", "params": {}}]}),
    ("an unknown parameter", "POST", S, {"steps": [{"op": "crop", "params": {"aspect": "1:1", "zz": 1}}]}),
    ("a malformed step", "POST", S, {"steps": [{"params": {}}]}),
    ("a paid step without allowPaid", "POST", S, {"steps": [{"op": "generate_layer", "params": {"prompt": "a bird"}}]}),
    ("a paid step without a key for the chosen service", "POST", S, {"steps": [{"op": "generate_layer", "params": {"prompt": "a bird"}}], "allowPaid": True, "allowUnknownPrice": True}),
    ("a step that fails: a font that is not installed", "POST", S, {"steps": [{"op": "add_text", "params": {"text": "Hi", "font": "No Such Font 77"}}]}),
    ("a step that fails: an adjustment that does not exist", "POST", S, {"steps": [{"op": "add_adjustment", "params": {"type": "no_such_adjustment"}}]}),
    ("a step that fails: a layer that does not exist", "POST", S, {"steps": [{"op": "set_layer", "params": {"layer": "no-such-layer", "opacity": 0.5}}]}),
    ("a step that fails: nothing selected to fill from", "POST", S, {"steps": [{"op": "heal_selection", "params": {}}]}),
    ("a step that fails: transform with bad corners", "POST", S, {"steps": [{"op": "transform_layer", "params": {"corners": [[0, 0]]}}]}),
    ("a document that does not exist", "GET", "/documents/00000000-0000-0000-0000-000000000000", None),
    ("an image that is not an image", "POST", "/documents?name=x", b"this is not an image"),
    ("a body that is not JSON", "POST", S, b"{nope"),
    ("redo with nothing to redo", "POST", f"/documents/{doc}/redo", None),
    ("a RAW request on a layer without a RAW file", "GET", f"/documents/{doc}/raw", None),
    ("a wrong method", "DELETE", "/operations", None),
]
errors = 0
for what, method, path, body in cases:
    code, raw = call(method, path, body, "application/json" if not isinstance(body, bytes) or body.startswith(b"{") else "image/png")
    texts = told(raw)
    is_error = code >= 400 or any(t == "failed" for t in texts)
    errors += is_error
    bad = [(t, swedish(t)) for t in texts if swedish(t)]
    check(f"{what}: {code}, told in English ({'; '.join(t for t in texts if len(t) > 12)[:110]})", is_error and not bad, f"not an error ({code})" if not is_error else str(bad)[:300])
check(f"at least 12 of the {len(cases)} requests were refused or failed (so there was something to read): {errors}", errors >= 12)
# The names of undo steps: a steps request is "Agent Edit", and the app's own names come back as written in English.
call("POST", S, {"steps": [{"op": "add_adjustment", "params": {"type": "black_white"}}]})
code, raw = call("POST", f"/documents/{doc}/undo")
name = json.loads(raw).get("undone")
check(f"undoing a steps request names it “Agent Edit” (got “{name}”)", name == "Agent Edit")
code, raw = call("POST", f"/documents/{doc}/redo")
name = json.loads(raw).get("redone")
check(f"redoing it names it the same (got “{name}”)", name == "Agent Edit")
code, raw = call("POST", f"/documents/{doc}/layers?name=second", open(image, "rb").read(), "image/jpeg")
code, raw = call("POST", f"/documents/{doc}/undo")
name = json.loads(raw).get("undone", "")
check(f"undoing an added layer names the step in English (got “{name}”)", code == 200 and name and not swedish(name) and name in strings, name)
print(f"{fails} check(s) failed." if fails else "All checks passed.")
sys.exit(1 if fails else 0)
PY
