"""Makes the documentation's example images that are missing in this folder.

Uses google/gemini-3-pro-image on OpenRouter (3:2, 2K) and saves them as JPEG (quality 95), about USD 0.13 per
image, billed by OpenRouter. Usage:

    OPENROUTER_API_KEY=... python3 -I site/source-images/generate.py
"""
import base64
import json
import os
import subprocess
import urllib.request

here = os.path.dirname(os.path.abspath(__file__))
key = os.environ["OPENROUTER_API_KEY"]
prompts = json.load(open(os.path.join(here, "prompts.json")))

for name, prompt in prompts.items():
    path = os.path.join(here, name)
    if os.path.exists(path):
        print("skip", name)
        continue
    body = {
        "model": "google/gemini-3-pro-image",
        "messages": [{"role": "user", "content": prompt}],
        "modalities": ["image", "text"],
        "image_config": {"aspect_ratio": "3:2", "image_size": "2K"},
    }
    request = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json", "X-Title": "Glimmer docs"},
    )
    try:
        response = json.load(urllib.request.urlopen(request, timeout=300))
    except Exception as error:
        print("FAIL", name, str(error)[:200])
        continue
    message = response["choices"][0]["message"]
    images = message.get("images") or []
    if not images:
        print("NO IMAGE", name, (message.get("content") or "")[:200])
        continue
    data = base64.b64decode(images[0]["image_url"]["url"].split(",", 1)[1])
    png = os.path.splitext(path)[0] + ".png"
    with open(png, "wb") as f:
        f.write(data)
    # The repo keeps a high-quality JPEG; the PNG original stays local (.gitignore).
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "95", png, "--out", path],
                   check=True, capture_output=True)
    print("ok", name, len(data), "bytes, cost", response.get("usage", {}).get("cost"))
