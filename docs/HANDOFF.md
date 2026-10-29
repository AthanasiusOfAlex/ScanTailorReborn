# ScanTailorReborn — Cross-Machine Handoff & Active Engineering State

**Last Updated**: 2026-10-29  
**Branch**: `main`  
**Current Active Milestone**: Phase 4, Step 4.1, **Substep 4.1.1 — Automatic Font-Scale Heuristic & Median Glyph Height Analyzer** ([`docs/WHITE_PAPER.md`](WHITE_PAPER.md), lines 284–287)

This document captures everything required to set up **ScanTailorReborn** on a new machine and resume engineering seamlessly with zero lost context.

---

## 1. New Computer Setup & Portability Checklist

### 1.1 System Prerequisites
1. **macOS 14.0+ (Sonoma or newer)** with Xcode / Command Line Tools providing **Swift 6.0+** (`swift --version`).
2. **Tesseract & Leptonica C Libraries** (linked by the `CTesseract` target in [`Package.swift`](../Package.swift) via `/opt/homebrew/lib` on Apple Silicon or `/usr/local/lib` on Intel):
   ```bash
   brew install tesseract leptonica
   # Optional: historical & polyglot language packs (Ancient Greek, Fraktur, Latin)
   brew install tesseract-lang
   ```

### 1.2 Sanity Verification on Arrival
Run from the repository root:
```bash
swift build
swift test
```
All test suites under [`Tests/`](../Tests) synthesize their own PDFs and bitmaps at runtime and have **zero external file dependencies**.

### 1.3 Notes on Git-Ignored & External Items
- **Git Remote**: Check `git remote -v`. If no remote is configured when migrating, either push `main` to a new remote (`git remote add origin <url> && git push -u origin main`) or transfer via `git bundle create scantailor.bundle --all`.
- **`.agents/` (Git-Ignored)**: Listed in [`.gitignore`](../.gitignore). Held optional local agent skills (`swift-expert`, `skill-creator`) on the previous machine; **not** required to build, test, or develop.
- **Empirical Benchmark PDFs (External / Cloud-Synced)**: [`docs/WHITE_PAPER.md`](WHITE_PAPER.md) references three real-world test PDFs stored outside the repo in `OneDrive-MRC/PDFs-in-the-making/`:
  - `flannery.1993` (*Flannery 1993* — clean calibrated scan)
  - `vermeersch.1934` (*Vermeersch 1934* — photocopied two-page spreads with dark gutter seams)
  - `simpson.1968/simpson.1968.400-403.pdf` (*Simpson 1968* — handheld smartphone camera spread wrapped at 72 DPI)
  These files are **not** needed for `swift test`, only for optional empirical CLI runs and Phase 7.1 benchmark verification.

---

## 2. Architecture & Completed Project Baseline

### 2.1 Strict 5-Layer Swift 6 Package Structure
Every target compiles with `.swiftLanguageMode(.v6)` and `.enableUpcomingFeature("StrictConcurrency")`. **Apple-specific frameworks (`PDFKit`, `CoreGraphics`, `Vision`, `Metal`, `Accelerate`) never leak into `ScanTailorContracts`, `ScanTailorCore`, or `ScanTailorPipeline`.**

| Layer / Target | Responsibility |
| :--- | :--- |
| [`ScanTailorContracts`](../Sources/ScanTailorContracts) | Pure `Sendable` geometry (`Point2D`, `Rect2D`, `Size2D`, `AffineTransform2D`, `DewarpGrid`), raster buffers (`GrayscaleBuffer`, MSB 64-bit word-packed `BinaryBitmap`, `IntegralBuffer`), OCR/confidence models, and backend protocols (`PDFSourceReader`, `ComputeAccelerator`, `OCREngine`, `PDFDocumentWriter: ~Copyable`). |
| [`ScanTailorCore`](../Sources/ScanTailorCore) | Portable vision & layout algorithms: `PageSplitEstimator`, `SkewEstimator`, `ContentBoxDetector`, `CylindricalDewarpSolver` + `TextLineTracer`, `AdaptiveBinarizer` (Sauvola/Wolf/Otsu), `BackgroundNormalizer`, `BorderAndSpeckleCleaner`, `MarginHarmonizer` (3-tier placement), `PublicationMargins`, binary morphology, seed-fill, and connected components. |
| [`ScanTailorPipeline`](../Sources/ScanTailorPipeline) | 3-pass [`BookPipelineCoordinator`](../Sources/ScanTailorPipeline/BookPipelineCoordinator.swift) (Pass 1: 600 DPI per-page analysis; Pass 2: book-wide statistical harmonization & IQR outlier filtering; Pass 3: 600 -> 300 DPI render, OCR, & PDF assembly), `BookProcessingManifest`, and polyglot [`DualOCREngine`](../Sources/ScanTailorPipeline/OCR/DualOCREngine.swift). |
| [`ScanTailorAppleBackend`](../Sources/ScanTailorAppleBackend) / [`ScanTailorPortableBackend`](../Sources/ScanTailorPortableBackend) / [`ScanTailorTesseractBackend`](../Sources/ScanTailorTesseractBackend) | `MetalComputeAccelerator` (MPS/Metal + vImage), `ApplePDFSourceReader`, `AppleVisionOCREngine`, `ApplePDFDocumentWriter` (1-bit CCITT Group 4 + invisible text layer), `DiagnosticOverlayRenderer`, pure-Swift SIMD `PortableComputeAccelerator`, and `TesseractOCREngine` (`CTesseract` + Leptonica C API). |
| [`ScanTailorCLI`](../Sources/ScanTailorCLI) | `scantailor-cli` (`process`, `inspect`), JSON manifest persistence/overrides, and low-confidence diagnostic overlay generation. |

### 2.2 Completed Phases & Roadmap to `v1.0.0`
- **Completed**: Initial 8-milestone core pipeline + v2.0 upgrades (see [`CHANGELOG.md`](../CHANGELOG.md)), empirical smartphone camera evaluation, 10 **v1.0 Release Criteria**, Agent-in-the-Loop CLI architecture, and the 4-Phase / 19-Substep execution plan in [`docs/WHITE_PAPER.md`](WHITE_PAPER.md) (lines 250–417):
  - **Phase 4**: Physical Scale & Scale-Invariant Lighting (`4.1.1` – `4.2.2`) — **In Progress (`4.1.1`)**
  - **Phase 5**: Page Quadrangle & Desk Excision (`5.1.1` – `5.2.2`) — Pending
  - **Phase 6**: Canonical Layout & Agentic Manifest CLI (`6.1.1` – `6.3.2`) — Pending
  - **Phase 7**: Verification & Final `v1.0.0` Release (`7.1.1` – `7.2.2`) — Pending

---

## 3. Active Work State: Substep 4.1.1 Blueprint

### 3.1 Objective & Scope Boundaries
Implement **Substep 4.1.1: Automatic Font-Scale Heuristic & Median Glyph Height Analyzer**:
1. Measure book-wide typographic pixel metrics across binary bitmaps and OCR observations: lowercase $x$-height ($H_x$), cap/ascender height ($H_{\text{cap}}$), vertical stem stroke thickness ($W_{\text{stroke}}$ — consumed downstream by Substep 4.2.1), baseline leading ($L_{\text{leading}}$), and 1-em body height ($H_{\text{em}}$).
2. Deduce genuine source optical DPI and physical page dimensions from standard published book typography ($\approx 10.0\text{ pt}$ / $3.53\text{ mm}$ em height, $x$-height $= 0.48\text{ em} = 4.8\text{ pt}$, cap-height $= 0.71\text{ em} = 7.1\text{ pt}$).
3. Eliminate 72/96-DPI camera-wrapper canvas & memory explosions (e.g., shrinking a `4032 x 2268 pt` = `56.0" x 31.5"` 72-DPI camera spread from `33,600 x 18,900 px` / 635 MB buffers and `30.1" x 32.0"` billboard pages down to `8064 x 4536 px` / 36.5 MB at 600 DPI and `~5.5" x 7.6"` octavo output pages) while preserving exact `1.0x` physical dimensions and `0 ms` pre-probe overhead on calibrated scans.
4. Persist `fontScaleEstimate` telemetry in `BookProcessingManifest` and report it in `ScanTailorCLI`.
5. Pass 100% of existing and new Swift Testing suites (`swift test`).

**Strict Scope Boundaries** (do not prematurely implement later substeps):
- Explicit CLI flags (`--page-size`, `--content-box-size`, `--input-dpi`) belong to **Substep 4.1.2**.
- `physicalScaleAmbiguous: true` warning clamping belongs to **Substep 4.1.3**.
- Dynamic `BackgroundNormalizer` closing radius refactoring belongs to **Substep 4.2.1**.

### 3.2 Already Completed in Git for 4.1.1
- [`Sources/ScanTailorContracts/Protocols/PDFSourceReader.swift`](../Sources/ScanTailorContracts/Protocols/PDFSourceReader.swift): Added `func pageBoxPoints(at index: Int) throws(PDFReadError) -> Rect2D` to `PDFSourceReader`. [`ApplePDFSourceReader`](../Sources/ScanTailorAppleBackend/ApplePDFSourceReader.swift) already implements this exact method signature (line 46), and no other conformers exist. Verified `swift build` compiles cleanly with 0 warnings/errors.

### 3.3 Verified Mathematical & Codebase Invariants (Read Before Coding)
1. **`source.dpi` Dependency in `AdaptiveBinarizer` & `BackgroundNormalizer`**:
   - Both `AdaptiveBinarizer.binarize` ([`AdaptiveBinarizer.swift`](../Sources/ScanTailorCore/Binarization/AdaptiveBinarizer.swift), line 115) and `BackgroundNormalizer.estimateBackground` ([`BackgroundNormalizer.swift`](../Sources/ScanTailorCore/Binarization/BackgroundNormalizer.swift), line 76) scale window/closing radii by `Double(source.dpi) / 300.0`.
   - When probing an uncalibrated raster slice rendered at `probeRenderDPI` (e.g., `72 DPI`, `2004 x 2268 px`), re-tag the temporary probe `GrayscaleBuffer` with `nominalDPI = FontScaleAnalyzer.nominalProbeDPI(forPixelSize:isLikelySpread:)` (`clamp(Int((Double(height) / (isLikelySpread ? 8.5 : 9.0)).rounded()), 150, 600)`, e.g. `252 DPI`) **before** calling `binarizer.binarize(...)`, while passing the original `declaredDPI = probeRenderDPI` (`72`) to `FontScaleAnalyzer.analyzePage(in:declaredDPI:ocrObservations:)`.
2. **Resolution-Invariant Declared Body Point Size**:
   - `declaredBodyPointSize = inferredEmHeightPixels * 72.0 / Double(declaredDPI)` is invariant to `probeRenderDPI`.
   - Calibrated scans yield `~10.0–10.4 pt`. A 300-DPI camera photo wrapped at 72 DPI yields `~41.7 pt` -> `rawScaleFactor = 10.0 / 41.7 = 0.24`, `inferredSourceOpticalDPI = 72.0 / 0.24 = 300 DPI`, `effectiveRenderDPI = Int((Double(processingDPI) * 0.24).rounded()) = 144`, producing `8064 x 4536 px` buffers stamped with `dpi: 600`.
3. **Unified `GrayscaleBuffer` Resample Formula**:
   - For oversized direct `GrayscaleBuffer` inputs to `processGrayscalePages`, resample by `resampleRatio = Double(configuration.processingDPI) / inferredOpticalDPI` and record `appliedScaleCorrectionFactor = Double(buf.dpi) / inferredOpticalDPI`.
   - Whether a caller passes `33,600 x 18,900 px @ 600 DPI` (`inferredOpticalDPI = 2500`) or `4032 x 2268 px @ 72 DPI` (`inferredOpticalDPI = 300`), both yield the identical `8064 x 4536 px @ 600 DPI` buffer and `0.24` scale factor.
   - When downsampling (`resampleRatio < 0.75`), pre-blur via `accelerator.gaussianBlur(buf, sigma: min(8.0, 0.45 / resampleRatio))` prior to `accelerator.affineWarp` (`AffineTransform2D.scale(sx: Double(dstW) / Double(srcW), sy: Double(dstH) / Double(srcH))`).
4. **Auto-Rescale Gate (`areDeclaredPagesOversized`)**:
   - Auto-rescaling (`wasAutoRescaled = true`) **must only trigger** when declared physical page dimensions exceed calibrated bounds:
     - Portrait / near-square (`width <= height * 1.15`): `height > 14.0 || width > 11.5` inches.
     - Landscape / spread (`width > height * 1.15`): `height > 14.5 || width > 22.0` inches.
   - This prevents false-positive shrinking on normal-sized pages (`8.5" x 11"`, `6" x 9"`, or the `2" x 3"` synthetic fixture in [`CLIIntegrationTests.swift`](../Tests/ScanTailorAppleBackendTests/CLIIntegrationTests.swift) at line 118) that contain 24 pt title text or 3 pt synthetic blocks, while catching 100% of 72/96-DPI camera/image-wrapper PDFs (`>= 150 DPI` captures wrapped at `72 DPI` exceed `14"`).
5. **Component Filtering & Bimodal 1D Gaussian KDE**:
   - Do **not** impose an upper density cap `< 0.88` on candidate components (`density >= 0.10` is sufficient): sans-serif `'I'`/`'l'` stems and synthetic rectangular test glyphs have `density == 1.0`. Macro-blobs (dark desk surfaces) are already excluded by `h <= 8% pageH`, `w <= 18% pageW`, outer 5% margin exclusion (when dimensions `>= 200 px`), and horizontal collinear chaining (`>= 4` components).
   - Use ink-pixel-weighted median height (`comp.pixelCount` weights) for initial chaining scale so background dust specks cannot bias `coarseScale`.
   - Bimodal 1D Gaussian KDE (`sigma = max(0.85, 0.055 * medH)`):
     - **Case 1 (Bimodal pair `p1 < p2` with `p2 / p1` in `[1.22, 1.75]`, `f(p1) >= 0.28 * fMax`, `f(p2) >= 0.22 * fMax`)**: `xHeight = p1`, `capHeight = p2`, `emHeight = (w1 * (p1 / 0.48) + w2 * (p2 / 0.71)) / (w1 + w2)`. Prevents upward drift on capital-heavy dictionaries or German nouns.
     - **Case 2a (Unimodal + `ocrUppercaseRatio > 0.75`)**: `capHeight = p*`, `xHeight = p* * (0.48 / 0.71)`, `emHeight = p* / 0.71`.
     - **Case 2b (Unimodal merged low-DPI distribution)**: If `Q75 / Q25 >= 1.25`, `xHeight = Q30`, `capHeight = Q78`; else `xHeight = p*`, `capHeight = p* * (0.71 / 0.48)`.
6. **Pass 3 Coordinate Alignment**:
   - In [`BookPipelineCoordinator.swift`](../Sources/ScanTailorPipeline/BookPipelineCoordinator.swift) (lines 640–659), `ocrObservations` are normalized `[0, 1] x [0, 1]` relative to `finalBitmap` / `framed600` (not `p1.cleanedBitmap`). Calling `fontScaleAnalyzer.analyzePage(in: framed600, declaredDPI: configuration.processingDPI, ocrObservations: ocrObservations)` on up to 16 evenly sampled pages guarantees exact coordinate alignment and benefits from Pass 1/Pass 2 border/footer removal.
7. **Deterministic `existingManifest` Override Re-Runs**:
   - When `existingManifest?.fontScaleEstimate?.wasAutoRescaled == true`, reuse `existingManifest.fontScaleEstimate.appliedScaleCorrectionFactor` so `effectiveRenderDPI` matches Run 1 to the exact pixel and `PageManualOverride` pixel boxes stay 100% aligned.

### 3.4 Remaining Implementation Steps for 4.1.1
1. **Create [`Sources/ScanTailorCore/Layout/FontScaleAnalyzer.swift`](../Sources/ScanTailorCore/Layout/FontScaleAnalyzer.swift)**:
   - Implement `FontScaleAnalyzer` (`Sendable`), `Configuration`, `PageGlyphMetrics` (`Sendable, Equatable, Codable`), `PreRasterScaleDecision` (`Sendable, Equatable`), and `BookScaleEstimate` (`Sendable, Equatable, Codable`) with complete DocC documentation.
   - Include `nominalProbeDPI(forPixelSize:isLikelySpread:)`, `isDeclaredPageOversized(_:)`, `areDeclaredPagesOversized(_:)`, `analyzePage(in:declaredDPI:ocrObservations:)`, `estimatePreRasterScale(from:declaredPageSizesInches:)`, and `summarizeBook(postCalibrationMetrics:processingDPI:canonicalSinglePageSizeInches:preScaleDecision:)`.
2. **Edit [`Sources/ScanTailorPipeline/BookPipelineCoordinator.swift`](../Sources/ScanTailorPipeline/BookPipelineCoordinator.swift)**:
   - Add `public var fontScaleEstimate: FontScaleAnalyzer.BookScaleEstimate?` to `BookProcessingManifest` (default `nil`, `CodingKeys`, `decodeIfPresent` for backward compatibility).
   - Add `enableAutomaticFontScaleCalibration: Bool = true` and `fontScaleConfiguration: FontScaleAnalyzer.Configuration` to `BookPipelineCoordinator.Configuration`.
   - In `processBook(reader:...)`, check `reader.pageBoxPoints(at:)` on active source pages; when oversized (or `existingManifest?.fontScaleEstimate?.wasAutoRescaled == true`), probe up to 3 interior pages (longest edge ~3800 px, snapping `66...78` to `72 DPI`) to compute `effectiveRenderDPI`, rasterize active pages at `effectiveRenderDPI`, and stamp `dpi: configuration.processingDPI` on resulting `GrayscaleBuffer`s.
   - In `processGrayscalePages(...)` (via shared internal helper accepting optional `preScaleDecision`), detect and resample direct oversized `GrayscaleBuffer` inputs via `accelerator.affineWarp` (with anti-aliasing `gaussianBlur`), and compute post-calibration `PageGlyphMetrics` in Pass 3 on `framed600` + `ocrObservations` (up to 16 evenly sampled pages) to populate `manifest.fontScaleEstimate`.
3. **Edit [`Sources/ScanTailorCLI/ScanTailorCLI.swift`](../Sources/ScanTailorCLI/ScanTailorCLI.swift)**:
   - Log auto-rescaling summary in `executeProcess(_:)` when `result.manifest.fontScaleEstimate?.wasAutoRescaled == true`.
   - Append `Typography & Scale` telemetry line in `formatManifestSummary(_:)` when `manifest.fontScaleEstimate != nil` (verified no existing tests assert brittle string matching on `formatManifestSummary`).
4. **Write Unit & Integration Tests**:
   - Create [`Tests/ScanTailorCoreTests/FontScaleAnalyzerTests.swift`](../Tests/ScanTailorCoreTests/FontScaleAnalyzerTests.swift) covering bimodal KDE separation (including heavy capitalization), `strokeWidthPixels` & two-column `baselineSpacingPixels`, immunity to outer dark desk blocks & dust specks, OCR observation fusion (ALL-CAPS disambiguation + tilted-line box height guard), `areDeclaredPagesOversized` + `estimatePreRasterScale`, and direct oversized `GrayscaleBuffer` rescaling in `BookPipelineCoordinator.processGrayscalePages`.
   - Extend [`Tests/ScanTailorAppleBackendTests/CLIIntegrationTests.swift`](../Tests/ScanTailorAppleBackendTests/CLIIntegrationTests.swift) with an end-to-end synthetic 72-DPI camera-wrapper spread PDF (`2400 x 1800 pt` = `33.3" x 25.0"` with 300-DPI-scaled 10 pt text lines), asserting book-sized output pages (`~5"–6.5" x 7"–8.5"`), `wasAutoRescaled == true`, and clean JSON manifest round-trip.
5. **Run `swift test`** and confirm 0 warnings, 0 errors, and 100% pass rate.
