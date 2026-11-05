# ScanTailorReborn

**ScanTailorReborn** is a command-line tool, written in pure **Swift 6** for macOS, that turns raw book scans and smartphone photos into clean, compact, searchable black-and-white PDFs with uniform page layout.

It is an independent project inspired by Scan Tailor, not a fork of it. Its executable is called `scantailor-reborn-cli`.

---

## What it does

- **Cleans each page**: removes desk, finger, scanner-bed and page-edge shadows; corrects camera perspective; deskews (±0.05°); flattens uneven lighting; binarizes adaptively (Wolf-Jolion or Sauvola); dewarps curved pages near the spine.
- **Splits spreads**: finds the gutter in two-page spreads and cuts out the crease.
- **Lays the whole book out consistently**: pages share one size, are centered, and keep their running headers on the same line (see [Layout rules](#layout-rules)).
- **Handles odd pages**: drops repository cover sheets (JSTOR, Project MUSE, Google Books, Internet Archive), keeps covers, plates and foldouts on their own page size, and removes blank pages only at the start and end.
- **Adds a searchable text layer**: Apple Vision, Tesseract, or both together (polytonic Greek, Latin and Fraktur supported).
- **Writes compact PDFs**: 300 DPI, 1-bit, CCITT Group 4, with one shared font for the whole invisible text layer.
- **Is built for iteration**: a fast layout-only run, per-page reports, contact sheets, and an adjustments file for the cases automatic detection cannot settle. Repeat runs reuse a cache.

---

## Installation

### Requirements
- macOS 14 (Sonoma) or later
- Swift 6.0 toolchain (Xcode 16 or later)
- Tesseract and Leptonica, for building and for the Tesseract OCR engine: `brew install tesseract`. For more languages: `brew install tesseract-lang`.

### Homebrew (from v1.0.0)

```bash
brew tap AthanasiusOfAlex/scantailor-reborn
brew install scantailor-reborn
```

### Build from source

```bash
git clone https://github.com/AthanasiusOfAlex/ScanTailorReborn.git
cd ScanTailorReborn
swift build -c release
cp .build/release/scantailor-reborn-cli /usr/local/bin/    # optional
```

### Tests

```bash
scripts/test.sh fast      # quick suite
swift test                # everything
```

---

## Quick start

```bash
scantailor-reborn-cli process book.pdf -o book-clean.pdf
```

With no options this splits spreads, cleans, lays out, runs Apple Vision OCR and writes a 300 DPI 1-bit PDF. A cache in `~/Library/Caches/ScanTailorReborn` makes repeat runs fast.

Scholarly book with Greek and Latin:

```bash
scantailor-reborn-cli process book.pdf -o book-clean.pdf --ocr-languages "grc+lat+eng"
```

(Naming a classical language picks `--ocr-engine dual` automatically.)

---

## Commands

```
scantailor-reborn-cli process <input.pdf> -o <output.pdf> [options]
scantailor-reborn-cli inspect <manifest.json> [--pages] [--json]
scantailor-reborn-cli --help
```

### `process`

`scantailor-reborn-cli --help` prints the authoritative list. All options:

**Output and reports**

| Option | Meaning |
| :--- | :--- |
| `-o`, `--output <path>` | Output PDF (300 DPI, 1-bit, searchable). Required unless `--stop-after` is used. |
| `--manifest <path.json>` | Write (or read) the JSON manifest of everything the run decided. |
| `--diagnostics-dir <dir>` | Folder for the manifest and PNG overlays of low-confidence pages. |
| `--all-diagnostics` | Overlays for every page, not just low-confidence ones. |
| `--stop-after layout` | Plan the layout only: no rendering, OCR or PDF. Needs `--manifest` or `--diagnostics-dir`. Writes contact sheets. |
| `--layout-sheets` | Also write layout contact sheets on a full run. |
| `--timings` | Print elapsed time per pass and work time per stage. |

**Choosing pages**

| Option | Meaning |
| :--- | :--- |
| `--page-range <range>` | 1-based source scans to process, e.g. `1-10` or `5..20`. |
| `--exclude-pages <list>` | Scans to skip, e.g. `1,2,5`. |
| `--cover-handling <mode>` | `auto` (default): drop repository cover sheets. `strip`: also drop an odd-sized printed cover. `keep`: drop none. |
| `--no-auto-prune` | Keep blank pages at the start and end too. Blank pages *between* pages are always kept. |
| `--first-page-side <side>` | `recto` (default) or `verso`. |
| `--split-mode <mode>` | `automatic` (default), `single` or `spread`. |
| `--gutter-trim-width <px>` | Strip cut from the spine crease, in px at 600 DPI (default 24). |

**Page size and layout**

| Option | Meaning |
| :--- | :--- |
| `--margins <spec>` | Margins around the text block, e.g. `"top=0.25in,bottom=0.25in,left=0.5in,right=0.5in"`, or `"0.5in"` for all four. Units: `in`, `pt`, `mm`, `cm`, `px`. Default: 0.25 in top and bottom, 0.5 in left and right. |
| `--page-size <spec>` | Output trim size: a preset (`octavo`, `trade-paperback`, `royal-octavo`, `crown-octavo`, `a5`, `a4`, `b5`, `letter`) or `<w>x<h>` such as `6x9in` or `148x210mm`. |
| `--content-box-size <w>x<h>` | Explicit text-block size, e.g. `4.5x7.5in`. |
| `--input-dpi <dpi>` | True optical DPI of the source, for PDFs that wrap photos at 72 or 96 DPI. |
| `--vertical-anchor <mode>` | `auto` (default): align full pages on their running header or first body line. `box-top`: align the tops of the text boxes (legacy). |
| `--no-running-headers` | Turn off running-header detection (and with it, vertical registration). |
| `--dimension-consensus <mode>` | `auto` (default): covers, plates and foldouts of another size stay out of the book's page size. `off`. |
| `--outlier-pages <list\|none>` | Exact outlier pages (1-based output pages and scans, e.g. `1,45,89-91,s120L`). Replaces automatic detection completely. |
| `--outlier-canvas <mode>` | `isolated` (default): each outlier gets its own page size. `shared`. |
| `--outlier-tolerance <frac>` | Relative size difference that makes a page an outlier (default 0.08). |

**Image cleaning**

| Option | Meaning |
| :--- | :--- |
| `--binarize <method>` | `wolf` (default) or `sauvola`. |
| `--no-dewarp` | Skip curvature dewarping (flatbed scans). |
| `--no-perspective` | Skip document-quad detection and perspective correction (alias `--no-quad`). |
| `--no-desk-mask` | Skip desk/background masking before binarization. |
| `--no-border-fallback` | Skip the fallback for pages with marginal geometry. |

**OCR**

| Option | Meaning |
| :--- | :--- |
| `--no-ocr` | No text layer. |
| `--ocr-engine <engine>` | `apple` (default), `tesseract` or `dual`. |
| `--ocr-languages <langs>` | `"grc+lat"`, `"en-US,de-DE"`, `"frk"`. Aliases `--languages`, `--ocr-lang`. |
| `--tessdata-dir <path>` | Folder of `.traineddata` files. |

**Performance**

| Option | Meaning |
| :--- | :--- |
| `-j`, `--jobs <n>` | Scans and pages handled at once (default 4). Results never depend on it; memory grows with it. |
| `--cache-dir <dir>` | Cache location (default `~/Library/Caches/ScanTailorReborn`). Safe to delete. |
| `--no-cache` | Compute everything, store nothing. |
| `--portable-backend` | Pure-Swift compute instead of Metal. |

**Adjustments**

| Option | Meaning |
| :--- | :--- |
| `--apply-manifest <file>` | Apply an [adjustments file](#adjustments-file). Flags on the command line win over its `book` section. A complete manifest from an earlier run is also accepted. |

### `inspect`

Prints a summary of a saved manifest.

```bash
scantailor-reborn-cli inspect d/book-layout-manifest.json            # summary
scantailor-reborn-cli inspect d/book-layout-manifest.json --pages    # one line per page: size, margins, tier, flags
scantailor-reborn-cli inspect d/book-layout-manifest.json --json     # machine-readable
```

---

## Layout rules

These are applied to the whole book after every page has been analyzed.

1. **The canvas hugs the text.** Its size is the largest clean text block in the book, plus **0.25 in top and bottom** and **0.5 in left and right** (or your `--margins`). It is not the size of the scanned paper.
2. **Every page is centered** left to right on that canvas, whichever side of the spread it came from. Inner and outer margins add to the canvas width but pages are not shifted toward the spine.
3. **Pages with a running header hang from the top.** Full pages are registered on their header (or first body line), so text does not jump when you page through.
4. **Pages without a header that run to the foot sit on the bottom.** This covers chapter and section openings.
5. **Floating pages keep their offset.** Title pages, dedications and similar pages keep their place relative to the text block.
6. **Outliers get their own size.** Covers, plates and foldouts do not distort the book's page size.
7. **Blank pages** are dropped only before the first and after the last page with content; kept blanks stay blank.
8. **Manual edits beat automatic detection.** Whatever the detector decides, an adjustments-file entry or an exact `--outlier-pages` list wins.

---

## Iterating on a hard book

The pipeline is designed for a loop in which a person or an agent looks at cheap previews and fixes only what is wrong.

```bash
# 1. Plan the layout only. No PDF, no OCR; fast.
scantailor-reborn-cli process book.pdf --stop-after layout --diagnostics-dir d/

# 2. Review it.
scantailor-reborn-cli inspect d/book-layout-manifest.json --pages
#    and open d/layout-sheet-01.png, ...
#    (red: canonical frame, green: text block, orange: outlier)

# 3. Write adjustments.json for the pages that need it, then repeat step 1
#    with --apply-manifest adjustments.json (repeats are fast: unchanged scans come from the cache).
scantailor-reborn-cli process book.pdf --stop-after layout --diagnostics-dir d/ --apply-manifest adjustments.json

# 4. Satisfied? Write the PDF (OCR is reused for unchanged pages).
scantailor-reborn-cli process book.pdf -o book-clean.pdf --apply-manifest adjustments.json
```

Pages with low confidence also get PNG overlays in the diagnostics folder: green is the main text box, blue retained headers and side clusters, red rejected noise, magenta traced text lines.

### Adjustments file

Strict JSON. Keys starting with `_` and the key `note` are ignored, so you can annotate freely.

```json
{
  "version": 1,
  "book":  { "page-size": "octavo", "margins": "0.75in", "outlier-pages": "1,s45L" },
  "scans": { "s12": { "split": "single" },
             "s30": { "splitX": "52%", "disableRectification": true } },
  "pages": { "s45L": { "skew": -0.4,
                       "contentBox": { "nudge": { "top": "-2mm", "bottom": "+0.1in" } } },
             "77":   { "tier": "standaloneFloating", "keep": true },
             "s88":  { "contentBox": { "rect": ["1.0in", "1.2in", "4.1in", "6.6in"] },
                       "offset": { "y": "+1mm" } } }
}
```

- **Page names.** `"45"` is output page 45 of the run you are looking at. `"s12"` is scan 12 of the source PDF, counted from the start of the PDF even with `--page-range`. `"s12L"` and `"s12R"` are the left and right halves of a split scan. Prefer scan names: they survive changes in splitting or pruning. More specific names win (`s12L` over `s12`).
- **`book`**: any ordinary option, with the flag name as key (without `--`).
- **`scans`**: `split` (`single`, `spread`, `auto`), `splitX` (`"52%"` or a length), `disableRectification`, `disableDeskMask`.
- **`pages`**: `skew` (degrees), `disableDewarp`, `contentBox.rect` `[left, top, right, bottom]`, `contentBox.nudge` `{top, left, bottom, right}` (positive moves an edge right or down), `offset` `{x, y}`, `tier` (`fullBody`, `edgeAnchoredPartial`, `standaloneFloating`), `outlier` (true or false), `pageSize` (an outlier's own size, same aspect), `keep`, `drop`, `runningHeader` (`automatic`, `present`, `absent`), `verticalRegistration` (`automatic`, `anchor`, `boxTop`), `borderFallback` (`automatic`, `forced`, `disabled`).
- **Lengths** need a unit: `in`, `mm`, `cm`, `pt`, `px` (pixels of the 600 DPI processing raster).
- Mistakes are reported all at once, with suggestions, before any scan is processed. The run prints which entries were applied and which were ignored (and why), and the manifest records the same.

---

## Examples

Cover and page selection:

```bash
scantailor-reborn-cli process article.pdf -o clean.pdf --exclude-pages 1 --page-range 2-16
```

Flatbed scans, no dewarping or perspective correction:

```bash
scantailor-reborn-cli process flatbed.pdf -o clean.pdf --no-dewarp --no-perspective
```

Fraktur with a deep binding crease:

```bash
scantailor-reborn-cli process goethe.pdf -o clean.pdf --ocr-languages "deu_frak+deu" --gutter-trim-width 32
```

Fixed output size and wider margins:

```bash
scantailor-reborn-cli process raw.pdf -o print.pdf --page-size 6x9in --margins "top=0.3in,bottom=0.3in,left=0.6in,right=0.6in"
```

Smartphone photos wrapped in a PDF at 72 DPI, with a known source resolution:

```bash
scantailor-reborn-cli process photos.pdf -o clean.pdf --input-dpi 300
```

---

## Using it with an AI agent

The repository includes an agent skill that teaches an agent to drive the loop above: plan, inspect, write an adjustments file, repeat. It is installed in this repo under `.claude/skills/scantailor-reborn` (and mirrored in `.agents/skills/`), and is also packaged as a Claude Code plugin:

```
/plugin marketplace add AthanasiusOfAlex/ScanTailorReborn
/plugin install scantailor-reborn@scantailor-reborn
```

The skill needs `scantailor-reborn-cli` on your `PATH` and says how to install it if it is missing.

---

## Architecture

```
Sources/
├── CTesseract/                 # C bridge to libtesseract and liblept
├── ScanTailorContracts/        # Geometry, raster, OCR types and protocols (no platform imports)
├── ScanTailorCore/             # Algorithms: deskew, split, binarize, dewarp, layout (no platform imports)
├── ScanTailorPortableBackend/  # Pure-Swift CPU compute
├── ScanTailorAppleBackend/     # Metal, Apple Vision OCR, PDFKit/CoreGraphics I/O
├── ScanTailorTesseractBackend/ # Tesseract C-FFI wrapper
├── ScanTailorPipeline/         # Pass coordinator, dual OCR engine, manifest
└── ScanTailorCLI/              # The scantailor-reborn-cli executable
```

---

## Documentation

- [Handoff notes](docs/HANDOFF.md): how each stage works, with the decisions behind it.
- [White paper](docs/WHITE_PAPER.md): goals, release criteria and the development plan.
- [Changelog](CHANGELOG.md)

## License

[MIT License](LICENCE.md). Copyright (c) 2026 **AthanasiusOfAlex**.
