---
name: scantailor-reborn
description: Turn scanned or photographed books (PDF) into clean, uniform, searchable black-and-white PDFs with the scantailor-cli tool, and fix pages that automatic layout gets wrong through an adjustments file. Use when the user wants to clean up, deskew, split, re-margin, resize or OCR a scanned book or article PDF, or wants to inspect or correct the layout of such a run.
---

# ScanTailorReborn (`scantailor-cli`)

Turns a raw book scan PDF into a 300 DPI, 1-bit, searchable PDF with uniform pages. You drive it as a loop: plan cheaply, look, correct only what is wrong, then render once.

## 0. Check the tool first

Run `command -v scantailor-cli`. If it prints nothing, **stop** and tell the user it is not installed. Do not guess at other tools. Offer:

```
brew tap AthanasiusOfAlex/scantailor-reborn && brew install scantailor-reborn
```

or, from source (macOS 14+, Swift 6, `brew install tesseract`):
`git clone https://github.com/AthanasiusOfAlex/ScanTailorReborn.git && cd ScanTailorReborn && swift build -c release`, then put `.build/release/scantailor-cli` on the `PATH`.

`scantailor-cli --help` is the authoritative option list; trust it over this file if they differ.

## 1. Ask what you cannot see

Before the first run, find out (ask only what is not already clear):
- Languages of the text (`--ocr-languages`, e.g. `grc+lat+eng`, `frk`). Greek or Fraktur selects the dual OCR engine automatically.
- Flatbed scans (add `--no-dewarp --no-perspective`) or camera photos (leave the defaults).
- Whether the output size is known (`--page-size 6x9in` or `--content-box-size`). Otherwise it is estimated from the type size.
- Whether the first scanned page is a recto (default) or verso (`--first-page-side verso`).

## 2. Plan the layout only (fast: no PDF, no OCR)

```
scantailor-cli process book.pdf --stop-after layout --diagnostics-dir d/ [options]
scantailor-cli inspect d/book-layout-manifest.json --pages
```

The manifest is named `<input-stem>-layout-manifest.json`. `inspect --pages` prints one line per output page (scan, side, tier, page size, text size, margins, skew, confidence, notes). `inspect --json` is the same data for programs. Contact sheets are `d/layout-sheet-NN.png` (red: canonical frame, green: text block, orange: outlier); `d/page-NNNN-diag.png` overlays exist for low-confidence pages. Look at the images, not only the numbers.

Pages worth checking: those marked `LOW-CONF` or flagged in "Pages to check", pages whose margins differ from their neighbours', and any page marked as an outlier.

If the manifest says `physicalScaleAmbiguous: true` (page would come out far larger than a book), **ask the user** for the page size instead of choosing one: octavo, trade paperback, A5, A4, or custom `<w>x<h>`; then pass `--page-size`.

## 3. Correct with an adjustments file

Write `adjustments.json`, then rerun step 2 with `--apply-manifest adjustments.json`. Repeats are fast because unchanged scans come from the cache. The run reports which entries were applied and which were ignored; check that report. Mistakes are all reported before any work starts.

```json
{
  "version": 1,
  "book":  { "page-size": "octavo", "margins": "0.75in", "outlier-pages": "1,s45L" },
  "scans": { "s12": { "split": "single" }, "s30": { "splitX": "52%", "disableRectification": true } },
  "pages": { "s45L": { "skew": -0.4, "contentBox": { "nudge": { "top": "-2mm", "bottom": "+0.1in" } } },
             "77":   { "tier": "standaloneFloating", "keep": true },
             "s88":  { "contentBox": { "rect": ["1.0in", "1.2in", "4.1in", "6.6in"] }, "offset": { "y": "+1mm" } } }
}
```

- **Names**: `"45"` = output page 45 of the run you are looking at; `"s12"` = scan 12 of the source PDF (counted from the start of the PDF, even with `--page-range`); `"s12L"`/`"s12R"` = halves of a split scan. **Prefer scan names**: they survive changes in splitting and pruning. More specific names win.
- **`book`**: any ordinary option, flag name without `--`. Flags on the command line win.
- **`scans`**: `split` (`single`|`spread`|`auto`), `splitX` (`"52%"` or a length), `disableRectification`, `disableDeskMask`.
- **`pages`**: `skew` (degrees), `disableDewarp`, `contentBox.rect` `[left, top, right, bottom]`, `contentBox.nudge` (positive moves an edge right/down), `offset` `{x,y}`, `tier` (`fullBody`|`edgeAnchoredPartial`|`standaloneFloating`), `outlier`, `pageSize`, `keep`, `drop`, `runningHeader` (`automatic`|`present`|`absent`), `verticalRegistration` (`automatic`|`anchor`|`boxTop`), `borderFallback` (`automatic`|`forced`|`disabled`).
- Lengths need a unit: `in`, `mm`, `cm`, `pt`, `px` (px of the 600 DPI raster). Keys starting with `_` and `note` are ignored: use them to explain each edit.

Manual entries always beat automatic detection. An exact `--outlier-pages` list replaces automatic outlier detection completely.

## 4. Know the layout rules before "fixing" things

- Canvas = largest clean text block + 0.25 in top/bottom + 0.5 in left/right. Every page is centered.
- Pages with a running header hang from the top; headerless pages that run to the foot (chapter openings) sit on the bottom; floating pages (title, dedication) keep their offset. A page that looks "wrong" may be following these rules; change its `tier` only when it really is classified wrongly.
- Covers, plates and foldouts get their own page size (outliers). Blank pages are dropped only before the first and after the last page with content.
- JSTOR, Project MUSE, Google Books and Internet Archive cover sheets are dropped by default (`--cover-handling auto|strip|keep`).

## 5. Render

When the layout looks right, run without `--stop-after`:

```
scantailor-cli process book.pdf -o book-clean.pdf --apply-manifest adjustments.json [options]
```

OCR for unchanged pages is reused. Add `--timings` to see where time goes; `-j N` sets parallelism (default 4; memory grows with it). `--no-cache` ignores the cache; `--cache-dir` moves it.

## Habits

- Never overwrite the user's original PDF; write to a new path.
- Keep every run's `adjustments.json` and tell the user where it is, so the result can be reproduced.
- Report in the user's terms: which pages you changed and why, and which pages remain doubtful.
- Don't invent flags. If you need something the CLI lacks, say so.
