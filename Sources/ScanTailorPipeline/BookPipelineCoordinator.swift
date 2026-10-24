import Foundation
import ScanTailorContracts
import ScanTailorCore

/// User-editable per-page overrides stored in a `BookProcessingManifest`.
public struct PageManualOverride: Sendable, Equatable, Codable {
    /// Optional manual skew angle in degrees (overrides automatic `SkewEstimator`).
    public var overrideSkewDegrees: Double?
    /// When `true`, forces 3D cubic-sheet dewarping to be bypassed on this page.
    public var disableDewarp: Bool?
    /// Optional manual content bounding box in 600 DPI source page coordinates.
    public var overrideContentBox: Rect2I?
    /// Optional manual destination origin on the 600 DPI canonical output canvas.
    public var overrideDestinationOrigin: Point2I?

    public init(
        overrideSkewDegrees: Double? = nil,
        disableDewarp: Bool? = nil,
        overrideContentBox: Rect2I? = nil,
        overrideDestinationOrigin: Point2I? = nil
    ) {
        self.overrideSkewDegrees = overrideSkewDegrees
        self.disableDewarp = disableDewarp
        self.overrideContentBox = overrideContentBox
        self.overrideDestinationOrigin = overrideDestinationOrigin
    }
}

/// Complete telemetry, geometry, and layout record for a single output page in the processed book.
public struct PageProcessingRecord: Sendable, Equatable, Codable {
    /// Zero-based sequential output page index.
    public var outputPageIndex: Int
    /// Zero-based source PDF page index from which this page originated.
    public var sourcePageIndex: Int
    /// Split slice side (`.single`, `.leftVerso`, or `.rightRecto`).
    public var splitSide: PageSide
    /// Logical book page side (`.verso`, `.recto`, or `.single`).
    public var bookSide: MarginHarmonizer.PageSide
    /// Applied skew angle in degrees.
    public var skewAngleDegrees: Double
    /// Skew estimation confidence in `[0, 1]`.
    public var skewConfidence: Double
    /// Whether 3D cubic-sheet dewarping was applied (`false` if flat page auto-bypassed or disabled).
    public var dewarpApplied: Bool
    /// Maximum vertical sag in pixels across the fitted 3D surface model.
    public var dewarpVerticalSagPixels: Double
    /// RMS vertical residual in pixels of the 3D surface fit (`0` if not applied).
    public var dewarpResidualRMSPixels: Double
    /// Number of text-line polylines traced on this page.
    public var tracedLineCount: Int
    /// Sampled traced text-line polylines (stored for diagnostic overlay rendering).
    public var tracedLines: [PolyLine2D]
    /// Computed 3-tier layout plan for this page.
    public var layoutPlan: MarginHarmonizer.PageLayoutPlan
    /// Combined confidence score across split, skew, and content detection in `[0, 1]`.
    public var overallConfidence: Double
    /// Whether this page fell below the confidence threshold and was flagged for diagnostic review.
    public var flaggedLowConfidence: Bool
    /// Optional user-editable manual overrides for incremental re-runs.
    public var manualOverride: PageManualOverride?

    public init(
        outputPageIndex: Int,
        sourcePageIndex: Int,
        splitSide: PageSide,
        bookSide: MarginHarmonizer.PageSide,
        skewAngleDegrees: Double,
        skewConfidence: Double,
        dewarpApplied: Bool,
        dewarpVerticalSagPixels: Double,
        dewarpResidualRMSPixels: Double,
        tracedLineCount: Int,
        tracedLines: [PolyLine2D],
        layoutPlan: MarginHarmonizer.PageLayoutPlan,
        overallConfidence: Double,
        flaggedLowConfidence: Bool,
        manualOverride: PageManualOverride? = nil
    ) {
        self.outputPageIndex = outputPageIndex
        self.sourcePageIndex = sourcePageIndex
        self.splitSide = splitSide
        self.bookSide = bookSide
        self.skewAngleDegrees = skewAngleDegrees
        self.skewConfidence = skewConfidence
        self.dewarpApplied = dewarpApplied
        self.dewarpVerticalSagPixels = dewarpVerticalSagPixels
        self.dewarpResidualRMSPixels = dewarpResidualRMSPixels
        self.tracedLineCount = tracedLineCount
        self.tracedLines = tracedLines
        self.layoutPlan = layoutPlan
        self.overallConfidence = overallConfidence
        self.flaggedLowConfidence = flaggedLowConfidence
        self.manualOverride = manualOverride
    }
}

/// Telemetry record for a sub-page slice pruned during processing (e.g. blank flyleaf or phantom spread half).
public struct PrunedPageRecord: Sendable, Equatable, Codable {
    /// Zero-based source scan index from which this slice originated.
    public var sourcePageIndex: Int
    /// Split slice side (`.single`, `.leftVerso`, or `.rightRecto`).
    public var splitSide: PageSide
    /// Measured foreground ink density in `[0, 1]`.
    public var inkDensity: Double
    /// Human-readable explanation of why this slice was pruned.
    public var reason: String

    public init(
        sourcePageIndex: Int,
        splitSide: PageSide,
        inkDensity: Double,
        reason: String
    ) {
        self.sourcePageIndex = sourcePageIndex
        self.splitSide = splitSide
        self.inkDensity = inkDensity
        self.reason = reason
    }
}

/// Persistent JSON manifest capturing book-wide canonical layout frames, per-spread split decisions,
/// per-page telemetry, and optional user overrides.
public struct BookProcessingManifest: Sendable, Equatable, Codable {
    /// Processing resolution in DPI (typically 600).
    public var processingDPI: Int
    /// Final output PDF resolution in DPI (typically 300).
    public var outputDPI: Int
    /// Canonical 600 DPI output canvas dimensions.
    public var canonicalCanvasSizeAtProcessingDPI: Size2I
    /// Canonical text frame for `.verso` (left) pages at `processingDPI`.
    public var versoCanonicalFrame: Rect2I
    /// Canonical text frame for `.recto` (right) pages at `processingDPI`.
    public var rectoCanonicalFrame: Rect2I
    /// Per-source-page gutter split decisions.
    public var sourcePageSplits: [PageSplitDecision]
    /// Per-output-page processing records.
    public var pages: [PageProcessingRecord]
    /// Sub-page slices pruned during processing (e.g. blank flyleaves or phantom spread halves).
    public var prunedPages: [PrunedPageRecord]
    /// Optional identifier of the OCR engine used during processing (e.g. "AppleVisionOCREngine", "TesseractOCREngine", "DualOCREngine").
    public var ocrEngine: String?
    /// Optional language codes passed to OCR engine during processing.
    public var ocrLanguages: [String]?

    public init(
        processingDPI: Int,
        outputDPI: Int,
        canonicalCanvasSizeAtProcessingDPI: Size2I,
        versoCanonicalFrame: Rect2I,
        rectoCanonicalFrame: Rect2I,
        sourcePageSplits: [PageSplitDecision],
        pages: [PageProcessingRecord],
        prunedPages: [PrunedPageRecord] = [],
        ocrEngine: String? = nil,
        ocrLanguages: [String]? = nil
    ) {
        self.processingDPI = processingDPI
        self.outputDPI = outputDPI
        self.canonicalCanvasSizeAtProcessingDPI = canonicalCanvasSizeAtProcessingDPI
        self.versoCanonicalFrame = versoCanonicalFrame
        self.rectoCanonicalFrame = rectoCanonicalFrame
        self.sourcePageSplits = sourcePageSplits
        self.pages = pages
        self.prunedPages = prunedPages
        self.ocrEngine = ocrEngine
        self.ocrLanguages = ocrLanguages
    }

    private enum CodingKeys: String, CodingKey {
        case processingDPI
        case outputDPI
        case canonicalCanvasSizeAtProcessingDPI
        case versoCanonicalFrame
        case rectoCanonicalFrame
        case sourcePageSplits
        case pages
        case prunedPages
        case ocrEngine
        case ocrLanguages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.processingDPI = try container.decode(Int.self, forKey: .processingDPI)
        self.outputDPI = try container.decode(Int.self, forKey: .outputDPI)
        self.canonicalCanvasSizeAtProcessingDPI = try container.decode(Size2I.self, forKey: .canonicalCanvasSizeAtProcessingDPI)
        self.versoCanonicalFrame = try container.decode(Rect2I.self, forKey: .versoCanonicalFrame)
        self.rectoCanonicalFrame = try container.decode(Rect2I.self, forKey: .rectoCanonicalFrame)
        self.sourcePageSplits = try container.decode([PageSplitDecision].self, forKey: .sourcePageSplits)
        self.pages = try container.decode([PageProcessingRecord].self, forKey: .pages)
        self.prunedPages = try container.decodeIfPresent([PrunedPageRecord].self, forKey: .prunedPages) ?? []
        self.ocrEngine = try container.decodeIfPresent(String.self, forKey: .ocrEngine)
        self.ocrLanguages = try container.decodeIfPresent([String].self, forKey: .ocrLanguages)
    }
}

/// Coordinates the 3-pass automated book processing pipeline:
/// - **Pass 1**: Source rasterization (600 DPI), dual-page spread splitting, multi-scale deskew,
///   3D cubic-sheet dewarping (with flat-page auto-bypass), illumination normalization, adaptive
///   binarization, border/speckle cleanup, and initial content box detection.
/// - **Pass 2**: Book-wide statistical outlier rejection and 3-tier margin harmonization
///   (`fullBody`, `edgeAnchoredPartial`, and `standaloneFloating`).
/// - **Pass 3**: Canonical canvas rendering, 600 $\rightarrow$ 300 DPI area-thresholded downsampling,
///   OCR recognition, and 1-bit CCITT Group 4 PDF assembly.
public struct BookPipelineCoordinator: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Internal processing resolution in DPI (default: `600`).
        public var processingDPI: Int
        /// Output PDF resolution in DPI (default: `300`, half of `processingDPI`).
        public var outputDPI: Int
        /// Spread split mode (`.automatic`, `.singlePage`, or `.twoPageSpread`).
        public var splitMode: PageSplitMode
        /// Central gutter strip trimming width in pixels at 600 DPI physically removed between split pages (default: `24`).
        /// Scaled proportionally when `processingDPI` differs from 600 DPI.
        public var gutterTrimWidth: Int
        /// Whether to automatically detect and prune blank sub-page slices (default: `true`).
        public var autoPruneBlankPages: Bool
        /// Maximum foreground ink density threshold (fraction in `[0, 1]`) to qualify as a blank page candidate (default: `0.010`, i.e. 1.0%).
        public var blankPageInkDensityThreshold: Double
        /// Whether 3D cubic-sheet curvature dewarping is enabled (default: `true`).
        public var enableDewarp: Bool
        /// Minimum vertical sag in pixels (at 600 DPI) required to trigger 3D dewarping; flatter pages bypass resampling (default: `12.0`).
        public var minDewarpSagPixelsAt600DPI: Double
        /// Adaptive binarization configuration.
        public var binarizerConfiguration: AdaptiveBinarizer.Configuration
        /// Border and speckle cleanup configuration.
        public var cleanerConfiguration: BorderAndSpeckleCleaner.Configuration
        /// Content box detector configuration.
        public var contentDetectorConfiguration: ContentBoxDetector.Configuration
        /// Book-wide margin harmonizer configuration.
        public var harmonizerConfiguration: MarginHarmonizer.Configuration
        /// Logical book page side assigned to the very first output page (default: `.recto`).
        public var firstPageSide: MarginHarmonizer.PageSide
        /// 1-based source PDF page indices to process (empty means all pages).
        public var pageRange: ClosedRange<Int>?
        /// 1-based source PDF page indices to exclude from processing.
        public var excludedPages: Set<Int>
        /// BCP-47 language codes passed to `OCREngine` (default: `["en-US"]`).
        public var ocrLanguages: [String]
        /// Confidence threshold in `[0, 1]` below which a page is flagged for diagnostic review (default: `0.75`).
        public var lowConfidenceThreshold: Double

        public init(
            processingDPI: Int = 600,
            outputDPI: Int = 300,
            splitMode: PageSplitMode = .automatic,
            gutterTrimWidth: Int = 24,
            autoPruneBlankPages: Bool = true,
            blankPageInkDensityThreshold: Double = 0.010,
            enableDewarp: Bool = true,
            minDewarpSagPixelsAt600DPI: Double = 12.0,
            binarizerConfiguration: AdaptiveBinarizer.Configuration = AdaptiveBinarizer.Configuration(
                method: .wolfJolion,
                backgroundNormalization: BackgroundNormalizer.Configuration()
            ),
            cleanerConfiguration: BorderAndSpeckleCleaner.Configuration = BorderAndSpeckleCleaner.Configuration(),
            contentDetectorConfiguration: ContentBoxDetector.Configuration = ContentBoxDetector.Configuration(cleanBordersFirst: false),
            harmonizerConfiguration: MarginHarmonizer.Configuration = MarginHarmonizer.Configuration(),
            firstPageSide: MarginHarmonizer.PageSide = .recto,
            pageRange: ClosedRange<Int>? = nil,
            excludedPages: Set<Int> = [],
            ocrLanguages: [String] = ["en-US"],
            lowConfidenceThreshold: Double = 0.75
        ) {
            self.processingDPI = max(150, processingDPI)
            self.outputDPI = max(72, outputDPI)
            self.splitMode = splitMode
            self.gutterTrimWidth = max(0, gutterTrimWidth)
            self.autoPruneBlankPages = autoPruneBlankPages
            self.blankPageInkDensityThreshold = min(max(0.0001, blankPageInkDensityThreshold), 0.10)
            self.enableDewarp = enableDewarp
            self.minDewarpSagPixelsAt600DPI = max(1.0, minDewarpSagPixelsAt600DPI)
            self.binarizerConfiguration = binarizerConfiguration
            self.cleanerConfiguration = cleanerConfiguration
            self.contentDetectorConfiguration = contentDetectorConfiguration
            self.harmonizerConfiguration = harmonizerConfiguration
            self.firstPageSide = (firstPageSide == .single) ? .recto : firstPageSide
            self.pageRange = pageRange
            self.excludedPages = excludedPages
            self.ocrLanguages = ocrLanguages
            self.lowConfidenceThreshold = min(max(0.0, lowConfidenceThreshold), 1.0)
        }
    }

    /// Errors that can occur during the 3-pass book pipeline.
    public enum PipelineError: Error, Sendable, Equatable {
        case pdfReadFailed(PDFReadError)
        case ocrFailed(OCRError)
        case pdfWriteFailed(PDFWriteError)
    }

    /// Output of a complete pipeline run (including the manifest and optional rendered 300 DPI bitmaps for inspection).
    public struct PipelineOutput: Sendable {
        public let manifest: BookProcessingManifest
        public let outputBitmapsAtOutputDPI: [BinaryBitmap]
        public let cleanedBitmapsAtProcessingDPI: [BinaryBitmap]

        public init(
            manifest: BookProcessingManifest,
            outputBitmapsAtOutputDPI: [BinaryBitmap],
            cleanedBitmapsAtProcessingDPI: [BinaryBitmap]
        ) {
            self.manifest = manifest
            self.outputBitmapsAtOutputDPI = outputBitmapsAtOutputDPI
            self.cleanedBitmapsAtProcessingDPI = cleanedBitmapsAtProcessingDPI
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Runs the complete 3-pass pipeline from a `PDFSourceReader` into a consuming `PDFDocumentWriter`.
    public func processBook<Writer: PDFDocumentWriter & ~Copyable>(
        reader: any PDFSourceReader,
        writer: consuming Writer,
        accelerator: any ComputeAccelerator,
        ocrEngine: (any OCREngine)? = nil,
        existingManifest: BookProcessingManifest? = nil,
        progressHandler: (@Sendable (_ completedPages: Int, _ totalSourcePages: Int) -> Void)? = nil
    ) async throws(PipelineError) -> PipelineOutput {
        let sourceCount = reader.pageCount
        var sourceGrayPages: [GrayscaleBuffer] = []
        sourceGrayPages.reserveCapacity(sourceCount)

        for srcIdx in 0..<sourceCount {
            let oneBased = srcIdx + 1
            if let range = configuration.pageRange, !range.contains(oneBased) {
                continue
            }
            if configuration.excludedPages.contains(oneBased) {
                continue
            }

            do {
                let gray = try await reader.rasterizePage(at: srcIdx, targetDPI: configuration.processingDPI)
                sourceGrayPages.append(gray)
            } catch {
                throw .pdfReadFailed(error)
            }
            progressHandler?(srcIdx + 1, sourceCount)
        }

        return try await processGrayscalePages(
            sourceGrayPages,
            writer: writer,
            accelerator: accelerator,
            ocrEngine: ocrEngine,
            existingManifest: existingManifest
        )
    }

    private struct Pass1Page {
        let outputPageIndex: Int
        let sourcePageIndex: Int
        let splitSide: PageSide
        let bookSide: MarginHarmonizer.PageSide
        let splitConfidence: Double
        let skewAngleDegrees: Double
        let skewConfidence: Double
        let dewarpApplied: Bool
        let dewarpVerticalSagPixels: Double
        let dewarpResidualRMSPixels: Double
        let tracedLines: [PolyLine2D]
        let cleanedBitmap: BinaryBitmap
        let detection: ContentBoxDetector.DetectionResult
        let manualOverride: PageManualOverride?
    }

    /// Runs the complete 3-pass pipeline directly on an array of source `GrayscaleBuffer` scans
    /// and writes the resulting 300 DPI 1-bit pages into `writer`.
    public func processGrayscalePages<Writer: PDFDocumentWriter & ~Copyable>(
        _ sourcePages: [GrayscaleBuffer],
        writer: consuming Writer,
        accelerator: any ComputeAccelerator,
        ocrEngine: (any OCREngine)? = nil,
        existingManifest: BookProcessingManifest? = nil
    ) async throws(PipelineError) -> PipelineOutput {
        let binarizer = AdaptiveBinarizer(configuration: configuration.binarizerConfiguration)
        let cleaner = BorderAndSpeckleCleaner(configuration: configuration.cleanerConfiguration)
        let tracer = TextLineTracer()
        let dewarpSolver = CylindricalDewarpSolver()
        let contentDetector = ContentBoxDetector(configuration: configuration.contentDetectorConfiguration)
        let harmonizer = MarginHarmonizer(configuration: configuration.harmonizerConfiguration)

        // Build lookup table of manual overrides by outputPageIndex if an existing manifest was supplied.
        var overridesByOutputIndex: [Int: PageManualOverride] = [:]
        if let existing = existingManifest {
            for rec in existing.pages {
                if let ov = rec.manualOverride {
                    overridesByOutputIndex[rec.outputPageIndex] = ov
                }
            }
        }

        // --- PASS 1: Page Split, Deskew, 3D Cubic-Sheet Dewarp, 600 DPI Binarization & Content Box Detection ---
        var sourceSplits: [PageSplitDecision] = []
        sourceSplits.reserveCapacity(sourcePages.count)
        var pass1Pages: [Pass1Page] = []
        var prunedPages: [PrunedPageRecord] = []

        let dpiScale = Double(configuration.processingDPI) / 600.0
        let minSagPixels = configuration.minDewarpSagPixelsAt600DPI * dpiScale
        let effectiveGutterTrimWidth = max(0, Int((Double(configuration.gutterTrimWidth) * dpiScale).rounded()))

        for (srcIdx, rawScan) in sourcePages.enumerated() {
            let splitDecision = PageSplitEstimator.estimateSplit(
                in: rawScan,
                mode: configuration.splitMode
            )
            sourceSplits.append(splitDecision)
            let slices = PageSplitEstimator.split(
                rawScan,
                using: splitDecision,
                gutterTrimWidth: effectiveGutterTrimWidth
            )

            for slice in slices {
                let outIdx = pass1Pages.count
                let manualOverride = overridesByOutputIndex[outIdx]

                let bookSide: MarginHarmonizer.PageSide
                switch slice.side {
                case .leftVerso:
                    bookSide = .verso
                case .rightRecto:
                    bookSide = .recto
                case .single:
                    let startIsRecto = (configuration.firstPageSide != .verso)
                    if startIsRecto {
                        bookSide = (outIdx % 2 == 0) ? .recto : .verso
                    } else {
                        bookSide = (outIdx % 2 == 0) ? .verso : .recto
                    }
                }

                // 1a. Multi-scale Deskew
                let skewEstimate = SkewEstimator.estimateSkew(in: slice.buffer)
                let appliedSkew = manualOverride?.overrideSkewDegrees ?? skewEstimate.angleDegrees
                let deskewedGray = SkewEstimator.deskew(
                    slice.buffer,
                    by: appliedSkew,
                    accelerator: accelerator
                )

                // 1b. Binarize deskewed page for text-line tracing & possible 3D cubic-sheet dewarping
                let initialBinary = binarizer.binarize(deskewedGray, accelerator: accelerator)
                let initialCleaned = cleaner.clean(initialBinary)

                let tracedLines = tracer.traceLines(in: initialCleaned)
                let pageSize = Size2I(width: deskewedGray.width, height: deskewedGray.height)

                var finalCleaned = initialCleaned
                var dewarpApplied = false
                var verticalSagPixels = 0.0
                var residualRMS = 0.0

                let shouldAllowDewarp = configuration.enableDewarp && !(manualOverride?.disableDewarp ?? false)
                if shouldAllowDewarp {
                    let solution = dewarpSolver.solve(pageSize: pageSize, lines: tracedLines)
                    if let model = solution.model {
                        residualRMS = model.residualRMSPixels
                        // Evaluate peak vertical excursion across u in [-0.85, 0.85]
                        var minZ = 0.0
                        var maxZ = 0.0
                        for step in -17...17 {
                            let u = Double(step) * 0.05
                            let z = model.depthProfile(u: u)
                            if z < minZ { minZ = z }
                            if z > maxZ { maxZ = z }
                        }
                        verticalSagPixels = (maxZ - minZ) * model.halfHeight

                        if verticalSagPixels >= minSagPixels {
                            let dewarpedGray = accelerator.meshWarp(
                                deskewedGray,
                                displacementGrid: solution.grid,
                                outputSize: pageSize
                            )
                            let dewarpedBinary = binarizer.binarize(dewarpedGray, accelerator: accelerator)
                            finalCleaned = cleaner.clean(dewarpedBinary)
                            dewarpApplied = true
                        }
                    }
                }

                // 1c. Pass 1 Content Box Detection (or manual override)
                var detection = contentDetector.detect(
                    in: finalCleaned,
                    dpi: configuration.processingDPI,
                    splitSide: slice.side
                )
                if let customBox = manualOverride?.overrideContentBox {
                    let customCluster = ContentBoxDetector.Cluster(
                        exactBounds: customBox,
                        foregroundPixels: max(1, finalCleaned.cropped(to: customBox).countBlackPixels())
                    )
                    detection = ContentBoxDetector.DetectionResult(
                        contentBox: customBox,
                        mainBodyBox: customBox,
                        retainedClusters: [customCluster],
                        rejectedBoxes: detection.rejectedBoxes,
                        confidence: 1.0
                    )
                }

                // 1d. Blank sub-page auto-pruning check
                if configuration.autoPruneBlankPages && manualOverride == nil {
                    let totalPixels = finalCleaned.width * finalCleaned.height
                    let blackPixels = finalCleaned.countBlackPixels()
                    let inkDensity = totalPixels > 0 ? Double(blackPixels) / Double(totalPixels) : 0.0

                    if inkDensity < configuration.blankPageInkDensityThreshold {
                        var isBlankConfirmed = false
                        if let ocrEngine {
                            let checkBitmap: BinaryBitmap
                            if configuration.processingDPI >= configuration.outputDPI * 2 {
                                checkBitmap = accelerator.downsampleBinaryTo300DPI(finalCleaned)
                            } else {
                                checkBitmap = finalCleaned
                            }
                            do {
                                let ocrObservations = try await ocrEngine.recognizeText(
                                    in: checkBitmap,
                                    dpi: configuration.outputDPI,
                                    languages: configuration.ocrLanguages
                                )
                                // Require at least one substantive word containing letters with confidence >= 0.60
                                // to prevent scanner glass dust, specks, or punctuation noise (e.g. "2%" at conf 0.5)
                                // from keeping empty flatbed / cover slices.
                                let substantiveWords = ocrObservations.filter { obs in
                                    obs.confidence >= 0.60 && obs.text.contains { $0.isLetter }
                                }
                                if substantiveWords.isEmpty {
                                    isBlankConfirmed = true
                                }
                            } catch {
                                if detection.contentBox == nil || detection.retainedClusters.isEmpty {
                                    isBlankConfirmed = true
                                }
                            }
                        } else {
                            if detection.contentBox == nil || detection.retainedClusters.isEmpty {
                                isBlankConfirmed = true
                            }
                        }

                        if isBlankConfirmed {
                            prunedPages.append(
                                PrunedPageRecord(
                                    sourcePageIndex: srcIdx,
                                    splitSide: slice.side,
                                    inkDensity: inkDensity,
                                    reason: "Blank sub-page slice (ink density \(String(format: "%.4f", inkDensity)) < \(String(format: "%.4f", configuration.blankPageInkDensityThreshold)), 0 OCR words)"
                                )
                            )
                            continue
                        }
                    }
                }

                pass1Pages.append(
                    Pass1Page(
                        outputPageIndex: outIdx,
                        sourcePageIndex: srcIdx,
                        splitSide: slice.side,
                        bookSide: bookSide,
                        splitConfidence: splitDecision.confidence,
                        skewAngleDegrees: appliedSkew,
                        skewConfidence: skewEstimate.confidence,
                        dewarpApplied: dewarpApplied,
                        dewarpVerticalSagPixels: verticalSagPixels,
                        dewarpResidualRMSPixels: residualRMS,
                        tracedLines: tracedLines,
                        cleanedBitmap: finalCleaned,
                        detection: detection,
                        manualOverride: manualOverride
                    )
                )
            }
        }

        // --- PASS 2: Book-Wide Outlier Rejection & 3-Tier Margin Harmonization ---
        let harmonizerInputs = pass1Pages.map { p in
            MarginHarmonizer.PageInput(
                pageIndex: p.outputPageIndex,
                side: p.bookSide,
                pageSize: Size2I(width: p.cleanedBitmap.width, height: p.cleanedBitmap.height),
                dpi: configuration.processingDPI,
                detection: p.detection
            )
        }

        let bookLayout = harmonizer.harmonizeBook(
            pages: harmonizerInputs,
            detector: contentDetector
        )

        // --- PASS 3: Canonical Framing, 600 -> 300 DPI Downsampling, OCR & 1-Bit PDF Assembly ---
        var records: [PageProcessingRecord] = []
        records.reserveCapacity(pass1Pages.count)
        var outputBitmaps: [BinaryBitmap] = []
        outputBitmaps.reserveCapacity(pass1Pages.count)
        var cleanedBitmaps: [BinaryBitmap] = []
        cleanedBitmaps.reserveCapacity(pass1Pages.count)

        let shouldDownsample2x = (configuration.processingDPI >= configuration.outputDPI * 2)

        for (idx, p1) in pass1Pages.enumerated() {
            var plan = bookLayout.pagePlans[idx]
            if let customOrigin = p1.manualOverride?.overrideDestinationOrigin {
                plan = MarginHarmonizer.PageLayoutPlan(
                    pageIndex: plan.pageIndex,
                    side: plan.side,
                    tier: plan.tier,
                    wasOutlierTrimmed: plan.wasOutlierTrimmed,
                    sourceContentBox: plan.sourceContentBox,
                    retainedClusterBoxes: plan.retainedClusterBoxes,
                    rejectedClusterBoxes: plan.rejectedClusterBoxes,
                    destinationOrigin: customOrigin,
                    canvasSize: plan.canvasSize
                )
            }
            if let customBox = p1.manualOverride?.overrideContentBox {
                plan = MarginHarmonizer.PageLayoutPlan(
                    pageIndex: plan.pageIndex,
                    side: plan.side,
                    tier: plan.tier,
                    wasOutlierTrimmed: false,
                    sourceContentBox: customBox,
                    retainedClusterBoxes: [customBox],
                    rejectedClusterBoxes: plan.rejectedClusterBoxes,
                    destinationOrigin: p1.manualOverride?.overrideDestinationOrigin ?? plan.destinationOrigin,
                    canvasSize: plan.canvasSize
                )
            }

            let framed600 = harmonizer.renderPage(from: p1.cleanedBitmap, plan: plan)
            let finalBitmap: BinaryBitmap
            if shouldDownsample2x {
                finalBitmap = accelerator.downsampleBinaryTo300DPI(framed600)
            } else {
                finalBitmap = framed600
            }

            var ocrObservations: [RecognizedTextObservation] = []
            if let ocrEngine {
                do {
                    ocrObservations = try await ocrEngine.recognizeText(
                        in: finalBitmap,
                        dpi: configuration.outputDPI,
                        languages: configuration.ocrLanguages
                    )
                } catch {
                    throw .ocrFailed(error)
                }
            }

            let pageWidthPoints = Double(finalBitmap.width) * 72.0 / Double(configuration.outputDPI)
            let pageHeightPoints = Double(finalBitmap.height) * 72.0 / Double(configuration.outputDPI)
            let pageBoxPoints = Rect2D(x: 0, y: 0, width: pageWidthPoints, height: pageHeightPoints)

            do {
                try writer.appendPage(
                    bitmap: finalBitmap,
                    dpi: configuration.outputDPI,
                    pageBoxPoints: pageBoxPoints,
                    ocrLayer: ocrObservations
                )
            } catch {
                throw .pdfWriteFailed(error)
            }

            let skewConf = p1.detection.contentBox == nil ? 1.0 : max(0.5, p1.skewConfidence)
            let overallConfidence = min(p1.splitConfidence, min(skewConf, p1.detection.confidence))
            let flagged = overallConfidence < configuration.lowConfidenceThreshold

            records.append(
                PageProcessingRecord(
                    outputPageIndex: p1.outputPageIndex,
                    sourcePageIndex: p1.sourcePageIndex,
                    splitSide: p1.splitSide,
                    bookSide: p1.bookSide,
                    skewAngleDegrees: p1.skewAngleDegrees,
                    skewConfidence: p1.skewConfidence,
                    dewarpApplied: p1.dewarpApplied,
                    dewarpVerticalSagPixels: p1.dewarpVerticalSagPixels,
                    dewarpResidualRMSPixels: p1.dewarpResidualRMSPixels,
                    tracedLineCount: p1.tracedLines.count,
                    tracedLines: p1.tracedLines,
                    layoutPlan: plan,
                    overallConfidence: overallConfidence,
                    flaggedLowConfidence: flagged,
                    manualOverride: p1.manualOverride
                )
            )
            outputBitmaps.append(finalBitmap)
            cleanedBitmaps.append(p1.cleanedBitmap)
        }

        do {
            try writer.finalize()
        } catch {
            throw .pdfWriteFailed(error)
        }

        let manifest = BookProcessingManifest(
            processingDPI: configuration.processingDPI,
            outputDPI: configuration.outputDPI,
            canonicalCanvasSizeAtProcessingDPI: bookLayout.canvasSize,
            versoCanonicalFrame: bookLayout.versoCanonicalFrame,
            rectoCanonicalFrame: bookLayout.rectoCanonicalFrame,
            sourcePageSplits: sourceSplits,
            pages: records,
            prunedPages: prunedPages,
            ocrEngine: ocrEngine.map { String(describing: type(of: $0)) },
            ocrLanguages: ocrEngine != nil ? configuration.ocrLanguages : nil
        )

        return PipelineOutput(
            manifest: manifest,
            outputBitmapsAtOutputDPI: outputBitmaps,
            cleanedBitmapsAtProcessingDPI: cleanedBitmaps
        )
    }
}
