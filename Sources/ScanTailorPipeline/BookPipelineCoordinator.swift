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
    /// Per-page policy for the macro-cluster border fallback (`nil` is `.automatic`).
    public var borderFallback: BorderFallbackPolicy?
    /// Per-page running-header policy (`nil` is `.automatic`).
    public var runningHeader: RunningHeaderPolicy?
    /// Per-page vertical registration policy (`nil` is `.automatic`).
    public var verticalRegistration: VerticalRegistrationPolicy?
    /// Forces the page to be a canonical page or a dimensional outlier (`nil` is automatic; Substep 6.2.1).
    public var dimensionClass: DimensionClass?
    /// Edge nudges applied to the detected content box, in 600 DPI pixels (positive moves an edge right or
    /// down). Resolved into ``overrideContentBox`` during pass 1, so a stored record never carries it (Substep 6.3.1).
    public var contentBoxNudge: ContentBoxNudge?
    /// Moves the content by this many 600 DPI pixels after all automatic placement (Substep 6.3.1).
    public var destinationOffset: Point2I?
    /// Forces the page's layout tier (`nil` is automatic; Substep 6.3.1).
    public var forcedTier: MarginHarmonizer.PlacementTier?
    /// PDF page size in inches for an outlier that has its own canvas (Substep 6.3.1).
    public var pageSizeInches: Size2D?
    /// Never drop this page as blank (Substep 6.3.1).
    public var keep: Bool?
    /// Drop this page from the book (Substep 6.3.1).
    public var drop: Bool?

    /// Displacements of the four edges of a content box in pixels; positive moves an edge right or down.
    public struct ContentBoxNudge: Sendable, Equatable, Codable {
        public var top: Int
        public var left: Int
        public var bottom: Int
        public var right: Int

        public init(top: Int = 0, left: Int = 0, bottom: Int = 0, right: Int = 0) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        /// `box` with each edge moved, kept inside `bounds`; `nil` when nothing is left.
        public func applied(to box: Rect2I, within bounds: Size2I) -> Rect2I? {
            let minX = min(max(0, box.minX + left), bounds.width)
            let maxX = min(max(0, box.maxX + right), bounds.width)
            let minY = min(max(0, box.minY + top), bounds.height)
            let maxY = min(max(0, box.maxY + bottom), bounds.height)
            guard maxX > minX, maxY > minY else { return nil }
            return Rect2I(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    /// `base` overlaid with the non-`nil` fields of `self` (used to let an adjustments file win over a stored manifest).
    public func overlaid(on base: PageManualOverride?) -> PageManualOverride {
        guard var r = base else { return self }
        r.overrideSkewDegrees = overrideSkewDegrees ?? r.overrideSkewDegrees
        r.disableDewarp = disableDewarp ?? r.disableDewarp
        r.overrideContentBox = overrideContentBox ?? r.overrideContentBox
        r.overrideDestinationOrigin = overrideDestinationOrigin ?? r.overrideDestinationOrigin
        r.borderFallback = borderFallback ?? r.borderFallback
        r.runningHeader = runningHeader ?? r.runningHeader
        r.verticalRegistration = verticalRegistration ?? r.verticalRegistration
        r.dimensionClass = dimensionClass ?? r.dimensionClass
        r.contentBoxNudge = contentBoxNudge ?? r.contentBoxNudge
        r.destinationOffset = destinationOffset ?? r.destinationOffset
        r.forcedTier = forcedTier ?? r.forcedTier
        r.pageSizeInches = pageSizeInches ?? r.pageSizeInches
        r.keep = keep ?? r.keep
        r.drop = drop ?? r.drop
        return r
    }

    public init(
        overrideSkewDegrees: Double? = nil,
        disableDewarp: Bool? = nil,
        overrideContentBox: Rect2I? = nil,
        overrideDestinationOrigin: Point2I? = nil,
        borderFallback: BorderFallbackPolicy? = nil,
        runningHeader: RunningHeaderPolicy? = nil,
        verticalRegistration: VerticalRegistrationPolicy? = nil,
        dimensionClass: DimensionClass? = nil,
        contentBoxNudge: ContentBoxNudge? = nil,
        destinationOffset: Point2I? = nil,
        forcedTier: MarginHarmonizer.PlacementTier? = nil,
        pageSizeInches: Size2D? = nil,
        keep: Bool? = nil,
        drop: Bool? = nil
    ) {
        self.contentBoxNudge = contentBoxNudge
        self.destinationOffset = destinationOffset
        self.forcedTier = forcedTier
        self.pageSizeInches = pageSizeInches
        self.keep = keep
        self.drop = drop
        self.dimensionClass = dimensionClass
        self.verticalRegistration = verticalRegistration
        self.borderFallback = borderFallback
        self.runningHeader = runningHeader
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
    /// Macro-cluster border fallback telemetry (`nil` when the fallback was not engaged).
    public var borderFallback: MacroBorderResult?
    /// Running header / first-baseline top anchor (`nil` when detection is disabled or for
    /// manifests written before Substep 6.1.1).
    public var topAnchor: PageTopAnchor?
    /// Vertical registration outcome (`nil` when no anchors were available or for manifests
    /// written before Substep 6.1.2).
    public var registration: PageVerticalRegistration?
    /// Consensus-dimension outcome (`nil` for manifests written before Substep 6.2.1).
    public var dimension: PageDimensionRecord?
    /// Horizontal (`width`) and vertical (`height`) factors this camera-photographed page was resampled by to
    /// match the book's text block (Substep 7.1.1b-i). Every box in ``layoutPlan`` is in the resampled page.
    /// `nil` for unscaled pages and manifests written before 7.1.1b.
    public var textBlockScale: Size2D?

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
        manualOverride: PageManualOverride? = nil,
        borderFallback: MacroBorderResult? = nil,
        topAnchor: PageTopAnchor? = nil,
        registration: PageVerticalRegistration? = nil,
        dimension: PageDimensionRecord? = nil,
        textBlockScale: Size2D? = nil
    ) {
        self.dimension = dimension
        self.textBlockScale = textBlockScale
        self.borderFallback = borderFallback
        self.topAnchor = topAnchor
        self.registration = registration
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
    /// Why, in a word: `leadingBlank`, `trailingBlank`, `coverSheet`, `cover` or `adjustment` (`nil` in older manifests).
    public var kind: String?

    public init(
        sourcePageIndex: Int,
        splitSide: PageSide,
        inkDensity: Double,
        reason: String,
        kind: String? = nil
    ) {
        self.sourcePageIndex = sourcePageIndex
        self.splitSide = splitSide
        self.inkDensity = inkDensity
        self.reason = reason
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case sourcePageIndex, splitSide, inkDensity, reason, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourcePageIndex = try c.decode(Int.self, forKey: .sourcePageIndex)
        splitSide = try c.decode(PageSide.self, forKey: .splitSide)
        inkDensity = try c.decode(Double.self, forKey: .inkDensity)
        reason = try c.decode(String.self, forKey: .reason)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
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
    /// Optional book-wide typographic glyph metrics and automatic physical scale calibration summary.
    public var fontScaleEstimate: FontScaleAnalyzer.BookScaleEstimate?
    /// Optional explicit source optical DPI override (`--input-dpi`).
    public var inputDPI: Int?
    /// Optional explicit target output page trim size override (`--page-size`).
    public var pageSize: PhysicalSizeSpec?
    /// Optional explicit canonical text block size override (`--content-box-size`).
    public var contentBoxSize: PhysicalSizeSpec?
    /// `true` when physical scale could not be determined automatically with high confidence and estimated single-page height exceeded `14"`, requiring AI agent-to-user escalation.
    public var physicalScaleAmbiguous: Bool
    /// Per-source-page document quadrangle detection and perspective rectification records
    /// (empty for manifests written before Substep 5.1.2).
    public var sourcePageGeometry: [SourcePageGeometryRecord]
    /// Book-wide running-header statistics (`nil` when detection is disabled or for manifests
    /// written before Substep 6.1.1).
    public var runningHeaderModel: RunningHeaderModel?
    /// Book-wide vertical registration summary (`nil` when no anchors were available or for
    /// manifests written before Substep 6.1.2).
    public var verticalRegistration: VerticalRegistrationSummary?
    /// Book-wide consensus-dimension summary (`nil` for manifests written before Substep 6.2.1).
    public var dimensionConsensus: DimensionConsensusSummary?
    /// What the adjustments file did (`nil` when none was applied, and for manifests written before Substep 6.3.1).
    public var adjustments: AdjustmentReport?
    /// Scan number (1-based, counted from the start of the source PDF) of each processed scan, indexed like
    /// ``PageProcessingRecord/sourcePageIndex`` (empty for manifests written before Substep 6.3.1, where the
    /// scan number is `sourcePageIndex + 1`).
    public var sourceScanNumbers: [Int]
    /// How the run went: parallel jobs, cache reuse and timings (`nil` for manifests written before Substep 6.3.2).
    /// It changes from run to run, so leave it out when comparing results.
    public var run: PipelineRunReport?

    /// Scan number of the scan a page came from.
    public func scanNumber(of record: PageProcessingRecord) -> Int {
        sourceScanNumbers.indices.contains(record.sourcePageIndex)
            ? sourceScanNumbers[record.sourcePageIndex]
            : record.sourcePageIndex + 1
    }

    /// The stable scan-based name of a page (`s12`, `s12L`, `s12R`) that an adjustments file can use.
    public func scanReference(of record: PageProcessingRecord) -> String {
        let half: String
        switch record.splitSide {
        case .single: half = ""
        case .leftVerso: half = "L"
        case .rightRecto: half = "R"
        }
        return "s\(scanNumber(of: record))\(half)"
    }

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
        ocrLanguages: [String]? = nil,
        fontScaleEstimate: FontScaleAnalyzer.BookScaleEstimate? = nil,
        inputDPI: Int? = nil,
        pageSize: PhysicalSizeSpec? = nil,
        contentBoxSize: PhysicalSizeSpec? = nil,
        physicalScaleAmbiguous: Bool = false,
        sourcePageGeometry: [SourcePageGeometryRecord] = [],
        runningHeaderModel: RunningHeaderModel? = nil,
        verticalRegistration: VerticalRegistrationSummary? = nil,
        dimensionConsensus: DimensionConsensusSummary? = nil,
        adjustments: AdjustmentReport? = nil,
        sourceScanNumbers: [Int] = []
    ) {
        self.sourceScanNumbers = sourceScanNumbers
        self.adjustments = adjustments
        self.dimensionConsensus = dimensionConsensus
        self.runningHeaderModel = runningHeaderModel
        self.verticalRegistration = verticalRegistration
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
        self.fontScaleEstimate = fontScaleEstimate
        self.inputDPI = inputDPI
        self.pageSize = pageSize
        self.contentBoxSize = contentBoxSize
        self.physicalScaleAmbiguous = physicalScaleAmbiguous
        self.sourcePageGeometry = sourcePageGeometry
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
        case fontScaleEstimate
        case inputDPI
        case pageSize
        case contentBoxSize
        case physicalScaleAmbiguous
        case sourcePageGeometry
        case runningHeaderModel
        case verticalRegistration
        case dimensionConsensus
        case adjustments
        case sourceScanNumbers
        case run
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
        self.fontScaleEstimate = try container.decodeIfPresent(FontScaleAnalyzer.BookScaleEstimate.self, forKey: .fontScaleEstimate)
        self.inputDPI = try container.decodeIfPresent(Int.self, forKey: .inputDPI)
        self.pageSize = try container.decodeIfPresent(PhysicalSizeSpec.self, forKey: .pageSize)
        self.contentBoxSize = try container.decodeIfPresent(PhysicalSizeSpec.self, forKey: .contentBoxSize)
        self.physicalScaleAmbiguous = try container.decodeIfPresent(Bool.self, forKey: .physicalScaleAmbiguous) ?? false
        self.sourcePageGeometry = try container.decodeIfPresent([SourcePageGeometryRecord].self, forKey: .sourcePageGeometry) ?? []
        self.runningHeaderModel = try container.decodeIfPresent(RunningHeaderModel.self, forKey: .runningHeaderModel)
        self.verticalRegistration = try container.decodeIfPresent(VerticalRegistrationSummary.self, forKey: .verticalRegistration)
        self.dimensionConsensus = try container.decodeIfPresent(DimensionConsensusSummary.self, forKey: .dimensionConsensus)
        self.adjustments = try container.decodeIfPresent(AdjustmentReport.self, forKey: .adjustments)
        self.sourceScanNumbers = try container.decodeIfPresent([Int].self, forKey: .sourceScanNumbers) ?? []
        self.run = try container.decodeIfPresent(PipelineRunReport.self, forKey: .run)
    }
}

/// A stage after which a run may stop early so an agent can inspect the result without paying for the whole book.
public enum PipelineStop: String, Sendable, Equatable, Codable {
    /// After page splitting, cleaning, content boxes, consensus sizes and the layout plans: the manifest and the
    /// cleaned 600 DPI pages exist, but nothing is rendered at output resolution, recognized, or written to a PDF.
    case layout
}

/// Coordinates the 3-pass automated book processing pipeline:
/// - **Pass 1**: Source rasterization (600 DPI), document quadrangle detection and perspective
///   rectification (desk excision), residual desk/background masking, dual-page spread splitting,
///   multi-scale deskew, 3D cubic-sheet dewarping (with flat-page auto-bypass), illumination
///   normalization, adaptive binarization, border/speckle cleanup, and initial content box detection.
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
        /// Optional explicit genuine source optical DPI (`--input-dpi`), overriding uncalibrated 72/96-DPI wrapper metadata.
        public var inputDPI: Int?
        /// Optional explicit target output page trim size (`--page-size`), forwarded to `harmonizerConfiguration.targetPageSize`.
        public var targetPageSize: PhysicalSizeSpec? {
            get { harmonizerConfiguration.targetPageSize }
            set { harmonizerConfiguration.targetPageSize = newValue }
        }
        /// Optional explicit canonical text block size (`--content-box-size`), forwarded to `harmonizerConfiguration.targetContentBoxSize`.
        public var targetContentBoxSize: PhysicalSizeSpec? {
            get { harmonizerConfiguration.targetContentBoxSize }
            set { harmonizerConfiguration.targetContentBoxSize = newValue }
        }
        /// Spread split mode (`.automatic`, `.singlePage`, or `.twoPageSpread`).
        public var splitMode: PageSplitMode
        /// Central gutter strip trimming width in pixels at 600 DPI physically removed between split pages (default: `24`).
        /// Scaled proportionally when `processingDPI` differs from 600 DPI.
        public var gutterTrimWidth: Int
        /// Whether to automatically detect and prune blank sub-page slices (default: `true`).
        public var autoPruneBlankPages: Bool
        /// What to do with library cover sheets and printed covers at the ends of the book (default: ``CoverHandling/auto``).
        public var coverHandling: CoverHandling
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
        /// Whether to automatically measure typographic glyph height and rescale oversized camera/image-wrapper pages (default: `true`).
        public var enableAutomaticFontScaleCalibration: Bool
        /// Configuration for automatic typographic font-scale analysis and camera-wrapper DPI deduction.
        public var fontScaleConfiguration: FontScaleAnalyzer.Configuration
        /// Whether to detect the document quadrangle and remove camera perspective before spread
        /// splitting (default: `true`). `fullFrame`/`rejected` detections always pass through.
        public var enablePerspectiveRectification: Bool
        /// Document quadrangle detector configuration.
        public var quadDetectorConfiguration: DocumentQuadDetector.Configuration
        /// Perspective rectifier configuration.
        public var rectifierConfiguration: PerspectiveRectifier.Configuration
        /// Whether to mask residual desk/background pixels before illumination normalization and
        /// binarization (default: `true`). Runs after perspective rectification, on every source
        /// page (including unrectified ones).
        public var enableDeskMasking: Bool
        /// Desk/background masker configuration.
        public var deskMaskerConfiguration: PaperRegionMasker.Configuration
        /// Whether the macro-cluster border fallback may run on pages whose geometry telemetry is
        /// marginal (default: `true`). A per-page `forced` override still engages it when `true`.
        public var enableBorderFallback: Bool
        /// Quadrangle detections below this confidence count as marginal and engage the border
        /// fallback (default: `0.70`).
        public var borderFallbackMarginalConfidence: Double
        /// Whether to detect running headers, folios, and first body baselines and record them as
        /// per-page top anchors (default: `true`). Detection is telemetry only; it changes no pixels.
        public var enableRunningHeaderDetection: Bool
        /// Running-header detector configuration.
        public var runningHeaderConfiguration: RunningHeaderDetector.Configuration
        /// Vertical registration configuration. Registration aligns full-body pages on their running
        /// header (or first body baseline) and needs `enableRunningHeaderDetection`.
        public var verticalRegistrationConfiguration: VerticalRegistration.Configuration
        /// Consensus-dimension clustering (Substep 6.2.1): which pages share the book's page size.
        public var dimensionConsensusConfiguration: DimensionConsensus.Configuration
        /// Draw each dimensional outlier on its own PDF page size instead of the book's shared canvas (Substep 6.2.2).
        public var isolateOutlierCanvases: Bool
        /// Per-scan and per-page edits from an adjustments file (`--apply-manifest`, Substep 6.3.1).
        public var adjustments: PageAdjustments
        /// Scan references (`s45L`) that join `dimensionConsensusConfiguration.manualOutlierPages` as the exact outlier list.
        public var manualOutlierReferences: [PageReference]
        /// Stops after the layout is decided (`--stop-after layout`): no pixels are rendered, recognized, or written.
        public var stopAfter: PipelineStop?
        /// Scans (pass 1) and pages (pass 3) processed at the same time (`--jobs`, Substep 6.3.2). The result does
        /// not depend on it; memory grows with it, by about one scan's working set per job.
        public var jobs: Int
        /// Reuse of earlier results (`--cache-dir`, Substep 6.3.2); `nil` computes everything.
        public var cache: PipelineCacheOptions?
        /// Resampling of camera-photographed pages to the book's text-block size (Substep 7.1.1b-i); `nil` keeps
        /// every page at its photographed scale. Flatbed scans are never resampled.
        public var cameraTextBlockScaling: TextBlockScaleNormalizer.Configuration?

        public init(
            processingDPI: Int = 600,
            outputDPI: Int = 300,
            inputDPI: Int? = nil,
            targetPageSize: PhysicalSizeSpec? = nil,
            targetContentBoxSize: PhysicalSizeSpec? = nil,
            splitMode: PageSplitMode = .automatic,
            gutterTrimWidth: Int = 24,
            autoPruneBlankPages: Bool = true,
            coverHandling: CoverHandling = .auto,
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
            lowConfidenceThreshold: Double = 0.75,
            enableAutomaticFontScaleCalibration: Bool = true,
            fontScaleConfiguration: FontScaleAnalyzer.Configuration = FontScaleAnalyzer.Configuration(),
            enablePerspectiveRectification: Bool = true,
            quadDetectorConfiguration: DocumentQuadDetector.Configuration = DocumentQuadDetector.Configuration(),
            rectifierConfiguration: PerspectiveRectifier.Configuration = PerspectiveRectifier.Configuration(),
            enableDeskMasking: Bool = true,
            deskMaskerConfiguration: PaperRegionMasker.Configuration = PaperRegionMasker.Configuration(),
            enableBorderFallback: Bool = true,
            borderFallbackMarginalConfidence: Double = 0.70,
            enableRunningHeaderDetection: Bool = true,
            runningHeaderConfiguration: RunningHeaderDetector.Configuration = RunningHeaderDetector.Configuration(),
            verticalRegistrationConfiguration: VerticalRegistration.Configuration = VerticalRegistration.Configuration(),
            dimensionConsensusConfiguration: DimensionConsensus.Configuration = DimensionConsensus.Configuration(),
            isolateOutlierCanvases: Bool = true,
            adjustments: PageAdjustments = .empty,
            manualOutlierReferences: [PageReference] = [],
            stopAfter: PipelineStop? = nil,
            jobs: Int = 1,
            cache: PipelineCacheOptions? = nil,
            cameraTextBlockScaling: TextBlockScaleNormalizer.Configuration? = TextBlockScaleNormalizer.Configuration()
        ) {
            self.jobs = max(1, jobs)
            self.cache = cache
            self.cameraTextBlockScaling = cameraTextBlockScaling
            self.adjustments = adjustments
            self.manualOutlierReferences = manualOutlierReferences
            self.stopAfter = stopAfter
            self.dimensionConsensusConfiguration = dimensionConsensusConfiguration
            self.isolateOutlierCanvases = isolateOutlierCanvases
            self.verticalRegistrationConfiguration = verticalRegistrationConfiguration
            self.enableRunningHeaderDetection = enableRunningHeaderDetection
            self.runningHeaderConfiguration = runningHeaderConfiguration
            self.enableBorderFallback = enableBorderFallback
            self.borderFallbackMarginalConfidence = min(1.0, max(0.0, borderFallbackMarginalConfidence))
            self.processingDPI = max(150, processingDPI)
            self.outputDPI = max(72, outputDPI)
            self.inputDPI = inputDPI.map { max(1, $0) }
            self.splitMode = splitMode
            self.gutterTrimWidth = max(0, gutterTrimWidth)
            self.autoPruneBlankPages = autoPruneBlankPages
            self.coverHandling = coverHandling
            self.blankPageInkDensityThreshold = min(max(0.0001, blankPageInkDensityThreshold), 0.10)
            self.enableDewarp = enableDewarp
            self.minDewarpSagPixelsAt600DPI = max(1.0, minDewarpSagPixelsAt600DPI)
            self.binarizerConfiguration = binarizerConfiguration
            self.cleanerConfiguration = cleanerConfiguration
            self.contentDetectorConfiguration = contentDetectorConfiguration
            var harm = harmonizerConfiguration
            if let targetPageSize {
                harm.targetPageSize = targetPageSize
            }
            if let targetContentBoxSize {
                harm.targetContentBoxSize = targetContentBoxSize
            }
            self.harmonizerConfiguration = harm
            self.firstPageSide = (firstPageSide == .single) ? .recto : firstPageSide
            self.pageRange = pageRange
            self.excludedPages = excludedPages
            self.ocrLanguages = ocrLanguages
            self.lowConfidenceThreshold = min(max(0.0, lowConfidenceThreshold), 1.0)
            self.enableAutomaticFontScaleCalibration = enableAutomaticFontScaleCalibration
            self.fontScaleConfiguration = fontScaleConfiguration
            self.enablePerspectiveRectification = enablePerspectiveRectification
            self.quadDetectorConfiguration = quadDetectorConfiguration
            self.rectifierConfiguration = rectifierConfiguration
            self.enableDeskMasking = enableDeskMasking
            self.deskMaskerConfiguration = deskMaskerConfiguration
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
        /// Per-page text-line profiles measured for running-header detection (empty when detection
        /// is disabled). Used for diagnostics (`--diagnostics-dir`).
        public let lineProfiles: [RunningHeaderDetector.PageLineProfile]
        /// The stage the run stopped after (`nil` for a complete run). A stopped run has no `outputBitmapsAtOutputDPI`.
        public let stoppedAfter: PipelineStop?

        public init(
            manifest: BookProcessingManifest,
            outputBitmapsAtOutputDPI: [BinaryBitmap],
            cleanedBitmapsAtProcessingDPI: [BinaryBitmap],
            lineProfiles: [RunningHeaderDetector.PageLineProfile] = [],
            stoppedAfter: PipelineStop? = nil
        ) {
            self.stoppedAfter = stoppedAfter
            self.lineProfiles = lineProfiles
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
        var activeSourceIndices: [Int] = []
        activeSourceIndices.reserveCapacity(sourceCount)

        for srcIdx in 0..<sourceCount {
            let oneBased = srcIdx + 1
            if let range = configuration.pageRange, !range.contains(oneBased) {
                continue
            }
            if configuration.excludedPages.contains(oneBased) {
                continue
            }
            activeSourceIndices.append(srcIdx)
        }

        let effectiveInputDPI = configuration.inputDPI ?? existingManifest?.inputDPI
        let effectivePageSize = configuration.targetPageSize ?? existingManifest?.pageSize
        let effectiveContentBoxSize = configuration.targetContentBoxSize ?? existingManifest?.contentBoxSize

        var effectiveRenderDPI = configuration.processingDPI
        var readerPreScaleDecision: FontScaleAnalyzer.PreRasterScaleDecision? = nil

        if !activeSourceIndices.isEmpty {
            if let explicitInputDPI = effectiveInputDPI {
                // Priority 1: Explicit `--input-dpi` overrides declared 72-DPI PDF wrapper metadata directly.
                let safeInputDPI = max(1, explicitInputDPI)
                let scaleFactor = 72.0 / Double(safeInputDPI)
                let shouldRescale = abs(scaleFactor - 1.0) > 1e-4
                let decision = FontScaleAnalyzer.PreRasterScaleDecision(
                    shouldRescale: shouldRescale,
                    scaleCorrectionFactor: shouldRescale ? scaleFactor : 1.0,
                    declaredBodyPointSize: nil,
                    inferredSourceOpticalDPI: Double(safeInputDPI),
                    confidence: 1.0,
                    probedPageCount: 0
                )
                readerPreScaleDecision = decision
                effectiveRenderDPI = decision.effectiveRenderDPI(forProcessingDPI: configuration.processingDPI)
            } else {
                // If no explicit dimension/DPI override is active and `existingManifest` already recorded a prior auto-rescale,
                // reuse its exact scale correction factor deterministically.
                if effectivePageSize == nil,
                   effectiveContentBoxSize == nil,
                   let priorEstimate = existingManifest?.fontScaleEstimate,
                   priorEstimate.wasAutoRescaled
                {
                    let reusedDecision = FontScaleAnalyzer.PreRasterScaleDecision(
                        shouldRescale: true,
                        scaleCorrectionFactor: priorEstimate.appliedScaleCorrectionFactor,
                        declaredBodyPointSize: priorEstimate.declaredBodyPointSizeBeforeRescale > 0.0
                            ? priorEstimate.declaredBodyPointSizeBeforeRescale
                            : nil,
                        inferredSourceOpticalDPI: priorEstimate.inferredSourceOpticalDPI,
                        confidence: priorEstimate.confidence,
                        probedPageCount: priorEstimate.sampledPageCount,
                        isPhysicalScaleAmbiguous: existingManifest?.physicalScaleAmbiguous ?? false,
                        wasAntiBillboardClamped: priorEstimate.wasAntiBillboardClamped
                    )
                    readerPreScaleDecision = reusedDecision
                    effectiveRenderDPI = reusedDecision.effectiveRenderDPI(forProcessingDPI: configuration.processingDPI)
                } else {
                    var pageBoxesPts: [Rect2D] = []
                    pageBoxesPts.reserveCapacity(activeSourceIndices.count)
                    for srcIdx in activeSourceIndices {
                        do {
                            let box = try reader.pageBoxPoints(at: srcIdx)
                            pageBoxesPts.append(box)
                        } catch {
                            throw .pdfReadFailed(error)
                        }
                    }

                    let declaredSizesInches = pageBoxesPts.map {
                        Size2D(width: $0.width / 72.0, height: $0.height / 72.0)
                    }
                    let fontScaleAnalyzer = FontScaleAnalyzer(configuration: configuration.fontScaleConfiguration)

                    if let targetPage = effectivePageSize {
                        // Priority 2: Explicit `--page-size` rescales oversized uncalibrated wrappers to match target sheet dimensions.
                        if fontScaleAnalyzer.areDeclaredPagesOversized(declaredSizesInches) {
                            let decision = deriveSheetScaleDecision(
                                targetSinglePageInches: targetPage.sizeInInches,
                                declaredPageSizesInches: declaredSizesInches,
                                referenceDeclaredDPI: 72
                            )
                            readerPreScaleDecision = decision
                            effectiveRenderDPI = decision.effectiveRenderDPI(forProcessingDPI: configuration.processingDPI)
                        } else {
                            readerPreScaleDecision = FontScaleAnalyzer.PreRasterScaleDecision(
                                shouldRescale: false,
                                scaleCorrectionFactor: 1.0,
                                declaredBodyPointSize: nil,
                                inferredSourceOpticalDPI: nil,
                                confidence: 1.0,
                                probedPageCount: 0
                            )
                        }
                    } else if let targetBox = effectiveContentBoxSize {
                        // Priority 3: Explicit `--content-box-size` probes oversized wrappers so detected content matches target box size.
                        if fontScaleAnalyzer.areDeclaredPagesOversized(declaredSizesInches) {
                            let binarizer = AdaptiveBinarizer(configuration: configuration.binarizerConfiguration)
                            let cleaner = BorderAndSpeckleCleaner(configuration: configuration.cleanerConfiguration)
                            let contentDetector = ContentBoxDetector(configuration: configuration.contentDetectorConfiguration)
                            let probeOffsets = Self.selectProbeIndices(from: activeSourceIndices.count, maxProbes: 3)
                            let targetBoxInches = targetBox.sizeInInches
                            var boxScales: [Double] = []

                            for offset in probeOffsets {
                                let srcIdx = activeSourceIndices[offset]
                                let boxPts = pageBoxesPts[offset]
                                let longestInches = max(1.0, max(boxPts.width, boxPts.height) / 72.0)
                                let rawProbeDPI = Int((3800.0 / longestInches).rounded())
                                let snappedProbeDPI = (66...78).contains(rawProbeDPI) ? 72 : rawProbeDPI
                                let probeRenderDPI = min(configuration.processingDPI, max(36, snappedProbeDPI))

                                let probeGray: GrayscaleBuffer
                                do {
                                    probeGray = try await reader.rasterizePage(at: srcIdx, targetDPI: probeRenderDPI)
                                } catch {
                                    throw .pdfReadFailed(error)
                                }

                                let probeSplit = PageSplitEstimator.estimateSplit(in: probeGray, mode: configuration.splitMode)
                                let probeGutterTrim = max(0, Int((Double(configuration.gutterTrimWidth) * Double(probeGray.width) / 4000.0).rounded()))
                                let probeSlices = PageSplitEstimator.split(probeGray, using: probeSplit, gutterTrimWidth: probeGutterTrim)

                                for slice in probeSlices {
                                    let sliceSize = Size2I(width: slice.buffer.width, height: slice.buffer.height)
                                    let isSliceSpread = slice.side == .single && Double(sliceSize.width) > Double(sliceSize.height) * 1.15
                                    let nominalDPI = FontScaleAnalyzer.nominalProbeDPI(forPixelSize: sliceSize, isLikelySpread: isSliceSpread)
                                    let nominalGray = GrayscaleBuffer(
                                        width: slice.buffer.width,
                                        height: slice.buffer.height,
                                        dpi: nominalDPI,
                                        pixels: slice.buffer.pixels
                                    )
                                    let probeBinary = binarizer.binarize(nominalGray, accelerator: accelerator)
                                    let cleanedProbe = cleaner.clean(probeBinary)
                                    let det = contentDetector.detect(in: cleanedProbe, dpi: nominalDPI, splitSide: slice.side)
                                    if let cBox = det.contentBox,
                                       !cBox.isEmpty,
                                       Double(cBox.height) >= Double(cleanedProbe.height) * 0.25,
                                       Double(cBox.width) >= Double(cleanedProbe.width) * 0.25
                                    {
                                        let detWInches = Double(cBox.width) / Double(probeRenderDPI)
                                        let detHInches = Double(cBox.height) / Double(probeRenderDPI)
                                        let s = 0.5 * (targetBoxInches.width / detWInches + targetBoxInches.height / detHInches)
                                        if s.isFinite && s > 0.0 {
                                            boxScales.append(s)
                                        }
                                    }
                                }
                            }

                            let decision: FontScaleAnalyzer.PreRasterScaleDecision
                            if let medianScale = Self.medianOfSorted(boxScales.sorted()), medianScale < 0.95 {
                                let clampedScale = min(0.95, max(0.02, medianScale))
                                decision = FontScaleAnalyzer.PreRasterScaleDecision(
                                    shouldRescale: true,
                                    scaleCorrectionFactor: clampedScale,
                                    declaredBodyPointSize: nil,
                                    inferredSourceOpticalDPI: 72.0 / clampedScale,
                                    confidence: 1.0,
                                    probedPageCount: boxScales.count
                                )
                            } else {
                                let impliedPage = impliedSinglePageInches(forContentBoxInches: targetBoxInches)
                                decision = deriveSheetScaleDecision(
                                    targetSinglePageInches: impliedPage,
                                    declaredPageSizesInches: declaredSizesInches,
                                    referenceDeclaredDPI: 72
                                )
                            }
                            readerPreScaleDecision = decision
                            effectiveRenderDPI = decision.effectiveRenderDPI(forProcessingDPI: configuration.processingDPI)
                        } else {
                            readerPreScaleDecision = FontScaleAnalyzer.PreRasterScaleDecision(
                                shouldRescale: false,
                                scaleCorrectionFactor: 1.0,
                                declaredBodyPointSize: nil,
                                inferredSourceOpticalDPI: nil,
                                confidence: 1.0,
                                probedPageCount: 0
                            )
                        }
                    } else {
                        // Priority 4: Automatic `FontScaleAnalyzer` typographic calibration (when enabled) + anti-billboard fallback on oversized wrappers.
                        if fontScaleAnalyzer.areDeclaredPagesOversized(declaredSizesInches) {
                            var probeMetrics: [FontScaleAnalyzer.PageGlyphMetrics] = []
                            var probedSpreadCount = 0
                            var probedSourceCount = 0

                            if configuration.enableAutomaticFontScaleCalibration {
                                let binarizer = AdaptiveBinarizer(configuration: configuration.binarizerConfiguration)
                                let probeOffsets = Self.selectProbeIndices(from: activeSourceIndices.count, maxProbes: 3)

                                for offset in probeOffsets {
                                    let srcIdx = activeSourceIndices[offset]
                                    let boxPts = pageBoxesPts[offset]
                                    let longestInches = max(1.0, max(boxPts.width, boxPts.height) / 72.0)
                                    let rawProbeDPI = Int((3800.0 / longestInches).rounded())
                                    let snappedProbeDPI = (66...78).contains(rawProbeDPI) ? 72 : rawProbeDPI
                                    let probeRenderDPI = min(configuration.processingDPI, max(36, snappedProbeDPI))

                                    let probeGray: GrayscaleBuffer
                                    do {
                                        probeGray = try await reader.rasterizePage(at: srcIdx, targetDPI: probeRenderDPI)
                                    } catch {
                                        throw .pdfReadFailed(error)
                                    }

                                    let probeSplit = PageSplitEstimator.estimateSplit(in: probeGray, mode: configuration.splitMode)
                                    probedSourceCount += 1
                                    if probeSplit.layoutType == .twoPageSpread {
                                        probedSpreadCount += 1
                                    }
                                    let probeGutterTrim = max(0, Int((Double(configuration.gutterTrimWidth) * Double(probeGray.width) / 4000.0).rounded()))
                                    let probeSlices = PageSplitEstimator.split(probeGray, using: probeSplit, gutterTrimWidth: probeGutterTrim)

                                    for slice in probeSlices {
                                        let sliceSize = Size2I(width: slice.buffer.width, height: slice.buffer.height)
                                        let isSliceSpread = slice.side == .single && Double(sliceSize.width) > Double(sliceSize.height) * 1.15
                                        let nominalDPI = FontScaleAnalyzer.nominalProbeDPI(forPixelSize: sliceSize, isLikelySpread: isSliceSpread)
                                        let nominalGray = GrayscaleBuffer(
                                            width: slice.buffer.width,
                                            height: slice.buffer.height,
                                            dpi: nominalDPI,
                                            pixels: slice.buffer.pixels
                                        )
                                        let probeBinary = binarizer.binarize(nominalGray, accelerator: accelerator)
                                        if let metrics = fontScaleAnalyzer.analyzePage(
                                            in: probeBinary,
                                            declaredDPI: probeRenderDPI,
                                            ocrObservations: []
                                        ) {
                                            probeMetrics.append(metrics)
                                        }
                                    }
                                }
                            }

                            let observedSpread: Bool? = probedSourceCount > 0
                                ? (probedSpreadCount * 2 >= probedSourceCount)
                                : nil
                            let decision = fontScaleAnalyzer.estimatePreRasterScale(
                                from: probeMetrics,
                                declaredPageSizesInches: declaredSizesInches,
                                referenceDeclaredDPI: 72,
                                splitMode: configuration.splitMode,
                                observedSpreadLayout: observedSpread
                            )
                            readerPreScaleDecision = decision
                            effectiveRenderDPI = decision.effectiveRenderDPI(forProcessingDPI: configuration.processingDPI)
                        } else if configuration.enableAutomaticFontScaleCalibration {
                            readerPreScaleDecision = FontScaleAnalyzer.PreRasterScaleDecision(
                                shouldRescale: false,
                                scaleCorrectionFactor: 1.0,
                                declaredBodyPointSize: nil,
                                inferredSourceOpticalDPI: nil,
                                confidence: 1.0,
                                probedPageCount: 0
                            )
                        }
                    }
                }
            }
        }

        // Scans are loaded one at a time by the pass-1 jobs; their sizes come from the page boxes, exactly as the
        // reader computes them, so the landscape split veto needs no raster.
        var rasterSizes: [Size2I] = []
        rasterSizes.reserveCapacity(activeSourceIndices.count)
        let renderScale = Double(effectiveRenderDPI) / 72.0
        for srcIdx in activeSourceIndices {
            let box: Rect2D
            do {
                box = try reader.pageBoxPoints(at: srcIdx)
            } catch {
                throw .pdfReadFailed(error)
            }
            rasterSizes.append(Size2I(
                width: max(1, Int((box.width * renderScale).rounded())),
                height: max(1, Int((box.height * renderScale).rounded()))
            ))
        }

        let renderDPI = effectiveRenderDPI
        let processingDPI = configuration.processingDPI
        let indices = activeSourceIndices
        let sourceFingerprint = configuration.cache?.sourceFingerprint
        let source = ScanSource(
            count: indices.count,
            sizes: rasterSizes,
            load: { (i: Int) async throws(PipelineError) -> GrayscaleBuffer in
                let raw: GrayscaleBuffer
                do throws(PDFReadError) {
                    raw = try await reader.rasterizePage(at: indices[i], targetDPI: renderDPI)
                } catch {
                    throw .pdfReadFailed(error)
                }
                return raw.dpi == processingDPI
                    ? raw
                    : GrayscaleBuffer(width: raw.width, height: raw.height, dpi: processingDPI, pixels: raw.pixels)
            },
            identity: { i in sourceFingerprint.map { "pdf:\($0)#\(indices[i])@\(renderDPI)" } }
        )

        return try await processScans(
            source,
            writer: writer,
            accelerator: accelerator,
            ocrEngine: ocrEngine,
            existingManifest: existingManifest,
            preScaleDecision: readerPreScaleDecision,
            scanNumbers: indices.map { $0 + 1 },
            progress: progressHandler
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
        let borderFallback: MacroBorderResult?
        let textBlockScale: Size2D?
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
        let (pages, decision) = prepareDirectPages(sourcePages, accelerator: accelerator, existingManifest: existingManifest)
        let hashPixels = configuration.cache != nil
        let source = ScanSource(
            count: pages.count,
            sizes: pages.map { Size2I(width: $0.width, height: $0.height) },
            load: { (i: Int) async throws(PipelineError) -> GrayscaleBuffer in pages[i] },
            identity: { i in
                guard hashPixels else { return nil }
                var hasher = KeyHasher()
                hasher.add(pages[i])
                return "pixels:\(hasher.hex)"
            }
        )
        return try await processScans(
            source,
            writer: writer,
            accelerator: accelerator,
            ocrEngine: ocrEngine,
            existingManifest: existingManifest,
            preScaleDecision: decision,
            scanNumbers: pages.indices.map { $0 + 1 },
            progress: nil
        )
    }

    /// Detects and resamples oversized direct `GrayscaleBuffer` inputs (the reader path decides this before rasterizing).
    /// - Returns: The pages to process and the scale decision (`nil` when no rule applied).
    private func prepareDirectPages(
        _ rawSourcePages: [GrayscaleBuffer],
        accelerator: any ComputeAccelerator,
        existingManifest: BookProcessingManifest?
    ) -> (pages: [GrayscaleBuffer], decision: FontScaleAnalyzer.PreRasterScaleDecision?) {
        let effectiveInputDPI = configuration.inputDPI ?? existingManifest?.inputDPI
        let effectivePageSize = configuration.targetPageSize ?? existingManifest?.pageSize
        let effectiveContentBoxSize = configuration.targetContentBoxSize ?? existingManifest?.contentBoxSize
        var effectiveHarmonizerConfig = configuration.harmonizerConfiguration
        effectiveHarmonizerConfig.targetPageSize = effectivePageSize
        effectiveHarmonizerConfig.targetContentBoxSize = effectiveContentBoxSize
        let binarizer = AdaptiveBinarizer(configuration: configuration.binarizerConfiguration)
        let cleaner = BorderAndSpeckleCleaner(configuration: configuration.cleanerConfiguration)
        let contentDetector = ContentBoxDetector(configuration: configuration.contentDetectorConfiguration)
        let fontScaleAnalyzer = FontScaleAnalyzer(configuration: configuration.fontScaleConfiguration)

        var sourcePages = rawSourcePages
        var effectivePreScaleDecision: FontScaleAnalyzer.PreRasterScaleDecision? = nil


        // Detect and resample direct `GrayscaleBuffer` inputs when not already handled by `processBook(reader:...)`.
        if effectivePreScaleDecision == nil && !sourcePages.isEmpty {
            let referenceDeclaredDPI = max(1, sourcePages[0].dpi)

            if let explicitInputDPI = effectiveInputDPI {
                // Priority 1: Explicit `--input-dpi` overrides declared buffer DPI metadata directly.
                let safeInputDPI = max(1, explicitInputDPI)
                let scaleFactor = Double(referenceDeclaredDPI) / Double(safeInputDPI)
                let shouldRescale = sourcePages.contains { max(1, $0.dpi) != safeInputDPI } || abs(scaleFactor - 1.0) > 1e-4
                let decision = FontScaleAnalyzer.PreRasterScaleDecision(
                    shouldRescale: shouldRescale,
                    scaleCorrectionFactor: shouldRescale ? scaleFactor : 1.0,
                    declaredBodyPointSize: nil,
                    inferredSourceOpticalDPI: Double(safeInputDPI),
                    confidence: 1.0,
                    probedPageCount: 0
                )
                effectivePreScaleDecision = decision
                sourcePages = Self.resampleOversizedGrayscalePages(
                    sourcePages,
                    scaleCorrectionFactor: decision.scaleCorrectionFactor,
                    explicitOpticalDPI: Double(safeInputDPI),
                    targetProcessingDPI: configuration.processingDPI,
                    accelerator: accelerator
                )
            } else if effectivePageSize == nil,
                      effectiveContentBoxSize == nil,
                      let priorEstimate = existingManifest?.fontScaleEstimate,
                      priorEstimate.wasAutoRescaled
            {
                let reusedDecision = FontScaleAnalyzer.PreRasterScaleDecision(
                    shouldRescale: true,
                    scaleCorrectionFactor: priorEstimate.appliedScaleCorrectionFactor,
                    declaredBodyPointSize: priorEstimate.declaredBodyPointSizeBeforeRescale > 0.0
                        ? priorEstimate.declaredBodyPointSizeBeforeRescale
                        : nil,
                    inferredSourceOpticalDPI: priorEstimate.inferredSourceOpticalDPI,
                    confidence: priorEstimate.confidence,
                    probedPageCount: priorEstimate.sampledPageCount,
                    isPhysicalScaleAmbiguous: existingManifest?.physicalScaleAmbiguous ?? false,
                    wasAntiBillboardClamped: priorEstimate.wasAntiBillboardClamped
                )
                effectivePreScaleDecision = reusedDecision
                sourcePages = Self.resampleOversizedGrayscalePages(
                    sourcePages,
                    scaleCorrectionFactor: reusedDecision.scaleCorrectionFactor,
                    targetProcessingDPI: configuration.processingDPI,
                    accelerator: accelerator
                )
            } else {
                let declaredSizesInches = sourcePages.map {
                    let dpi = Double(max(1, $0.dpi))
                    return Size2D(width: Double($0.width) / dpi, height: Double($0.height) / dpi)
                }

                if let targetPage = effectivePageSize {
                    // Priority 2: Explicit `--page-size` rescales oversized uncalibrated buffers to match target sheet dimensions.
                    if fontScaleAnalyzer.areDeclaredPagesOversized(declaredSizesInches) {
                        let decision = deriveSheetScaleDecision(
                            targetSinglePageInches: targetPage.sizeInInches,
                            declaredPageSizesInches: declaredSizesInches,
                            referenceDeclaredDPI: referenceDeclaredDPI
                        )
                        effectivePreScaleDecision = decision
                        if decision.shouldRescale {
                            sourcePages = Self.resampleOversizedGrayscalePages(
                                sourcePages,
                                scaleCorrectionFactor: decision.scaleCorrectionFactor,
                                targetProcessingDPI: configuration.processingDPI,
                                accelerator: accelerator
                            )
                        }
                    }
                } else if let targetBox = effectiveContentBoxSize {
                    // Priority 3: Explicit `--content-box-size` probes oversized buffers so detected content matches target box size.
                    if fontScaleAnalyzer.areDeclaredPagesOversized(declaredSizesInches) {
                        let probeIndices = Self.selectProbeIndices(from: sourcePages.count, maxProbes: 3)
                        let targetBoxInches = targetBox.sizeInInches
                        var boxScales: [Double] = []

                        for idx in probeIndices {
                            let buf = sourcePages[idx]
                            let srcDPI = Double(max(1, buf.dpi))
                            let (probeBuf, downsampleScale) = Self.downsampleProbeBufferIfNeeded(buf, maxDimension: 4200)
                            let probeSplit = PageSplitEstimator.estimateSplit(in: probeBuf, mode: configuration.splitMode)
                            let probeGutterTrim = max(0, Int((Double(configuration.gutterTrimWidth) * Double(probeBuf.width) / 4000.0).rounded()))
                            let probeSlices = PageSplitEstimator.split(probeBuf, using: probeSplit, gutterTrimWidth: probeGutterTrim)
                            let effectiveSliceDPI = max(1e-3, srcDPI * downsampleScale)

                            for slice in probeSlices {
                                let sliceSize = Size2I(width: slice.buffer.width, height: slice.buffer.height)
                                let isSliceSpread = slice.side == .single && Double(sliceSize.width) > Double(sliceSize.height) * 1.15
                                let nominalDPI = FontScaleAnalyzer.nominalProbeDPI(forPixelSize: sliceSize, isLikelySpread: isSliceSpread)
                                let nominalGray = GrayscaleBuffer(
                                    width: slice.buffer.width,
                                    height: slice.buffer.height,
                                    dpi: nominalDPI,
                                    pixels: slice.buffer.pixels
                                )
                                let probeBinary = binarizer.binarize(nominalGray, accelerator: accelerator)
                                let cleanedProbe = cleaner.clean(probeBinary)
                                let det = contentDetector.detect(in: cleanedProbe, dpi: nominalDPI, splitSide: slice.side)
                                if let cBox = det.contentBox,
                                   !cBox.isEmpty,
                                   Double(cBox.height) >= Double(cleanedProbe.height) * 0.25,
                                   Double(cBox.width) >= Double(cleanedProbe.width) * 0.25
                                {
                                    let detWInches = Double(cBox.width) / effectiveSliceDPI
                                    let detHInches = Double(cBox.height) / effectiveSliceDPI
                                    let s = 0.5 * (targetBoxInches.width / detWInches + targetBoxInches.height / detHInches)
                                    if s.isFinite && s > 0.0 {
                                        boxScales.append(s)
                                    }
                                }
                            }
                        }

                        let decision: FontScaleAnalyzer.PreRasterScaleDecision
                        if let medianScale = Self.medianOfSorted(boxScales.sorted()), medianScale < 0.95 {
                            let clampedScale = min(0.95, max(0.02, medianScale))
                            decision = FontScaleAnalyzer.PreRasterScaleDecision(
                                shouldRescale: true,
                                scaleCorrectionFactor: clampedScale,
                                declaredBodyPointSize: nil,
                                inferredSourceOpticalDPI: Double(referenceDeclaredDPI) / clampedScale,
                                confidence: 1.0,
                                probedPageCount: boxScales.count
                            )
                        } else {
                            let impliedPage = impliedSinglePageInches(
                                forContentBoxInches: targetBoxInches,
                                margins: effectiveHarmonizerConfig.margins
                            )
                            decision = deriveSheetScaleDecision(
                                targetSinglePageInches: impliedPage,
                                declaredPageSizesInches: declaredSizesInches,
                                referenceDeclaredDPI: referenceDeclaredDPI
                            )
                        }
                        effectivePreScaleDecision = decision
                        if decision.shouldRescale {
                            sourcePages = Self.resampleOversizedGrayscalePages(
                                sourcePages,
                                scaleCorrectionFactor: decision.scaleCorrectionFactor,
                                targetProcessingDPI: configuration.processingDPI,
                                accelerator: accelerator
                            )
                        }
                    }
                } else if fontScaleAnalyzer.areDeclaredPagesOversized(declaredSizesInches) {
                    // Priority 4: Automatic `FontScaleAnalyzer` typographic calibration (when enabled) + anti-billboard fallback on oversized buffers.
                    var probeMetrics: [FontScaleAnalyzer.PageGlyphMetrics] = []
                    var probedSpreadCount = 0
                    var probedSourceCount = 0

                    if configuration.enableAutomaticFontScaleCalibration {
                        let probeIndices = Self.selectProbeIndices(from: sourcePages.count, maxProbes: 3)

                        for idx in probeIndices {
                            let buf = sourcePages[idx]
                            let (probeBuf, downsampleScale) = Self.downsampleProbeBufferIfNeeded(buf, maxDimension: 4200)
                            let probeSplit = PageSplitEstimator.estimateSplit(in: probeBuf, mode: configuration.splitMode)
                            probedSourceCount += 1
                            if probeSplit.layoutType == .twoPageSpread {
                                probedSpreadCount += 1
                            }
                            let probeGutterTrim = max(0, Int((Double(configuration.gutterTrimWidth) * Double(probeBuf.width) / 4000.0).rounded()))
                            let probeSlices = PageSplitEstimator.split(probeBuf, using: probeSplit, gutterTrimWidth: probeGutterTrim)

                            for slice in probeSlices {
                                let sliceSize = Size2I(width: slice.buffer.width, height: slice.buffer.height)
                                let isSliceSpread = slice.side == .single && Double(sliceSize.width) > Double(sliceSize.height) * 1.15
                                let nominalDPI = FontScaleAnalyzer.nominalProbeDPI(forPixelSize: sliceSize, isLikelySpread: isSliceSpread)
                                let nominalGray = GrayscaleBuffer(
                                    width: slice.buffer.width,
                                    height: slice.buffer.height,
                                    dpi: nominalDPI,
                                    pixels: slice.buffer.pixels
                                )
                                let probeBinary = binarizer.binarize(nominalGray, accelerator: accelerator)
                                let srcDPI = max(1, buf.dpi)
                                if let rawMetrics = fontScaleAnalyzer.analyzePage(
                                    in: probeBinary,
                                    declaredDPI: srcDPI,
                                    ocrObservations: []
                                ) {
                                    if downsampleScale < 0.9999 {
                                        let invScale = 1.0 / downsampleScale
                                        let fullEm = rawMetrics.inferredEmHeightPixels * invScale
                                        let scaledMetrics = FontScaleAnalyzer.PageGlyphMetrics(
                                            xHeightPixels: rawMetrics.xHeightPixels * invScale,
                                            capHeightPixels: rawMetrics.capHeightPixels * invScale,
                                            inferredEmHeightPixels: fullEm,
                                            strokeWidthPixels: rawMetrics.strokeWidthPixels * invScale,
                                            baselineSpacingPixels: rawMetrics.baselineSpacingPixels.map { $0 * invScale },
                                            declaredDPI: srcDPI,
                                            declaredBodyPointSize: fullEm * 72.0 / Double(srcDPI),
                                            inferredOpticalDPI: fullEm * 72.0 / configuration.fontScaleConfiguration.targetBodyEmPointSize,
                                            sampledGlyphCount: rawMetrics.sampledGlyphCount,
                                            chainedLineCount: rawMetrics.chainedLineCount,
                                            isBimodal: rawMetrics.isBimodal,
                                            ocrLineCount: rawMetrics.ocrLineCount,
                                            confidence: rawMetrics.confidence
                                        )
                                        probeMetrics.append(scaledMetrics)
                                    } else {
                                        probeMetrics.append(rawMetrics)
                                    }
                                }
                            }
                        }
                    }

                    let observedSpread: Bool? = probedSourceCount > 0
                        ? (probedSpreadCount * 2 >= probedSourceCount)
                        : nil
                    let decision = fontScaleAnalyzer.estimatePreRasterScale(
                        from: probeMetrics,
                        declaredPageSizesInches: declaredSizesInches,
                        referenceDeclaredDPI: referenceDeclaredDPI,
                        splitMode: configuration.splitMode,
                        observedSpreadLayout: observedSpread
                    )
                    effectivePreScaleDecision = decision
                    if decision.shouldRescale {
                        sourcePages = Self.resampleOversizedGrayscalePages(
                            sourcePages,
                            scaleCorrectionFactor: decision.scaleCorrectionFactor,
                            targetProcessingDPI: configuration.processingDPI,
                            accelerator: accelerator
                        )
                    }
                }
            }
        }
        return (sourcePages, effectivePreScaleDecision)
    }

    /// Runs the three passes on scans from `source`.
    private func processScans<Writer: PDFDocumentWriter & ~Copyable>(
        _ source: ScanSource,
        writer: consuming Writer,
        accelerator: any ComputeAccelerator,
        ocrEngine: (any OCREngine)?,
        existingManifest: BookProcessingManifest?,
        preScaleDecision effectivePreScaleDecision: FontScaleAnalyzer.PreRasterScaleDecision?,
        scanNumbers: [Int],
        progress: (@Sendable (_ completedScans: Int, _ totalScans: Int) -> Void)?
    ) async throws(PipelineError) -> PipelineOutput {
        let runStart = ContinuousClock.now
        let effectiveInputDPI = configuration.inputDPI ?? existingManifest?.inputDPI
        let effectivePageSize = configuration.targetPageSize ?? existingManifest?.pageSize
        let effectiveContentBoxSize = configuration.targetContentBoxSize ?? existingManifest?.contentBoxSize

        var effectiveHarmonizerConfig = configuration.harmonizerConfiguration
        effectiveHarmonizerConfig.targetPageSize = effectivePageSize
        effectiveHarmonizerConfig.targetContentBoxSize = effectiveContentBoxSize

        let binarizer = AdaptiveBinarizer(configuration: configuration.binarizerConfiguration)
        let cleaner = BorderAndSpeckleCleaner(configuration: configuration.cleanerConfiguration)
        let tracer = TextLineTracer()
        let dewarpSolver = CylindricalDewarpSolver()
        let contentDetector = ContentBoxDetector(configuration: configuration.contentDetectorConfiguration)
        let harmonizer = MarginHarmonizer(configuration: effectiveHarmonizerConfig)
        let fontScaleAnalyzer = FontScaleAnalyzer(configuration: configuration.fontScaleConfiguration)

        // Build lookup table of manual overrides by outputPageIndex if an existing manifest was supplied.
        var overridesByOutputIndex: [Int: PageManualOverride] = [:]
        if let existing = existingManifest {
            for rec in existing.pages {
                if let ov = rec.manualOverride {
                    overridesByOutputIndex[rec.outputPageIndex] = ov
                }
            }
        }

        // --- PASS 1: Perspective Rectification, Desk Masking, Page Split, Deskew, 3D Cubic-Sheet Dewarp, 600 DPI Binarization & Content Box Detection ---
        // Scans run in parallel (at most `jobs` at a time), each loaded only when its job starts, and reuse cached
        // results when the cache has them. Output page numbers depend on which earlier pages were dropped or
        // pruned, so they are assigned afterwards, in scan order: the result is the same as one scan at a time.
        let pass1Start = ContinuousClock.now
        var priorGeometryBySourceIndex: [Int: SourcePageGeometryRecord] = [:]
        for record in existingManifest?.sourcePageGeometry ?? [] {
            priorGeometryBySourceIndex[record.sourcePageIndex] = record
        }

        let dpiScale = Double(configuration.processingDPI) / 600.0
        let jobCount = max(1, configuration.jobs)
        let cache = PipelineCache(configuration.cache)
        let context = Pass1Context(
            binarizer: binarizer,
            cleaner: cleaner,
            tracer: tracer,
            dewarpSolver: dewarpSolver,
            contentDetector: contentDetector,
            fontScaleAnalyzer: fontScaleAnalyzer,
            accelerator: accelerator,
            ocrEngine: ocrEngine,
            cache: cache,
            fingerprint: cache == nil ? "" : pass1Fingerprint(effectivePageSize: effectivePageSize, accelerator: accelerator, ocrEngine: ocrEngine),
            effectivePageSize: effectivePageSize,
            minSagPixels: configuration.minDewarpSagPixelsAt600DPI * dpiScale,
            gutterTrimWidth: max(0, Int((Double(configuration.gutterTrimWidth) * dpiScale).rounded()))
        )

        // Landscape scans in a portrait book are plates or tables, not two-page spreads (Substep 6.2.1).
        let dimensionConsensus = DimensionConsensus(configuration: configuration.dimensionConsensusConfiguration)
        let splitVetoedSources: Set<Int> = configuration.splitMode == .automatic
            ? Set(dimensionConsensus.splitVetoes(sourceSizes: source.sizes))
            : []

        var resolver = AdjustmentResolver(
            adjustments: configuration.adjustments,
            scanNumbers: scanNumbers,
            processingDPI: configuration.processingDPI
        )

        // What each scan job is asked to do. Page edits are matched by scan reference only (`s12`, `s12L`); edits by
        // page number are matched below, once the numbers are known.
        var jobs: [ScanJob] = []
        jobs.reserveCapacity(source.count)
        for srcIdx in 0..<source.count {
            let scanAdjustment = resolver.scanAdjustment(forScanAt: srcIdx)
            var priorGeometry = priorGeometryBySourceIndex[srcIdx]
            if let scanAdjustment, scanAdjustment.disableRectification != nil || scanAdjustment.disableDeskMask != nil {
                var record = priorGeometry ?? SourcePageGeometryRecord(
                    sourcePageIndex: srcIdx,
                    rasterSize: source.sizes[srcIdx],
                    detection: nil,
                    rectified: false,
                    plan: nil
                )
                var geometryOverride = record.manualOverride ?? SourcePageGeometryOverride()
                if let v = scanAdjustment.disableRectification { geometryOverride.disableRectification = v }
                if let v = scanAdjustment.disableDeskMask { geometryOverride.disableDeskMask = v }
                record.manualOverride = geometryOverride
                priorGeometry = record
            }
            let splitMode: PageSplitMode
            if let forced = scanAdjustment?.split, forced != .automatic {
                splitMode = forced
            } else {
                splitMode = splitVetoedSources.contains(srcIdx) ? .singlePage : configuration.splitMode
            }
            var edits: [PageSide: HeavyPageEdits] = [:]
            for side in [PageSide.single, .leftVerso, .rightRecto] {
                edits[side] = HeavyPageEdits(resolver.scanBasedOverride(scanIndex: srcIdx, side: side))
            }
            jobs.append(ScanJob(
                index: srcIdx,
                priorGeometry: priorGeometry,
                splitMode: splitMode,
                splitX: scanAdjustment?.splitX,
                edits: edits
            ))
        }

        let plannedJobs = jobs
        let totalScans = source.count
        var scanResults = try await BoundedParallel.map(
            count: plannedJobs.count,
            jobs: jobCount,
            progress: { completed in progress?(completed, totalScans) }
        ) { (i: Int) async throws(PipelineError) -> ScanResult in
            try await self.processScan(plannedJobs[i], source: source, context: context)
        }

        // A title page beside a blank half has no gutter to find: when the book's other scans of that size were
        // split, split this one too (Substep 7.1.1d). The scan keeps the split in any later re-run.
        var consensusSplitSources: [Int] = []
        if configuration.splitMode == .automatic {
            consensusSplitSources = BookEnds.consensusSplitScans(
                sizes: source.sizes,
                sliceCounts: scanResults.map { $0.slices.count },
                eligible: jobs.map { $0.splitMode == .automatic }
            )
            if !consensusSplitSources.isEmpty {
                var splitJobs = consensusSplitSources.map { srcIdx -> ScanJob in
                    var job = jobs[srcIdx]
                    job.splitMode = .twoPageSpread
                    jobs[srcIdx] = job
                    return job
                }
                let redone = try await BoundedParallel.map(count: splitJobs.count, jobs: jobCount) { [splitJobs] (i: Int) async throws(PipelineError) -> ScanResult in
                    try await self.processScan(splitJobs[i], source: source, context: context)
                }
                splitJobs.removeAll()
                for (srcIdx, result) in zip(consensusSplitSources, redone) { scanResults[srcIdx] = result }
            }
        }

        // Library cover sheets (read from the first two and the last scan) and printed covers.
        var coverVerdicts: [Int: (verdict: BookEnds.Verdict, reason: String)] = [:]   // by scan index
        if configuration.coverHandling != .keep {
            var covers: [Int: (BookEnds.Verdict, String)] = [:]
            if let ocrEngine {
                let ocr = CachedOCR(engine: ocrEngine, cache: cache)
                for srcIdx in BookEnds.coverSheetCandidates(scanCount: scanResults.count) {
                    var text = ""
                    for slice in scanResults[srcIdx].slices {
                        let bitmap = configuration.processingDPI >= configuration.outputDPI * 2
                            ? accelerator.downsampleBinaryTo300DPI(slice.cleaned)
                            : slice.cleaned
                        if let result = try? await ocr.recognize(bitmap, dpi: configuration.outputDPI, languages: configuration.ocrLanguages) {
                            text += " " + result.observations.map(\.text).joined(separator: " ")
                        }
                    }
                    if let repository = CoverSheetDetector.repository(in: text) {
                        covers[srcIdx] = (.coverSheet, "Cover sheet added by \(repository)")
                    }
                }
            }
            if configuration.coverHandling == .strip {
                for srcIdx in BookEnds.printedCoverScans(sizes: source.sizes, tolerance: configuration.dimensionConsensusConfiguration.toleranceFraction) where covers[srcIdx] == nil {
                    covers[srcIdx] = (.cover, "Printed cover (odd-sized first or last scan)")
                }
            }
            coverVerdicts = covers.mapValues { (verdict: $0.0, reason: $0.1) }
        }
        // Which slices leave the book: covers, and blanks before the first or after the last page with content.
        var flatBlank: [Bool] = []
        var flatCover: [BookEnds.Verdict?] = []
        for (srcIdx, result) in scanResults.enumerated() {
            for slice in result.slices {
                flatBlank.append(configuration.autoPruneBlankPages && slice.isBlank == true)
                flatCover.append(coverVerdicts[srcIdx]?.verdict)
            }
        }
        let pruneVerdicts = BookEnds.verdicts(isBlank: flatBlank, isCover: flatCover)
        var flatIndex = -1

        // Number the pages in order, applying drops, blank pruning and every page edit.
        var numbered: [NumberedPage] = []
        var prunedPages: [PrunedPageRecord] = []
        var splitScanNumbers: Set<Int> = []
        var correctedEdits: [Int: [PageSide: HeavyPageEdits]] = [:]
        for (srcIdx, result) in scanResults.enumerated() {
            if result.slices.count > 1 { splitScanNumbers.insert(scanNumbers[srcIdx]) }
            for (sliceIndex, slice) in result.slices.enumerated() {
                flatIndex += 1
                let outIdx = numbered.count
                let manualOverride = resolver.override(
                    outputIndex: outIdx,
                    scanIndex: srcIdx,
                    side: slice.side,
                    base: overridesByOutputIndex[outIdx]
                )
                if manualOverride?.drop == true {
                    prunedPages.append(
                        PrunedPageRecord(
                            sourcePageIndex: srcIdx,
                            splitSide: slice.side,
                            inkDensity: 0,
                            reason: "Dropped by an adjustment (drop: true)",
                            kind: "adjustment"
                        )
                    )
                    continue
                }

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

                // An edit by page number, or a stored manifest's override, that changes pixels: process again.
                // (Such a page has an override, so it is never pruned as blank and the numbering stands.)
                let finalEdits = HeavyPageEdits(manualOverride)
                if finalEdits != slice.edits {
                    correctedEdits[srcIdx, default: jobs[srcIdx].edits][slice.side] = finalEdits
                }

                // Covers and blank pages at the ends of the book (pages with any edit are kept).
                if manualOverride == nil, let verdict = pruneVerdicts[flatIndex] {
                    let reason: String
                    switch verdict {
                    case .coverSheet, .cover:
                        reason = coverVerdicts[srcIdx]?.reason ?? "Cover"
                    case .leadingBlank, .trailingBlank:
                        reason = "Blank \(verdict == .leadingBlank ? "leading" : "trailing") sub-page slice (ink density \(String(format: "%.4f", slice.inkDensity)) < \(String(format: "%.4f", configuration.blankPageInkDensityThreshold)), 0 OCR words)"
                    }
                    prunedPages.append(
                        PrunedPageRecord(
                            sourcePageIndex: srcIdx,
                            splitSide: slice.side,
                            inkDensity: slice.inkDensity,
                            reason: reason,
                            kind: verdict.rawValue
                        )
                    )
                    continue
                }

                numbered.append(NumberedPage(
                    sourceIndex: srcIdx,
                    sliceIndex: sliceIndex,
                    outputIndex: outIdx,
                    bookSide: bookSide,
                    manualOverride: manualOverride
                ))
            }
        }

        if !correctedEdits.isEmpty {
            let rerunScans = correctedEdits.keys.sorted()
            let rerunJobs = rerunScans.map { srcIdx -> ScanJob in
                var job = jobs[srcIdx]
                job.edits = correctedEdits[srcIdx] ?? job.edits
                return job
            }
            let redone = try await BoundedParallel.map(count: rerunJobs.count, jobs: jobCount) { (i: Int) async throws(PipelineError) -> ScanResult in
                try await self.processScan(rerunJobs[i], source: source, context: context)
            }
            for (srcIdx, result) in zip(rerunScans, redone) {
                // Same scan, same split: only the slices' pixels differ.
                scanResults[srcIdx].slices = result.slices
                scanResults[srcIdx].reused = scanResults[srcIdx].reused && result.reused
                scanResults[srcIdx].clock.merge(result.clock)
            }
        }

        // 1b-iii. A blank page kept between pages (or between covers) is laid out blank: the fibres and specks the
        // detector found on it would otherwise make a text block, a skew and an own canvas of their own. An edited
        // content box keeps the page as content.
        let automaticDetections = numbered.map { page -> ContentBoxDetector.DetectionResult in
            let slice = scanResults[page.sourceIndex].slices[page.sliceIndex]
            let edited = page.manualOverride?.overrideContentBox != nil || page.manualOverride?.contentBoxNudge != nil
            guard slice.isBlank == true, !edited, slice.detection.holdsOnlySpecks(dpi: configuration.processingDPI) else {
                return slice.detection
            }
            return slice.detection.blanked
        }

        // 1c. Camera photos: every page's text block at the book's size (Substep 7.1.1b-i). Perspective shows the
        // pages of one photo at different scales, so each camera page is resampled before anything measures it.
        // Scales come from the automatic detection; content-box edits below refer to the resampled page, the one
        // `inspect` shows.
        let textBlockScales: [Size2D?] = configuration.cameraTextBlockScaling.map { scaling in
            TextBlockScaleNormalizer.scales(
                for: numbered.indices.map { k in
                    let page = numbered[k]
                    return TextBlockScaleNormalizer.PageInput(
                        group: page.sourceIndex,
                        contentBox: automaticDetections[k].contentBox,
                        isEligible: scanResults[page.sourceIndex].header.geometry.looksLikeCameraPhoto
                    )
                },
                configuration: scaling
            )
        } ?? Array(repeating: nil, count: numbered.count)
        let scaledPages = textBlockScales.indices.filter { textBlockScales[$0] != nil }
        var resampledBitmaps = [BinaryBitmap?](repeating: nil, count: numbered.count)
        var scaleClock = StageClock()
        if !scaledPages.isEmpty {
            let start = ContinuousClock.now
            let sources = scaledPages.map { scanResults[numbered[$0].sourceIndex].slices[numbered[$0].sliceIndex].cleaned }
            let factors = scaledPages.map { textBlockScales[$0]! }
            let resampled = await BoundedParallel.map(count: scaledPages.count, jobs: jobCount) { (i: Int) async -> BinaryBitmap in
                TextBlockScaleNormalizer.resample(sources[i], by: factors[i])
            }
            for (i, k) in scaledPages.enumerated() { resampledBitmaps[k] = resampled[i] }
            scaleClock.add("pass1.textBlockScale", ContinuousClock.now - start)
        }

        // 1c (continued). Content-box edits, applied over the automatic detection.
        var pass1Pages: [Pass1Page] = []
        pass1Pages.reserveCapacity(numbered.count)
        for (k, page) in numbered.enumerated() {
            let result = scanResults[page.sourceIndex]
            let slice = result.slices[page.sliceIndex]
            let textBlockScale = textBlockScales[k]
            let finalCleaned = resampledBitmaps[k] ?? slice.cleaned
            let pageSize = Size2I(width: finalCleaned.width, height: finalCleaned.height)
            var manualOverride = page.manualOverride
            var detection = textBlockScale.map { TextBlockScaleNormalizer.scaled(automaticDetections[k], by: $0, within: pageSize) }
                ?? automaticDetections[k]
            let tracedLines = textBlockScale.map { scale in
                slice.tracedLines.map { line in
                    PolyLine2D(points: line.points.map { Point2D(x: $0.x * scale.width, y: $0.y * scale.height) })
                }
            } ?? slice.tracedLines
            if let nudge = manualOverride?.contentBoxNudge {
                // Nudge the absolute box if one was given, otherwise the detected one; keep the result as an
                // absolute box so the stored override stays idempotent.
                if let base = manualOverride?.overrideContentBox ?? detection.contentBox,
                   let nudged = nudge.applied(to: base, within: pageSize) {
                    manualOverride?.overrideContentBox = nudged
                    manualOverride?.contentBoxNudge = nil
                } else {
                    resolver.note(page: page.outputIndex, ignored: "contentBox.nudge", reason: "the page has no content box to nudge, or the nudge removes it")
                    manualOverride?.contentBoxNudge = nil
                }
            }
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

            pass1Pages.append(
                Pass1Page(
                    outputPageIndex: page.outputIndex,
                    sourcePageIndex: page.sourceIndex,
                    splitSide: slice.side,
                    bookSide: page.bookSide,
                    splitConfidence: result.header.split.confidence,
                    skewAngleDegrees: slice.appliedSkewDegrees,
                    skewConfidence: slice.skewEstimate.confidence,
                    dewarpApplied: slice.dewarpApplied,
                    dewarpVerticalSagPixels: slice.dewarpVerticalSagPixels,
                    dewarpResidualRMSPixels: slice.dewarpResidualRMSPixels,
                    tracedLines: tracedLines,
                    cleanedBitmap: finalCleaned,
                    detection: detection,
                    manualOverride: manualOverride,
                    borderFallback: slice.borderFallback,
                    textBlockScale: textBlockScale
                )
            )
        }
        let sourceGeometry = scanResults.map(\.header.geometry)
        let sourceSplits = scanResults.map(\.header.split)
        let scansReused = scanResults.filter(\.reused).count
        var workClock = StageClock()
        for result in scanResults { workClock.merge(result.clock) }
        workClock.merge(scaleClock)
        scanResults = []
        let pass1Elapsed = ContinuousClock.now - pass1Start
        let pass2Start = ContinuousClock.now


        // --- Running headers & top baselines (telemetry only; changes no pixels) ---
        var topAnchors: [PageTopAnchor?] = Array(repeating: nil, count: pass1Pages.count)
        var runningHeaderModel: RunningHeaderModel? = nil
        var lineProfiles: [RunningHeaderDetector.PageLineProfile] = []
        if configuration.enableRunningHeaderDetection && !pass1Pages.isEmpty {
            let headerDetector = RunningHeaderDetector(configuration: configuration.runningHeaderConfiguration)
            let profiles = pass1Pages.map { p in
                headerDetector.profilePage(
                    p.cleanedBitmap,
                    region: p.manualOverride?.overrideContentBox ?? p.detection.contentBox,
                    pageIndex: p.outputPageIndex,
                    side: p.bookSide
                )
            }
            var policies: [Int: RunningHeaderPolicy] = [:]
            for p in pass1Pages {
                if let policy = p.manualOverride?.runningHeader { policies[p.outputPageIndex] = policy }
            }
            lineProfiles = profiles
            let analysis = headerDetector.analyzeBook(profiles, policies: policies)
            topAnchors = analysis.anchors.map(Optional.some)
            runningHeaderModel = analysis.model
        }

        // --- PASS 2: Book-Wide Outlier Rejection & 3-Tier Margin Harmonization ---
        let harmonizerInputs = pass1Pages.enumerated().map { idx, p in
            MarginHarmonizer.PageInput(
                pageIndex: p.outputPageIndex,
                side: p.bookSide,
                pageSize: Size2I(width: p.cleanedBitmap.width, height: p.cleanedBitmap.height),
                dpi: configuration.processingDPI,
                detection: p.detection,
                hasRunningHeader: topAnchors[idx]?.kind == .runningHeader
            )
        }

        // Which pages share the book's page size, and which are covers, plates, or foldouts?
        let dimensionInputs = pass1Pages.enumerated().map { idx, p in
            DimensionConsensus.PageInput(
                pageIndex: p.outputPageIndex,
                pageSize: Size2I(width: p.cleanedBitmap.width, height: p.cleanedBitmap.height),
                contentBox: p.manualOverride?.overrideContentBox ?? p.detection.contentBox,
                bodyLinePitch: idx < lineProfiles.count ? lineProfiles[idx].bodyLinePitch : nil,
                forcedClass: p.manualOverride?.dimensionClass
            )
        }
        // The exact outlier list is the plain page numbers plus any scan references (`s45L`), resolved now that
        // the output pages exist. Either one switches automatic detection off completely.
        var classifier = dimensionConsensus
        var unresolvedOutlierReferences: [PageReference] = []
        if !configuration.manualOutlierReferences.isEmpty {
            var manual = configuration.dimensionConsensusConfiguration.manualOutlierPages ?? []
            for reference in configuration.manualOutlierReferences {
                let matches = pass1Pages.filter { p in
                    switch reference {
                    case .outputPage(let n): return p.outputPageIndex == n - 1
                    case .scan(let n, let half):
                        guard scanNumbers[p.sourcePageIndex] == n else { return false }
                        switch (half, p.splitSide) {
                        case (.whole, _), (.left, .leftVerso), (.right, .rightRecto): return true
                        default: return false
                        }
                    }
                }
                if matches.isEmpty { unresolvedOutlierReferences.append(reference) }
                manual.formUnion(matches.map(\.outputPageIndex))
            }
            var consensusConfiguration = configuration.dimensionConsensusConfiguration
            consensusConfiguration.manualOutlierPages = manual
            classifier = DimensionConsensus(configuration: consensusConfiguration)
        }
        var dimensionResult = classifier.classify(pages: dimensionInputs)
        // A page whose only fault is a text block too large may owe it to a smudge or an edge texture beside the
        // text: trim it to the book's text width as Pass 2 trims ordinary pages, and judge it again.
        let overflowOnly = dimensionResult.records.indices.filter { i in
            dimensionResult.records[i].kinds == [.contentOverflow] && pass1Pages[i].manualOverride?.overrideContentBox == nil
        }
        if !overflowOnly.isEmpty {
            let outliers = dimensionResult.outlierPageIndices
            let canonicalInputs = harmonizerInputs.filter { !outliers.contains($0.pageIndex) }
            let prior = harmonizer.canonicalWidthPrior(canonicalInputs.isEmpty ? harmonizerInputs : canonicalInputs)
            var trimmedInputs = dimensionInputs
            for i in overflowOnly {
                let refined = contentDetector.refineWithCanonicalWidthPrior(
                    pass1Pages[i].detection, canonicalWidth: prior,
                    maxWidthExcessFraction: harmonizer.configuration.pass2OutlierWidthExcessFraction)
                trimmedInputs[i].contentBox = refined.contentBox
            }
            if trimmedInputs != dimensionInputs { dimensionResult = classifier.classify(pages: trimmedInputs) }
        }
        dimensionResult.summary.splitVetoedSourcePages = splitVetoedSources.sorted()
        dimensionResult.summary.splitByConsensusSourcePages = consensusSplitSources
        var outlierCanvasSizes: [Int: Size2I] = [:]
        for (input, record) in zip(dimensionInputs, dimensionResult.records) {
            if let size = record.proposedCanvasSize { outlierCanvasSizes[input.pageIndex] = size }
        }

        var forcedTiers: [Int: MarginHarmonizer.PlacementTier] = [:]
        for p in pass1Pages {
            if let tier = p.manualOverride?.forcedTier { forcedTiers[p.outputPageIndex] = tier }
        }
        let isManualOutlierList = configuration.dimensionConsensusConfiguration.manualOutlierPages != nil
            || !configuration.manualOutlierReferences.isEmpty
        let bookLayout = harmonizer.harmonizeBook(
            pages: harmonizerInputs,
            detector: contentDetector,
            dimensionOutliers: dimensionResult.outlierPageIndices,
            outlierCanvasSizes: outlierCanvasSizes,
            minimumCanonicalPages: isManualOutlierList ? 1 : 3,
            forcedTiers: forcedTiers
        )
        if let manual = configuration.dimensionConsensusConfiguration.manualOutlierPages {
            dimensionResult.summary.ignoredManualPages = manual.filter { $0 >= pass1Pages.count }.sorted().map { $0 + 1 }
        }
        dimensionResult.summary.ignoredManualReferences = unresolvedOutlierReferences.map(\.description)

        // --- PASS 3: Canonical Framing, 600 -> 300 DPI Downsampling, OCR & 1-Bit PDF Assembly ---
        var records: [PageProcessingRecord] = []
        records.reserveCapacity(pass1Pages.count)
        var outputBitmaps: [BinaryBitmap] = []
        outputBitmaps.reserveCapacity(pass1Pages.count)
        var cleanedBitmaps: [BinaryBitmap] = []
        cleanedBitmaps.reserveCapacity(pass1Pages.count)

        let hasExplicitDimensionOverride = (effectiveInputDPI != nil)
            || (effectivePageSize != nil)
            || (effectiveContentBoxSize != nil)
        let wasSourceOversized = (effectivePreScaleDecision?.shouldRescale == true)
            || (effectivePreScaleDecision?.isPhysicalScaleAmbiguous == true)
            || (effectivePreScaleDecision?.wasAntiBillboardClamped == true)
        var anyPageCanvasClamped = false
        var clampedCanonicalInches: Size2D? = nil

        let shouldDownsample2x = (configuration.processingDPI >= configuration.outputDPI * 2)
        let stopsAfterLayout = (configuration.stopAfter == .layout)
        let sampledGlyphPageIndices = Self.selectEvenlySampledIndices(from: pass1Pages.count, maxSamples: 16)
        var postCalibrationGlyphMetrics: [FontScaleAnalyzer.PageGlyphMetrics] = []
        postCalibrationGlyphMetrics.reserveCapacity(sampledGlyphPageIndices.count)

        // Apply manual overrides to the harmonizer's plans, then register full-body pages vertically.
        var overriddenPlans = bookLayout.pagePlans
        for (idx, p1) in pass1Pages.enumerated() {
            if let customOrigin = p1.manualOverride?.overrideDestinationOrigin {
                overriddenPlans[idx].destinationOrigin = customOrigin
            }
            if let customBox = p1.manualOverride?.overrideContentBox {
                overriddenPlans[idx].wasOutlierTrimmed = false
                overriddenPlans[idx].sourceContentBox = customBox
                overriddenPlans[idx].retainedClusterBoxes = [customBox]
            }
        }
        var registrationRecords: [PageVerticalRegistration?] = Array(repeating: nil, count: pass1Pages.count)
        var registrationSummary: VerticalRegistrationSummary? = nil
        if configuration.enableRunningHeaderDetection && !pass1Pages.isEmpty {
            let registration = VerticalRegistration(configuration: configuration.verticalRegistrationConfiguration)
            let inputs = pass1Pages.enumerated().map { idx, p1 in
                VerticalRegistration.PageInput(
                    plan: overriddenPlans[idx],
                    anchor: topAnchors[idx],
                    policy: p1.manualOverride?.verticalRegistration,
                    hasManualOrigin: p1.manualOverride?.overrideDestinationOrigin != nil
                )
            }
            let registered = registration.register(
                pages: inputs,
                versoFrame: bookLayout.versoCanonicalFrame,
                rectoFrame: bookLayout.rectoCanonicalFrame,
                bodyLinePitch: VerticalRegistration.typicalPitch(of: runningHeaderModel)
            )
            overriddenPlans = registered.plans
            registrationRecords = registered.records.map(Optional.some)
            for idx in registrationRecords.indices where overriddenPlans[idx].isDimensionOutlier {
                registrationRecords[idx]?.flags.append("registration:dimensionalOutlier")
            }
            registrationSummary = registered.summary
        }

        // The scale the shared canvas needs to stay below the anti-billboard cap; isolated outliers share it so a
        // cover keeps its true size relative to the body.
        var canonicalClampScale = 1.0
        if !hasExplicitDimensionOverride {
            let raw = Size2D(
                width: Double(bookLayout.canvasSize.width) / Double(configuration.processingDPI),
                height: Double(bookLayout.canvasSize.height) / Double(configuration.processingDPI)
            )
            let needsClamp = wasSourceOversized
                ? fontScaleAnalyzer.isDeclaredPageOversized(raw)
                : (raw.height > configuration.fontScaleConfiguration.maxCalibratedSpreadHeightInches
                    || raw.width > configuration.fontScaleConfiguration.maxCalibratedSpreadWidthInches)
            if needsClamp {
                let clamped = fontScaleAnalyzer.clampAntiBillboardPageSizeInches(raw)
                if clamped.wasClamped, raw.width > 0 { canonicalClampScale = clamped.sizeInches.width / raw.width }
            }
        }
        var isolatedOutputPages: [Int] = []

        // Each page's final plan: its own canvas for an isolated outlier, then any manual offset.
        var finalPlans: [MarginHarmonizer.PageLayoutPlan] = []
        var isolatedCanvasFlags: [Bool] = []
        finalPlans.reserveCapacity(pass1Pages.count)
        isolatedCanvasFlags.reserveCapacity(pass1Pages.count)
        for (idx, p1) in pass1Pages.enumerated() {
            var plan = overriddenPlans[idx]
            var isolatedCanvas = false
            if configuration.isolateOutlierCanvases, let size = plan.proposedCanvasSize {
                // The outlier gets a canvas of its own: its content stays where it sits on the scan.
                plan.canvasSize = size
                if p1.manualOverride?.overrideDestinationOrigin == nil, let box = plan.sourceContentBox {
                    plan.destinationOrigin = Point2I(
                        x: min(max(0, box.minX), max(0, size.width - box.width)),
                        y: min(max(0, box.minY), max(0, size.height - box.height))
                    )
                }
                isolatedCanvas = true
            }

            // A manual shift of the content (`offset`), applied after every automatic placement rule.
            if let offset = p1.manualOverride?.destinationOffset {
                plan.destinationOrigin = Point2I(x: plan.destinationOrigin.x + offset.x, y: plan.destinationOrigin.y + offset.y)
            }
            finalPlans.append(plan)
            isolatedCanvasFlags.append(isolatedCanvas)
        }
        let pass2Elapsed = ContinuousClock.now - pass2Start

        // Render, downsample and recognize the pages in parallel (a run that stops after the layout renders nothing).
        let pass3Start = ContinuousClock.now
        let shouldCollectScaleTelemetry = configuration.enableAutomaticFontScaleCalibration || (effectivePreScaleDecision != nil)
        let cachedOCR = ocrEngine.map { CachedOCR(engine: $0, cache: cache) }
        let renderPlans = finalPlans
        let renderSources = pass1Pages.map(\.cleanedBitmap)
        let processingDPIValue = configuration.processingDPI
        let outputDPIValue = configuration.outputDPI
        let ocrLanguages = configuration.ocrLanguages
        let renderedPages = try await BoundedParallel.map(
            count: stopsAfterLayout ? 0 : pass1Pages.count,
            jobs: jobCount
        ) { (idx: Int) async throws(PipelineError) -> RenderedPage in
            var page = RenderedPage()
            let plan = renderPlans[idx]
            let framed = page.clock.measure("pass3.render") { harmonizer.renderPage(from: renderSources[idx], plan: plan) }
            let output = page.clock.measure("pass3.render") { shouldDownsample2x ? accelerator.downsampleBinaryTo300DPI(framed) : framed }
            page.bitmap = output
            if let cachedOCR {
                let start = ContinuousClock.now
                do throws(OCRError) {
                    (page.observations, page.ocrReused) = try await cachedOCR.recognize(output, dpi: outputDPIValue, languages: ocrLanguages)
                } catch {
                    throw .ocrFailed(error)
                }
                page.clock.add("pass3.ocr", ContinuousClock.now - start)
            }
            if shouldCollectScaleTelemetry && sampledGlyphPageIndices.contains(idx) && !plan.isDimensionOutlier {
                let observations = page.observations
                page.glyphMetrics = page.clock.measure("pass3.glyphTelemetry") {
                    fontScaleAnalyzer.analyzePage(in: framed, declaredDPI: processingDPIValue, ocrObservations: observations)
                }
            }
            return page
        }

        for (idx, p1) in pass1Pages.enumerated() {
            let plan = finalPlans[idx]
            let isolatedCanvas = isolatedCanvasFlags[idx]
            let renderedBitmap = stopsAfterLayout ? nil : renderedPages[idx].bitmap
            let ocrObservations = stopsAfterLayout ? [] : renderedPages[idx].observations
            if !stopsAfterLayout {
                if let metrics = renderedPages[idx].glyphMetrics { postCalibrationGlyphMetrics.append(metrics) }
                workClock.merge(renderedPages[idx].clock)
            }

            let outputWidthPixels = renderedBitmap?.width ?? max(1, shouldDownsample2x ? plan.canvasSize.width / 2 : plan.canvasSize.width)
            let outputHeightPixels = renderedBitmap?.height ?? max(1, shouldDownsample2x ? plan.canvasSize.height / 2 : plan.canvasSize.height)
            var pageWidthPoints = Double(outputWidthPixels) * 72.0 / Double(configuration.outputDPI)
            var pageHeightPoints = Double(outputHeightPixels) * 72.0 / Double(configuration.outputDPI)
            if isolatedCanvas {
                pageWidthPoints *= canonicalClampScale
                pageHeightPoints *= canonicalClampScale
                if !hasExplicitDimensionOverride {
                    let own = Size2D(width: pageWidthPoints / 72.0, height: pageHeightPoints / 72.0)
                    let capped = fontScaleAnalyzer.clampAntiBillboardPageSizeInches(own)
                    if capped.wasClamped {
                        pageWidthPoints = capped.sizeInches.width * 72.0
                        pageHeightPoints = capped.sizeInches.height * 72.0
                    }
                }
            } else if !hasExplicitDimensionOverride {
                let rawSizeInches = Size2D(width: pageWidthPoints / 72.0, height: pageHeightPoints / 72.0)
                let needsCanvasClamp: Bool
                if wasSourceOversized {
                    needsCanvasClamp = fontScaleAnalyzer.isDeclaredPageOversized(rawSizeInches)
                } else {
                    needsCanvasClamp = rawSizeInches.height > configuration.fontScaleConfiguration.maxCalibratedSpreadHeightInches
                        || rawSizeInches.width > configuration.fontScaleConfiguration.maxCalibratedSpreadWidthInches
                }
                if needsCanvasClamp {
                    let clamped = fontScaleAnalyzer.clampAntiBillboardPageSizeInches(rawSizeInches)
                    if clamped.wasClamped {
                        pageWidthPoints = clamped.sizeInches.width * 72.0
                        pageHeightPoints = clamped.sizeInches.height * 72.0
                        anyPageCanvasClamped = true
                        clampedCanonicalInches = clamped.sizeInches
                    }
                }
            }
            if let wanted = p1.manualOverride?.pageSizeInches {
                // An outlier's own page size: the picture is scaled uniformly, so the aspect ratio must match.
                let aspect = pageWidthPoints / max(1, pageHeightPoints)
                let wantedAspect = wanted.width / max(0.001, wanted.height)
                if !isolatedCanvas {
                    resolver.note(page: p1.outputPageIndex, ignored: "pageSize", reason: "only an outlier page that has its own canvas can change its page size")
                } else if abs(wantedAspect - aspect) / aspect > 0.05 {
                    resolver.note(
                        page: p1.outputPageIndex,
                        ignored: "pageSize",
                        reason: String(format: "the requested shape (%.2f×%.2f in) differs from the page's (%.2f×%.2f in); give the same aspect ratio", wanted.width, wanted.height, pageWidthPoints / 72, pageHeightPoints / 72)
                    )
                } else {
                    pageWidthPoints = wanted.width * 72.0
                    pageHeightPoints = wanted.height * 72.0
                }
            }
            let pageBoxPoints = Rect2D(x: 0, y: 0, width: pageWidthPoints, height: pageHeightPoints)

            if let finalBitmap = renderedBitmap {
                let start = ContinuousClock.now
                do throws(PDFWriteError) {
                    try writer.appendPage(
                        bitmap: finalBitmap,
                        dpi: configuration.outputDPI,
                        pageBoxPoints: pageBoxPoints,
                        ocrLayer: ocrObservations
                    )
                } catch {
                    throw .pdfWriteFailed(error)
                }
                workClock.add("pass3.write", ContinuousClock.now - start)
            }

            var dimensionRecord = dimensionResult.records[idx]
            if isolatedCanvas {
                dimensionRecord.pdfPageSizePoints = Size2D(width: pageWidthPoints, height: pageHeightPoints)
                isolatedOutputPages.append(p1.outputPageIndex)
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
                    manualOverride: p1.manualOverride,
                    borderFallback: p1.borderFallback,
                    topAnchor: topAnchors[idx],
                    registration: registrationRecords[idx],
                    dimension: dimensionRecord,
                    textBlockScale: p1.textBlockScale
                )
            )
            if let renderedBitmap { outputBitmaps.append(renderedBitmap) }
            cleanedBitmaps.append(p1.cleanedBitmap)
        }

        if !stopsAfterLayout {
            let start = ContinuousClock.now
            do {
                try writer.finalize()
            } catch {
                throw .pdfWriteFailed(error)
            }
            workClock.add("pass3.write", ContinuousClock.now - start)
        }
        let pass3Elapsed = ContinuousClock.now - pass3Start

        let rawCanonicalInches = Size2D(
            width: Double(bookLayout.canvasSize.width) / Double(configuration.processingDPI),
            height: Double(bookLayout.canvasSize.height) / Double(configuration.processingDPI)
        )
        let effectiveCanonicalInches = clampedCanonicalInches ?? rawCanonicalInches

        let physicalScaleAmbiguous: Bool
        if hasExplicitDimensionOverride {
            physicalScaleAmbiguous = false
        } else if effectivePreScaleDecision?.isPhysicalScaleAmbiguous == true {
            physicalScaleAmbiguous = true
        } else if anyPageCanvasClamped
            && rawCanonicalInches.height > configuration.fontScaleConfiguration.maxCalibratedPortraitHeightInches
        {
            physicalScaleAmbiguous = true
        } else {
            physicalScaleAmbiguous = false
        }

        let fontScaleEstimate: FontScaleAnalyzer.BookScaleEstimate?
        if configuration.enableAutomaticFontScaleCalibration || (effectivePreScaleDecision != nil) {
            fontScaleEstimate = fontScaleAnalyzer.summarizeBook(
                postCalibrationMetrics: postCalibrationGlyphMetrics,
                processingDPI: configuration.processingDPI,
                canonicalSinglePageSizeInches: effectiveCanonicalInches,
                preScaleDecision: effectivePreScaleDecision
            )
        } else {
            fontScaleEstimate = nil
        }

        var finalDimensionSummary = dimensionResult.summary
        finalDimensionSummary.isolatedCanvasPages = isolatedOutputPages

        let adjustmentReport: AdjustmentReport? = resolver.isActive
            ? resolver.report(
                outputPageCount: pass1Pages.count,
                producedScans: Set(pass1Pages.map { scanNumbers[$0.sourcePageIndex] }),
                splitScans: splitScanNumbers
            )
            : nil

        var manifest = BookProcessingManifest(
            processingDPI: configuration.processingDPI,
            outputDPI: configuration.outputDPI,
            canonicalCanvasSizeAtProcessingDPI: bookLayout.canvasSize,
            versoCanonicalFrame: bookLayout.versoCanonicalFrame,
            rectoCanonicalFrame: bookLayout.rectoCanonicalFrame,
            sourcePageSplits: sourceSplits,
            pages: records,
            prunedPages: prunedPages,
            ocrEngine: ocrEngine.map { String(describing: type(of: $0)) },
            ocrLanguages: ocrEngine != nil ? configuration.ocrLanguages : nil,
            fontScaleEstimate: fontScaleEstimate,
            inputDPI: effectiveInputDPI,
            pageSize: effectivePageSize,
            contentBoxSize: effectiveContentBoxSize,
            physicalScaleAmbiguous: physicalScaleAmbiguous,
            sourcePageGeometry: sourceGeometry,
            runningHeaderModel: runningHeaderModel,
            verticalRegistration: registrationSummary,
            dimensionConsensus: finalDimensionSummary,
            adjustments: adjustmentReport,
            sourceScanNumbers: scanNumbers
        )

        func seconds(_ d: Duration) -> Double { Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18 }
        var timings: [PipelineRunReport.StageTiming] = [
            .init(stage: "total", seconds: seconds(ContinuousClock.now - runStart), isElapsed: true),
            .init(stage: "pass1", seconds: seconds(pass1Elapsed), isElapsed: true),
            .init(stage: "pass2", seconds: seconds(pass2Elapsed), isElapsed: true),
            .init(stage: "pass3", seconds: seconds(pass3Elapsed), isElapsed: true),
        ]
        timings += workClock.timings
        manifest.run = PipelineRunReport(
            jobs: jobCount,
            cache: configuration.cache.map { options in
                PipelineRunReport.CacheReport(
                    scansReused: cache == nil ? 0 : scansReused,
                    scans: totalScans,
                    ocrReused: renderedPages.filter { $0.ocrReused }.count,
                    ocrPages: cachedOCR == nil ? 0 : renderedPages.count,
                    directory: options.directory.path
                )
            },
            timings: timings
        )

        return PipelineOutput(
            manifest: manifest,
            outputBitmapsAtOutputDPI: outputBitmaps,
            cleanedBitmapsAtProcessingDPI: cleanedBitmaps,
            lineProfiles: lineProfiles,
            stoppedAfter: configuration.stopAfter
        )
    }

    // MARK: - Font-Scale Probing & Resampling Helpers

    private func deriveSheetScaleDecision(
        targetSinglePageInches: Size2D,
        declaredPageSizesInches: [Size2D],
        referenceDeclaredDPI: Int
    ) -> FontScaleAnalyzer.PreRasterScaleDecision {
        var scales: [Double] = []
        scales.reserveCapacity(declaredPageSizesInches.count)

        for decl in declaredPageSizesInches where decl.width > 0.0 && decl.height > 0.0 {
            let isSpread: Bool
            switch configuration.splitMode {
            case .twoPageSpread:
                isSpread = true
            case .singlePage:
                isSpread = false
            case .automatic:
                isSpread = decl.width > decl.height * 1.15
            }
            let expectedSheetW = isSpread ? (targetSinglePageInches.width * 2.0) : targetSinglePageInches.width
            let expectedSheetH = targetSinglePageInches.height
            let s = max(expectedSheetW / decl.width, expectedSheetH / decl.height)
            if s.isFinite && s > 0.0 {
                scales.append(s)
            }
        }

        guard let medianScale = Self.medianOfSorted(scales.sorted()), medianScale < 0.95 else {
            return FontScaleAnalyzer.PreRasterScaleDecision(
                shouldRescale: false,
                scaleCorrectionFactor: 1.0,
                declaredBodyPointSize: nil,
                inferredSourceOpticalDPI: nil,
                confidence: 1.0,
                probedPageCount: 0
            )
        }

        let clampedScale = min(0.95, max(0.02, medianScale))
        let optDPI = Double(max(1, referenceDeclaredDPI)) / clampedScale
        return FontScaleAnalyzer.PreRasterScaleDecision(
            shouldRescale: true,
            scaleCorrectionFactor: clampedScale,
            declaredBodyPointSize: nil,
            inferredSourceOpticalDPI: optDPI,
            confidence: 1.0,
            probedPageCount: 0
        )
    }

    private func impliedSinglePageInches(
        forContentBoxInches contentBoxInches: Size2D,
        margins: PublicationMargins? = nil
    ) -> Size2D {
        let activeMargins = margins ?? configuration.harmonizerConfiguration.margins
        let refDPI = 600
        let vMargins = activeMargins.verticalMargins(dpi: refDPI)
        let versoH = activeMargins.horizontalMargins(for: .verso, dpi: refDPI)
        let rectoH = activeMargins.horizontalMargins(for: .recto, dpi: refDPI)
        let hPaddingInches = Double(max(versoH.left + versoH.right, rectoH.left + rectoH.right)) / Double(refDPI)
        let vPaddingInches = Double(vMargins.top + vMargins.bottom) / Double(refDPI)
        return Size2D(
            width: max(0.5, contentBoxInches.width + hPaddingInches),
            height: max(0.5, contentBoxInches.height + vPaddingInches)
        )
    }

    private static func medianOfSorted(_ sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 {
            return sorted[mid]
        }
        return 0.5 * (sorted[mid - 1] + sorted[mid])
    }

    private static func selectProbeIndices(from count: Int, maxProbes: Int) -> [Int] {
        guard count > 0, maxProbes > 0 else { return [] }
        if count <= maxProbes {
            return Array(0..<count)
        }
        if count == 4 && maxProbes == 3 {
            return [1, 2, 3]
        }
        let interior = count >= 5 ? Array(1..<(count - 1)) : Array(1..<count)
        if interior.count <= maxProbes {
            return interior
        }
        var selected: [Int] = []
        selected.reserveCapacity(maxProbes)
        for k in 0..<maxProbes {
            let idx = Int((Double(k) * Double(interior.count - 1) / Double(max(1, maxProbes - 1))).rounded())
            selected.append(interior[idx])
        }
        return selected
    }

    private static func selectEvenlySampledIndices(from count: Int, maxSamples: Int) -> Set<Int> {
        guard count > 0, maxSamples > 0 else { return [] }
        if count <= maxSamples {
            return Set(0..<count)
        }
        var indices = Set<Int>()
        indices.reserveCapacity(maxSamples)
        for k in 0..<maxSamples {
            let idx = Int((Double(k) * Double(count - 1) / Double(max(1, maxSamples - 1))).rounded())
            indices.insert(idx)
        }
        return indices
    }

    private static func downsampleProbeBufferIfNeeded(
        _ buffer: borrowing GrayscaleBuffer,
        maxDimension: Int
    ) -> (buffer: GrayscaleBuffer, scale: Double) {
        var current = copy buffer
        while max(current.width, current.height) > maxDimension && current.width >= 256 && current.height >= 256 {
            let dstW = max(1, current.width / 2)
            let dstH = max(1, current.height / 2)
            let srcW = current.width
            var dstPixels = ContiguousArray<UInt8>(repeating: 255, count: dstW * dstH)
            current.pixels.withUnsafeBufferPointer { srcPtr in
                dstPixels.withUnsafeMutableBufferPointer { dstPtr in
                    for dy in 0..<dstH {
                        let r0 = (dy * 2) * srcW
                        let r1 = (dy * 2 + 1) * srcW
                        let dstRow = dy * dstW
                        for dx in 0..<dstW {
                            let sx = dx * 2
                            let sum = Int(srcPtr[r0 + sx]) + Int(srcPtr[r0 + sx + 1])
                                + Int(srcPtr[r1 + sx]) + Int(srcPtr[r1 + sx + 1])
                            dstPtr[dstRow + dx] = UInt8((sum + 2) >> 2)
                        }
                    }
                }
            }
            current = GrayscaleBuffer(
                width: dstW,
                height: dstH,
                dpi: max(1, current.dpi / 2),
                pixels: dstPixels
            )
        }
        let scale = Double(current.width) / Double(max(1, buffer.width))
        return (current, scale)
    }

    private static func resampleOversizedGrayscalePages(
        _ pages: [GrayscaleBuffer],
        scaleCorrectionFactor: Double,
        explicitOpticalDPI: Double? = nil,
        targetProcessingDPI: Int,
        accelerator: any ComputeAccelerator
    ) -> [GrayscaleBuffer] {
        var resampled: [GrayscaleBuffer] = []
        resampled.reserveCapacity(pages.count)

        for buf in pages {
            let srcDPI = Double(max(1, buf.dpi))
            let inferredOpticalDPI = explicitOpticalDPI ?? (srcDPI / max(1e-6, scaleCorrectionFactor))
            let resampleRatio = Double(targetProcessingDPI) / max(1.0, inferredOpticalDPI)
            let dstW = max(1, Int((Double(buf.width) * resampleRatio).rounded()))
            let dstH = max(1, Int((Double(buf.height) * resampleRatio).rounded()))

            if dstW == buf.width && dstH == buf.height {
                resampled.append(
                    GrayscaleBuffer(
                        width: buf.width,
                        height: buf.height,
                        dpi: targetProcessingDPI,
                        pixels: buf.pixels
                    )
                )
                continue
            }

            let preFiltered: GrayscaleBuffer
            if resampleRatio < 0.75 {
                let sigma = min(8.0, 0.45 / max(1e-4, resampleRatio))
                preFiltered = accelerator.gaussianBlur(buf, sigma: sigma)
            } else {
                preFiltered = buf
            }

            let sx = Double(dstW) / Double(buf.width)
            let sy = Double(dstH) / Double(buf.height)
            let warped = accelerator.affineWarp(
                preFiltered,
                transform: .scale(sx: sx, sy: sy),
                outputSize: Size2I(width: dstW, height: dstH)
            )
            resampled.append(
                GrayscaleBuffer(
                    width: warped.width,
                    height: warped.height,
                    dpi: targetProcessingDPI,
                    pixels: warped.pixels
                )
            )
        }

        return resampled
    }
}
