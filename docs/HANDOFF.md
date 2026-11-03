# ScanTailorReborn — Cross-Machine Handoff & Active Engineering State

**Last Updated**: 2026-11-02  
**Branch**: `main`  
**Current Active Milestone**: Phase 4, Step 4.2, **Substep 4.2.2 — Dual-Pass Illumination Flattening (Anti-Starvation)** ([`docs/WHITE_PAPER.md`](WHITE_PAPER.md), lines 302–305)

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
All test suites under [`Tests/`](../Tests) synthesize their own PDFs and bitmaps at runtime and have **zero external file dependencies** (currently **98 tests across 17 suites**, passing with 0 warnings).

### 1.3 Notes on Git-Ignored & External Items
- **Git Remote**: Check `git remote -v`. If no remote is configured when migrating, either push `main` to a new remote (`git remote add origin <url> && git push -u origin main`) or transfer via `git bundle create scantailor.bundle --all`.
- **`.agents/` (Git-Ignored)**: Listed in [`.gitignore`](../.gitignore). Holds optional local agent skills (`swift-expert`, `skill-creator`); **not** required to build, test, or develop.
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
| [`ScanTailorCore`](../Sources/ScanTailorCore) | Portable vision & layout algorithms: `FontScaleAnalyzer`, `PhysicalSizeSpec`, `PageSplitEstimator`, `SkewEstimator`, `ContentBoxDetector`, `CylindricalDewarpSolver` + `TextLineTracer`, `AdaptiveBinarizer` (Sauvola/Wolf/Otsu), `BackgroundNormalizer`, `BorderAndSpeckleCleaner`, `MarginHarmonizer` (3-tier placement), `PublicationMargins`, binary morphology, seed-fill, and connected components. |
| [`ScanTailorPipeline`](../Sources/ScanTailorPipeline) | 3-pass [`BookPipelineCoordinator`](../Sources/ScanTailorPipeline/BookPipelineCoordinator.swift) (pre-raster font-scale calibration; Pass 1: 600 DPI per-page analysis; Pass 2: book-wide statistical harmonization & IQR outlier filtering; Pass 3: 600 -> 300 DPI render, OCR, post-calibration typography telemetry, & PDF assembly), `BookProcessingManifest`, and polyglot [`DualOCREngine`](../Sources/ScanTailorPipeline/OCR/DualOCREngine.swift). |
| [`ScanTailorAppleBackend`](../Sources/ScanTailorAppleBackend) / [`ScanTailorPortableBackend`](../Sources/ScanTailorPortableBackend) / [`ScanTailorTesseractBackend`](../Sources/ScanTailorTesseractBackend) | `MetalComputeAccelerator` (MPS/Metal + vImage), `ApplePDFSourceReader`, `AppleVisionOCREngine`, `ApplePDFDocumentWriter` (1-bit CCITT Group 4 + invisible text layer), `DiagnosticOverlayRenderer`, pure-Swift SIMD `PortableComputeAccelerator`, and `TesseractOCREngine` (`CTesseract` + Leptonica C API). |
| [`ScanTailorCLI`](../Sources/ScanTailorCLI) | `scantailor-cli` (`process`, `inspect`), JSON manifest persistence/overrides, typography & scale telemetry reporting, and low-confidence diagnostic overlay generation. |

### 2.2 Completed Phases & Roadmap to `v1.0.0`
- **Completed**: Initial 8-milestone core pipeline + v2.0 upgrades (see [`CHANGELOG.md`](../CHANGELOG.md)), empirical smartphone camera evaluation, 10 **v1.0 Release Criteria**, Agent-in-the-Loop CLI architecture, and the 4-Phase / 19-Substep execution plan in [`docs/WHITE_PAPER.md`](WHITE_PAPER.md) (lines 250–417):
  - **Phase 4**: Physical Scale & Scale-Invariant Lighting (`4.1.1` – `4.2.2`) — **In Progress (`4.1.1` – `4.2.1` Completed; `4.2.2` Active)**
  - **Phase 5**: Page Quadrangle & Desk Excision (`5.1.1` – `5.2.2`) — Pending
  - **Phase 6**: Canonical Layout & Agentic Manifest CLI (`6.1.1` – `6.3.2`) — Pending
  - **Phase 7**: Verification & Final `v1.0.0` Release (`7.1.1` – `7.2.2`) — Pending

---

## 3. Completed Phase 4 Substeps (`4.1.1`–`4.2.1`) & Active Substep 4.2.2 State

### 3.1 Recently Completed: Substep 4.1.1 (`FontScaleAnalyzer`)
Implemented automatic font-scale heuristic, median glyph height analyzer, and pre-raster camera-wrapper scale rescue across 4 source/CLI/test layers:
1. **[`Sources/ScanTailorCore/Layout/FontScaleAnalyzer.swift`](../Sources/ScanTailorCore/Layout/FontScaleAnalyzer.swift)**:
   - Measures per-page and book-wide typographic metrics: lowercase $x$-height (`xHeightPixels`), cap/ascender height (`capHeightPixels`), 1-em body height (`inferredEmHeightPixels`), vertical stem stroke thickness (`strokeWidthPixels` — ready for Substep 4.2.1), and two-column-safe baseline spacing (`baselineSpacingPixels`).
   - Uses ink-pixel-weighted median `coarseScale`, collinear horizontal text chaining (`>= 4` components), and bimodal 1D Gaussian KDE (`p2 / p1` in `[1.22, 1.75]`) with OCR uppercase-ratio disambiguation and tilted-line box height guards (`[0.75x, 1.25x]`).
   - Gates automatic rescaling via `areDeclaredPagesOversized(_:)` (`> 14.0"` tall or `> 11.5"` wide for portrait; `> 14.5"` tall or `> 22.0"` wide for spreads) so calibrated scans incur `0 ms` pre-probe overhead and exact `1.0x` physical dimensions.
2. **[`Sources/ScanTailorPipeline/BookPipelineCoordinator.swift`](../Sources/ScanTailorPipeline/BookPipelineCoordinator.swift)**:
   - Added `BookProcessingManifest.fontScaleEstimate: FontScaleAnalyzer.BookScaleEstimate?` (backward-compatible `decodeIfPresent`) and `Configuration.enableAutomaticFontScaleCalibration` / `fontScaleConfiguration`.
   - Pre-probes up to 3 interior pages on oversized PDFs via `reader.pageBoxPoints(at:)` (re-tagging probe slices with `FontScaleAnalyzer.nominalProbeDPI` prior to `binarizer.binarize`), rasterizes active pages at `effectiveRenderDPI`, and stamps `dpi: configuration.processingDPI`.
   - Resamples oversized direct `GrayscaleBuffer` inputs in `processGrayscalePages` via anti-aliased `gaussianBlur` + `affineWarp` (`resampleRatio = Double(processingDPI) / inferredOpticalDPI`), reuses `existingManifest.fontScaleEstimate.appliedScaleCorrectionFactor` on deterministic override re-runs, and computes post-calibration `BookScaleEstimate` across up to 16 evenly sampled Pass 3 `framed600` pages.
3. **[`Sources/ScanTailorCLI/ScanTailorCLI.swift`](../Sources/ScanTailorCLI/ScanTailorCLI.swift)**:
   - Logs pre-raster auto-rescaling diagnostics in `executeProcess(_:)` when `wasAutoRescaled == true` and appends `Typography & Scale:` telemetry in `formatManifestSummary(_:)`.
4. **Tests (`83/83` passing, 0 warnings)**:
   - [`Tests/ScanTailorCoreTests/FontScaleAnalyzerTests.swift`](../Tests/ScanTailorCoreTests/FontScaleAnalyzerTests.swift) (6 unit/pipeline tests).
   - [`Tests/ScanTailorAppleBackendTests/CLIIntegrationTests.swift`](../Tests/ScanTailorAppleBackendTests/CLIIntegrationTests.swift) (`testUncalibrated72DPICameraWrapperSpreadPDFAutoRescalesToBookDimensions`).

### 3.2 Recently Completed: Substep 4.1.2 (`PhysicalSizeSpec` & CLI/Manifest Dimension Controls)
Implemented explicit CLI & manifest physical dimension and source-DPI overrides across `ScanTailorCore`, `ScanTailorPipeline`, `ScanTailorCLI`, and tests:
1. **[`Sources/ScanTailorCore/Layout/PhysicalSizeSpec.swift`](../Sources/ScanTailorCore/Layout/PhysicalSizeSpec.swift)**:
   - `Sendable, Equatable, Codable, CustomStringConvertible` 2D dimension type supporting `in`, `mm`, `cm`, `pt`, and `px` (600-DPI baseline) plus 17 bibliographic and ISO/ANSI book presets (`octavo`, `trade-paperback`, `royal-octavo`, `crown-octavo`, `demy-octavo`, `duodecimo`, `mass-market`, `quarto`, `folio`, `a4`, `a5`, `a6`, `b5`, `jis-b5`, `letter`, `legal`, `executive`, and normalized aliases).
   - Dual-form `Codable` encoding structured `{width, height, unit, preset?}` JSON while decoding both keyed JSON objects and compact string shorthands (e.g. `"a5"`, `"4.5x7.5in"`) for ergonomic agentic manifest edits.
2. **[`Sources/ScanTailorCore/Layout/MarginHarmonizer.swift`](../Sources/ScanTailorCore/Layout/MarginHarmonizer.swift)** & **[`PublicationMargins.swift`](../Sources/ScanTailorCore/Layout/PublicationMargins.swift)**:
   - Added `targetPageSize: PhysicalSizeSpec?` and `targetContentBoxSize: PhysicalSizeSpec?` to `MarginHarmonizer.Configuration` (locking output `canvasSize` with proportional symmetric/asymmetric gutter margin distribution, using `targetContentBoxSize.width` as `priorCanonicalWidth` for Pass 2 smudge outlier trimming, and clamping `Tier 1` destination origins safely inside `canvasSize`).
   - Added `"cm"` / `"centimeter"` / `"centimeters"` unit support to `PublicationMargins.Dimension.parse(_:)`.
3. **[`Sources/ScanTailorPipeline/BookPipelineCoordinator.swift`](../Sources/ScanTailorPipeline/BookPipelineCoordinator.swift)** & **[`ScanTailorCLI.swift`](../Sources/ScanTailorCLI/ScanTailorCLI.swift)**:
   - Added backward-compatible `inputDPI: Int?`, `pageSize: PhysicalSizeSpec?`, and `contentBoxSize: PhysicalSizeSpec?` to `BookProcessingManifest`, `BookPipelineCoordinator.Configuration`, and `ScanTailorCLI.ProcessOptions` (`--page-size`/`--trim-size`, `--content-box-size`/`--content-size`/`--text-box-size`, `--input-dpi`/`--source-dpi` in `18...4800`).
   - Enforced 4-level override precedence (`--input-dpi` > `--page-size` > `--content-box-size` > automatic `FontScaleAnalyzer` calibration) across both PDF and `GrayscaleBuffer` pipelines, resolving CLI flags ahead of `existingManifest` overrides.
4. **Tests (`88/88` passing across 15 suites, 0 warnings)**:
   - [`Tests/ScanTailorCoreTests/DimensionControlsTests.swift`](../Tests/ScanTailorCoreTests/DimensionControlsTests.swift) (4 unit/pipeline tests).
   - [`Tests/ScanTailorAppleBackendTests/CLIIntegrationTests.swift`](../Tests/ScanTailorAppleBackendTests/CLIIntegrationTests.swift) (`testExplicitCLIDimensionAndInputDPIOverridesProduceExactPDFMediaBoxes`).

### 3.3 Recently Completed: Substep 4.1.3 (`Anti-Billboard Canvas Normalization & Agent Escalation`)
Implemented dual-stage anti-billboard PDF canvas clamping and `physicalScaleAmbiguous` agent escalation across `ScanTailorCore`, `ScanTailorPipeline`, `ScanTailorCLI`, and tests:
1. **[`Sources/ScanTailorCore/Layout/FontScaleAnalyzer.swift`](../Sources/ScanTailorCore/Layout/FontScaleAnalyzer.swift)**:
   - Added `minConfidenceForAutoRescale: Double` (`0.55`) and `fallbackAmbiguousSinglePageSizeInches: Size2D` (`8.5" x 11.0"`) to `FontScaleAnalyzer.Configuration`, plus backward-compatible `isPhysicalScaleAmbiguous` and `wasAntiBillboardClamped` flags on `PreRasterScaleDecision` and `wasAntiBillboardClamped` on `BookScaleEstimate`.
   - Added `clampAntiBillboardPageSizeInches(_:)` for aspect-preserving PDF canvas clamping within calibrated limits (`<= 11.5" x 14.0"` portrait, `<= 22.0" x 14.0"` landscape).
   - Updated `estimatePreRasterScale(from:declaredPageSizesInches:referenceDeclaredDPI:splitMode:observedSpreadLayout:)` to reject low-confidence typography (`medianConf < 0.55`, preventing sparse cover display titles from crushing pages into postage stamps), apply aspect-preserving fallback clamping when typography is absent or low-confidence, clamp residual `> 14.0"` post-rescale pages, and flag `isPhysicalScaleAmbiguous = true` whenever scale could not be determined automatically with high confidence and estimated single-page height exceeded `14.0"`.
2. **[`Sources/ScanTailorPipeline/BookPipelineCoordinator.swift`](../Sources/ScanTailorPipeline/BookPipelineCoordinator.swift)**:
   - Added backward-compatible `BookProcessingManifest.physicalScaleAmbiguous: Bool` (defaults to `false` via `decodeIfPresent`).
   - Recorded empirical `observedSpreadLayout` from `PageSplitEstimator` during probing, enforced zero-probe anti-billboard normalization even when `enableAutomaticFontScaleCalibration == false` (unless an explicit dimension/DPI override is active), and added a Pass 3 `pageBoxPoints` anti-billboard safety guard before `writer.appendPage(...)`.
   - Preserved `physicalScaleAmbiguous` and `wasAntiBillboardClamped` on non-scale override re-runs (`existingManifest`), while clearing `physicalScaleAmbiguous = false` and honoring exact user-requested dimensions (including `folio` `12" x 15"`) when `inputDPI`, `pageSize`, or `contentBoxSize` is explicitly provided.
3. **[`Sources/ScanTailorCLI/ScanTailorCLI.swift`](../Sources/ScanTailorCLI/ScanTailorCLI.swift)**:
   - Emits `WARNING [physicalScaleAmbiguous=true]: ...` escalation guidance in `executeProcess(_:)` and surfaces `Physical Scale Status: AMBIGUOUS (physicalScaleAmbiguous=true)` and `anti-billboard clamped` telemetry in `formatManifestSummary(_:)`.
4. **Tests (`93/93` passing across 16 suites, 0 warnings)**:
   - [`Tests/ScanTailorCoreTests/AntiBillboardTests.swift`](../Tests/ScanTailorCoreTests/AntiBillboardTests.swift) (4 unit/pipeline tests covering illustration-only and sparse display-cover wrappers, calibrated Octavo & `8.5" x 14.0"` Legal preservation, disabled auto-calibration + Pass 3 margin-inflated canvas guard, legacy JSON decoding, non-scale rerun preservation, and explicit `folio` resolution).
   - [`Tests/ScanTailorAppleBackendTests/CLIIntegrationTests.swift`](../Tests/ScanTailorAppleBackendTests/CLIIntegrationTests.swift) (`testIllustrationOnlyCameraWrapperClampsBillboardMediaBoxAndEscalatesUntilPageSizeOverride` + `physicalScaleAmbiguous == false` verification on `testUncalibrated72DPICameraWrapperSpreadPDFAutoRescalesToBookDimensions`).

### 3.4 Recently Completed: Substep 4.2.1 (`Dynamic Kernel Radius & Sigma Derivation`)
Implemented glyph-scale adaptive morphological closing radius, Gaussian smoothing $\sigma$, dynamic pyramid downsampling, and $O(1)$ van Herk separable grayscale morphology across `ScanTailorCore`, `ScanTailorPipeline`, and tests:
1. **[`Sources/ScanTailorCore/Binarization/BackgroundNormalizer.swift`](../Sources/ScanTailorCore/Binarization/BackgroundNormalizer.swift)**:
   - Added `GlyphScale` (`xHeightPixels`, `strokeWidthPixels`, `capHeightPixels`, `confidence`, plus `init(metrics:scaleFactor:)`), `DerivedKernelParameters`, and `NormalizationResult`, and extended `BackgroundNormalizer.Configuration` (`Codable`) with backward-compatible `enableGlyphScaleAdaptation` (`true`), `closingRadiusXHeightMultiplier` (`1.25`), `closingRadiusStrokeWidthMultiplier` (`6.25`), and `minimumGlyphConfidence` (`0.35`).
   - Implemented `deriveKernelParameters(imageWidth:imageHeight:dpi:glyphScale:)` to scale full-resolution closing radius $R_{\text{closing}} = \max(\alpha_x H_x, \alpha_s W_{\text{stroke}}, 0.85 H_{\text{cap}})$, full-resolution Gaussian $\sigma_{\text{full}} = \sigma_{\text{ref},300} \cdot (R_{\text{closing}} / R_{\text{ref},300})$, and `effectiveDownsampleFactor` (`max(baseFactor, fullResClosingRadius / (3 * baseFactor))`, preventing 64-tap Gaussian truncation while preserving pure inter-line paper blocks), with `nominalProbeDPI` fallback on non-text 72/96-DPI camera plates and safe bounds on blank/low-confidence pages.
   - Implemented `estimateGlyphScale(in:accelerator:)` using a compact `<= 1600 px` area-averaged probe + $O(1)$ integral-image Sauvola pre-binarization (`radius = 6%` of `min(W, H)`, zero recursion, zero thick-stroke hollowing) + `FontScaleAnalyzer` (`maxComponentHeightFraction: 0.20`, `maxComponentWidthFraction: 0.30`).
   - Replaced $O(W \cdot H \cdot R)$ nested loops in `grayscaleDilateSeparable` and `grayscaleErodeSeparable` with bit-exact $O(1)$-per-pixel van Herk / Gil-Werman prefix-suffix block scans.
2. **[`Sources/ScanTailorCore/Binarization/AdaptiveBinarizer.swift`](../Sources/ScanTailorCore/Binarization/AdaptiveBinarizer.swift)** & **[`BookPipelineCoordinator.swift`](../Sources/ScanTailorPipeline/BookPipelineCoordinator.swift)**:
   - Added `AdaptiveBinarizer.deriveWindowRadius(for:glyphScale:)` and optional `glyphScale` forwarding on `binarize(_:accelerator:glyphScale:)` / `binarize(_:integralBuffer:glyphScale:)` so local Sauvola/Wolf-Jolion thresholding shares `BackgroundNormalizer`'s resolved `GlyphScale` without probing twice and prevents interior hollowing on thick camera/display strokes.
   - Updated Pass 1 dewarped re-binarization in `BookPipelineCoordinator` to reuse full-resolution `GlyphScale` measured on `initialCleaned`.
3. **Tests (`98/98` passing across 17 suites, 0 warnings)**:
   - [`Tests/ScanTailorCoreTests/GlyphAdaptiveNormalizationTests.swift`](../Tests/ScanTailorCoreTests/GlyphAdaptiveNormalizationTests.swift) (5 unit/pipeline tests covering `deriveKernelParameters` mathematical invariants & `Codable`, 72-DPI camera character-erosion prevention vs fixed-DPI starvation, calibrated 300-DPI bold stroke-width protection, blank/illustration fallbacks, bit-exact van Herk equivalence, and Pass 1 `BookPipelineCoordinator` integration).

### 3.5 Active Work State: Substep 4.2.2 — Dual-Pass Illumination Flattening (Anti-Starvation)
Status: **Implementation in progress (2/5 new tests passing, 98/98 existing tests passing, 0 warnings)**

#### 3.5.1 Work Completed So Far
1. **Mathematical Invariants & Dual-Pass Background Quotient Engine** ([`Sources/ScanTailorCore/Binarization/BackgroundNormalizer.swift`](../Sources/ScanTailorCore/Binarization/BackgroundNormalizer.swift)):
   - **Extended Telemetry & Configuration**:
     - Added `dualPassApplied: Bool`, `secondPassDownsampledBlurSigma: Double`, `contrastLevelingApplied: Bool`, and `peakContrastGain: Double` to `DerivedKernelParameters` (`Codable` with `decodeIfPresent` defaults).
     - Added `enableDualPassFlattening: Bool = true`, `secondPassBlurSigmaScale: Double = 0.65`, `enableAntiStarvationContrastLeveling: Bool = true`, and `maximumContrastGain: Double = 2.50` (`[1.0, 3.5]`) to `BackgroundNormalizer.Configuration` (`Codable` with backward-compatible defaults).
   - **Pass 1 & Unclipped Quotient Calculation**:
     - Computes coarse glyph-bridging closing and Gaussian smoothing on downsampled grid.
     - Upsamples Pass 1 background to full resolution and computes unclipped fixed-point quotient $Q_1 = (I \cdot 255) / B_1$ in `UInt16` (`[0, 1020]`), eliminating 8-bit clipping so both dark ink and bright highlights retain exact relative ratios.
   - **Slope-Aware Morphological Closing (`closeSlopeAwareUInt16`)**:
     - Developed $O(N)$ separable 1D closing with continuous boundary-slope extrapolation when boundary pixels follow a smooth gradient (`v >= 96 && abs(v - vRef) <= 28 * dist`).
     - Eliminates upward slope bias on steep spine-boundary ramps and camera vignette slopes right down to $x = 0$, preventing artificial gutter shadows.
   - **Pass 2 Pure-Paper Sampling & Diffusion Inpainting**:
     - Samples pure paper pixels ($s \ge \text{rawPaperFloor}$ and $Q_1 \ge \max(96, 0.88 \cdot \text{crest})$), discarding ink cores and stroke skirts.
     - Inpaints ink-covered cells using multi-stride normalized spatial diffusion (`strides = [1, 1, 2, 4, 8, 16, 32]`) and applies normalized Gaussian smoothing ($\sigma_2 = 0.65 \cdot \sigma_1$) to form residual background $B_2$.
     - Computes composite background $B_{\text{eff}} = \min(255, \max(1, (B_1 \cdot B_2) / 255))$ in Q6 fixed-point format (`backgroundSmallQ6`).
   - **Anti-Starvation Contrast Leveling**:
     - Measures ink-core foreground absorption $A = 255 - Q_2$ for cells with $Q_1 \le 0.78 \cdot \text{crest}$.
     - Detects veiling-glare contrast depression ($p_{10} < p_{80} - 6.0$).
     - Smooths macro glare envelope via $O(1)$ 3-pass running-sum box blur (`boxBlur2DClampedFloat`), free from Gaussian kernel-radius truncation.
     - Applies $C^1$-smooth noise-gated quadratic-to-linear boost above noise floor ($A > 16$, $Q_2 < 239$), harmonizing veiled ink cores to crisp black without boosting paper grain or faint bleed-through.
   - **Fast Bilinear Axis LUT Precomputation**:
     - Added `makeBilinearAxisLUT` to precalculate horizontal interpolation coordinates and weights in $O(W)$ instead of $O(W \cdot H)$ floating-point calculations during normalization and upsampling.

2. **Outlier-Robust Wolf-Jolion Anchor Estimation** ([`Sources/ScanTailorCore/Binarization/AdaptiveBinarizer.swift`](../Sources/ScanTailorCore/Binarization/AdaptiveBinarizer.swift)):
   - Updated `measureWolfJolionAnchors` to sample the interior $[8.3\%..91.7\%]$ region of the page (with automatic full-page fallback if interior `maxStdDev < 3.0`).
   - Uses $0.05\%$ quantile for dark anchor $M$ (`minGray`) and $98\%$ active-window quantile for peak variance $R_{\max}$ (`maxStdDev`).
   - Prevents peripheral camera desk borders (e.g. $x < 22$ dark wood strips) from poisoning global Wolf-Jolion parameters.

3. **Passing Test Suites & Diagnostics** ([`Tests/ScanTailorCoreTests/DualPassIlluminationTests.swift`](../Tests/ScanTailorCoreTests/DualPassIlluminationTests.swift)):
   - **98/98 existing tests across 17 suites pass** with 0 warnings.
   - **2/5 new tests in `DualPassIlluminationTests` pass**:
     - `testCodableBackwardCompatibilityEdgeCasesAndBookPipelineUniformity` (JSON encoding/decoding backward compatibility, zero strength passthrough, dark sheet, and 300-DPI `BookPipelineCoordinator` Pass 1 pipeline).
     - `testBleedThroughAndPaperGrainAreProtectedBySoftNoiseGate` (Verified zero false positives on reverse-side bleed-through ghosts and random paper fiber noise under contrast leveling).

#### 3.5.2 Diagnostics for the 3 Remaining Tests in `DualPassIlluminationTests.swift`
1. **`testSimpsonPage2GradientAndGlareAchievesUniformStrokeWeightWithoutStarvation`**:
   - Status: Paper flattening and glare recovery work properly (upper paper $\ge 250$, lower paper $\ge 250$, upper ink mean $< 112.0$, upper/lower text recall both $\ge 92\%$ vs single-pass $< 72\%$).
   - Current Failure: Line 354 `abs(upperStemWidth - lowerStemWidth) <= 0.60` measured `1.81 px`.
   - Action Needed: Investigate why upper glared stem run width is `1.81 px` different from lower stem run width. Check the binarization threshold / contrast gain multiplier, or tune `measureMeanStemRunWidth` scanline sampling / tolerance in the test.
2. **`testDenseMultiColumnTextDoesNotDepressBackgroundEstimateInPass2`**:
   - Status: Runs and estimates background cleanly, but Pass 1 error was low (`maePass1 = 0.143` vs expected `> 8.0`).
   - Current Failure: Lines 459 & 461 `maePass1 > 8.0` and `maePass2 < maePass1 * 0.35`.
   - Action Needed: The synthetic two-column layout currently has enough pure paper between words/lines that Pass 1's sliding maximum captures uncontaminated paper. Adjust the synthetic column fixture (e.g. tighter line leading or a realistic optical PSF blur spreading ink across narrow inter-line gaps) so that Pass 1's downsampled area averaging is pulled down by ink skirts (`maePass1 > 6.0..8.0`) while Pass 2's pure paper sampling isolates clean gap centers (`maePass2 < 3.0` and `maePass2 < maePass1 * 0.40`).
3. **`testSteepBoundarySpineShadowFlattensRightUpToPageEdgeWithoutGutterCloud`**:
   - Status: Steep spine shadow paper is flattened from $< 165$ (single pass) to $\ge 242.0$ (dual pass), and spine-adjacent text recall is $\ge 94\%$.
   - Current Failure: Line 542 `spineMarginFalsePositives == 0` measured `1476` false positive pixels in margin $x = 4..<32$.
   - Action Needed: Check the paper background estimate right at the boundary $x = 4..<32$. Ensure `closeSlopeAwareUInt16` extrapolation or `rawB2` paper floor in `computeResolvedSmallFields` correctly covers the boundary margin cells so the threshold does not dip below the spine paper level.

---

## 4. Next Milestone Resume Prompt

To resume engineering on **Substep 4.2.2**, copy and provide the following prompt:

```markdown
We are resuming development of ScanTailorReborn on Substep 4.2.2: Dual-Pass Illumination Flattening (Anti-Starvation).

1. Read `.agents/skills/swift-expert/SKILL.md` in full before modifying Swift code.
2. Review Section 3.5 of `docs/HANDOFF.md` for the current status of Substep 4.2.2.
3. Fix the 3 remaining test issues in `Tests/ScanTailorCoreTests/DualPassIlluminationTests.swift` and `Sources/ScanTailorCore/Binarization/BackgroundNormalizer.swift`:
   - `testSimpsonPage2GradientAndGlareAchievesUniformStrokeWeightWithoutStarvation`: stem run width uniformity (`abs(upperStemWidth - lowerStemWidth) <= 0.60`).
   - `testDenseMultiColumnTextDoesNotDepressBackgroundEstimateInPass2`: realistic optical PSF ink spread causing Pass 1 depression (`maePass1`) and Pass 2 recovery (`maePass2`).
   - `testSteepBoundarySpineShadowFlattensRightUpToPageEdgeWithoutGutterCloud`: resolve the 1476 margin false positives in `x = 4..<32`.
4. Run `swift test --filter DualPassIlluminationTests` (sandboxed first, then with bypass if needed) until all 5 tests pass.
5. Run full `swift test` and confirm 103/103 tests pass with 0 warnings across all 18 suites.
6. Update `docs/HANDOFF.md` to mark Substep 4.2.2 and Phase 4 complete, advance milestone to Phase 5 Substep 5.1.1, report concisely with clickable file:// links, and pause before starting Phase 5.
```
