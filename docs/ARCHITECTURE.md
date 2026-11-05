# Architecture

How ScanTailorReborn is put together: the design rules, the package layers, the passes a book goes through, and the files a run reads and writes. Each stage is specified in [PIPELINE.md](PIPELINE.md). Building, testing and releasing are covered in [DEVELOPMENT.md](DEVELOPMENT.md).

## Design rules

1. **A tool for a loop, not an oracle.** No fixed set of heuristics can foresee every scan: thumbs, desks, odd bindings, plates. The CLI handles the common cases on its own. For the rest it makes the work cheap to inspect and correct: a layout-only run, contact sheets, `inspect --pages`, a "pages to check" list, and a small adjustments file. A person or an AI agent drives the loop (see the README, *Iterating on a hard book*). Each fix should be a cheap preview or a precise edit, not one more heuristic for an edge case.
2. **Manual edits beat automatic detection.** An adjustments-file entry or an exact list (`--outlier-pages`) replaces detection for what it names. Automatic detection only has to get most pages right.
3. **Telemetry for every decision.** Every automatic decision is recorded in the manifest with its confidence and flags, so a caller can see why a page looks as it does.
4. **Platform-free core.** Apple frameworks (PDFKit, CoreGraphics, Vision, Metal, Accelerate) never appear in `ScanTailorContracts`, `ScanTailorCore` or `ScanTailorPipeline`.
5. **Swift 6 throughout.** Every target builds in Swift 6 language mode with strict concurrency. Data types are `Sendable` values, the PDF writer is `~Copyable`, and new manifest fields decode with `decodeIfPresent`, so older manifests still load.

## Package layers

| Target | Responsibility |
| :--- | :--- |
| `ScanTailorContracts` | Geometry (`Point2D`, `Rect2I`, `AffineTransform2D`, `Homography2D`, `DewarpGrid`, …); rasters (`GrayscaleBuffer`, the word-packed `BinaryBitmap`, `IntegralBuffer`); OCR and confidence models; backend protocols (`PDFSourceReader`, `ComputeAccelerator`, `OCREngine`, `PDFDocumentWriter`). |
| `ScanTailorCore` | Algorithms: geometry (quad detection, rectification); binarization and cleaning; deskew; dewarp; layout (split, content box, headers, consensus, harmonizer, registration, covers, scale); morphology and connected components. |
| `ScanTailorPipeline` | `BookPipelineCoordinator` (the passes); `ScanProcessing` (per-scan pass 1); the manifest records; the adjustments file and its resolver; `PipelineCache`; `BoundedParallel`; `DualOCREngine`. |
| `ScanTailorAppleBackend` | `ApplePDFSourceReader`; `ApplePDFDocumentWriter` (CCITT G4 + invisible text); `AppleVisionOCREngine`; `MetalComputeAccelerator`; the diagnostic overlay and layout contact-sheet renderers. |
| `ScanTailorPortableBackend` | `PortableComputeAccelerator`: pure-Swift SIMD fallback (`--portable-backend`). |
| `ScanTailorTesseractBackend`, `CTesseract` | `TesseractOCREngine` over the Tesseract C API, with an RAII `LeptonicaPix`. |
| `ScanTailorCLI` | `scantailor-reborn-cli`: option parsing, `process` and `inspect`, run summaries, the page table and page review. |

`CTesseract` links `tesseract` and `leptonica` with rpaths to `/opt/homebrew/lib` and `/usr/local/lib`, so the build works on either Homebrew prefix.

## Passes

Pages are processed at **600 DPI** and written at **300 DPI**.

0. **Scale probe** (only for PDFs whose declared pages are billboard-sized): up to three interior pages are measured to infer the true optical DPI ([PIPELINE §1](PIPELINE.md#1-physical-scale)).
1. **Pass 1, per scan** (parallel, cached), in [`ScanProcessing.swift`](../Sources/ScanTailorPipeline/ScanProcessing.swift). Each scan is rasterized, then goes through:
   - perspective rectification;
   - desk masking;
   - for camera photos only: the paper outline and paper mask;
   - spread split.

   Then each page goes through:
   - deskew;
   - binarize;
   - clean;
   - dewarp, then binarize and clean again;
   - content box;
   - the blank verdict.
2. **Book-wide decisions**, all cheap and run on every run. In order:
   - cover sheets and end-only blank pruning;
   - consensus split;
   - camera text-block scaling;
   - running headers;
   - dimension consensus;
   - harmonization (canvas, tiers, placement);
   - the adjustments file's layout edits;
   - vertical registration.

   `--stop-after layout` stops here and writes the manifest and contact sheets.
3. **Pass 3, per page** (parallel). Each page is rendered on its canvas at 300 DPI and recognized (the OCR is cached). The page and its text layer are then appended to the PDF.

## Files

- **Manifest** (`BookProcessingManifest`, JSON; `--manifest`, or `<stem>-layout-manifest.json` in `--diagnostics-dir`). It holds everything the run decided:
  - per-scan geometry (`SourcePageGeometryRecord`);
  - per-page records (`PageProcessingRecord`: detection, tier, plan, anchor, registration, dimension class, border fallback, text-block scale);
  - book models (running headers, dimension consensus, vertical registration, font scale);
  - pruned pages with their kind;
  - the adjustments report;
  - the run report (timings and cache counts; it changes every run, so leave it out when comparing manifests).

  A complete manifest given to `--apply-manifest` is applied read-only. Its overrides are keyed by output page number, so they can land on the wrong page once the numbering changes. Prefer an adjustments file.
- **Adjustments file** ([`PageAdjustments.swift`](../Sources/ScanTailorPipeline/PageAdjustments.swift), [`AdjustmentResolver.swift`](../Sources/ScanTailorPipeline/AdjustmentResolver.swift)): a small, strict JSON file written by hand. The README gives the format.
  - Every mistake is collected and reported before any scan is processed.
  - Page names: `45` is an output page. `s12` is a source scan, counted from the start of the PDF even with `--page-range`. `s12L` and `s12R` are halves. More specific names win.
  - Pixel-changing edits (skew, dewarp, border fallback, split, geometry) run in pass 1 and invalidate that scan's cache entry. Everything else is applied after the cache: content boxes, nudges, offsets, tiers, outliers, page sizes, keep and drop, and book options.
  - Content-box nudges are resolved into absolute boxes, so applying a file twice gives the same result.
- **Diagnostics** (`--diagnostics-dir`):
  - the manifest;
  - `page-NNNN-diag.png` overlays for low-confidence pages, or every page with `--all-diagnostics`;
  - `layout-sheet-NN.png` contact sheets at about 40 DPI (red is the canonical frame, green the placed text block, orange an outlier with its own canvas);
  - `<stem>-lines.json`, with each page's text lines, anchor and registration.

## Cache and parallelism

- **Pass-1 cache** ([`PipelineCache.swift`](../Sources/ScanTailorPipeline/PipelineCache.swift)): stores a `ScanHeader` per scan and a `SliceOutcome` per page. Keys are SHA-256 hashes of:
  - the code version (the executable's Mach-O `LC_UUID`, so a rebuild reuses nothing);
  - every pass-1 setting;
  - the source identity (a hash of the PDF, plus the scan index and render DPI);
  - the scan-level and pixel-changing page edits.

  Entries are LZFSE-compressed binary plists of about 275 KB per page. Each is written to a temporary file and renamed, and an unreadable entry counts as a miss. On a hit the scan is not even rasterized.
- **OCR cache:** keyed by the rendered bitmap, `OCREngine.cacheIdentity` (engine, settings, library and OS versions) and the languages. The cache lives in `~/Library/Caches/ScanTailorReborn`. It is never pruned, and deleting it is always safe.
- **Parallelism** ([`BoundedParallel.swift`](../Sources/ScanTailorPipeline/BoundedParallel.swift)):
  - Pass 1 and pass 3 run at most `--jobs` items at a time, and results come back in input order. Page numbering, sides, drops and pruning are assigned afterwards in scan order, so the output never depends on `--jobs`.
  - Every job runs in a child task, even with one job, because Metal and CoreGraphics release memory only when a task ends.
- **Measured** on Flannery 1993 (16 scans, release, 8P+2E cores):

  | Run | Time | Peak memory |
  | :--- | :--- | :--- |
  | Cold, 1 / 4 / 8 jobs | 27 s / 12.5 s / 11 s | 1.5 / 4.2 / 5.4 GB |
  | Warm, unchanged, full PDF | 0.65 s | — |
  | Warm, `--stop-after layout` | 0.4 s | — |

  Cold, warm and serial runs give identical manifests (leaving out `run`) and identical PDF content.
- **Cost:** a cold run is dominated by `BackgroundNormalizer` (about 0.9 s per page). A content-box or skew change on one page usually moves the book-wide frame, so most pages are rendered again and their OCR runs again. `PipelineOutput` keeps every cleaned 600 DPI bitmap in memory, about 4 MB per page.

## OCR and PDF output

- **Engines.** `apple` (Vision, the default), `tesseract`, or `dual`. Naming a classical language (`grc`, `lat`, `frk`, `deu_frak`) selects `dual`.
- **`DualOCREngine`** runs both engines and merges their words:
  - Words overlapping by more than 40 % vertically and 30 % horizontally count as the same word.
  - Words in polytonic Greek, or containing a Fraktur long s, override Latin readings.
  - Otherwise a confidence lead of more than 0.15 wins.
  - Words only one engine found are kept.
  - Classical language codes are removed before calling Vision, and the output is sorted into reading order.
- **PDF.** `ApplePDFDocumentWriter` writes 1-bit CCITT Group 4 images with an invisible text layer. It sets the text with a single 12 pt font scaled through the text matrix: one font per document, not one per size. That cut Flannery from 5.3 MB to 1.4 MB. Each page gets its own media box, which outlier canvases use.
