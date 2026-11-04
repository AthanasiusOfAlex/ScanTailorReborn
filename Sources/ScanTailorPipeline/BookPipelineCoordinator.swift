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

    public init(
        overrideSkewDegrees: Double? = nil,
        disableDewarp: Bool? = nil,
        overrideContentBox: Rect2I? = nil,
        overrideDestinationOrigin: Point2I? = nil,
        borderFallback: BorderFallbackPolicy? = nil,
        runningHeader: RunningHeaderPolicy? = nil,
        verticalRegistration: VerticalRegistrationPolicy? = nil,
        dimensionClass: DimensionClass? = nil
    ) {
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
        dimension: PageDimensionRecord? = nil
    ) {
        self.dimension = dimension
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
        dimensionConsensus: DimensionConsensusSummary? = nil
    ) {
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
    }
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

        public init(
            processingDPI: Int = 600,
            outputDPI: Int = 300,
            inputDPI: Int? = nil,
            targetPageSize: PhysicalSizeSpec? = nil,
            targetContentBoxSize: PhysicalSizeSpec? = nil,
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
            isolateOutlierCanvases: Bool = true
        ) {
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

        public init(
            manifest: BookProcessingManifest,
            outputBitmapsAtOutputDPI: [BinaryBitmap],
            cleanedBitmapsAtProcessingDPI: [BinaryBitmap],
            lineProfiles: [RunningHeaderDetector.PageLineProfile] = []
        ) {
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

        var sourceGrayPages: [GrayscaleBuffer] = []
        sourceGrayPages.reserveCapacity(activeSourceIndices.count)

        for srcIdx in activeSourceIndices {
            do {
                let rawGray = try await reader.rasterizePage(at: srcIdx, targetDPI: effectiveRenderDPI)
                let stampedGray = (rawGray.dpi == configuration.processingDPI)
                    ? rawGray
                    : GrayscaleBuffer(
                        width: rawGray.width,
                        height: rawGray.height,
                        dpi: configuration.processingDPI,
                        pixels: rawGray.pixels
                    )
                sourceGrayPages.append(stampedGray)
            } catch {
                throw .pdfReadFailed(error)
            }
            progressHandler?(srcIdx + 1, sourceCount)
        }

        return try await processGrayscalePagesImpl(
            sourceGrayPages,
            writer: writer,
            accelerator: accelerator,
            ocrEngine: ocrEngine,
            existingManifest: existingManifest,
            preScaleDecisionFromReader: readerPreScaleDecision
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
        try await processGrayscalePagesImpl(
            sourcePages,
            writer: writer,
            accelerator: accelerator,
            ocrEngine: ocrEngine,
            existingManifest: existingManifest,
            preScaleDecisionFromReader: nil
        )
    }

    private func processGrayscalePagesImpl<Writer: PDFDocumentWriter & ~Copyable>(
        _ rawSourcePages: [GrayscaleBuffer],
        writer: consuming Writer,
        accelerator: any ComputeAccelerator,
        ocrEngine: (any OCREngine)?,
        existingManifest: BookProcessingManifest?,
        preScaleDecisionFromReader: FontScaleAnalyzer.PreRasterScaleDecision?
    ) async throws(PipelineError) -> PipelineOutput {
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

        var sourcePages = rawSourcePages
        var effectivePreScaleDecision = preScaleDecisionFromReader

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
        var sourceSplits: [PageSplitDecision] = []
        sourceSplits.reserveCapacity(sourcePages.count)
        var pass1Pages: [Pass1Page] = []
        var prunedPages: [PrunedPageRecord] = []
        var sourceGeometry: [SourcePageGeometryRecord] = []
        sourceGeometry.reserveCapacity(sourcePages.count)
        var priorGeometryBySourceIndex: [Int: SourcePageGeometryRecord] = [:]
        for record in existingManifest?.sourcePageGeometry ?? [] {
            priorGeometryBySourceIndex[record.sourcePageIndex] = record
        }

        let dpiScale = Double(configuration.processingDPI) / 600.0
        let minSagPixels = configuration.minDewarpSagPixelsAt600DPI * dpiScale
        let effectiveGutterTrimWidth = max(0, Int((Double(configuration.gutterTrimWidth) * dpiScale).rounded()))

        // Landscape scans in a portrait book are plates or tables, not two-page spreads (Substep 6.2.1).
        let dimensionConsensus = DimensionConsensus(configuration: configuration.dimensionConsensusConfiguration)
        let splitVetoedSources: Set<Int> = configuration.splitMode == .automatic
            ? Set(dimensionConsensus.splitVetoes(sourceSizes: sourcePages.map { Size2I(width: $0.width, height: $0.height) }))
            : []

        for (srcIdx, unrectifiedScan) in sourcePages.enumerated() {
            // 0a. Document quadrangle detection & perspective rectification (desk excision).
            let (rectifiedScan, rectificationRecord) = rectifySourcePage(
                unrectifiedScan,
                sourcePageIndex: srcIdx,
                priorRecord: priorGeometryBySourceIndex[srcIdx],
                targetPageSize: effectivePageSize
            )
            // 0b. Residual desk/background masking (gutter wedges, crop-edge slivers, or the full
            // desk when rectification was skipped, rejected, or disabled).
            let (rawScan, geometryRecord) = maskDeskOfSourcePage(rectifiedScan, record: rectificationRecord)
            sourceGeometry.append(geometryRecord)

            let splitDecision = PageSplitEstimator.estimateSplit(
                in: rawScan,
                mode: splitVetoedSources.contains(srcIdx) ? .singlePage : configuration.splitMode
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
                let fallbackContext = configuration.enableBorderFallback
                    ? geometryRecord.borderFallbackContext(
                        splitSide: slice.side,
                        policy: manualOverride?.borderFallback,
                        marginalConfidence: configuration.borderFallbackMarginalConfidence
                    )
                    : nil
                let (initialCleaned, initialFallback) = cleaner.clean(initialBinary, fallback: fallbackContext)
                var borderFallbackResult = initialFallback

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
                            let dewarpedGlyphScale = fontScaleAnalyzer.analyzePage(
                                in: initialCleaned,
                                declaredDPI: deskewedGray.dpi,
                                ocrObservations: []
                            ).map { BackgroundNormalizer.GlyphScale(metrics: $0) }
                            let dewarpedBinary = binarizer.binarize(
                                dewarpedGray,
                                accelerator: accelerator,
                                glyphScale: dewarpedGlyphScale
                            )
                            let (dewarpedCleaned, dewarpedFallback) = cleaner.clean(dewarpedBinary, fallback: fallbackContext)
                            finalCleaned = dewarpedCleaned
                            borderFallbackResult = dewarpedFallback
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
                        manualOverride: manualOverride,
                        borderFallback: borderFallbackResult
                    )
                )
            }
        }

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
        let harmonizerInputs = pass1Pages.map { p in
            MarginHarmonizer.PageInput(
                pageIndex: p.outputPageIndex,
                side: p.bookSide,
                pageSize: Size2I(width: p.cleanedBitmap.width, height: p.cleanedBitmap.height),
                dpi: configuration.processingDPI,
                detection: p.detection
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
        var dimensionResult = dimensionConsensus.classify(pages: dimensionInputs)
        dimensionResult.summary.splitVetoedSourcePages = splitVetoedSources.sorted()
        var outlierCanvasSizes: [Int: Size2I] = [:]
        for (input, record) in zip(dimensionInputs, dimensionResult.records) {
            if let size = record.proposedCanvasSize { outlierCanvasSizes[input.pageIndex] = size }
        }

        let bookLayout = harmonizer.harmonizeBook(
            pages: harmonizerInputs,
            detector: contentDetector,
            dimensionOutliers: dimensionResult.outlierPageIndices,
            outlierCanvasSizes: outlierCanvasSizes,
            minimumCanonicalPages: configuration.dimensionConsensusConfiguration.manualOutlierPages != nil ? 1 : 3
        )
        if let manual = configuration.dimensionConsensusConfiguration.manualOutlierPages {
            dimensionResult.summary.ignoredManualPages = manual.filter { $0 >= pass1Pages.count }.sorted().map { $0 + 1 }
        }

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

            let shouldCollectScaleTelemetry = configuration.enableAutomaticFontScaleCalibration || (effectivePreScaleDecision != nil)
            if shouldCollectScaleTelemetry && sampledGlyphPageIndices.contains(idx) && !plan.isDimensionOutlier {
                if let glyphMetrics = fontScaleAnalyzer.analyzePage(
                    in: framed600,
                    declaredDPI: configuration.processingDPI,
                    ocrObservations: ocrObservations
                ) {
                    postCalibrationGlyphMetrics.append(glyphMetrics)
                }
            }

            var pageWidthPoints = Double(finalBitmap.width) * 72.0 / Double(configuration.outputDPI)
            var pageHeightPoints = Double(finalBitmap.height) * 72.0 / Double(configuration.outputDPI)
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
                    dimension: dimensionRecord
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
            ocrLanguages: ocrEngine != nil ? configuration.ocrLanguages : nil,
            fontScaleEstimate: fontScaleEstimate,
            inputDPI: effectiveInputDPI,
            pageSize: effectivePageSize,
            contentBoxSize: effectiveContentBoxSize,
            physicalScaleAmbiguous: physicalScaleAmbiguous,
            sourcePageGeometry: sourceGeometry,
            runningHeaderModel: runningHeaderModel,
            verticalRegistration: registrationSummary,
            dimensionConsensus: finalDimensionSummary
        )

        return PipelineOutput(
            manifest: manifest,
            outputBitmapsAtOutputDPI: outputBitmaps,
            cleanedBitmapsAtProcessingDPI: cleanedBitmaps,
            lineProfiles: lineProfiles
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
