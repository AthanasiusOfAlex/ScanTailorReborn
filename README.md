# ScanTailorReborn

**ScanTailorReborn** is a modern, high-performance command-line tool written in pure **Swift 6** designed to transform raw scans and smartphone photos of books into ultra-crisp, compact, archivable black-and-white PDFs.

It incorporates the principles of Scan Tailor with modern algorithmic enhancements: 600 DPI internal binarization, 3D cylindrical sheet dewarping for curved book spines, multi-scale deskew, illumination normalization, book-wide 3-tier margin harmonization, Metal GPU compute acceleration, and an invisible searchable text layer generated via Apple Vision OCR.

---

## Features

- **600 DPI Processing & 300 DPI 1-Bit CCITT Output**: Processes scans at full 600 DPI resolution for precise edge retention, producing compact 300 DPI 1-bit monochrome PDFs compressed using CCITT Group 4 fax encoding.
- **Multi-Scale Deskew**: Automatically estimates and corrects skew angles to within ±0.05° using projection profile variance analysis and coarse-to-fine search.
- **Intelligent Page Splitting**: Automatically detects gutter shadows, spine creases, and dual-page book spreads to split facing pages into individual recto and verso pages.
- **3D Cylindrical Dewarping**: Traces text baselines across curved book gutters, fits 3D cubic sheet curvature models, and unrolls distorted page geometry to restore straight lines.
- **Adaptive Binarization**: Advanced adaptive thresholding algorithms (Wolf-Jolion and Sauvola) combined with background illumination normalization to remove paper bleed-through, stains, shadows, and yellowing.
- **Book-Wide Margin Harmonization**: Enforces uniform canonical page dimensions across the entire book. Analyzes page content using a 3-tier layout model (Body, Headers/Footers, Noise) to align text blocks aesthetically across facing pages.
- **Searchable OCR Layer**: Integrates Apple Vision OCR to embed an invisible, selectable, searchable text layer positioned directly over the binarized glyphs.
- **Metal GPU Acceleration**: Fast parallel morphological operations, integral image calculations, and dewarp mesh resampling accelerated by Apple Metal and Accelerate vImage, with a pure-Swift portable fallback.
- **JSON Manifest & Non-Destructive Workflow**: Outputs a complete JSON processing manifest detailing all computed parameters (skew, split position, dewarp sag, content boxes, confidence scores). Supports per-page manual overrides and re-runs.
- **Diagnostic Overlays**: Generates color-coded PNG diagnostic overlays highlighting detected text boxes, headers/footers, rejected noise, traced text lines, and gutter bounds.

---

## Installation & Building

### Requirements
- **macOS 14.0 (Sonoma)** or later
- **Swift 6.0** toolchain or Xcode 16+

### Build from Source

Clone the repository and compile the release binary using the Swift Package Manager:

```bash
git clone https://github.com/AthanasiusOfAlex/ScanTailorReborn.git
cd ScanTailorReborn
swift build -c release
```

The compiled binary will be located at:
```bash
.build/release/scantailor-cli
```

Optionally install it into your `$PATH` (e.g. `/usr/local/bin`):
```bash
cp .build/release/scantailor-cli /usr/local/bin/
```

### Running Tests

```bash
swift test
```

---

## CLI Usage

ScanTailorReborn provides two primary commands: `process` and `inspect`.

```bash
scantailor-cli process <input.pdf> -o <output.pdf> [options]
scantailor-cli inspect <manifest.json>
```

---

### Command: `process`

Processes an input PDF through the complete book-processing pipeline and outputs a clean 1-bit searchable PDF.

```bash
scantailor-cli process <input.pdf> -o <output.pdf> [options]
```

#### Positional Arguments

| Argument | Description |
| :--- | :--- |
| `<input.pdf>` | Path to the source raw scan PDF file. |

#### Options

| Flag / Option | Argument | Description |
| :--- | :--- | :--- |
| `-o`, `--output` | `<path>` | **Required.** Path to the output 300 DPI 1-bit searchable PDF. |
| `--split-mode` | `<mode>` | Page splitting mode for dual-page spreads. Choices: `automatic` (default), `single`, `spread`. |
| `--binarize` | `<method>` | Adaptive thresholding algorithm. Choices: `wolf` (default) or `sauvola`. |
| `--no-dewarp` | *None* | Disables 3D cubic-sheet spine curvature dewarping. Useful for flatbed scans or planar documents. |
| `--no-ocr` | *None* | Disables the Apple Vision OCR engine. Output PDF will contain only binarized raster images without a text layer. |
| `--manifest` | `<path.json>` | Path to read an existing JSON manifest (for manual overrides) or write the resulting manifest. |
| `--diagnostics-dir` | `<path>` | Directory to save the processing manifest JSON and rendered diagnostic PNG overlays. |
| `--all-diagnostics` | *None* | Forces diagnostic PNG overlay generation for **all** pages, not just pages flagged as low-confidence. |
| `--portable-backend` | *None* | Forces the pure-Swift portable compute backend instead of Apple Metal GPU shaders. |
| `-h`, `--help` | *None* | Displays command-line usage information and exits. |

---

### Detailed Option Explanations

#### `--split-mode <mode>`
Specifies how dual-page spreads should be detected and split into individual pages:
- `automatic` / `auto` *(default)*: Analyzes aspect ratio and gutter shadow intensity to automatically determine if a source page is a two-page spread or a single page.
- `single` / `singlepage`: Treats all source pages as single pages; disables spread splitting.
- `spread` / `twopage`: Forces every source page to be split into two individual pages (recto and verso) along the detected gutter.

#### `--binarize <method>`
Selects the adaptive thresholding algorithm used to separate ink from background paper:
- `wolf` / `wolf-jolion` *(default)*: Christian Wolf and Jean-Michel Jolion binarization. Highly resilient against uneven page lighting, gutter shadows, and gradient illumination.
- `sauvola`: Jaakko Sauvola adaptive thresholding. Computes thresholds based on local standard deviation.

#### `--no-dewarp`
Bypasses the 3D cylindrical sheet dewarper. By default, ScanTailorReborn traces baseline curvature across horizontal text lines, fits a cubic polynomial sag model, and unrolls curved book page margins. If your input documents were scanned on a flatbed scanner or are already flat, use `--no-dewarp` for faster execution.

#### `--no-ocr`
Omits the OCR pass. By default, ScanTailorReborn executes an asynchronous Apple Vision text recognition pass on each dewarped, deskewed page and embeds an invisible text layer directly aligned over the black-and-white glyphs. Pass `--no-ocr` to skip text recognition and speed up processing.

#### `--manifest <path.json>`
Path to a JSON processing manifest file. 
- When providing a path to a file that does not yet exist, ScanTailorReborn writes the complete pipeline configuration and per-page metrics (skew angles, split coordinates, dewarp sag, content boxes, layout tiers, and confidence ratings) to this file.
- When pointing to an existing manifest file, ScanTailorReborn loads the parameters and allows you to apply manual adjustments or inspect prior run data.

#### `--diagnostics-dir <dir>`
Specifies a directory where diagnostic outputs are placed. When specified, ScanTailorReborn automatically outputs:
1. `<stem>-manifest.json`: Complete book layout and processing manifest.
2. `page-XXXX-diag.png`: Color-coded 600 DPI diagnostic overlays for flagged (low-confidence) pages showing content bounding boxes, header/footer bounds, noise rejections, and traced text lines.

#### `--all-diagnostics`
By default, diagnostic PNG overlays are only generated for pages with confidence ratings below the threshold (`< 0.60`). Providing `--all-diagnostics` renders diagnostic PNGs for **every** output page in `--diagnostics-dir`.

#### `--portable-backend`
Disables Apple Metal GPU compute kernels and runs portable, pure-Swift morphological and raster algorithms. Useful for running on systems without active GPU acceleration or for cross-platform portability verification.

---

### Command: `inspect`

Inspects a previously saved JSON processing manifest and prints an ASCII summary of book dimensions, canonical margin frames, and per-page metrics.

```bash
scantailor-cli inspect <manifest.json>
```

#### Example Output:

```text
=== ScanTailorReborn Manifest Summary ===
Processing DPI: 600 | Output DPI: 300
Canonical 600 DPI Canvas: 4960 x 7016 px
Verso Canonical Text Frame: 3720 x 5612 at (620, 702)
Recto Canonical Text Frame: 3720 x 5612 at (620, 702)
Total Output Pages: 12 (from 6 source scan(s))
-----------------------------------------
Page 1 (src #1, verso): tier=body, skew=+0.12°, dewarp=yes (sag 14.2px), conf=0.94
Page 2 (src #1, recto): tier=body, skew=-0.08°, dewarp=yes (sag 12.8px), conf=0.96
Page 3 (src #2, verso): tier=body, skew=+0.05°, dewarp=yes (sag 18.5px), conf=0.91
Page 4 (src #2, recto): tier=chapterOpening, skew=+0.02°, dewarp=yes (sag 8.1px), conf=0.88
Page 5 (src #3, verso): tier=body, skew=-0.15°, dewarp=yes (sag 42.0px), conf=0.55 [FLAGGED]
```

---

## Common Workflows & Examples

### 1. Standard Book Processing with OCR & GPU Acceleration

Process dual-page spreads from a smartphone or book scanner into a searchable PDF:

```bash
scantailor-cli process input_book.pdf -o cleaned_book.pdf
```

### 2. Flatbed Scans (No Dewarping Needed)

For flatbed scans or planar sheets where pages have no spine curvature:

```bash
scantailor-cli process flatbed_scan.pdf -o cleaned_flatbed.pdf --no-dewarp
```

### 3. Reviewing Flagged Pages with Diagnostic Overlays

Save diagnostic overlays and the JSON manifest to inspect pages that might need manual review:

```bash
scantailor-cli process book.pdf -o output.pdf --diagnostics-dir ./diagnostics
```

Open `./diagnostics/page-0005-diag.png` to inspect flagged pages. Overlays use color coding:
- **Green**: Detected main body text box.
- **Blue**: Retained header/footer and side clusters.
- **Red**: Rejected border noise, fingers, shadows, or edge artifacts.
- **Magenta**: Traced text lines used for spine curvature dewarping.

### 4. Single-Page Document Mode

For non-book documents (articles, contracts, single receipts):

```bash
scantailor-cli process document.pdf -o document_clean.pdf --split-mode single
```

---

## Architecture

The project is structured into modular Swift packages adhering to pure Swift 6 strict concurrency (`-strict-concurrency=complete`):

```
Sources/
├── ScanTailorContracts/       # Pure Swift geometric, raster, and protocol primitives (Zero platform imports)
├── ScanTailorCore/            # Core algorithms: deskew, split, binarize, dewarp, layout (Zero platform imports)
├── ScanTailorPortableBackend/ # Portable pure-Swift CPU compute implementation (Zero platform imports)
├── ScanTailorAppleBackend/    # macOS Metal GPU acceleration, Apple Vision OCR, and PDFKit/CoreGraphics I/O
├── ScanTailorPipeline/        # Multi-stage book pipeline coordinator and manifest engine
└── ScanTailorCLI/             # Command-line interface executable (scantailor-cli)
```

---

## License

This project is licensed under the [MIT License](LICENCE.md).

Copyright (c) 2026 **AthanasiusOfAlex**.
