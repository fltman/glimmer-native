# Example images for the documentation

The screenshots on glimmer.brattoo.com use these AI-generated example images, so the site never shows copyrighted or private pictures. They are invented scenes with no real people, brands or companies.

- `prompts.json`: one prompt per image (file name → prompt).
- `generate.py`: makes any image that is missing, with `google/gemini-3-pro-image` on OpenRouter (3:2, 2K), and saves it as JPEG at quality 95. The PNG originals stay local and are not committed. It costs about USD 0.13 per image, billed by OpenRouter.

```sh
OPENROUTER_API_KEY=… python3 -I site/source-images/generate.py
```

Keep the generated files here, so the same images are used every time the screenshots are retaken.
