#!/bin/zsh
# Every operation and every endpoint refuses a parameter it does not know, by name, before
# anything is applied (the series' rule, 2026-11-16). Walks the running app's own list of
# operations and sends each one an unknown parameter; then the endpoints' query parameters
# and bodies. The document must be untouched afterwards.
#
#   scripts/test-unknown-parameters.sh
#
# The no-network copy through scripts/test-app.sh (GUI lock, no key). Exit 0 = passed.
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  COPY=$(scripts/offline-copy.sh | tail -1) || exit 1
  GLIMMER_TEST_LIMIT=240 GLIMMER_TEST_APP="$COPY" exec scripts/test-app.sh "$0"
fi
python3 -I - "$GLIMMER_PORT" "$PWD/site/source-images/mug.jpg" <<'PY'
import json, sys, urllib.request, urllib.error
port, image = sys.argv[1], sys.argv[2]
base = f"http://127.0.0.1:{port}/api/v1"
fails = 0
def call(method, path, body=None, content="application/json"):
    data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method, headers={"X-Glimmer-Agent": "1", "Content-Type": content})
    try:
        with urllib.request.urlopen(req, timeout=120) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()
def message(raw):
    try: return json.loads(raw)["error"]["message"]
    except Exception: return raw[:80].decode("utf8", "replace")
def check(what, ok, detail=""):
    global fails
    print(("✔ " if ok else "✘ ") + what + (f" ({detail})" if detail and not ok else ""))
    if not ok: fails += 1
code, raw = call("POST", "/documents?name=walk", open(image, "rb").read(), "image/jpeg")
doc = json.loads(raw)["document"]["id"]
def fingerprint():
    d = json.loads(call("GET", f"/documents/{doc}")[1])["document"]
    return json.dumps([d["width"], d["height"], d["layers"], d.get("hasSelection")], sort_keys=True)
before = fingerprint()
ops = [o for o in json.loads(call("GET", "/operations")[1])["operations"] if "call" not in o]
let_through = []
for o in ops:
    code, raw = call("POST", f"/documents/{doc}/steps", {"steps": [{"op": o["name"], "params": {"zzNotAParameter": 1}}], "allowPaid": False})
    if not (code == 400 and "no parameter named zzNotAParameter" in message(raw)): let_through.append(f'{o["name"]} → {code}: {message(raw)[:70]}')
check(f"each of the {len(ops)} operations refuses a parameter it doesn't have, by name, with 400", not let_through, "; ".join(let_through))
code, raw = call("POST", f"/documents/{doc}/steps", {"steps": [{"op": "add_adjustment", "params": {"type": "black_white"}}, {"op": "crop", "params": {"aspect": "1:1", "zz": 1}}]})
check("a request with one bad step runs none of its steps", code == 400 and "No step of this request was run" in message(raw) and fingerprint() == before, message(raw))
code, raw = call("POST", f"/documents/{doc}/steps", {"steps": [{"op": "add_adjustment", "params": {"type": "exposure", "params": {"brightness": 0.2}}}]})
check("a setting its adjustment doesn't have is refused by name", code == 400 and "no parameter named brightness in params" in message(raw), message(raw))
code, raw = call("POST", f"/documents/{doc}/steps", {"steps": [{"op": "apply_filter", "params": {"type": "gaussian_blur", "params": {"amount": 3}}}]})
check("a setting its filter doesn't have is refused by name", code == 400 and "no parameter named amount in params" in message(raw), message(raw))
code, raw = call("POST", f"/documents/{doc}/steps", {"steps": [{"op": "crop", "aspect": "1:1"}]})
check("a setting beside \"op\" instead of inside \"params\" is refused", code == 400 and "no parameter named aspect" in message(raw) and "inside \"params\"" in message(raw), message(raw))
code, raw = call("POST", f"/documents/{doc}/steps", {"steps": [{"op": "auto_color"}], "dryRun": True})
check("an unknown name in the steps body is refused", code == 400 and "no parameter named dryRun" in message(raw), message(raw))
for method, path, body, name in [
    ("GET", f"/documents/{doc}/image?maxSide=64&size=3", None, "size"),
    ("GET", f"/documents/{doc}?verbose=1", None, "verbose"),
    ("GET", "/operations?tier=core", None, "tier"),
    ("POST", f"/documents/{doc}/export?format=png", {"format": "png"}, "format"),
    ("POST", f"/documents/{doc}/export", {"format": "png", "qualty": 0.5}, "qualty"),
    ("POST", f"/documents/{doc}/undo", {"steps": 2}, "steps"),
    ("POST", f"/documents/{doc}/layers?fit=cover&scale=2", {"fromDocument": doc}, "scale"),
    ("POST", "/documents?title=x", {"width": 10, "height": 10}, "title"),
    ("POST", "/documents", {"width": 10, "height": 10, "colour": "red"}, "colour"),
]:
    code, raw = call(method, path, body)
    check(f"{method} {path.split('?')[0].replace(doc, '{id}')} refuses “{name}”", code == 400 and f"no parameter named {name}" in message(raw), f"{code}: {message(raw)[:90]}")
check("the document is untouched after all of it", fingerprint() == before)
# `rationale` is the one name accepted everywhere, and every published schema is closed.
code, raw = call("GET", f"/documents/{doc}/image?maxSide=64&rationale=to%20look")
check("rationale is accepted in a query", code == 200, f"{code}")
code, raw = call("POST", f"/documents/{doc}/export", {"format": "png", "maxSide": 64, "rationale": "to show"})
check("rationale is accepted in a body", code == 200, f"{code}: {message(raw)[:80]}")
all_ops = json.loads(call("GET", "/operations")[1])["operations"]
open_ones = [o["name"] for o in all_ops if o["params"].get("additionalProperties") is not False or "rationale" not in o["params"]["properties"]]
check(f"each of the {len(all_ops)} published schemas is closed and has rationale", not open_ones, ", ".join(open_ones))
bare = [o["name"] for o in all_ops if "params" in o["params"]["properties"] and "x-byType" not in o["params"]["properties"]["params"]]
check("the nested settings are published per type", not bare, ", ".join(bare))
code, raw = call("POST", f"/documents/{doc}/steps", {"steps": [{"op": "add_adjustment", "params": {"type": "black_white", "rationale": "as asked"}}]})
check("and a proper step still runs", code == 200, message(raw))
print()
print("All unknown-parameter checks passed." if fails == 0 else f"{fails} check(s) failed.")
sys.exit(1 if fails else 0)
PY
