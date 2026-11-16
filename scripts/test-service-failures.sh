#!/bin/zsh
# When a service refuses, or answers with something that can't be used, the document is left as it was:
# no layer, no undo step, and the service's own words come back. Run against a test copy that calls a
# stand-in on this Mac (127.0.0.1) instead of OpenRouter, with a key that is no key: nothing leaves the
# Mac and nothing can be billed. This is the path every picture service shares after its own adapter
# (the adapters' handling of refusals is tested one by one in the package).
#   scripts/test-service-failures.sh
set -u
cd "$(dirname "$0")/.."
if [[ -z "${GLIMMER_PORT:-}" ]]; then
  FAKE_PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')
  export FAKE_PORT FAKE_MODE=$(mktemp -t glimmer-fake-mode)
  GLIMMER_FAKE_SERVICE="http://127.0.0.1:$FAKE_PORT" exec scripts/test-app.sh "$0"
fi
python3 -I - "$FAKE_PORT" "$FAKE_MODE" <<'PY' &
import sys, json, http.server
port, mode_file = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        mode = open(mode_file).read().strip()
        open(mode_file + ".calls", "a").write(mode + "\n")
        if mode == "refusal": code, body, kind = 422, json.dumps({"error": {"message": "This request cannot be served: the account is restricted (ref 7Q-ZETA).", "code": 422}}), "application/json"
        elif mode == "nopicture": code, body, kind = 200, json.dumps({"id": "x", "model": "m", "choices": [{"index": 0, "finish_reason": "stop", "message": {"role": "assistant", "content": "Here is your picture!"}}]}), "application/json"
        else: code, body, kind = 200, "<html><body>Gateway says hello</body></html>", "text/html"
        self.send_response(code); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(body.encode()))); self.end_headers(); self.wfile.write(body.encode())
    do_GET = do_POST
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
FAKE_PID=$!
trap 'kill $FAKE_PID 2>/dev/null; rm -f "$FAKE_MODE" "$FAKE_MODE.calls"' EXIT
sleep 1
python3 -I - "$GLIMMER_PORT" "$FAKE_MODE" site/source-images/mug.jpg <<'PY'
import sys, json, urllib.request, urllib.error
port, mode_file, image = sys.argv[1], sys.argv[2], sys.argv[3]
base = f"http://127.0.0.1:{port}/api/v1"
fails = 0
def call(method, path, body=None, content="application/json"):
    data = body if isinstance(body, (bytes, type(None))) else json.dumps(body).encode()
    req = urllib.request.Request(base + path, data=data, method=method, headers={"X-Glimmer-Agent": "1", "Content-Type": content})
    try:
        with urllib.request.urlopen(req, timeout=180) as r: return r.status, r.read()
    except urllib.error.HTTPError as e: return e.code, e.read()
def check(what, ok, detail=""):
    global fails
    print(("✔ " if ok else "✘ ") + what + (f" ({detail})" if detail and not ok else ""))
    if not ok: fails += 1
code, raw = call("POST", "/documents?name=failures", open(image, "rb").read(), "image/jpeg")
doc = json.loads(raw)["document"]["id"]
def fingerprint():
    d = json.loads(call("GET", f"/documents/{doc}")[1])["document"]
    return json.dumps([d["width"], d["height"], d["layers"], d.get("hasSelection")], sort_keys=True)
before = fingerprint()
def calls():
    try: return len(open(mode_file + ".calls").read().split())
    except FileNotFoundError: return 0
steps = {"generate_layer": {"prompt": "a red ball"}, "image_edit_composite": {"instruction": "make the mug red"}}
import time
def finished(code, raw):
    """A paid step runs as a job: wait for it and give back what it ended as."""
    try: job = json.loads(raw).get("job")
    except Exception: job = None
    if not job: return code, raw.decode("utf8", "replace")
    for _ in range(240):
        c, r = call("GET", f"/jobs/{job['id']}")
        text = r.decode("utf8", "replace")
        try: status = json.loads(r)["job"]["status"]
        except Exception: status = "?"
        if status not in ("queued", "running"): return c, text
        time.sleep(0.5)
    return 0, "the job never finished"
# One free step first, so the newest undo step is a known one: after each failure, Undo must take back
# exactly that step (so the failure made none of its own), and Redo puts it back.
opened = fingerprint()
call("POST", f"/documents/{doc}/steps", {"steps": [{"op": "add_adjustment", "params": {"type": "black_white"}}]})
before = fingerprint()
check("the free step before the failures changed the document", before != opened)
for mode, what in (("refusal", "a refusal (HTTP 422 with the service's own sentence)"), ("nopicture", "an answer with no picture in it"), ("garbage", "a web page instead of an answer")):
    open(mode_file, "w").write(mode)
    for op, params in steps.items():
        n = calls()
        code, raw = call("POST", f"/documents/{doc}/steps", {"steps": [{"op": op, "params": params}], "allowPaid": True})
        code, text = finished(code, raw)
        reached = calls() > n
        check(f"{op}, {what}: the stand-in was called", reached, text[:160])
        failed = '"failed"' in text or code >= 400
        check(f"{op}, {what}: reported as failed, not done", failed and '"status" : "done"' not in text, text[:300])
        if mode == "refusal": check(f"{op}: the service's own words come back", "the account is restricted (ref 7Q-ZETA)" in text, text[:400])
        check(f"{op}, {what}: the document is as it was (layers, size, selection)", fingerprint() == before)
        code, raw = call("POST", f"/documents/{doc}/undo")
        check(f"{op}, {what}: no undo step was made (Undo takes back the step from before the failure)", code == 200 and fingerprint() == opened, raw[:160].decode("utf8", "replace"))
        call("POST", f"/documents/{doc}/redo")
        check(f"{op}, {what}: Redo puts that step back", fingerprint() == before)
print(f"{fails} check(s) failed." if fails else "All checks passed.")
sys.exit(1 if fails else 0)
PY
