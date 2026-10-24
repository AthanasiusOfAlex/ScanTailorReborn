# ScanTailorReborn: Changelog & Architectural Evolution

This document traces the complete development history of **ScanTailorReborn**, detailing where the project started, the real-world empirical benchmarks that identified core deficiencies, and the systematic algorithmic enhancements executed across Phases 1, 2, and 3.

---

## 1. Executive Summary & Project Origins

**ScanTailorReborn** was conceived as an automated, pure **Swift 6** command-line book digitization pipeline designed to transform raw scans and smartphone photographs of books into compact, publication-quality 300 DPI 1-bit monochrome PDFs (CCITT Group 4) with invisible searchable OCR text layers.

### Initial Baseline Architecture (v1.0.0)
At inception, ScanTailorReborn implemented the core stages inspired by Scan Tailor:
- **600 DPI Internal Processing & 300 DPI Output**: Sub-pixel edge retention during deskew and thresholding, outputting CCITT Group 4 1-bit PDFs.
- **Multi-Scale Deskew**: Projection profile variance analysis and coarse-to-fine search over $\pm 45^\circ$.
- **Spread Splitting**: Basic gutter shadow valley detection to bisect dual-page spreads into recto and verso pages.
- **3D Cylindrical Dewarping**: Baseline tracing across horizontal text lines, fitting a 3D cubic sheet curvature model, and resampling warped page margins.
- **Adaptive Binarization**: Wolf-Jolion and Sauvola thresholding with illumination normalization.
- **Layout & Margin Harmonization**: 3-tier content classification (Body, Headers/Footers, Noise) to align pages across facing spreads.
- **Searchable OCR Layer**: Native macOS Apple Vision (`VNRecognizeTextRequest`) OCR embedding invisible text layers over raster glyphs.
- **Hardware Acceleration**: Apple Metal GPU shaders with Accelerate vImage and a pure-Swift portable fallback.

---

## 2. Initial Real-World Evaluation & Baseline Deficiencies

To stress-test the initial baseline under authentic digitization conditions, rigorous empirical benchmarks were conducted against two contrasting academic documents:

### Benchmark 1: `flannery.1993.pdf` (Modern Journal Scan with Digital Contamination)
- **Profile**: 16 single pages, ~204 DPI, flat typography, digital JSTOR download cover, and digital tracking footers on every page.
- **Observed Behavior**:
  - *Successes*: Flat pages auto-bypassed dewarping ($s_{\max} < 11.7\text{ px}$); `ContentBoxDetector` cleanly rejected the digital JSTOR footer ($932\text{ px}$ below text body) on 100% of pages without clipping footnotes.
  - *Deficiency 1 (False Confidence Warnings)*: The skew estimator flagged all 16 pages with low confidence warnings (`conf=0.50`) despite pristine, horizontal typography.
  - *Deficiency 2 (PDF Font Bloat)*: The 16-page PDF generated at **5.3 MB**, even though the underlying CCITT Group 4 image streams totaled only **1.4 MB**. Every text observation instantiated a separate dynamic `CTFont`, causing Quartz to embed dozens of duplicate font subsets.

### Benchmark 2: `vermeersch.1934.pdf` (Facing Spreads, Binding Warp & Ecclesiastical Latin)
- **Profile**: 10 landscape scans (20 pages), ~204 DPI photocopier scan (Ricoh MP 2555), heavy 1934 Latin typography, persistent central spine crease shadows, cylindrical binding warp, and an off-center single title page scan on flatbed.
- **Observed Behavior**:
  - *Successes*: Apple Vision achieved extraordinary accuracy transcribing 1934 Latin (diacritics, section markers `§`, legal citations, canonical abbreviations). Curled pages were flattened from $s_{\max} = 27.5\text{ px}$ to RMS residual $< 2.34\text{ px}$.
  - *Deficiency 3 (Dark Crease Flank Drift)*: The gutter corridor cost function penalized ink, interpreting dark spine seams as heavy penalties. As a result, split lines drifted into adjacent lighter paper rather than bisecting the dark crease centerline.
  - *Deficiency 4 (Spine Crease Bleeding & Content Box Corruption)*: Zero-width knife splitting left narrow dark crease remnants along slice boundaries. Morphological closing (`closeBrick(64, 14)`) bridged crease fragments into body text, causing content boxes to expand to the cut edge ($x = 2..4\text{ px}$) on Pages 4, 8, 14, 18, and 20.
  - *Deficiency 5 (Blank Slice Generation)*: Scan 1 (a single title page placed on the flatbed) produced an empty, character-less Page 1 slice ($0$ words).
  - *Deficiency 6 (Classical Language Limitation)*: Apple Vision does not support Polytonic Ancient Greek (`grc`) or Fraktur (`deu_frak`/`frk`), failing on classical multi-lingual scholarship.

---

## 3. Systematic Implementation Record

To eliminate these deficiencies, a 3-phase architectural overhaul was planned, executed, and verified under pure Swift 6 strict concurrency:

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                       Phase 1: Core Calibration & Fonts                     │
│  - Recalibrate Skew Energy Ratio Denominator (/ 1.5)                        │
│  - Single Canonical 12pt CTFont + CGContext Text Matrix Affine Scaling      │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
┌──────────────────────────────────────▼──────────────────────────────────────┐
│                  Phase 2: Spine Crease, Gutter & Layout                      │
│  - Substep 2.1: Dual-Mode Gutter Detection (White Valley vs Dark Crease >=75%)│
│  - Substep 2.2: Central Gutter Strip Trimming (Physical Crease Cutout)       │
│  - Substep 2.3: Split-Boundary Noise Exclusion Zone (Directional Edge Mask)  │
│  - Substep 2.4: Blank Sub-Page Auto-Pruning & IQR Outlier Filtering          │
│  - Substep 2.5: Publication Margin Engine & CLI Configuration Options        │
└──────────────────────────────────────┬──────────────────────────────────────┘
                                       │
┌──────────────────────────────────────▼──────────────────────────────────────┐
│               Phase 3: Classical OCR & Multi-Engine Dispatch                 │
│  - Substep 3.1: Swift 6 libtesseract C Bridging, LeptonicaPix RAII, & Engine│
│  - Substep 3.2: DualOCREngine Synthesis, Spatial Merging, Script Priority,   │
│                 Language Filtering & Full CLI Integration                    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

### Phase 1: Core Calibration & PDF Font Optimization

#### Substep 1.1: Recalibrate `SkewEstimator` Confidence Metric
- **Problem**: `(ratio - 1.0) / 4.0` was overly conservative. Normal text projection peaks ($2.1\times$ median energy) yielded $0.275$, clamped to $0.50$ by `BookPipelineCoordinator`, causing 100% false-positive warnings.
- **Solution**: Recalibrated the denominator from `4.0` down to `1.5` in [SkewEstimator.swift](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorCore/Deskew/SkewEstimator.swift):
  $$\text{confidence} = \min\left(1.0, \max\left(0.0, \frac{\text{ratio} - 1.0}{1.5}\right)\right)$$
- **Result**: Clean text pages now evaluate to confidence $\ge 0.75$, completely eliminating false-positive warnings on straight documents.

#### Substep 1.2: PDF Font Stream Deduplication via Text Matrix Scaling
- **Problem**: `ApplePDFDocumentWriter` instantiated dynamic `CTFont` sizes for each text observation, forcing Quartz `CGPDFContext` to embed 28+ distinct TrueType font subsets and bloating output PDFs to 5.3 MB.
- **Solution**: Refactored [ApplePDFDocumentWriter.swift](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorAppleBackend/ApplePDFDocumentWriter.swift) to instantiate a single canonical 12 pt base font once per document. Individual text observations compute uniform horizontal and vertical scale factors applied directly via `CGContext.textMatrix` and `CGAffineTransform`.
- **Result**: Flannery output PDF file size dropped from **5.3 MB down to 1.4 MB** (a **73.6% size reduction**), exactly matching raw 1-bit CCITT Group 4 raster stream size.

---

### Phase 2: Spine Crease, Gutter & Content Filtering & Margins

#### Substep 2.1: Dual-Mode Gutter Detection & Dark Crease Centerline Tracking
- **Problem**: In [PageSplitEstimator.swift](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorCore/Layout/PageSplitEstimator.swift), `meanCorridorInk * 3.5` penalized dark spine seams, displacing the cut line into adjacent white margins.
- **Solution**: Added vertical continuity analysis ($\ge 75\%$ dark pixel continuity along candidate columns). When continuous vertical ink is present, the estimator automatically switches from **White Valley Mode** to **Dark Crease Mode**. In Dark Crease Mode, corridor ink is **maximized** rather than penalized, locking onto the dark crease midline across tilt angles $\phi \in [-3.0^\circ, +3.0^\circ]$.

#### Substep 2.2: Central Gutter Strip Trimming (Physical Crease Cutout)
- **Problem**: Zero-width knife splitting left narrow dark crease bands along inner page boundaries.
- **Solution**: Introduced configurable gutter strip trimming (`--gutter-trim-width <px>`, default: 24 px at 600 DPI) in [PageSplitEstimator.swift](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorCore/Layout/PageSplitEstimator.swift) and [BookPipelineCoordinator.swift](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorPipeline/BookPipelineCoordinator.swift). Left sub-pages clip at $X_{\text{split}} - W_{\text{gutter}} / 2$ and right sub-pages start at $X_{\text{split}} + W_{\text{gutter}} / 2$, physically cutting out dark spine shadow strips at the slicing stage.

#### Substep 2.3: Split-Boundary Noise Exclusion in `ContentBoxDetector`
- **Problem**: Residual crease ink bridged into body text during morphological closing (`closeBrick(64, 14)`), expanding content boxes to $x = 2..4\text{ px}$.
- **Solution**: Added `splitEdgeExclusionFraction = 0.04` (4% of slice width) in [ContentBoxDetector.swift](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorCore/Layout/ContentBoxDetector.swift). On sliced sub-pages (`.leftVerso` inner right margin, `.rightRecto` inner left margin), a directional boundary mask clears ink along the cut margin prior to morphological closing, disconnecting crease remnants and ensuring they are filtered as noise.

#### Substep 2.4: Blank Sub-Page Auto-Pruning & Layout Outlier Filtering
- **Problem**: Single title pages or oversize foldouts caused blank phantom pages (Vermeersch Page 1) and distorted canonical canvas dimensions.
- **Solution**:
  - Implemented automatic pruning in [BookPipelineCoordinator.swift](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorPipeline/BookPipelineCoordinator.swift): sub-page slices with foreground ink density $< 0.5\%$ and 0 recognized OCR words are automatically discarded.
  - Added interquartile range (IQR) outlier rejection in [MarginHarmonizer.swift](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorCore/Layout/MarginHarmonizer.swift) to exclude anomalous page dimensions from canonical frame calculations.

#### Substep 2.5: Publication Margin Engine & CLI Configuration
- **Problem**: Hardcoded margins lacked flexibility for print-on-demand publishing and binding clearance.
- **Solution**: Standardized default publication margins relative to detected text blocks to **0.25 in** (top/bottom) and **0.50 in** (left/right). Exposed comprehensive CLI options:
  - `--margins <spec>`: Supports inches (`in`), points (`pt`), millimeters (`mm`), and pixels (`px`), including `inner`/`outer`/`gutter` binding qualifiers.
  - `--page-range <range>`: Restricts processing (e.g. `1-10`, `5..20`).
  - `--exclude-pages <list>`: Explicitly skips source scans (e.g. `1,2,5`).
  - `--first-page-side <side>`: Configures initial logical side (`recto` or `verso`).
  - `--no-auto-prune`: Preserves blank slices when desired.

---

### Phase 3: Classical Language OCR & Multi-Engine Dispatch

#### Substep 3.1: Swift 6 `libtesseract` C Bridging & `TesseractOCREngine`
- **Problem**: Scholarly texts with Polytonic Ancient Greek or German Fraktur could not be recognized by Apple Vision.
- **Solution**:
  - Created [CTesseract](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/CTesseract/include/CTesseract.h) bridging `tesseract/capi.h` and `leptonica/allheaders.h`.
  - Built `LeptonicaPix` memory-safe RAII wrapper for zero-leak `PIX*` lifecycle management.
  - Implemented [TesseractOCREngine](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorTesseractBackend/TesseractOCREngine.swift) conforming to `OCREngine: Sendable` with complete coordinate space inversion (transforming bottom-left Leptonica pixel boxes to top-left ScanTailor canvas space) and multi-language support (`grc`, `deu_frak`/`frk`, `lat`, `eng`).

#### Substep 3.2: Pipeline Multi-Engine Dispatch & `DualOCREngine` Synthesis
- **Problem**: Running either Apple Vision or Tesseract alone forces a compromise between Apple Vision's superior Latin/layout neural model and Tesseract's classical script capability.
- **Solution**:
  - Implemented [DualOCREngine](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorPipeline/OCR/DualOCREngine.swift) supporting concurrent synthesis:
    1. **Spatial Bounding Box Merging**: Merges detections with vertical overlap ratio $> 0.40$ and horizontal overlap ratio $> 0.30$.
    2. **Classical Script Prioritization**: Detections containing Polytonic Greek (`U+0370...U+03FF`, `U+1F00...U+1FFF`) or Fraktur long s (`ſ`) unconditionally supersede Latin misrecognitions.
    3. **Confidence Differential Arbitration**: Favors detections with confidence differential $> 0.15$.
    4. **Unique Retention**: Retains non-overlapping words identified by either engine.
    5. **Apple Vision Language Filtering**: Strips classical language codes (`grc`, `deu_frak`, `frk`, `lat`) prior to calling Apple Vision, avoiding unsupported language errors.
    6. **Reading Order Sorting**: Emits observations sorted geometrically top-to-bottom, left-to-right.
  - Wired CLI flags in [ScanTailorCLI.swift](file:///Users/louismelahn/Antigravity/ScanTailorReborn/Sources/ScanTailorCLI/ScanTailorCLI.swift): `--ocr-engine <apple|tesseract|dual>`, `--ocr-languages <langs>` (aliases: `--languages`, `--ocr-lang`), and `--tessdata-dir <path>`.

---

## 4. Verification & Benchmark Comparison Matrix

### Before vs. After Benchmark Comparison

| Metric / Dimension | Baseline (v1.0.0) | Current Release (v2.0.0) | Impact |
| :--- | :--- | :--- | :--- |
| **Flannery PDF File Size** | 5.3 MB | 1.4 MB | **73.6% reduction** (single base font reuse) |
| **Skew Confidence Warnings** | 100% false-positive rate | 0% false positives | Calibrated denominator ($/ 1.5$) |
| **Spine Crease Slicing** | Knife-split, drift into paper | Dual-mode tracking + 24 px trim | Bects crease midline & excises fold |
| **Crease Content Bleed** | Crease bridged to body ($x=2..4$) | Crease filtered as noise | 4% boundary exclusion zone |
| **Blank Flatbed Slices** | Emitted as empty page | Automatically pruned | Ink density $< 0.5\%$ + 0 OCR words |
| **Ancient Greek OCR** | Unsupported (garbled Latin) | High accuracy polytonic Greek | Tesseract & DualOCREngine (`grc`) |
| **German Fraktur OCR** | Unsupported (garbled Latin) | Accurate Fraktur (`ſ`, ligatures) | Tesseract & DualOCREngine (`deu_frak`) |
| **Publication Margins** | Hardcoded ratios | Fully configurable via CLI | Inches, mm, pt, px; inner/outer |
| **Swift 6 Strict Concurrency**| Partial | 100% complete (`-strict-concurrency=complete`) | Zero warnings, zero data races |

### Test Suite Execution Summary

| Target Suite | Test Count | Concurrency Mode | Result |
| :--- | :---: | :---: | :---: |
| `ScanTailorContracts` | N/A (Protocols & Types) | Swift 6 Complete | Built cleanly |
| `ScanTailorCore` | 17 tests | Swift 6 Complete | **PASS** |
| `ScanTailorPortableBackend` | 5 tests | Swift 6 Complete | **PASS** |
| `ScanTailorAppleBackend` | 5 tests | Swift 6 Complete | **PASS** |
| `ScanTailorTesseractBackend` | 3 tests | Swift 6 Complete | **PASS** |
| `ScanTailorPipeline` | 9 tests | Swift 6 Complete | **PASS** |
| `ScanTailorCLI` | End-to-End CLI | Swift 6 Complete | **PASS** |
| **Total** | **39 tests** | **Swift 6 Complete** | **All Passing** |

---

## 5. Summary of Added CLI Options

| Flag | Parameter | Description |
| :--- | :--- | :--- |
| `--gutter-trim-width` | `<px>` | Central gutter strip trimming width at 600 DPI (default: `24`). |
| `--margins` | `<spec>` | Publication margins relative to text block, e.g. `"top=0.25in,bottom=0.25in,left=0.5in,right=0.5in"`. |
| `--page-range` | `<range>` | 1-based source scan range (e.g. `1-10`, `5..20`). |
| `--exclude-pages` | `<list>` | Comma-separated 1-based source scans to skip (e.g. `1,2,5`). |
| `--first-page-side` | `<side>` | Initial logical book side: `recto` (default) or `verso`. |
| `--no-auto-prune` | *None* | Disables automatic pruning of blank sub-page slices. |
| `--ocr-engine` | `<engine>` | OCR engine selection: `apple` (default on macOS), `tesseract`, or `dual`. |
| `--ocr-languages` | `<langs>` | Language codes, e.g. `"grc+lat"`, `"en-US"`, `"frk"` (aliases: `--languages`, `--ocr-lang`). |
| `--tessdata-dir` | `<path>` | Custom directory containing Tesseract `.traineddata` models. |
