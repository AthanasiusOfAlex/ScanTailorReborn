# ScanTailorReborn

**ScanTailorReborn** is a modern, high-performance command-line tool written in pure **Swift 6** designed to transform raw scans and smartphone photos of books into ultra-crisp, compact, archivable black-and-white PDFs.

It incorporates the principles of Scan Tailor with modern algorithmic enhancements: 600 DPI internal binarization, 3D cylindrical sheet dewarping for curved book spines, multi-scale deskew, dual-mode gutter detection and spine crease excision, split-boundary noise exclusion, illumination normalization, book-wide publication margin harmonization, Metal GPU compute acceleration, and a multi-engine invisible searchable text layer combining Apple Vision and Tesseract OCR (with polytonic Ancient Greek, Latin, and Fraktur support).

---

## Features

- **600 DPI Processing & 300 DPI 1-Bit CCITT Output**: Processes scans at full 600 DPI resolution for precise edge retention, producing compact 300 DPI 1-bit monochrome PDFs compressed using CCITT Group 4 fax encoding.
- **Multi-Scale Deskew**: Automatically estimates and corrects skew angles to within ±0.05° using projection profile variance analysis and coarse-to-fine search, with calibrated confidence metrics.
- **Intelligent Page Splitting & Dual-Mode Gutter Detection**: Automatically detects gutter shadows, spine creases, and dual-page book spreads. Dynamically switches between White Valley and Dark Crease modes based on vertical ink continuity ($\ge 75\%$) to bisect dark spine seams accurately.
- **Central Gutter Strip Trimming**: Configurable gutter trimming (`--gutter-trim-width`) physically excises dark crease shadow bands during page slicing, preventing crease ink from entering downstream stages.
- **Split-Boundary Noise Exclusion**: Directional pre-closing edge masking in content box detection prevents residual binding shadow or crease fragments from bridging into text blocks.
- **Blank Sub-Page Auto-Pruning & Outlier Rejection**: Discards blank sub-page slices (e.g. single-page title scans on flatbeds) and applies interquartile range (IQR) outlier rejection to protect canonical page dimensions.
- **3D Cylindrical Dewarping**: Traces text baselines across curved book gutters, fits 3D cubic sheet curvature models, and unrolls distorted page geometry to restore straight lines with flat-page auto-bypass.
- **Adaptive Binarization**: Advanced adaptive thresholding algorithms (Wolf-Jolion and Sauvola) combined with background illumination normalization to remove paper bleed-through, stains, shadows, and yellowing.
- **Publication Margin Harmonization**: Enforces uniform canonical page dimensions across the entire book with configurable publication margins (`--margins`), page ranges (`--page-range`), page exclusion (`--exclude-pages`), and initial logical side (`--first-page-side`).
- **Multi-Engine Searchable OCR Layer**:
  - **Apple Vision**: Ultra-fast native macOS neural text recognition for modern scripts and ecclesiastical Latin.
  - **Tesseract OCR**: High-accuracy classical language support (Polytonic Ancient Greek `grc`, German Fraktur `deu_frak`/`frk`, Latin `lat`, English `eng`).
  - **Dual Engine Synthesis**: Concurrently queries both engines and synthesizes observations—spatially merging bounding boxes, prioritizing classical polytonic Greek and Fraktur alphabets over Latin misrecognitions, and outputting in reading order.
- **PDF Font Stream Deduplication**: Reuses a single canonical 12 pt base font scaled via affine transformation matrices, reducing output PDF file sizes from >5 MB down to ~1.4 MB.
- **Metal GPU Acceleration**: Fast parallel morphological operations, integral image calculations, and dewarp mesh resampling accelerated by Apple Metal and Accelerate vImage, with a pure-Swift portable fallback.
- **JSON Manifest & Non-Destructive Workflow**: Outputs a complete JSON processing manifest detailing all computed parameters (skew, split position, dewarp sag, content boxes, confidence scores). Supports per-page manual overrides and re-runs.
- **Diagnostic Overlays**: Generates color-coded PNG diagnostic overlays highlighting detected text boxes, headers/footers, rejected noise, traced text lines, and gutter bounds.

---

## Installation & Building

### Requirements
- **macOS 14.0 (Sonoma)** or later
- **Swift 6.0** toolchain or Xcode 16+
- **Tesseract OCR (optional, for Tesseract and Dual OCR engines)**:
  ```bash
  brew install tesseract
  # Optional classical and European language packs:
  brew install tesseract-lang
  ```

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
| `--manifest` | `<path.json>` | Path to read an existing JSON manifest (for manual overrides) or write the resulting manifest. |
| `--diagnostics-dir` | `<dir>` | Directory to save the processing manifest JSON and rendered diagnostic PNG overlays. |
| `--all-diagnostics` | *None* | Forces diagnostic PNG overlay generation for **all** pages, not just pages flagged as low-confidence. |
| `--split-mode` | `<mode>` | Page splitting mode for dual-page spreads. Choices: `automatic` (default), `single`, `spread`. |
| `--gutter-trim-width` | `<px>` | Central gutter strip trimming width in pixels at 600 DPI (default: `24`). Excision of dark spine seams. |
| `--margins` | `<spec>` | Publication margins relative to detected text, e.g. `"top=0.25in,bottom=0.25in,left=0.5in,right=0.5in"`. Supports `in`, `pt`, `mm`, `px`, and `inner`/`outer`/`gutter` qualifiers. |
| `--page-range` | `<range>` | 1-based source scan page range to process, e.g. `1-10`, `5..20`. |
| `--exclude-pages` | `<list>` | Comma-separated 1-based source scan indices to skip, e.g. `1,2,5`. |
| `--first-page-side` | `<side>` | Initial logical book side: `recto` (default) or `verso`. |
| `--binarize` | `<method>` | Adaptive thresholding algorithm: `wolf` (default) or `sauvola`. |
| `--no-auto-prune` | *None* | Disables automatic pruning of blank sub-page slices (retains empty flyleaves/halftitles). |
| `--no-dewarp` | *None* | Disables 3D cubic-sheet spine curvature dewarping. Useful for flatbed scans or planar documents. |
| `--no-ocr` | *None* | Disables OCR entirely. Output PDF will contain only binarized raster images without a text layer. |
| `--ocr-engine` | `<engine>` | OCR engine selection: `apple` (default on macOS), `tesseract`, or `dual`. |
| `--ocr-languages` | `<langs>` | Comma- or plus-separated language codes, e.g. `"grc+lat"`, `"en-US,de-DE"`, `"frk"`. Aliases: `--languages`, `--ocr-lang`. |
| `--tessdata-dir` | `<path>` | Custom directory containing Tesseract `.traineddata` language models. |
| `--portable-backend` | *None* | Forces the pure-Swift portable compute backend instead of Apple Metal GPU shaders. |
| `-h`, `--help` | *None* | Displays command-line usage information and exits. |

---

### Detailed Option Explanations

#### `--split-mode <mode>`
Specifies how dual-page spreads should be detected and split into individual pages:
- `automatic` / `auto` *(default)*: Analyzes aspect ratio and gutter shadow intensity to automatically determine if a source page is a two-page spread or a single page.
- `single` / `singlepage`: Treats all source pages as single pages; disables spread splitting.
- `spread` / `twopage`: Forces every source page to be split into two individual pages (recto and verso) along the detected gutter.

#### `--gutter-trim-width <px>`
Configures the physical strip excised from the central spine crease during spread splitting (default: `24` pixels at 600 DPI, approximately 1 mm).
- When a physical book is photographed open, the spine crease leaves a dark vertical line. Slicing with zero width leaves dark line ink on the sliced boundaries.
- The gutter trim width cuts out $W_{\text{gutter}} / 2$ pixels on both sides of the detected midline, preventing crease ink from reaching downstream layout analysis or appearing on page edges.

#### `--margins <spec>`
Configures publication margins relative to the detected content box across all pages:
- Format: Key-value pairs separated by commas, supporting units `in` (inches), `pt` (points), `mm` (millimeters), or `px` (pixels at 600 DPI).
- Absolute margins: `"top=0.25in,bottom=0.25in,left=0.5in,right=0.5in"`
- Book-binding (inner/outer) margins: `"top=0.25in,bottom=0.25in,inner=0.6in,outer=0.4in"`
- Uniform shorthand: `"0.5in"` sets all four margins to 0.5 inches.
- Defaults if omitted: **0.25 in** top/bottom, **0.50 in** left/right.

#### `--first-page-side <side>`
Specifies whether the first processed page starts on the `recto` (right-hand, default) or `verso` (left-hand) side of a book spread. This controls the alternating inner/outer binding margins throughout the document.

#### `--page-range <range>` & `--exclude-pages <list>`
- `--page-range 5-20` (or `5..20`): Restricts processing to a subset of source scans.
- `--exclude-pages 1,2`: Explicitly skips specified 1-based source scan pages (such as blank cover scans, color calibration cards, or digital covers).

#### `--no-auto-prune`
By default, ScanTailorReborn automatically prunes blank sub-page slices (slices with foreground ink density $< 0.5\%$ and 0 recognized OCR words), eliminating phantom empty pages caused by single title pages scanned on flatbeds. Providing `--no-auto-prune` preserves these blank slices in the output PDF.

#### `--ocr-engine <engine>`
Selects the OCR engine for text recognition:
- `apple` *(default on macOS)*: Uses Apple's Vision framework (`VNRecognizeTextRequest`). Highly optimized on Apple Silicon, excellent for English, French, German, and Ecclesiastical Latin.
- `tesseract`: Uses `libtesseract` via pure Swift 6 C-FFI. Supports classical languages such as Polytonic Ancient Greek (`grc`) and Fraktur (`deu_frak`/`frk`).
- `dual`: Runs both Apple Vision and Tesseract concurrently, merging results spatially. Classical Greek and Fraktur scripts take precedence over Latin misrecognitions, while standard Latin text benefits from Apple Vision's neural engine.

#### `--ocr-languages <langs>` (Aliases: `--languages`, `--ocr-lang`)
Specifies the language codes for OCR. Accepts comma-separated or plus-separated strings:
- Tesseract codes: `grc` (Ancient Greek), `lat` (Latin), `deu_frak` or `frk` (German Fraktur), `eng` (English), `deu` (German).
- Apple Vision codes: BCP-47 codes such as `en-US`, `de-DE`, `fr-FR`, `la`.
- When classical language codes (`grc`, `deu_frak`, `frk`) are specified and `--ocr-engine` is omitted, ScanTailorReborn automatically selects `--ocr-engine dual` to ensure optimal coverage.

#### `--tessdata-dir <path>`
Specifies a custom directory containing Tesseract `.traineddata` files. Defaults to Homebrew's standard path (`/opt/homebrew/share/tessdata` or `/usr/local/share/tessdata`) or `$TESSDATA_PREFIX`.

#### `--binarize <method>`
Selects the adaptive thresholding algorithm used to separate ink from background paper:
- `wolf` / `wolf-jolion` *(default)*: Christian Wolf and Jean-Michel Jolion binarization. Highly resilient against uneven page lighting, gutter shadows, and gradient illumination.
- `sauvola`: Jaakko Sauvola adaptive thresholding. Computes thresholds based on local standard deviation.

#### `--no-dewarp`
Bypasses the 3D cylindrical sheet dewarper. By default, ScanTailorReborn traces baseline curvature across horizontal text lines, fits a cubic polynomial sag model, and unrolls curved book page margins. If your input documents were scanned on a flatbed scanner or are already flat, use `--no-dewarp` for faster execution.

#### `--no-ocr`
Omits the OCR pass entirely. Passes `--no-ocr` to skip text recognition and speed up processing.

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

### 1. Standard Book Processing with Dual-Engine Classical OCR

Process dual-page spreads containing scholarly Greek, Latin, and English text into a compact, searchable PDF:

```bash
scantailor-cli process book_greek_latin.pdf \
  -o cleaned_scholarly.pdf \
  --ocr-engine dual \
  --ocr-languages "grc+lat+eng"
```

### 2. German Fraktur Text with Custom Gutter Trimming

Process an antique 19th-century German volume printed in Fraktur with a deep binding crease:

```bash
scantailor-cli process goethe_fraktur.pdf \
  -o cleaned_goethe.pdf \
  --ocr-engine dual \
  --ocr-languages "deu_frak+deu" \
  --gutter-trim-width 32
```

### 3. Custom Publication Margins (Inner / Outer Binding Clearance)

Prepare a book scan for high-quality printing and binding with extra inner margin clearance:

```bash
scantailor-cli process raw_scans.pdf \
  -o print_ready.pdf \
  --margins "top=0.3in,bottom=0.3in,inner=0.6in,outer=0.4in" \
  --first-page-side recto
```

### 4. Excluding Digital Cover Pages & Selective Page Range

Skip the first JSTOR cover page and process only pages 2 through 16:

```bash
scantailor-cli process article.pdf \
  -o article_clean.pdf \
  --exclude-pages 1 \
  --page-range 2-16
```

### 5. Flatbed Scans (No Dewarping Needed)

For flatbed scans or planar sheets where pages have no spine curvature:

```bash
scantailor-cli process flatbed_scan.pdf -o cleaned_flatbed.pdf --no-dewarp
```

### 6. Reviewing Flagged Pages with Diagnostic Overlays

Save diagnostic overlays and the JSON manifest to inspect pages that might need manual review:

```bash
scantailor-cli process book.pdf -o output.pdf --diagnostics-dir ./diagnostics
```

Open `./diagnostics/page-0005-diag.png` to inspect flagged pages. Overlays use color coding:
- **Green**: Detected main body text box.
- **Blue**: Retained header/footer and side clusters.
- **Red**: Rejected border noise, fingers, shadows, or edge artifacts.
- **Magenta**: Traced text lines used for spine curvature dewarping.

---

## Architecture

The project is structured into modular Swift packages adhering to pure Swift 6 strict concurrency (`-strict-concurrency=complete`):

```
Sources/
├── CTesseract/                # C bridging header & modulemap for libtesseract and liblept
├── ScanTailorContracts/       # Pure Swift geometric, raster, OCR, and protocol primitives (Zero platform imports)
├── ScanTailorCore/            # Core algorithms: deskew, split, binarize, dewarp, layout (Zero platform imports)
├── ScanTailorPortableBackend/ # Portable pure-Swift CPU compute implementation (Zero platform imports)
├── ScanTailorAppleBackend/    # macOS Metal GPU acceleration, Apple Vision OCR, and PDFKit/CoreGraphics I/O
├── ScanTailorTesseractBackend/# Swift 6 libtesseract C-FFI wrapper, LeptonicaPix RAII, and TesseractOCREngine
├── ScanTailorPipeline/        # Multi-stage book pipeline coordinator, DualOCREngine, and manifest engine
└── ScanTailorCLI/             # Command-line interface executable (scantailor-cli)
```

---

## Documentation & Research

- [**Technical White Paper**](docs/WHITE_PAPER.md): Comprehensive real-world evaluation, algorithmic case studies (*Flannery 1993*, *Vermeersch 1934*), mathematical analysis of layout/confidence metrics, and architectural implementation record covering Phases 1, 2, and 3.

---

## License

This project is licensed under the [MIT License](LICENCE.md).

Copyright (c) 2026 **AthanasiusOfAlex**.
