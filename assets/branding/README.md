# Repository artwork

| Export | Size | Editable source |
| --- | --- | --- |
| [`header.png`](header.png) | 2243 × 701 | [`header.html`](header.html) |
| [`social-preview.png`](social-preview.png) | 1280 × 640 | [`social-preview.html`](social-preview.html) |

The header PNG is the approved Host Grotesk ExtraBold version. The social
preview uses the same logo and the README's one-sentence tagline.

## Preview and remake

From the repository root:

```sh
python3 -m http.server 8767 --bind 127.0.0.1 --directory assets/branding
```

Open:

- `http://127.0.0.1:8767/header.html`
- `http://127.0.0.1:8767/social-preview.html`
- `http://127.0.0.1:8767/checks.html`

The sources need no build tools or internet access once served. Font files and
the original image are included, so another font release cannot silently
change the result. Edit the title/font constants in `header.html`, or the
HTML and CSS in `social-preview.html`.

To export with Playwright, set the viewport to the export's dimensions, wait
for `window.headerReady` on the header or `document.fonts.ready` on the social
page, then capture `#artwork` with `scale: 'css'`. This avoids accidentally
exporting double-size PNGs on a Retina display:

```js
await page.locator('#artwork').screenshot({ path: 'social-preview.png', scale: 'css' });
```

Run `checks.html` before submitting an artwork change. Its standalone browser
checks cover real font loading, preservation of the header's approved artwork,
the logo crop, the tagline, the safe area, PNG dimensions, and GitHub's
under-1-MB social-image limit. For automation, await `window.brandingChecks`
and require `failed === 0`. These complement the app's `sh tests/run.sh`.

## Social-image safe area

Keep important content inside **x = 80…1200, y = 80…560**. This matches the
roughly 80px guides in the supplied GitHub template and comfortably exceeds
40 CSS points. The checks inspect both actual rendered content bounds and the
exported PNG's outer border.

GitHub recommends a 1280 × 640 PNG, JPG, or GIF under 1 MB. The exported PNG is
ready to upload under the repository's **Settings → Social preview**; merely
committing it does not change that GitHub setting.

## Artwork and fonts

`original.png` preserves the generated source artwork. The header renderer
replaces its baked-in original lettering with real Host Grotesk 800, while the
social renderer crops its unchanged recovery mark. The mark is **raster
artwork**, not an editable vector logo. Typography and layout are editable code.
[`original-image-prompt.txt`](original-image-prompt.txt) preserves the original
generation brief if the illustration itself needs to be remade.
If the illustration's composition changes, update the header's replacement
rectangle and the social page's SVG crop, then rerun the browser checks.

Host Grotesk is by Element Type, Doğukan Karapınar, and İbrahim Kaçtıoğlu.
The bundled ExtraBold (800) and Medium (500) files retain their
[SIL Open Font License](OFL.txt), rather than the repository's MIT license.
