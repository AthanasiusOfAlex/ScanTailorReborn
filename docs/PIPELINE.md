# Pipeline stages

A stage-by-stage specification, in processing order, with the defaults and the reasons behind them. Coordinates are in pixels of the 600 DPI processing raster unless stated otherwise. [ARCHITECTURE.md](ARCHITECTURE.md) gives the overall flow. Each stage ends with its known limitations.

---

## 1. Physical scale

Phone photos wrapped by tools such as `img2pdf` declare 72 DPI. A 4032 px photo then reads as a 56 in page, which rasterizes to 33,600 px at 600 DPI and prints as a billboard.

- **Gate.** Rescaling is considered only when the declared pages are oversized (`FontScaleAnalyzer.areDeclaredPagesOversized`):

  | Pages | Oversized when |
  | :--- | :--- |
  | Portrait | taller than 14 in or wider than 11.5 in |
  | Spreads | taller than 14.5 in or wider than 22 in |

  Calibrated scans skip the probe and are used at their declared size.
- **Font-scale probe** (`FontScaleAnalyzer`): measures x-height, cap height, em height, stroke width and baseline spacing on up to three interior pages:
  - takes an ink-weighted median over collinear chains of at least 4 components;
  - separates x-height from cap height with a bimodal KDE, using the OCR uppercase ratio;
  - relates the measurements to roughly 10 pt book type to infer the optical DPI.

  Typography with a median confidence below 0.55, such as a sparse display cover, is rejected.
- **Precedence:** `--input-dpi`, then `--page-size`, then `--content-box-size`, then automatic calibration.
- **Anti-billboard clamp:** when typography is missing or unreliable, the page is clamped with its aspect kept, to at most 11.5 × 14 in (portrait) or 22 × 14 in (landscape). The manifest then sets `physicalScaleAmbiguous: true` when the result is still taller than 14 in. An agent seeing that flag should ask the user for a trim size.
- **Outliers** share the body's clamp factor, so a cover keeps its size relative to the book, and are capped on their own only if still too big. Explicit size options skip the clamp.
- **Sizes** (`PhysicalSizeSpec`): units are `in`, `mm`, `cm`, `pt` and `px`. Presets: octavo, trade-paperback, royal-octavo, crown-octavo, demy-octavo, duodecimo, mass-market, quarto, folio, a4, a5, a6, b5, jis-b5, letter, legal and executive. JSON accepts either an object or a short string such as `"a5"` or `"4.5x7.5in"`.

## 2. Perspective rectification

**`DocumentQuadDetector`** ([`DocumentQuadDetector.swift`](../Sources/ScanTailorCore/Geometry/DocumentQuadDetector.swift)) works on a raster whose long side is at most 1024 px:

1. **Paper region.** The score is local mean minus local standard deviation, split with Otsu. A second split separates a light desk from paper when dark text would otherwise group them. The region is closed, its holes filled, and its convex hull reduced to the maximum inscribed quad.
2. **Edges.** Multi-scale Canny (σ = 1, 2 and 4) keeps edges that persist across scales, are dark outside and bright inside, and separate the region from the rest. This rejects text and wood grain.
3. **Sides.** Each side is fitted by deterministic RANSAC plus total least squares. A side whose end segments disagree by more than 1.5° is a `bentSide` (an open-book spine dip) and uses corner-local lines.
4. **Refinement.** Sub-pixel, at full resolution, with MAD-trimmed refits. Corners are line intersections, so occluded corners are extrapolated.
5. **Validation.** The quad must be convex, with corner angles of 90° ± 35°, and pass checks on proportions, area, side support and contrast. A region that fills the frame counts as `fullFrame` only if the border ring is at least 80 % paper; a picture of bare wood is `rejected`.

The outcome is `detected`, `fullFrame` or `rejected`, with flags `occluded:<side>`, `bentSide:<side>`, `lowContrastDesk`, `cornerFallback:<corner>` and `noDeskDetected`. On synthetic fixtures corner errors are 0.07 px or less.

**`PerspectiveRectifier`** ([`PerspectiveRectifier.swift`](../Sources/ScanTailorCore/Geometry/PerspectiveRectifier.swift)) maps the quad onto a rectangle with a Hartley-normalized homography:

- **Aspect ratio** from the Zhang–He whiteboard method. When the solved focal length is implausible it assumes a focal length of 0.8 × the image diagonal.
- **Page-size snap:** with `--page-size`, an aspect within 15 % of a single page or a spread snaps to it.
- **Output:** no edge is downsampled, and the output is capped at 1.25× the source pixels. Resampling is bilinear, and pixels outside the source are white.

Flatbed pages (`fullFrame`, `rejected`, disabled) pass through byte-identical. The scan's override (`overrideQuad`, `disableRectification`) is keyed by source scan, because rectification comes before the split. Turn it off with `--no-perspective`.

**Limitation:** the scale probe (§1) still sees unrectified pages.

## 3. Desk and paper masking

**`PaperRegionMasker`** ([`PaperRegionMasker.swift`](../Sources/ScanTailorCore/Binarization/PaperRegionMasker.swift)) classifies paper as §2 does, then flood-fills only the **non-paper pixels connected to the image border**. Ink and figures that never reach the edge are never touched.

- **Trust gate.** Local variance at the boundary must exceed the paper's own variance by `minimumBoundarySharpnessStd` (3.0). A real paper edge is a step and passes, even against low-contrast laminate. An illumination gradient or a vignette has no step and is left alone.
- **`full` mode.** Used when the desk covers more than 25 % of the frame, which happens on unrectified pages. Nothing is masked when the "paper" itself fills the frame without a clean border ring.
- **`residual` mode** (the usual case after rectification). Masks at most 8 % deep from each edge and 15 % of the area in total. A page that would exceed the cap is not masked at all and is flagged, so a misclassification leaves desk visible rather than erasing content.
- **Refinement.** The mask is eroded by one working pixel, then regrown only through dark full-resolution pixels, so text close to the paper edge survives.
- **Fill.** Masked pixels are filled with inpainted paper tone, not white, so no false ink seam appears next to shadowed paper.

Turn it off with `--no-desk-mask` or `disableDeskMask`.

**Camera photos** of open books (`SourcePageGeometryRecord.looksLikeCameraPhoto`) also get:

- **`CameraGutterLocator.Outline`:** traces the paper outline.
- **`CameraPaperMasker`:** paints everything outside the outline with inpainted paper tone.

## 4. Spread split

**`PageSplitEstimator`** looks for the gutter in two modes:

- **White-valley mode** for an ordinary pale gutter.
- **Dark-crease mode** when columns are at least 75 % continuously dark. It maximizes corridor ink instead of penalizing it, so the cut follows the crease midline at tilts of up to ±3°.

A strip `--gutter-trim-width` wide (default 24 px) is then cut out along the seam.

- **Camera photos:** `estimateCameraSplit` cuts at the text-free gap under the notch in the traced paper outline. On Simpson 1968, 8 of 8 cuts land on the fold.
- **Landscape veto:** in `automatic` mode, when at least 75 % of scans are portrait, a landscape scan is kept as one page (tables) and listed in `splitVetoedSourcePages`. The veto looks at scan shape only, before rectification.
- **Consensus split** (`BookEnds.consensusSplitScans`): a whole scan whose size matches at least three split scans (within 75 % of its size group) is split too. An example is a title page scanned beside a blank half. Recorded in `dimensionConsensus.splitByConsensusSourcePages`.
- **Overrides:** an adjustments-file `split` or `splitX` wins. `splitX` cuts along a straight vertical line.

## 5. Deskew and dewarp

- **Deskew** (`SkewEstimator`): projection-profile energy with a coarse-to-fine search. Confidence is `(ratio − 1) / 1.5`, clamped to 0–1, and clean text scores at least 0.75. An adjustments-file `skew` wins.
- **Dewarp** (`TextLineTracer` + `CylindricalDewarpSolver`): traces text baselines and fits a cylindrical cubic sheet. Pages whose sag is below the minimum are left flat. The dewarped page is binarized and cleaned again, reusing the measured glyph scale. Turn it off with `--no-dewarp` or `disableDewarp`. On Simpson 1968 it traced 49 lines (sag 3509 px, RMS 12.3 px).

## 6. Illumination and binarization

**`BackgroundNormalizer`** ([`BackgroundNormalizer.swift`](../Sources/ScanTailorCore/Binarization/BackgroundNormalizer.swift)) divides the image by an estimated background before thresholding.

- **Glyph-scaled kernels.** A closing radius fixed by DPI fails on camera pages: with 200 px glyphs, a 48 px kernel erodes into the text column and starves the threshold. The kernel and blur therefore follow the measured glyphs:
  - Glyphs are measured on a probe of at most 1600 px (integral-image Sauvola, then `FontScaleAnalyzer`), below a confidence of 0.35 the DPI-based fallback is used.
  - Closing radius: R = max(1.25 · x-height, 6.25 · stroke width, 0.85 · cap height).
  - σ scales with R.
  - The pyramid factor is raised so the Gaussian is never truncated.
  - Morphology uses the van Herk/Gil-Werman algorithm (O(1) per pixel, bit-exact).
- **Dual-pass flattening.**
  - Pass 1 forms an unclipped quotient Q₁ = 255 · I / B₁ in `UInt16`.
  - Each block's paper level is a mode-seeking crest.
  - Pure-paper samples (at least 0.88 × the crest) are inpainted and smoothed into B₂. Faint edges of strokes next to ink are rejected as samples.
  - The smoothing uses point-reflected boundaries, v(−k) = 2v(0) − v(k), which reproduce edge ramps exactly and keep steep spine shadows from leaving false ink.
  - B_eff = B₁ · B₂ / 255, in Q6 fixed point.
- **Anti-starvation contrast leveling.**
  - The ink envelope is sampled from paper-supported cells only, ignoring outliers above p90 + 40 (desk strips).
  - Gain g = clamp(p90, 145, 175) / envelope, at most 2.5.
  - The gain is applied multiplicatively, A′ = A · (1 + (g − 1) · w), because glare compresses absorption multiplicatively.
  - The gate w is a smoothstep from absorption 16 to 40, driven by the 3×3 peak, so stroke edges follow their stroke while grain and bleed-through stay untouched.

**`AdaptiveBinarizer`**: Wolf-Jolion (the default) or Sauvola (`--binarize`). The window radius follows the same glyph scale, which avoids hollowing thick strokes.

## 7. Border cleaning

`BorderAndSpeckleCleaner.removeScanBorders` erases components touching several edges, and edge bars up to twice the 14 % strip limit.

**Macro-border fallback** ([`MacroBorderFallback.swift`](../Sources/ScanTailorCore/Binarization/MacroBorderFallback.swift)) removes desk that the standard rules miss: blocks detached from the edge by a white band, or deeper or shorter than the strip rules allow.

- **Detection.**
  - A coarse grid (cell = short side / 64) marks cells dark at a black density of 0.30 or more.
  - From each eligible edge, a scan may cross empty cells for up to 10 % of the page, then must find a solid dark run (solidity at least 0.85).
  - A candidate is accepted when it is deeper than the strip limit, at most 35 % deep, and at least 15 % of the edge long.
  - It must not be **text-like**: at most 15 % of its pixel rows may be blank. Text has line gaps; binarized wood grain (noisy, about 40 % black) and solid blocks have none. Density alone cannot tell them apart.
- **When it runs.** Only when the page's geometry is marginal: `quad:rejected`, a quad with confidence below 0.70, `occluded`, `cornerFallback`, `lowContrastDesk`, a capped or skipped mask, or an override set to `forced`. The gutter side of a split page is never eligible.
- **Overrides.** `--no-border-fallback`, or the page's `borderFallback` set to `automatic`, `forced` or `disabled`.

**Limitations:** a dense halftone or hatched figure with no blank rows, touching an outer edge, on a marginal page, looks like grain. Set `borderFallback: disabled` for that page.

## 8. Content box

**`ContentBoxDetector`** closes the cleaned bitmap (`closeBrick(64, 14)`), clusters it, and keeps the main body plus headers, folios and side notes near it. Rejected clusters go to the overlay in red.

- **Split-edge exclusion:** ignores the 4 % of a split page next to the cut.
- **Edge noise:**
  - A column group cut off from the text by a gap of at least 1 % of the width, and holding less than 20 % of the ink, is dropped (page-edge textures, scanner noise).
  - Except a column of numbers (`marginalGlyphColumn`): the page and section numbers of a table of contents, or marginal line numbers. It needs at least three clusters within 0.5 in of the text, each at most 0.3 in tall, 0.75 in wide and three times as tall as wide, stacked with blank space between them (filling at most 60 % of their height), in a column at most 0.75 in wide. The same test runs before this step on the clusters set aside so far (in the outer edge strip, or as margin smudges) that lie level with the body and are larger than specks, so a column of numbers on a tightly cut scan is kept too.
  - Columns inked over at least 70 % of the height are erased (rules, streaks).
- **Page-edge stacks** (`edgeStackBands`): the edges of the following leaves, seen beside the outer margin. A band is erased before clustering when it meets all of these tests:
  - it lies in the outer third (left of a verso, right of a recto, either side of an unsplit page);
  - its pieces are at least four times as tall as wide, span 80 % of their 0.5 in strips, and cover 40 % of the page height;
  - it averages 1.5 lines per strip, so a single rule is kept;
  - it is at most a quarter of the page wide, with at least half its ink in such pieces, so ruled tables are kept.

  The band grows over broken leaf edges within 0.15 in and is padded by 0.05 in.
- **Specks:** marks whose longer side is under 0.06 in neither set the box edges nor count as rescued headers or folios.
- **Strict margins** (`Configuration.strictMargins`, camera photos): drops line art and keeps only headers and folios close to the vertically merged text block.
- **Content overflow:** a page whose only outlier kind is `contentOverflow` is trimmed to the book's text width (`canonicalWidthPrior`), and the consensus (§12) is run again.

**Limitation:** a halftone gutter shadow fused with text (Vermeersch scan 2) still swells the box. Fix it with `contentBox.rect`.

## 9. Camera text-block scaling

**`TextBlockScaleNormalizer`** scales each camera page so its full text block matches the book's median, before header detection and layout:

- Width and height are scaled separately, each between 0.8× and 1.25×.
- Short full-width pages keep the book's aspect; other pages keep the aspect from their photo.
- Content-box edits refer to the scaled page. `PageProcessingRecord.textBlockScale` records the factors.
- `Configuration.cameraTextBlockScaling = nil` turns it off.

With it, Simpson 1968 lays out all 16 pages at 0.50/0.50/0.25/0.25 in.

## 10. Blank pages and covers

- **Blank verdict:** a page is blank when its ink density is below `blankPageInkDensityThreshold` and it has no OCR word.
  - On a page holding only specks, the ink of page-edge stacks is subtracted first.
  - A blank page whose retained clusters are all under 0.1 in tall (`holdsOnlySpecks`) is **laid out blank** (`blanked`): no text block and no skew. On the sample, specks reached 0.09 in and real content started at 0.11 in.
  - A page with no content box is never a size outlier; it takes the book's canvas. An edited content box wins.
- **Pruning:** blank pages are dropped **only before the first and after the last page with content**, as from partial scans or stripped covers. Blank pages between content pages keep the recto/verso order. `--no-auto-prune` keeps them all.
- **Covers** (`CoverSheetDetector`, `--cover-handling`):
  - `auto` drops a page only when the OCR text of the first two or the last scan contains a fixed phrase of JSTOR, Project MUSE, Google Books or the Internet Archive. Per-page watermarks ("Digitized by Google", Project MUSE's stamp) do not count. With `--no-ocr` there is no cover detection.
  - `strip` also drops an odd-sized first or last scan (`BookEnds.printedCoverScans`).
  - `keep` drops nothing.
  - Endpapers, bookplates and stamp pages are left to the adjustments file.
- **Records:** `PrunedPageRecord.kind` is one of `leadingBlank`, `trailingBlank`, `coverSheet`, `cover` or `adjustment`.

## 11. Running headers

**`RunningHeaderDetector`** ([`RunningHeaderDetector.swift`](../Sources/ScanTailorCore/Layout/RunningHeaderDetector.swift)) gives every page a **top anchor**: the running header's baseline, or else the first body baseline.

- **Page profile.**
  - Lines come from a row ink profile inside the content box. A row counts as inked above 0.6 % of the width.
  - Bands taller than 1.7 typical lines are split at near-empty rows.
  - Thin, wide, solid bands are rules and are folded into the line above.
  - Accent-sized bands, under 0.6 of the typical height, join the nearest line.
  - Specks, smaller than half a core height and narrower than two cores (dust, a pen dash), are dropped.
  - Each line records its bounds, baseline, core height and ink.
- **Column analysis** ([`TextColumnAnalysis.swift`](../Sources/ScanTailorCore/Layout/TextColumnAnalysis.swift)): the same streak and isolated-group tests as §8.
- **Candidates.** A top line is a header candidate when:
  - the next baseline is at least 1.5 body pitches below it, or 1.05 pitches with a gap under it at least twice the normal one, or 1.2 pitches with an outer folio;
  - its core is 0.35–1.75× the body core (taller is `titleLike`).

  A "line" taller than a fifth of the page is not an anchor (`body:linesUnresolved`); slanted camera columns merge lines.
- **Clustering.** Per side (verso, recto, single), on offset in pitches and height ratio, with tolerances of 0.35 pitch and 0.20. A cluster confirms headers with at least 3 pages and at least 30 % of the side's text pages; sides with 6 text pages or fewer need only 2. Absolute position is deliberately not used, because camera captures shift it.
- **Second chance** (`header:lenient`, confidence 0.7× the base): candidates just outside the cluster, such as taller folio digits or a sunk first body line.
- **Folios.** In the header line, the outer-end segment at most 4.5 core heights wide; a header that narrow is folio-only. A footer folio is a narrow segment at least 1.5 pitches below the last line.
- **Override:** the page's `runningHeader` set to `automatic`, `present` or `absent`. `--no-running-headers` turns detection, and with it registration, off.

**Limitations:** headers the content box already rejected cannot be seen; two-column bodies give a noisy first baseline.

## 12. Dimension consensus and outlier canvases

**`DimensionConsensus`** ([`DimensionConsensus.swift`](../Sources/ScanTailorCore/Layout/DimensionConsensus.swift)) sorts pages into canonical pages and outliers. It uses sizes and boxes only, no pixels.

- **Outlier kinds.**
  - `oversize` or `undersize`: width or height off the median by more than max(1.5 × IQR, `--outlier-tolerance` × median). The default tolerance is 0.08, because ordinary cropping varies by up to 5 % and covers by 9 % or more.
  - `orientation`: a landscape page in a portrait book.
  - `contentOverflow`: a normal page size, but a text block more than 15 % above the book's 85th percentile.
  - `manual`.
- **Not applied** to books with fewer than 5 pages. Sizes are **ambiguous**, and only overflow and manual outliers count, when more than 25 % of pages differ or the IQR exceeds 25 % of the median (a large second size group).
- **`scaleMismatch`**: a line pitch more than 20 % off the book's. It is a flag only and is not corrected.
- **Manual list.** `--outlier-pages` (output pages or scan names) **replaces** detection. It works even with detection off or a short book, and `none` means no outliers. Per-page `outlier: true|false` is also honored.
- **Outlier canvases.** Outliers are left out of the canvas, the frame and the width prior, are never width-trimmed, and are laid out as Tier 3. With `--outlier-canvas isolated` (the default) each gets its own canvas and PDF page size: the scan size, grown to hold its text block. `pageSize` rescales it, keeping the aspect within 5 %.

**Limitations:** thumbnail covers stay small; foldouts are not rotated; two-page viewers show odd-sized spreads around outliers.

## 13. Publication layout

**`MarginHarmonizer.harmonizeBook`** ([`MarginHarmonizer.swift`](../Sources/ScanTailorCore/Layout/MarginHarmonizer.swift)) applies the layout rules listed in the README.

- **Canvas.** The canvas is the canonical text block plus the margins: 0.25 in top and bottom and 0.5 in left and right by default (`--margins`). It is not the scanned paper size.
- **Canonical frame.** Its size is the largest box in the densest size cluster (`largestInMainCluster`, a 2 % window), so boxes swollen by gutter or edge noise do not inflate it. IQR and median filtering run first. `--content-box-size` and `--page-size` fix the frame or canvas instead.
- **Inner and outer margins** widen the canvas, but pages are not shifted toward the spine.
- **Tiers.** Every page is centered left to right. The tier sets the vertical position:

  | Tier | Pages | Vertical position |
  | :--- | :--- | :--- |
  | 1 `fullBody` | Width and height within 8 % of the frame. | Top on the frame top. |
  | 2 `edgeAnchoredPartial` | Full width and at least 22 % of the frame height, or any page with a running header. | Header pages hang from the top. Otherwise a block that reaches the foot of the scan's text block sits on the frame bottom (a chapter opening), one that starts at its head hangs from the top (a chapter ending), and anything else keeps its height. The tolerance is max(24 px, 12 % of the text height). |
  | 3 `standaloneFloating` | Title pages, dedications, dividers, outliers. | Keeps its offset from the scan's text block, and stays centered when it was centered within max(0.3 in, 8 % of the width). |

  A **headerless Tier 3 opening** that runs to the foot also sits on the bottom when it:
  - is not an outlier or a forced tier;
  - is at least 22 % of the frame tall but shorter than it;
  - ends within 1/4 in of the foot;
  - drops at least twice as far from the head.

  An example is a lectio opening set narrower than the body. A short opening, a title page, or a page with an undetected header keeps its offset.
- **Overrides.** Applied after automatic placement: `tier` (forced), `offset`, and `contentBox.rect` or `nudge`.

**Known case:** Flannery 1993 p. 277 (an appendix opening with a drop folio) runs 0.25 in below the frame. Fix it with the adjustments file.

## 14. Vertical registration

**`VerticalRegistration`** ([`VerticalRegistration.swift`](../Sources/ScanTailorCore/Layout/VerticalRegistration.swift)) moves pages vertically only, after harmonization and overrides, so text does not jump between pages.

- **Lines.**
  - The header line is the frame top plus the median distance from the content top to the header baseline.
  - The body line is the header line plus the median distance from header to first body baseline. In a book without headers it is measured from the frame top instead.
  - Medians come from the pages themselves, so the typical page does not move.
- **Registered pages:** Tier 1, and Tier 2 pages anchored at the top. Headerless pages in a book with headers align their first body baseline to the body line.
- **Preserved pages:** Tier 3, Tier 2 at the bottom or natural height, `titleLike`, `sinkage`, blank pages, and outliers (`registration:dimensionalOutlier`).
- **Left on the box top**, with a flag:
  - `ambiguousTop`: no anchor, confidence below 0.5, or a header out of the cluster.
  - `atypicalLines`: a line pitch more than 30 % off the book's.
  - `headersUndetectedOnSide`: a body-anchored page on a side without headers while the other side has them.
  - `shiftTooLarge`: a shift over min(3 pitches, 12 % of the frame).

  Shifts are clamped to the canvas.
- **Overrides:** `verticalRegistration: anchor` forces registration and skips the checks; `boxTop` turns it off for the page. A manual destination always wins. `--vertical-anchor box-top` turns registration off for the whole book.
- **Telemetry:** the manifest's `verticalRegistration` records the header and body baseline spreads before and after. On Flannery the header spread went from 9 px to 0, and on Long from 15 px to 0.

**Limitation:** the distance from header to first body line varies by up to about 20 px even in clean scans, so body lines can stay slightly off.
