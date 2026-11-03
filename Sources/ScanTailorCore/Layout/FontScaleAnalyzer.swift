import Foundation
import ScanTailorContracts

/// Analyzes typographic glyph geometry across binarized pages and optional OCR observations
/// to measure character $x$-height, cap/ascender height, vertical stem stroke thickness,
/// baseline leading, and 1-em body scale, deducing genuine physical optical DPI on uncalibrated
/// camera-wrapper documents.
public struct FontScaleAnalyzer: Sendable {

    /// Configuration parameters for typographic glyph-height analysis and oversized-page detection.
    public struct Configuration: Sendable, Equatable, Codable {
        /// Standard published book body font size in typographical points (`1 pt = 1/72 in`, default: `10.0`, $\approx 3.53\text{ mm}$).
        public var targetBodyEmPointSize: Double

        /// Ratio of lowercase $x$-height to 1-em body height (`H_x / H_em`, default: `0.48`, i.e., `4.8 pt` at `10.0 pt` body).
        public var xHeightToEmRatio: Double

        /// Ratio of capital / ascender height to 1-em body height (`H_cap / H_em`, default: `0.71`, i.e., `7.1 pt` at `10.0 pt` body).
        public var capHeightToEmRatio: Double

        /// Minimum candidate glyph bounding-box height in pixels (default: `4`).
        public var minComponentHeight: Int

        /// Maximum candidate glyph height as a fraction of page height (default: `0.08`).
        public var maxComponentHeightFraction: Double

        /// Maximum candidate glyph width as a fraction of page width (default: `0.18`).
        public var maxComponentWidthFraction: Double

        /// Minimum foreground fill density (`pixelCount / boundingBox.area`) for glyph candidates (default: `0.10`).
        public var minComponentDensity: Double

        /// Outer margin exclusion strip as a fraction of width/height when page dimensions are at least `200 px` (default: `0.05`).
        public var outerMarginExclusionFraction: Double

        /// Minimum number of collinear components required to form a valid horizontal text chain (default: `4`).
        public var minComponentsPerChain: Int

        /// Maximum calibrated width in inches for portrait or near-square single pages (`width <= height * 1.15`, default: `11.5`).
        public var maxCalibratedPortraitWidthInches: Double

        /// Maximum calibrated height in inches for portrait or near-square single pages (`width <= height * 1.15`, default: `14.0`).
        public var maxCalibratedPortraitHeightInches: Double

        /// Maximum calibrated width in inches for landscape / two-page spreads (`width > height * 1.15`, default: `22.0`).
        public var maxCalibratedSpreadWidthInches: Double

        /// Maximum calibrated height in inches for landscape / two-page spreads (`width > height * 1.15`, default: `14.5`).
        public var maxCalibratedSpreadHeightInches: Double

        /// Minimum aggregate glyph confidence in `[0, 1]` required to trust measured typography for automatic camera-wrapper rescaling (default: `0.55`).
        public var minConfidenceForAutoRescale: Double

        /// Aspect-preserving single-page physical bounding envelope in inches applied when an oversized wrapper's scale is ambiguous (default: `8.5" x 11.0"`).
        public var fallbackAmbiguousSinglePageSizeInches: Size2D

        /// Creates a font-scale analyzer configuration.
        public init(
            targetBodyEmPointSize: Double = 10.0,
            xHeightToEmRatio: Double = 0.48,
            capHeightToEmRatio: Double = 0.71,
            minComponentHeight: Int = 4,
            maxComponentHeightFraction: Double = 0.08,
            maxComponentWidthFraction: Double = 0.18,
            minComponentDensity: Double = 0.10,
            outerMarginExclusionFraction: Double = 0.05,
            minComponentsPerChain: Int = 4,
            maxCalibratedPortraitWidthInches: Double = 11.5,
            maxCalibratedPortraitHeightInches: Double = 14.0,
            maxCalibratedSpreadWidthInches: Double = 22.0,
            maxCalibratedSpreadHeightInches: Double = 14.5,
            minConfidenceForAutoRescale: Double = 0.55,
            fallbackAmbiguousSinglePageSizeInches: Size2D = Size2D(width: 8.5, height: 11.0)
        ) {
            self.targetBodyEmPointSize = max(4.0, min(36.0, targetBodyEmPointSize))
            self.xHeightToEmRatio = max(0.30, min(0.65, xHeightToEmRatio))
            self.capHeightToEmRatio = max(self.xHeightToEmRatio + 0.10, min(0.90, capHeightToEmRatio))
            self.minComponentHeight = max(3, minComponentHeight)
            self.maxComponentHeightFraction = max(0.02, min(0.25, maxComponentHeightFraction))
            self.maxComponentWidthFraction = max(0.05, min(0.50, maxComponentWidthFraction))
            self.minComponentDensity = max(0.04, min(0.50, minComponentDensity))
            self.outerMarginExclusionFraction = max(0.0, min(0.20, outerMarginExclusionFraction))
            self.minComponentsPerChain = max(3, minComponentsPerChain)
            self.maxCalibratedPortraitWidthInches = max(4.0, maxCalibratedPortraitWidthInches)
            self.maxCalibratedPortraitHeightInches = max(5.0, maxCalibratedPortraitHeightInches)
            self.maxCalibratedSpreadWidthInches = max(8.0, maxCalibratedSpreadWidthInches)
            self.maxCalibratedSpreadHeightInches = max(5.0, maxCalibratedSpreadHeightInches)
            self.minConfidenceForAutoRescale = max(0.15, min(0.95, minConfidenceForAutoRescale))
            self.fallbackAmbiguousSinglePageSizeInches = Size2D(
                width: max(3.5, fallbackAmbiguousSinglePageSizeInches.width),
                height: max(5.0, fallbackAmbiguousSinglePageSizeInches.height)
            )
        }

        private enum CodingKeys: String, CodingKey {
            case targetBodyEmPointSize
            case xHeightToEmRatio
            case capHeightToEmRatio
            case minComponentHeight
            case maxComponentHeightFraction
            case maxComponentWidthFraction
            case minComponentDensity
            case outerMarginExclusionFraction
            case minComponentsPerChain
            case maxCalibratedPortraitWidthInches
            case maxCalibratedPortraitHeightInches
            case maxCalibratedSpreadWidthInches
            case maxCalibratedSpreadHeightInches
            case minConfidenceForAutoRescale
            case fallbackAmbiguousSinglePageSizeInches
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                targetBodyEmPointSize: try c.decodeIfPresent(Double.self, forKey: .targetBodyEmPointSize) ?? 10.0,
                xHeightToEmRatio: try c.decodeIfPresent(Double.self, forKey: .xHeightToEmRatio) ?? 0.48,
                capHeightToEmRatio: try c.decodeIfPresent(Double.self, forKey: .capHeightToEmRatio) ?? 0.71,
                minComponentHeight: try c.decodeIfPresent(Int.self, forKey: .minComponentHeight) ?? 4,
                maxComponentHeightFraction: try c.decodeIfPresent(Double.self, forKey: .maxComponentHeightFraction) ?? 0.08,
                maxComponentWidthFraction: try c.decodeIfPresent(Double.self, forKey: .maxComponentWidthFraction) ?? 0.18,
                minComponentDensity: try c.decodeIfPresent(Double.self, forKey: .minComponentDensity) ?? 0.10,
                outerMarginExclusionFraction: try c.decodeIfPresent(Double.self, forKey: .outerMarginExclusionFraction) ?? 0.05,
                minComponentsPerChain: try c.decodeIfPresent(Int.self, forKey: .minComponentsPerChain) ?? 4,
                maxCalibratedPortraitWidthInches: try c.decodeIfPresent(Double.self, forKey: .maxCalibratedPortraitWidthInches) ?? 11.5,
                maxCalibratedPortraitHeightInches: try c.decodeIfPresent(Double.self, forKey: .maxCalibratedPortraitHeightInches) ?? 14.0,
                maxCalibratedSpreadWidthInches: try c.decodeIfPresent(Double.self, forKey: .maxCalibratedSpreadWidthInches) ?? 22.0,
                maxCalibratedSpreadHeightInches: try c.decodeIfPresent(Double.self, forKey: .maxCalibratedSpreadHeightInches) ?? 14.5,
                minConfidenceForAutoRescale: try c.decodeIfPresent(Double.self, forKey: .minConfidenceForAutoRescale) ?? 0.55,
                fallbackAmbiguousSinglePageSizeInches: try c.decodeIfPresent(Size2D.self, forKey: .fallbackAmbiguousSinglePageSizeInches) ?? Size2D(width: 8.5, height: 11.0)
            )
        }
    }

    /// Measured typographic pixel metrics and deduced optical scale for a single page or slice.
    public struct PageGlyphMetrics: Sendable, Equatable, Codable {
        /// Estimated lowercase $x$-height ($H_x$) in pixels.
        public let xHeightPixels: Double
        /// Estimated capital / ascender height ($H_{\text{cap}}$) in pixels.
        public let capHeightPixels: Double
        /// Inferred 1-em body font height ($H_{\text{em}}$) in pixels.
        public let inferredEmHeightPixels: Double
        /// Estimated vertical stem stroke thickness ($W_{\text{stroke}}$) in pixels.
        public let strokeWidthPixels: Double
        /// Estimated baseline-to-baseline vertical line spacing ($L_{\text{leading}}$) in pixels, or `nil` when fewer than two overlapping lines exist.
        public let baselineSpacingPixels: Double?
        /// Declared raster resolution in DPI associated with the analyzed bitmap.
        public let declaredDPI: Int
        /// Resolution-invariant body point size implied by `declaredDPI` (`inferredEmHeightPixels * 72 / declaredDPI`).
        public let declaredBodyPointSize: Double
        /// Genuine optical DPI deduced for this bitmap assuming standard `targetBodyEmPointSize` typography.
        public let inferredOpticalDPI: Double
        /// Number of horizontally chained glyph components included in height KDE estimation.
        public let sampledGlyphCount: Int
        /// Number of collinear horizontal text-line chains detected on the page.
        public let chainedLineCount: Int
        /// Whether bimodal 1D Gaussian KDE cleanly separated distinct $x$-height and cap-height peaks.
        public let isBimodal: Bool
        /// Number of substantive OCR text observations evaluated during analysis.
        public let ocrLineCount: Int
        /// Measurement confidence score in `[0, 1]`.
        public let confidence: Double

        /// Creates a per-page glyph metrics record.
        public init(
            xHeightPixels: Double,
            capHeightPixels: Double,
            inferredEmHeightPixels: Double,
            strokeWidthPixels: Double,
            baselineSpacingPixels: Double?,
            declaredDPI: Int,
            declaredBodyPointSize: Double,
            inferredOpticalDPI: Double,
            sampledGlyphCount: Int,
            chainedLineCount: Int,
            isBimodal: Bool,
            ocrLineCount: Int,
            confidence: Double
        ) {
            self.xHeightPixels = xHeightPixels
            self.capHeightPixels = capHeightPixels
            self.inferredEmHeightPixels = inferredEmHeightPixels
            self.strokeWidthPixels = strokeWidthPixels
            self.baselineSpacingPixels = baselineSpacingPixels
            self.declaredDPI = declaredDPI
            self.declaredBodyPointSize = declaredBodyPointSize
            self.inferredOpticalDPI = inferredOpticalDPI
            self.sampledGlyphCount = sampledGlyphCount
            self.chainedLineCount = chainedLineCount
            self.isBimodal = isBimodal
            self.ocrLineCount = ocrLineCount
            self.confidence = confidence
        }
    }

    /// Pre-rasterization scale decision produced from probing oversized source pages.
    public struct PreRasterScaleDecision: Sendable, Equatable, Codable {
        /// Whether source pages represent oversized uncalibrated wrappers that should be rescaled.
        public let shouldRescale: Bool
        /// Multiplicative physical scale correction factor (`1.0` when `shouldRescale == false`; e.g. `0.24` for a 300-DPI photo wrapped at 72 DPI).
        public let scaleCorrectionFactor: Double
        /// Median pre-rescale body font size in declared PDF points (`nil` if no probe ran or no text was detected).
        public let declaredBodyPointSize: Double?
        /// Deduced genuine source optical DPI (`nil` if no probe ran or no text was detected).
        public let inferredSourceOpticalDPI: Double?
        /// Confidence score of the scale estimate in `[0, 1]`.
        public let confidence: Double
        /// Number of probed pages or slices that yielded valid typographic measurements.
        public let probedPageCount: Int
        /// `true` when physical scale could not be determined automatically with high confidence and estimated single-page height exceeded `14"`.
        public let isPhysicalScaleAmbiguous: Bool
        /// `true` when anti-billboard bounding clamped the page dimensions instead of relying purely on high-confidence prose scale.
        public let wasAntiBillboardClamped: Bool

        /// Creates a pre-rasterization scale decision.
        public init(
            shouldRescale: Bool,
            scaleCorrectionFactor: Double,
            declaredBodyPointSize: Double?,
            inferredSourceOpticalDPI: Double?,
            confidence: Double,
            probedPageCount: Int,
            isPhysicalScaleAmbiguous: Bool = false,
            wasAntiBillboardClamped: Bool = false
        ) {
            self.shouldRescale = shouldRescale
            self.scaleCorrectionFactor = scaleCorrectionFactor
            self.declaredBodyPointSize = declaredBodyPointSize
            self.inferredSourceOpticalDPI = inferredSourceOpticalDPI
            self.confidence = confidence
            self.probedPageCount = probedPageCount
            self.isPhysicalScaleAmbiguous = isPhysicalScaleAmbiguous
            self.wasAntiBillboardClamped = wasAntiBillboardClamped
        }

        private enum CodingKeys: String, CodingKey {
            case shouldRescale
            case scaleCorrectionFactor
            case declaredBodyPointSize
            case inferredSourceOpticalDPI
            case confidence
            case probedPageCount
            case isPhysicalScaleAmbiguous
            case wasAntiBillboardClamped
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.shouldRescale = try c.decode(Bool.self, forKey: .shouldRescale)
            self.scaleCorrectionFactor = try c.decode(Double.self, forKey: .scaleCorrectionFactor)
            self.declaredBodyPointSize = try c.decodeIfPresent(Double.self, forKey: .declaredBodyPointSize)
            self.inferredSourceOpticalDPI = try c.decodeIfPresent(Double.self, forKey: .inferredSourceOpticalDPI)
            self.confidence = try c.decode(Double.self, forKey: .confidence)
            self.probedPageCount = try c.decode(Int.self, forKey: .probedPageCount)
            self.isPhysicalScaleAmbiguous = try c.decodeIfPresent(Bool.self, forKey: .isPhysicalScaleAmbiguous) ?? false
            self.wasAntiBillboardClamped = try c.decodeIfPresent(Bool.self, forKey: .wasAntiBillboardClamped) ?? false
        }

        /// Computes the effective PDF rasterization DPI needed so that resulting pixels correspond to `processingDPI` in true book scale.
        /// - Parameter processingDPI: Target internal pipeline processing DPI (typically `600`).
        /// - Returns: Effective `targetDPI` to pass to `PDFSourceReader.rasterizePage(at:targetDPI:)`.
        public func effectiveRenderDPI(forProcessingDPI processingDPI: Int) -> Int {
            guard shouldRescale else { return processingDPI }
            return max(12, Int((Double(processingDPI) * scaleCorrectionFactor).rounded()))
        }
    }

    /// Book-wide typographic telemetry and physical scale calibration summary persisted in `BookProcessingManifest`.
    public struct BookScaleEstimate: Sendable, Equatable, Codable {
        /// Whether automatic rescaling was applied to correct oversized uncalibrated input pages.
        public let wasAutoRescaled: Bool
        /// Whether anti-billboard normalization clamped page scale because typography was absent, low-confidence, or exceeded calibrated bounds.
        public let wasAntiBillboardClamped: Bool
        /// Physical scale correction factor applied to declared source dimensions (`1.0` for calibrated scans).
        public let appliedScaleCorrectionFactor: Double
        /// Deduced genuine optical DPI of the source document.
        public let inferredSourceOpticalDPI: Double
        /// Internal pipeline processing DPI at which pixel metrics below are expressed (typically `600`).
        public let processingDPI: Int
        /// Book-wide median lowercase $x$-height ($H_x$) in pixels at `processingDPI`.
        public let medianXHeightPixels: Double
        /// Book-wide median cap / ascender height ($H_{\text{cap}}$) in pixels at `processingDPI`.
        public let medianCapHeightPixels: Double
        /// Book-wide median 1-em body height ($H_{\text{em}}$) in pixels at `processingDPI`.
        public let medianEmHeightPixels: Double
        /// Book-wide median vertical stem stroke thickness ($W_{\text{stroke}}$) in pixels at `processingDPI`.
        public let medianStrokeWidthPixels: Double
        /// Book-wide median inter-line baseline leading ($L_{\text{leading}}$) in pixels at `processingDPI`, if available.
        public let medianBaselineSpacingPixels: Double?
        /// Post-calibration body font point size (`medianEmHeightPixels * 72 / processingDPI`).
        public let estimatedBodyPointSize: Double
        /// Declared body font point size prior to rescaling (`estimatedBodyPointSize` when `wasAutoRescaled == false`).
        public let declaredBodyPointSizeBeforeRescale: Double
        /// Canonical single-page output dimensions in physical inches (`width`, `height`).
        public let estimatedSinglePageSizeInches: Size2D
        /// Number of pages contributing to the book-wide typographic summary.
        public let sampledPageCount: Int
        /// Aggregate confidence in `[0, 1]`.
        public let confidence: Double

        /// Creates a book-wide font scale and typography estimate.
        public init(
            wasAutoRescaled: Bool,
            wasAntiBillboardClamped: Bool = false,
            appliedScaleCorrectionFactor: Double,
            inferredSourceOpticalDPI: Double,
            processingDPI: Int,
            medianXHeightPixels: Double,
            medianCapHeightPixels: Double,
            medianEmHeightPixels: Double,
            medianStrokeWidthPixels: Double,
            medianBaselineSpacingPixels: Double?,
            estimatedBodyPointSize: Double,
            declaredBodyPointSizeBeforeRescale: Double,
            estimatedSinglePageSizeInches: Size2D,
            sampledPageCount: Int,
            confidence: Double
        ) {
            self.wasAutoRescaled = wasAutoRescaled
            self.wasAntiBillboardClamped = wasAntiBillboardClamped
            self.appliedScaleCorrectionFactor = appliedScaleCorrectionFactor
            self.inferredSourceOpticalDPI = inferredSourceOpticalDPI
            self.processingDPI = processingDPI
            self.medianXHeightPixels = medianXHeightPixels
            self.medianCapHeightPixels = medianCapHeightPixels
            self.medianEmHeightPixels = medianEmHeightPixels
            self.medianStrokeWidthPixels = medianStrokeWidthPixels
            self.medianBaselineSpacingPixels = medianBaselineSpacingPixels
            self.estimatedBodyPointSize = estimatedBodyPointSize
            self.declaredBodyPointSizeBeforeRescale = declaredBodyPointSizeBeforeRescale
            self.estimatedSinglePageSizeInches = estimatedSinglePageSizeInches
            self.sampledPageCount = sampledPageCount
            self.confidence = confidence
        }

        private enum CodingKeys: String, CodingKey {
            case wasAutoRescaled
            case wasAntiBillboardClamped
            case appliedScaleCorrectionFactor
            case inferredSourceOpticalDPI
            case processingDPI
            case medianXHeightPixels
            case medianCapHeightPixels
            case medianEmHeightPixels
            case medianStrokeWidthPixels
            case medianBaselineSpacingPixels
            case estimatedBodyPointSize
            case declaredBodyPointSizeBeforeRescale
            case estimatedSinglePageSizeInches
            case sampledPageCount
            case confidence
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.wasAutoRescaled = try c.decode(Bool.self, forKey: .wasAutoRescaled)
            self.wasAntiBillboardClamped = try c.decodeIfPresent(Bool.self, forKey: .wasAntiBillboardClamped) ?? false
            self.appliedScaleCorrectionFactor = try c.decode(Double.self, forKey: .appliedScaleCorrectionFactor)
            self.inferredSourceOpticalDPI = try c.decode(Double.self, forKey: .inferredSourceOpticalDPI)
            self.processingDPI = try c.decode(Int.self, forKey: .processingDPI)
            self.medianXHeightPixels = try c.decode(Double.self, forKey: .medianXHeightPixels)
            self.medianCapHeightPixels = try c.decode(Double.self, forKey: .medianCapHeightPixels)
            self.medianEmHeightPixels = try c.decode(Double.self, forKey: .medianEmHeightPixels)
            self.medianStrokeWidthPixels = try c.decode(Double.self, forKey: .medianStrokeWidthPixels)
            self.medianBaselineSpacingPixels = try c.decodeIfPresent(Double.self, forKey: .medianBaselineSpacingPixels)
            self.estimatedBodyPointSize = try c.decode(Double.self, forKey: .estimatedBodyPointSize)
            self.declaredBodyPointSizeBeforeRescale = try c.decode(Double.self, forKey: .declaredBodyPointSizeBeforeRescale)
            self.estimatedSinglePageSizeInches = try c.decode(Size2D.self, forKey: .estimatedSinglePageSizeInches)
            self.sampledPageCount = try c.decode(Int.self, forKey: .sampledPageCount)
            self.confidence = try c.decode(Double.self, forKey: .confidence)
        }
    }

    /// Active configuration for this analyzer.
    public let configuration: Configuration

    /// Creates a font-scale analyzer with the specified configuration.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Nominal Probe DPI & Oversized Gate

    /// Computes a realistic nominal DPI tag (`[150, 600]`) for binarizing an uncalibrated probe raster
    /// so `AdaptiveBinarizer` and `BackgroundNormalizer` scale their local windows to actual pixel dimensions
    /// rather than an artificial 72 DPI wrapper tag.
    /// - Parameters:
    ///   - pixelSize: Pixel dimensions of the single-page slice or full raster being binarized.
    ///   - isLikelySpread: `true` if `pixelSize` represents an unsplit landscape two-page spread; `false` for a single page or split slice.
    /// - Returns: Clamped nominal DPI in `150...600`.
    public static func nominalProbeDPI(forPixelSize pixelSize: Size2I, isLikelySpread: Bool = false) -> Int {
        let assumedHeightInches = isLikelySpread ? 8.5 : 9.0
        let raw = Int((Double(max(1, pixelSize.height)) / assumedHeightInches).rounded())
        return min(600, max(150, raw))
    }

    /// Returns `true` when a single declared page box in inches exceeds standard calibrated document bounds.
    /// - Parameter pageSizeInches: Declared page width and height in inches.
    /// - Returns: `true` if the page dimensions exceed calibrated portrait (`11.5" x 14.0"`) or spread (`22.0" x 14.5"`) limits.
    public func isDeclaredPageOversized(_ pageSizeInches: Size2D) -> Bool {
        let w = pageSizeInches.width
        let h = pageSizeInches.height
        guard w > 0.0, h > 0.0 else { return false }
        if w > h * 1.15 {
            return h > configuration.maxCalibratedSpreadHeightInches
                || w > configuration.maxCalibratedSpreadWidthInches
        } else {
            return h > configuration.maxCalibratedPortraitHeightInches
                || w > configuration.maxCalibratedPortraitWidthInches
        }
    }

    /// Convenience static check using default calibrated bounds.
    /// - Parameter pageSizeInches: Declared page width and height in inches.
    /// - Returns: `true` if the declared dimensions exceed calibrated portrait or spread limits.
    public static func isDeclaredPageOversized(
        _ pageSizeInches: Size2D,
        configuration: Configuration = Configuration()
    ) -> Bool {
        FontScaleAnalyzer(configuration: configuration).isDeclaredPageOversized(pageSizeInches)
    }

    /// Returns `true` when at least half of the valid declared page sizes in a document exceed calibrated bounds.
    /// - Parameter pageSizesInches: Declared physical sizes in inches for active source pages.
    /// - Returns: `true` if camera-wrapper scale probing should run.
    public func areDeclaredPagesOversized(_ pageSizesInches: [Size2D]) -> Bool {
        let valid = pageSizesInches.filter { $0.width > 0.0 && $0.height > 0.0 }
        guard !valid.isEmpty else { return false }
        let oversizedCount = valid.filter { isDeclaredPageOversized($0) }.count
        return oversizedCount * 2 >= valid.count
    }

    /// Convenience static check across multiple declared page sizes using default calibrated bounds.
    /// - Parameter pageSizesInches: Declared physical sizes in inches for active source pages.
    /// - Returns: `true` if camera-wrapper scale probing should run.
    public static func areDeclaredPagesOversized(
        _ pageSizesInches: [Size2D],
        configuration: Configuration = Configuration()
    ) -> Bool {
        FontScaleAnalyzer(configuration: configuration).areDeclaredPagesOversized(pageSizesInches)
    }

    // MARK: - Per-Page Glyph Analysis

    /// Convenience static entry point for analyzing a single binarized page.
    public static func analyzePage(
        in bitmap: borrowing BinaryBitmap,
        declaredDPI: Int,
        ocrObservations: [RecognizedTextObservation] = [],
        configuration: Configuration = Configuration()
    ) -> PageGlyphMetrics? {
        FontScaleAnalyzer(configuration: configuration).analyzePage(
            in: bitmap,
            declaredDPI: declaredDPI,
            ocrObservations: ocrObservations
        )
    }

    /// Measures typographic pixel metrics ($H_x$, $H_{\text{cap}}$, $W_{\text{stroke}}$, $L_{\text{leading}}$, $H_{\text{em}}$)
    /// across horizontally chained text components and optional OCR observations on a 1-bit page bitmap.
    /// - Parameters:
    ///   - bitmap: Binarized 1-bit page or slice (`1 = black ink`, `0 = white paper`).
    ///   - declaredDPI: Declared DPI associated with `bitmap` (e.g. `72` for raw probe or `600` for Pass 3 canvas).
    ///   - ocrObservations: Optional OCR observations in normalized `[0, 1] x [0, 1]` (or pixel) top-left coordinates.
    /// - Returns: `PageGlyphMetrics` if sufficient collinear text glyphs are present, or `nil` on blank/non-text pages.
    public func analyzePage(
        in bitmap: borrowing BinaryBitmap,
        declaredDPI: Int,
        ocrObservations: [RecognizedTextObservation] = []
    ) -> PageGlyphMetrics? {
        let width = bitmap.width
        let height = bitmap.height
        let safeDeclaredDPI = max(1, declaredDPI)
        guard width >= 32, height >= 32 else { return nil }

        let allComponents = ConnectedComponentAnalyzer.extractComponents(from: bitmap, connectivity: .eight)
        guard allComponents.count >= configuration.minComponentsPerChain else { return nil }

        let minCompH = configuration.minComponentHeight
        let maxCompH = max(minCompH + 2, Int((Double(height) * configuration.maxComponentHeightFraction).rounded()))
        let maxCompW = max(12, Int((Double(width) * configuration.maxComponentWidthFraction).rounded()))
        let marginX = width >= 200 ? Int((Double(width) * configuration.outerMarginExclusionFraction).rounded()) : 0
        let marginY = height >= 200 ? Int((Double(height) * configuration.outerMarginExclusionFraction).rounded()) : 0
        let excludeBorderTouch = (width >= 64 && height >= 64)

        let initialCandidates = allComponents.filter { comp in
            let box = comp.boundingBox
            let w = box.width
            let h = box.height
            guard h >= minCompH && h <= maxCompH else { return false }
            guard w >= 1 && w <= maxCompW else { return false }
            guard comp.pixelCount >= 4 else { return false }
            if excludeBorderTouch {
                if box.minX == 0 || box.minY == 0 || box.maxX == width || box.maxY == height {
                    return false
                }
            }
            if marginX > 0 {
                let midX = box.minX + w / 2
                if midX < marginX || midX > width - marginX {
                    return false
                }
            }
            if marginY > 0 {
                let midY = box.minY + h / 2
                if midY < marginY || midY > height - marginY {
                    return false
                }
            }
            let aspect = Double(w) / Double(h)
            guard aspect >= 0.06 && aspect <= 6.5 else { return false }
            return comp.density >= configuration.minComponentDensity
        }

        guard initialCandidates.count >= configuration.minComponentsPerChain else { return nil }

        // Ink-pixel-weighted median height protects `coarseScale` from background pepper/dust specks.
        let coarseScale = Self.weightedMedianHeight(of: initialCandidates)
        guard coarseScale >= Double(minCompH) else { return nil }

        var (chainedCandidates, chains) = extractCollinearChains(
            from: initialCandidates,
            coarseScale: coarseScale,
            minCompH: minCompH,
            maxCompH: maxCompH
        )

        // Fallback if an interior diagram/blotch pulled `coarseScale` above the actual text height.
        if chains.isEmpty {
            let smallerPool = initialCandidates.filter { Double($0.boundingBox.height) < coarseScale * 0.65 }
            if smallerPool.count >= configuration.minComponentsPerChain {
                let retryScale = Self.weightedMedianHeight(of: smallerPool)
                (chainedCandidates, chains) = extractCollinearChains(
                    from: smallerPool,
                    coarseScale: retryScale,
                    minCompH: minCompH,
                    maxCompH: maxCompH
                )
            }
        }

        guard !chains.isEmpty else { return nil }

        // Gather all components participating in valid horizontal text chains.
        var chainedComponents: [ConnectedComponent] = []
        for chain in chains {
            for idx in chain {
                chainedComponents.append(chainedCandidates[idx])
            }
        }
        guard chainedComponents.count >= configuration.minComponentsPerChain else { return nil }

        let rawHeights = chainedComponents.map { Double($0.boundingBox.height) }.sorted()
        let rawMedH = Self.continuousQuantile(sorted: rawHeights, p: 0.50)

        // Trim residual punctuation fragments (< 0.48 * medH) and accidental two-line merges (> 2.10 * medH).
        // Both xHeight (0.48 em) and capHeight (0.71 em) always lie inside [0.676 * medH, 1.479 * medH].
        let minGlyphH = max(Double(minCompH), rawMedH * 0.48)
        let maxGlyphH = rawMedH * 2.10
        let filteredGlyphs = chainedComponents.filter { comp in
            let h = Double(comp.boundingBox.height)
            return h >= minGlyphH && h <= maxGlyphH
        }
        let activeGlyphs = filteredGlyphs.count >= configuration.minComponentsPerChain
            ? filteredGlyphs
            : chainedComponents

        let glyphIntHeights = activeGlyphs.map(\.boundingBox.height)
        let sortedHeights = glyphIntHeights.map(Double.init).sorted()
        let medH = Self.continuousQuantile(sorted: sortedHeights, p: 0.50)

        // Evaluate OCR case statistics and line-box height observations.
        let ocrStats = evaluateOCRObservations(
            ocrObservations,
            bitmapWidth: width,
            bitmapHeight: height
        )

        // Bimodal 1D Gaussian KDE over glyph heights.
        let kdeResult = estimateHeightsViaKDE(
            intHeights: glyphIntHeights,
            sortedHeights: sortedHeights,
            medH: medH,
            ocrUppercaseRatio: ocrStats.uppercaseRatio
        )

        var xHeight = kdeResult.xHeight
        var capHeight = kdeResult.capHeight
        var emHeight = kdeResult.emHeight

        // Fuse valid horizontal OCR line heights when guarded against tilted-line bounding-box inflation.
        // A tilted or curved OCR line box of width W has height H_line*cos(theta) + W*sin(theta) >> H_line,
        // so any OCR implied em-height deviating beyond [0.75x, 1.25x] of component-derived `emHeight` is rejected.
        let guardedOcrEms = ocrStats.impliedEmHeightsPixels.filter { ocrEm in
            ocrEm >= emHeight * 0.75 && ocrEm <= emHeight * 1.25
        }
        if !guardedOcrEms.isEmpty {
            let sortedOcrEms = guardedOcrEms.sorted()
            let medianOcrEm = Self.continuousQuantile(sorted: sortedOcrEms, p: 0.50)
            let ocrWeight = kdeResult.isBimodal ? 0.15 : 0.25
            let fusedEm = (1.0 - ocrWeight) * emHeight + ocrWeight * medianOcrEm
            let ratio = fusedEm / max(1e-6, emHeight)
            emHeight = fusedEm
            xHeight *= ratio
            capHeight *= ratio
        }

        let strokeWidth = estimateStrokeWidth(
            in: bitmap,
            glyphs: activeGlyphs,
            emHeight: emHeight
        )

        let baselineSpacing = estimateBaselineSpacing(
            chains: chains,
            candidates: chainedCandidates,
            emHeight: emHeight
        )

        let declaredBodyPt = emHeight * 72.0 / Double(safeDeclaredDPI)
        let inferredOpticalDPI = emHeight * 72.0 / configuration.targetBodyEmPointSize

        // Confidence combines sample count, line count, KDE peak clarity, and OCR corroboration.
        let countScore = min(1.0, Double(activeGlyphs.count) / 60.0)
        let lineScore = min(1.0, Double(chains.count) / 5.0)
        let modeBonus = kdeResult.isBimodal ? 0.14 : (ocrStats.uppercaseRatio != nil ? 0.06 : 0.0)
        let ocrBonus = !guardedOcrEms.isEmpty ? 0.06 : 0.0
        let rawConfidence = 0.42 * countScore + 0.38 * lineScore + modeBonus + ocrBonus
        let confidence = min(1.0, max(0.15, rawConfidence))

        guard xHeight.isFinite, capHeight.isFinite, emHeight.isFinite,
              declaredBodyPt.isFinite, inferredOpticalDPI.isFinite, emHeight > 0.0
        else {
            return nil
        }

        return PageGlyphMetrics(
            xHeightPixels: xHeight,
            capHeightPixels: capHeight,
            inferredEmHeightPixels: emHeight,
            strokeWidthPixels: strokeWidth,
            baselineSpacingPixels: baselineSpacing,
            declaredDPI: safeDeclaredDPI,
            declaredBodyPointSize: declaredBodyPt,
            inferredOpticalDPI: inferredOpticalDPI,
            sampledGlyphCount: activeGlyphs.count,
            chainedLineCount: chains.count,
            isBimodal: kdeResult.isBimodal,
            ocrLineCount: ocrStats.substantiveCount,
            confidence: confidence
        )
    }

    // MARK: - Pre-Raster Scale Decision, Anti-Billboard Clamping & Book Summary

    /// Clamps a physical single-page canvas size in inches proportionally so automatic PDF generation
    /// never produces 20–30 inch billboard pages.
    /// - Parameter pageSizeInches: Candidate output page size in inches.
    /// - Returns: A tuple `(sizeInches, wasClamped)` preserving exact aspect ratio within calibrated bounds.
    public func clampAntiBillboardPageSizeInches(
        _ pageSizeInches: Size2D
    ) -> (sizeInches: Size2D, wasClamped: Bool) {
        let w = pageSizeInches.width
        let h = pageSizeInches.height
        guard w.isFinite, h.isFinite, w > 0.0, h > 0.0 else {
            return (pageSizeInches, false)
        }
        let maxW: Double
        let maxH = configuration.maxCalibratedPortraitHeightInches
        if w > h * 1.15 {
            maxW = configuration.maxCalibratedSpreadWidthInches
        } else {
            maxW = configuration.maxCalibratedPortraitWidthInches
        }
        let scale = min(maxW / w, maxH / h)
        guard scale < 1.0 - 1e-6 else {
            return (pageSizeInches, false)
        }
        let clampedScale = max(0.01, scale)
        return (
            Size2D(width: w * clampedScale, height: h * clampedScale),
            true
        )
    }

    /// Evaluates probed page glyph metrics alongside declared physical page dimensions in inches
    /// to determine whether the input document is an oversized camera/image wrapper requiring scale calibration
    /// or anti-billboard normalization.
    /// - Parameters:
    ///   - probeMetrics: Typographic measurements collected from probed pages or slices.
    ///   - declaredPageSizesInches: Declared physical sizes in inches of active source pages.
    ///   - referenceDeclaredDPI: Declared resolution of the unscaled source coordinate space (`72` for PDF point space, or `buffer.dpi` for direct raster inputs).
    ///   - splitMode: Active spread split mode (`.automatic`, `.singlePage`, or `.twoPageSpread`).
    ///   - observedSpreadLayout: Optional empirical observation from `PageSplitEstimator` indicating whether probed pages split as two-page spreads.
    /// - Returns: A `PreRasterScaleDecision` specifying whether to rescale, by what factor, and whether physical scale remains ambiguous.
    public func estimatePreRasterScale(
        from probeMetrics: [PageGlyphMetrics],
        declaredPageSizesInches: [Size2D],
        referenceDeclaredDPI: Int = 72,
        splitMode: PageSplitMode = .automatic,
        observedSpreadLayout: Bool? = nil
    ) -> PreRasterScaleDecision {
        let safeRefDPI = Double(max(1, referenceDeclaredDPI))
        guard areDeclaredPagesOversized(declaredPageSizesInches) else {
            return PreRasterScaleDecision(
                shouldRescale: false,
                scaleCorrectionFactor: 1.0,
                declaredBodyPointSize: nil,
                inferredSourceOpticalDPI: nil,
                confidence: 1.0,
                probedPageCount: 0,
                isPhysicalScaleAmbiguous: false,
                wasAntiBillboardClamped: false
            )
        }

        // Compute median uncalibrated single-page physical dimensions across active source pages.
        var singlePageWidths: [Double] = []
        var singlePageHeights: [Double] = []
        for decl in declaredPageSizesInches where decl.width > 0.0 && decl.height > 0.0 {
            let isSpread: Bool
            switch splitMode {
            case .twoPageSpread:
                isSpread = true
            case .singlePage:
                isSpread = false
            case .automatic:
                isSpread = observedSpreadLayout ?? (decl.width > decl.height * 1.15)
            }
            singlePageWidths.append(isSpread ? (decl.width * 0.5) : decl.width)
            singlePageHeights.append(decl.height)
        }

        let medianSingleW = singlePageWidths.isEmpty
            ? 16.0
            : Self.continuousQuantile(sorted: singlePageWidths.sorted(), p: 0.50)
        let medianSingleH = singlePageHeights.isEmpty
            ? 24.0
            : Self.continuousQuantile(sorted: singlePageHeights.sorted(), p: 0.50)
        let rawExceedsAmbiguousHeight = medianSingleH > configuration.maxCalibratedPortraitHeightInches

        // Aspect-preserving anti-billboard fallback scale when typography is absent or low-confidence.
        let fallbackEnv = configuration.fallbackAmbiguousSinglePageSizeInches
        let isLandscapeSingle = medianSingleW > medianSingleH * 1.15
        let envW = isLandscapeSingle ? max(fallbackEnv.width, fallbackEnv.height) : fallbackEnv.width
        let envH = isLandscapeSingle ? min(fallbackEnv.width, fallbackEnv.height) : fallbackEnv.height
        let rawFallbackScale = min(envW / max(1e-6, medianSingleW), envH / max(1e-6, medianSingleH))

        func makeAmbiguousFallbackDecision(
            declaredBodyPt: Double?,
            confidence: Double,
            probedCount: Int
        ) -> PreRasterScaleDecision {
            guard rawFallbackScale < 0.999 else {
                return PreRasterScaleDecision(
                    shouldRescale: false,
                    scaleCorrectionFactor: 1.0,
                    declaredBodyPointSize: declaredBodyPt,
                    inferredSourceOpticalDPI: nil,
                    confidence: confidence,
                    probedPageCount: probedCount,
                    isPhysicalScaleAmbiguous: rawExceedsAmbiguousHeight,
                    wasAntiBillboardClamped: false
                )
            }
            let clampedFallback = min(0.99, max(0.02, rawFallbackScale))
            return PreRasterScaleDecision(
                shouldRescale: true,
                scaleCorrectionFactor: clampedFallback,
                declaredBodyPointSize: declaredBodyPt,
                inferredSourceOpticalDPI: safeRefDPI / clampedFallback,
                confidence: confidence,
                probedPageCount: probedCount,
                isPhysicalScaleAmbiguous: rawExceedsAmbiguousHeight,
                wasAntiBillboardClamped: true
            )
        }

        let validProbe = probeMetrics.filter {
            $0.declaredBodyPointSize.isFinite && $0.declaredBodyPointSize > 0.0
        }
        guard !validProbe.isEmpty else {
            return makeAmbiguousFallbackDecision(declaredBodyPt: nil, confidence: 0.0, probedCount: 0)
        }

        let inliers = Self.filterMetricsOutliers(validProbe, keyPath: \.declaredBodyPointSize)
        let bodyPts = inliers.map(\.declaredBodyPointSize).sorted()
        let medianDeclaredPt = Self.continuousQuantile(sorted: bodyPts, p: 0.50)
        let medianConf = Self.continuousQuantile(
            sorted: inliers.map(\.confidence).sorted(),
            p: 0.50
        )

        // Require high typographic confidence (multi-line prose rather than 1-line cover titles or diagram labels)
        // before trusting measured glyph height for automatic optical scale deduction.
        guard medianConf >= configuration.minConfidenceForAutoRescale else {
            return makeAmbiguousFallbackDecision(
                declaredBodyPt: medianDeclaredPt,
                confidence: medianConf,
                probedCount: validProbe.count
            )
        }

        let rawScale = configuration.targetBodyEmPointSize / max(1e-6, medianDeclaredPt)

        // Maximum anti-billboard ceiling scale for single output pages.
        let maxAllowedW = isLandscapeSingle
            ? configuration.maxCalibratedSpreadWidthInches
            : configuration.maxCalibratedPortraitWidthInches
        let maxAllowedH = configuration.maxCalibratedPortraitHeightInches
        let maxBillboardScale = min(
            maxAllowedW / max(1e-6, medianSingleW),
            maxAllowedH / max(1e-6, medianSingleH)
        )

        // Only auto-rescale via prose typography when declared typography is substantially inflated (`rawScale <= 0.78`,
        // i.e., declared body text >= ~12.8 pt). If `rawScale > 0.78` on a wide spread whose split pages already fit
        // within `maxAllowedW x maxAllowedH`, preserve 1:1 calibrated dimensions; otherwise clamp billboard pages.
        guard rawScale <= 0.78 else {
            if maxBillboardScale < 0.999 {
                let clampedBillboard = min(0.99, max(0.02, maxBillboardScale))
                return PreRasterScaleDecision(
                    shouldRescale: true,
                    scaleCorrectionFactor: clampedBillboard,
                    declaredBodyPointSize: medianDeclaredPt,
                    inferredSourceOpticalDPI: safeRefDPI / clampedBillboard,
                    confidence: medianConf,
                    probedPageCount: validProbe.count,
                    isPhysicalScaleAmbiguous: rawExceedsAmbiguousHeight,
                    wasAntiBillboardClamped: true
                )
            }
            return PreRasterScaleDecision(
                shouldRescale: false,
                scaleCorrectionFactor: 1.0,
                declaredBodyPointSize: medianDeclaredPt,
                inferredSourceOpticalDPI: safeRefDPI / max(1e-6, rawScale),
                confidence: medianConf,
                probedPageCount: validProbe.count,
                isPhysicalScaleAmbiguous: false,
                wasAntiBillboardClamped: false
            )
        }

        // Prevent pathological over-shrinking below 3.5" physical page height, and enforce the anti-billboard ceiling.
        let minSafeScale = min(0.78, max(0.02, 3.5 / max(3.5, medianSingleH)))
        let proseScale = min(0.78, max(minSafeScale, rawScale))
        let postProseExceedsMaxHeight = (medianSingleH * proseScale) > configuration.maxCalibratedPortraitHeightInches + 1e-6
        let needsBillboardClamp = proseScale > maxBillboardScale + 1e-6
        let clampedScale = needsBillboardClamp ? max(0.02, min(proseScale, maxBillboardScale)) : proseScale
        let inferredOpticalDPI = safeRefDPI / clampedScale

        return PreRasterScaleDecision(
            shouldRescale: true,
            scaleCorrectionFactor: clampedScale,
            declaredBodyPointSize: medianDeclaredPt,
            inferredSourceOpticalDPI: inferredOpticalDPI,
            confidence: medianConf,
            probedPageCount: validProbe.count,
            isPhysicalScaleAmbiguous: postProseExceedsMaxHeight,
            wasAntiBillboardClamped: needsBillboardClamp
        )
    }

    /// Aggregates post-calibration page glyph metrics across the book into a persistent `BookScaleEstimate`.
    /// - Parameters:
    ///   - postCalibrationMetrics: `PageGlyphMetrics` measured on Pass 3 harmonized pages at `processingDPI`.
    ///   - processingDPI: Internal pipeline processing DPI (typically `600`).
    ///   - canonicalSinglePageSizeInches: Final canonical single-page dimensions in inches.
    ///   - preScaleDecision: Optional pre-rasterization scale decision applied before Pass 1.
    /// - Returns: Consolidated `BookScaleEstimate`, or `nil` if no typographic evidence was available.
    public func summarizeBook(
        postCalibrationMetrics: [PageGlyphMetrics],
        processingDPI: Int,
        canonicalSinglePageSizeInches: Size2D,
        preScaleDecision: PreRasterScaleDecision? = nil
    ) -> BookScaleEstimate? {
        let safeProcDPI = max(72, processingDPI)
        let wasRescaled = preScaleDecision?.shouldRescale ?? false
        let wasBillboardClamped = preScaleDecision?.wasAntiBillboardClamped ?? false
        let appliedScale = wasRescaled ? (preScaleDecision?.scaleCorrectionFactor ?? 1.0) : 1.0

        if postCalibrationMetrics.isEmpty {
            guard wasRescaled,
                  let preOptDPI = preScaleDecision?.inferredSourceOpticalDPI
            else {
                return nil
            }
            if wasBillboardClamped && preScaleDecision?.declaredBodyPointSize == nil {
                return BookScaleEstimate(
                    wasAutoRescaled: true,
                    wasAntiBillboardClamped: true,
                    appliedScaleCorrectionFactor: appliedScale,
                    inferredSourceOpticalDPI: preOptDPI,
                    processingDPI: safeProcDPI,
                    medianXHeightPixels: 0.0,
                    medianCapHeightPixels: 0.0,
                    medianEmHeightPixels: 0.0,
                    medianStrokeWidthPixels: 0.0,
                    medianBaselineSpacingPixels: nil,
                    estimatedBodyPointSize: 0.0,
                    declaredBodyPointSizeBeforeRescale: 0.0,
                    estimatedSinglePageSizeInches: canonicalSinglePageSizeInches,
                    sampledPageCount: preScaleDecision?.probedPageCount ?? 0,
                    confidence: preScaleDecision?.confidence ?? 0.0
                )
            }
            let postBodyPt: Double
            let prePt: Double
            if let explicitPrePt = preScaleDecision?.declaredBodyPointSize {
                prePt = explicitPrePt
                postBodyPt = explicitPrePt * appliedScale
            } else {
                postBodyPt = configuration.targetBodyEmPointSize
                prePt = postBodyPt / max(1e-6, appliedScale)
            }
            let emPx = postBodyPt * Double(safeProcDPI) / 72.0
            let xPx = emPx * configuration.xHeightToEmRatio
            let capPx = emPx * configuration.capHeightToEmRatio
            let strokePx = max(1.0, emPx * 0.088)
            return BookScaleEstimate(
                wasAutoRescaled: true,
                wasAntiBillboardClamped: wasBillboardClamped,
                appliedScaleCorrectionFactor: appliedScale,
                inferredSourceOpticalDPI: preOptDPI,
                processingDPI: safeProcDPI,
                medianXHeightPixels: xPx,
                medianCapHeightPixels: capPx,
                medianEmHeightPixels: emPx,
                medianStrokeWidthPixels: strokePx,
                medianBaselineSpacingPixels: nil,
                estimatedBodyPointSize: postBodyPt,
                declaredBodyPointSizeBeforeRescale: prePt,
                estimatedSinglePageSizeInches: canonicalSinglePageSizeInches,
                sampledPageCount: preScaleDecision?.probedPageCount ?? 0,
                confidence: preScaleDecision?.confidence ?? 0.5
            )
        }

        let inliers = Self.filterMetricsOutliers(postCalibrationMetrics, keyPath: \.inferredEmHeightPixels)

        let medX = Self.continuousQuantile(sorted: inliers.map(\.xHeightPixels).sorted(), p: 0.50)
        let medCap = Self.continuousQuantile(sorted: inliers.map(\.capHeightPixels).sorted(), p: 0.50)
        let medEm = Self.continuousQuantile(sorted: inliers.map(\.inferredEmHeightPixels).sorted(), p: 0.50)
        let medStroke = Self.continuousQuantile(sorted: inliers.map(\.strokeWidthPixels).sorted(), p: 0.50)

        let spacings = inliers.compactMap(\.baselineSpacingPixels).sorted()
        let medSpacing: Double? = spacings.isEmpty
            ? nil
            : Self.continuousQuantile(sorted: spacings, p: 0.50)

        let postBodyPt = medEm * 72.0 / Double(safeProcDPI)
        let preBodyPt: Double
        if wasRescaled, let explicitPrePt = preScaleDecision?.declaredBodyPointSize {
            preBodyPt = explicitPrePt
        } else {
            preBodyPt = postBodyPt / max(1e-6, appliedScale)
        }

        let inferredSourceDPI: Double
        if let explicitOptDPI = preScaleDecision?.inferredSourceOpticalDPI,
           (wasRescaled || preScaleDecision?.probedPageCount == 0)
        {
            inferredSourceDPI = explicitOptDPI
        } else {
            inferredSourceDPI = Double(safeProcDPI) * (postBodyPt / configuration.targetBodyEmPointSize)
        }

        let baseConf = Self.continuousQuantile(sorted: inliers.map(\.confidence).sorted(), p: 0.50)
        let multiPageBoost = inliers.count >= 3 ? 0.08 : (inliers.count == 2 ? 0.04 : 0.0)
        let finalConf = min(1.0, max(0.15, baseConf + multiPageBoost))

        return BookScaleEstimate(
            wasAutoRescaled: wasRescaled,
            wasAntiBillboardClamped: wasBillboardClamped,
            appliedScaleCorrectionFactor: appliedScale,
            inferredSourceOpticalDPI: inferredSourceDPI,
            processingDPI: safeProcDPI,
            medianXHeightPixels: medX,
            medianCapHeightPixels: medCap,
            medianEmHeightPixels: medEm,
            medianStrokeWidthPixels: medStroke,
            medianBaselineSpacingPixels: medSpacing,
            estimatedBodyPointSize: postBodyPt,
            declaredBodyPointSizeBeforeRescale: preBodyPt,
            estimatedSinglePageSizeInches: canonicalSinglePageSizeInches,
            sampledPageCount: postCalibrationMetrics.count,
            confidence: finalConf
        )
    }

    // MARK: - Internal Chaining & KDE Algorithms

    private func extractCollinearChains(
        from pool: [ConnectedComponent],
        coarseScale: Double,
        minCompH: Int,
        maxCompH: Int
    ) -> (candidates: [ConnectedComponent], chains: [[Int]]) {
        let minRefinedH = max(Double(minCompH), coarseScale * 0.38)
        let maxRefinedH = min(Double(maxCompH), coarseScale * 2.60)

        var candidates = pool.filter { comp in
            let h = Double(comp.boundingBox.height)
            return h >= minRefinedH && h <= maxRefinedH
        }
        guard candidates.count >= configuration.minComponentsPerChain else {
            return ([], [])
        }

        candidates.sort { a, b in
            let midXA = a.boundingBox.minX + a.boundingBox.maxX
            let midXB = b.boundingBox.minX + b.boundingBox.maxX
            if midXA != midXB {
                return midXA < midXB
            }
            return (a.boundingBox.minY + a.boundingBox.maxY) < (b.boundingBox.minY + b.boundingBox.maxY)
        }

        let n = candidates.count
        let maxGap = 3.2 * coarseScale
        let maxOverlap = 0.45 * coarseScale
        let maxVertOffset = 0.85 * coarseScale
        let maxSlope = tan(25.0 * .pi / 180.0)

        var bestRight = [Int](repeating: -1, count: n)
        var bestRightScore = [Double](repeating: .infinity, count: n)
        var bestLeft = [Int](repeating: -1, count: n)
        var bestLeftScore = [Double](repeating: .infinity, count: n)

        for i in 0..<n {
            let boxI = candidates[i].boundingBox
            let cyI = 0.5 * Double(boxI.minY + boxI.maxY)
            let cxI = 0.5 * Double(boxI.minX + boxI.maxX)

            for j in (i + 1)..<n {
                let boxJ = candidates[j].boundingBox
                let cxJ = 0.5 * Double(boxJ.minX + boxJ.maxX)
                if cxJ <= cxI { continue }

                let gapX = Double(boxJ.minX - boxI.maxX)
                if gapX > maxGap {
                    if gapX > maxGap + coarseScale * 4.5 {
                        break
                    }
                    continue
                }
                if gapX < -maxOverlap { continue }

                let cyJ = 0.5 * Double(boxJ.minY + boxJ.maxY)
                let dy = abs(cyJ - cyI)
                if dy > maxVertOffset { continue }

                let dx = max(cxJ - cxI, coarseScale * 0.5)
                if (dy / dx) > maxSlope { continue }

                let overlapY = min(boxI.maxY, boxJ.maxY) - max(boxI.minY, boxJ.minY)
                if overlapY <= 0 && dy > coarseScale * 0.45 { continue }

                let cost = max(0.0, gapX) + 3.5 * dy
                if cost < bestRightScore[i] {
                    bestRightScore[i] = cost
                    bestRight[i] = j
                }
                if cost < bestLeftScore[j] {
                    bestLeftScore[j] = cost
                    bestLeft[j] = i
                }
            }
        }

        let minChainLen = configuration.minComponentsPerChain
        let minSpanX = max(12.0, 2.2 * coarseScale)
        var visited = [Bool](repeating: false, count: n)
        var chains: [[Int]] = []

        for i in 0..<n {
            if visited[i] { continue }
            let prev = bestLeft[i]
            if prev != -1 && bestRight[prev] == i {
                continue
            }

            var chain: [Int] = []
            var curr = i
            var minX = Int.max
            var maxX = Int.min
            while curr != -1 && !visited[curr] {
                visited[curr] = true
                chain.append(curr)
                let b = candidates[curr].boundingBox
                if b.minX < minX { minX = b.minX }
                if b.maxX > maxX { maxX = b.maxX }

                let next = bestRight[curr]
                if next != -1 && bestLeft[next] == curr {
                    curr = next
                } else {
                    break
                }
            }

            if chain.count >= minChainLen && Double(maxX - minX) >= minSpanX {
                chains.append(chain)
            }
        }

        return (candidates, chains)
    }

    private struct KDEHeightEstimate {
        let xHeight: Double
        let capHeight: Double
        let emHeight: Double
        let isBimodal: Bool
    }

    private func estimateHeightsViaKDE(
        intHeights: [Int],
        sortedHeights: [Double],
        medH: Double,
        ocrUppercaseRatio: Double?
    ) -> KDEHeightEstimate {
        let xRatio = configuration.xHeightToEmRatio
        let capRatio = configuration.capHeightToEmRatio

        // Build exact integer-height histogram so KDE evaluation is O(distinctHeights * gridPoints).
        var countsByHeight: [Int: Int] = [:]
        countsByHeight.reserveCapacity(64)
        for h in intHeights {
            countsByHeight[h, default: 0] += 1
        }
        let histBins = countsByHeight.map { (h: Double($0.key), count: Double($0.value)) }
            .sorted { $0.h < $1.h }

        let sigma = max(0.85, 0.055 * medH)
        let invTwoSigmaSq = 1.0 / (2.0 * sigma * sigma)
        let minGrid = max(1.0, (sortedHeights.first ?? medH) - 2.0 * sigma)
        let maxGrid = (sortedHeights.last ?? medH) + 2.0 * sigma
        let step = max(0.05, min(0.25, sigma * 0.12))
        let gridCount = max(5, Int(ceil((maxGrid - minGrid) / step)) + 1)

        var gridX = ContiguousArray<Double>(repeating: 0.0, count: gridCount)
        var gridF = ContiguousArray<Double>(repeating: 0.0, count: gridCount)
        var fMax = 0.0
        var globalMaxIdx = 0

        for idx in 0..<gridCount {
            let x = minGrid + Double(idx) * step
            var density = 0.0
            for bin in histBins {
                let d = x - bin.h
                density += bin.count * exp(-(d * d) * invTwoSigmaSq)
            }
            gridX[idx] = x
            gridF[idx] = density
            if density > fMax {
                fMax = density
                globalMaxIdx = idx
            }
        }

        // Extract local maxima with 3-point parabolic refinement.
        struct Peak {
            let pos: Double
            let density: Double
            let gridIdx: Int
        }

        var peaks: [Peak] = []
        var idx = 1
        while idx < gridCount - 1 {
            if gridF[idx] >= gridF[idx - 1] {
                var plateauEnd = idx
                while plateauEnd + 1 < gridCount - 1 && abs(gridF[plateauEnd + 1] - gridF[idx]) <= 1e-12 {
                    plateauEnd += 1
                }
                if gridF[plateauEnd] > gridF[plateauEnd + 1] {
                    let centerIdx = (idx + plateauEnd) / 2
                    let refinedX = Self.parabolicPeakX(
                        x0: gridX[centerIdx],
                        step: step,
                        fMinus: gridF[max(0, centerIdx - 1)],
                        fZero: gridF[centerIdx],
                        fPlus: gridF[min(gridCount - 1, centerIdx + 1)]
                    )
                    peaks.append(Peak(pos: refinedX, density: gridF[centerIdx], gridIdx: centerIdx))
                }
                idx = plateauEnd + 1
            } else {
                idx += 1
            }
        }

        let pStar: Double
        if let topPeak = peaks.max(by: { $0.density < $1.density }) {
            pStar = topPeak.pos
        } else {
            pStar = gridX[globalMaxIdx]
        }

        // Case 1: Bimodal pair (p1 < p2) with p2/p1 in [1.22, 1.75], f(p1) >= 0.28 * fMax, f(p2) >= 0.22 * fMax.
        let targetCapOverX = capRatio / xRatio
        var bestPair: (p1: Peak, p2: Peak, score: Double)? = nil

        if peaks.count >= 2 && fMax > 0.0 {
            for a in 0..<peaks.count {
                let pk1 = peaks[a]
                guard pk1.density >= 0.28 * fMax else { continue }
                for b in (a + 1)..<peaks.count {
                    let pk2 = peaks[b]
                    guard pk2.density >= 0.22 * fMax else { continue }
                    let ratio = pk2.pos / max(1e-6, pk1.pos)
                    guard ratio >= 1.22 && ratio <= 1.75 else { continue }

                    // Require a discernible valley between pk1 and pk2.
                    var minValley = min(pk1.density, pk2.density)
                    if pk1.gridIdx + 1 <= pk2.gridIdx - 1 {
                        for k in (pk1.gridIdx + 1)...(pk2.gridIdx - 1) {
                            if gridF[k] < minValley { minValley = gridF[k] }
                        }
                    }
                    guard minValley <= 0.88 * min(pk1.density, pk2.density) else { continue }

                    let score = (pk1.density + pk2.density) / fMax
                        - 0.35 * abs(ratio - targetCapOverX)
                    if bestPair == nil || score > bestPair!.score {
                        bestPair = (pk1, pk2, score)
                    }
                }
            }
        }

        if let pair = bestPair {
            let p1 = pair.p1.pos
            let p2 = pair.p2.pos
            let w1 = pair.p1.density
            let w2 = pair.p2.density
            let em = (w1 * (p1 / xRatio) + w2 * (p2 / capRatio)) / max(1e-9, w1 + w2)
            return KDEHeightEstimate(xHeight: p1, capHeight: p2, emHeight: em, isBimodal: true)
        }

        // Case 2a: Unimodal + OCR ALL-CAPS disambiguation (ocrUppercaseRatio > 0.75).
        if let upperRatio = ocrUppercaseRatio, upperRatio > 0.75 {
            let capH = pStar
            let xH = capH * (xRatio / capRatio)
            let em = capH / capRatio
            return KDEHeightEstimate(xHeight: xH, capHeight: capH, emHeight: em, isBimodal: false)
        }

        // Case 2b: Unimodal merged low-DPI or uniform-case distribution.
        let q25 = Self.continuousQuantile(sorted: sortedHeights, p: 0.25)
        let q75 = Self.continuousQuantile(sorted: sortedHeights, p: 0.75)
        if q25 > 0.0 && (q75 / q25) >= 1.25 {
            let xH = Self.continuousQuantile(sorted: sortedHeights, p: 0.30)
            let capH = Self.continuousQuantile(sorted: sortedHeights, p: 0.78)
            let em = 0.5 * ((xH / xRatio) + (capH / capRatio))
            return KDEHeightEstimate(xHeight: xH, capHeight: capH, emHeight: em, isBimodal: false)
        } else {
            let xH = pStar
            let capH = pStar * (capRatio / xRatio)
            let em = pStar / xRatio
            return KDEHeightEstimate(xHeight: xH, capHeight: capH, emHeight: em, isBimodal: false)
        }
    }

    // MARK: - Stroke Width & Multi-Column Baseline Spacing

    private func estimateStrokeWidth(
        in bitmap: borrowing BinaryBitmap,
        glyphs: [ConnectedComponent],
        emHeight: Double
    ) -> Double {
        var runHistogram: [Int: Int] = [:]
        runHistogram.reserveCapacity(32)
        var totalRuns = 0

        // Sample up to 400 evenly spaced chained glyphs for fast O(1) page runtime.
        let step = max(1, glyphs.count / 400)
        var idx = 0
        while idx < glyphs.count {
            let box = glyphs[idx].boundingBox
            let w = box.width
            let h = box.height
            let trimY = h >= 5 ? max(1, h / 5) : 0
            let yStart = box.minY + trimY
            let yEnd = max(yStart + 1, box.maxY - trimY)
            let isWideEnoughForCrossbar = Double(w) > 0.38 * Double(h)
            let maxStemRun = isWideEnoughForCrossbar ? max(2, Int((Double(w) * 0.75).rounded(.down))) : w

            for y in yStart..<min(bitmap.height, yEnd) {
                var x = box.minX
                while x < box.maxX {
                    if bitmap[x, y] {
                        let runStart = x
                        while x < box.maxX && bitmap[x, y] {
                            x += 1
                        }
                        let runLen = x - runStart
                        if runLen >= 1 && runLen <= maxStemRun {
                            runHistogram[runLen, default: 0] += 1
                            totalRuns += 1
                        }
                    } else {
                        x += 1
                    }
                }
            }
            idx += step
        }

        let fallbackStroke = max(1.0, 0.088 * emHeight)
        guard totalRuns >= 6 else {
            return fallbackStroke
        }

        let measured = Self.histogramMedian(runHistogram, totalCount: totalRuns)
        return min(max(1.0, measured), max(2.0, 0.35 * emHeight))
    }

    private struct FittedLineSegment {
        let minX: Int
        let maxX: Int
        let meanX: Double
        let meanBaselineY: Double
        let slope: Double

        func baselineY(atX x: Double) -> Double {
            meanBaselineY + slope * (x - meanX)
        }
    }

    private func estimateBaselineSpacing(
        chains: [[Int]],
        candidates: [ConnectedComponent],
        emHeight: Double
    ) -> Double? {
        guard chains.count >= 2 else { return nil }

        var segments: [FittedLineSegment] = []
        segments.reserveCapacity(chains.count)

        for chain in chains {
            var minX = Int.max
            var maxX = Int.min
            var sumX = 0.0
            var sumY = 0.0
            let count = Double(chain.count)

            for idx in chain {
                let box = candidates[idx].boundingBox
                if box.minX < minX { minX = box.minX }
                if box.maxX > maxX { maxX = box.maxX }
                sumX += 0.5 * Double(box.minX + box.maxX)
                sumY += Double(box.maxY)
            }

            let meanX = sumX / count
            let meanY = sumY / count
            var num = 0.0
            var den = 0.0
            for idx in chain {
                let box = candidates[idx].boundingBox
                let dx = 0.5 * Double(box.minX + box.maxX) - meanX
                let dy = Double(box.maxY) - meanY
                num += dx * dy
                den += dx * dx
            }
            let rawSlope = den > 1e-3 ? (num / den) : 0.0
            let clampedSlope = min(0.45, max(-0.45, rawSlope))

            segments.append(
                FittedLineSegment(
                    minX: minX,
                    maxX: maxX,
                    meanX: meanX,
                    meanBaselineY: meanY,
                    slope: clampedSlope
                )
            )
        }

        segments.sort { $0.meanBaselineY < $1.meanBaselineY }

        // Pair each line segment only with its nearest horizontally-overlapping vertical successor
        // so two-column and multi-column layouts never interleave baselines from adjacent columns.
        let minSpacing = 0.85 * emHeight
        let maxSpacing = 3.20 * emHeight
        var spacings: [Double] = []
        spacings.reserveCapacity(segments.count)

        for i in 0..<segments.count {
            let segA = segments[i]
            let spanA = max(1, segA.maxX - segA.minX)
            var bestDelta: Double? = nil

            for j in (i + 1)..<segments.count {
                let segB = segments[j]
                let roughDy = segB.meanBaselineY - segA.meanBaselineY
                if roughDy > maxSpacing * 1.35 {
                    break
                }

                let overlapMinX = max(segA.minX, segB.minX)
                let overlapMaxX = min(segA.maxX, segB.maxX)
                let overlapSpan = overlapMaxX - overlapMinX
                let minSpan = min(spanA, max(1, segB.maxX - segB.minX))
                guard overlapSpan > 0 && Double(overlapSpan) >= 0.20 * Double(minSpan) else {
                    continue
                }

                let evalX = 0.5 * Double(overlapMinX + overlapMaxX)
                let dy = segB.baselineY(atX: evalX) - segA.baselineY(atX: evalX)
                if dy >= minSpacing && dy <= maxSpacing {
                    bestDelta = dy
                    break
                }
            }

            if let delta = bestDelta {
                spacings.append(delta)
            }
        }

        guard !spacings.isEmpty else { return nil }
        spacings.sort()
        return Self.continuousQuantile(sorted: spacings, p: 0.50)
    }

    // MARK: - OCR Observation Evaluation

    private struct OCRAnalysisStats {
        let substantiveCount: Int
        let uppercaseRatio: Double?
        let impliedEmHeightsPixels: [Double]
    }

    private func evaluateOCRObservations(
        _ observations: [RecognizedTextObservation],
        bitmapWidth: Int,
        bitmapHeight: Int
    ) -> OCRAnalysisStats {
        guard !observations.isEmpty else {
            return OCRAnalysisStats(substantiveCount: 0, uppercaseRatio: nil, impliedEmHeightsPixels: [])
        }

        var upperCount = 0
        var lowerCount = 0
        var substantiveCount = 0
        var impliedEms: [Double] = []
        impliedEms.reserveCapacity(observations.count)

        let ascenderChars = Set<Character>("bdfhkltBDFHKLT0123456789")
        let descenderChars = Set<Character>("gjpqyQ")

        for obs in observations {
            guard obs.confidence >= 0.45 else { continue }
            var obsLetters = 0
            var hasUpperOrAscender = false
            var hasDescender = false

            for ch in obs.text {
                if ch.isLetter {
                    obsLetters += 1
                    if ch.isUppercase {
                        upperCount += 1
                        hasUpperOrAscender = true
                    } else if ch.isLowercase {
                        lowerCount += 1
                        if ascenderChars.contains(ch) {
                            hasUpperOrAscender = true
                        }
                        if descenderChars.contains(ch) {
                            hasDescender = true
                        }
                    }
                } else if ch.isNumber {
                    hasUpperOrAscender = true
                }
            }

            guard obsLetters >= 1 else { continue }
            substantiveCount += 1

            let box = obs.boundingBox
            guard box.width > 0.0, box.height > 0.0 else { continue }

            let isNormalized = box.maxX <= 1.05 && box.maxY <= 1.05 && box.width <= 1.05 && box.height <= 1.05
            let pxW = isNormalized ? box.width * Double(bitmapWidth) : box.width
            let pxH = isNormalized ? box.height * Double(bitmapHeight) : box.height
            guard pxH >= 3.0, pxW >= 2.0 else { continue }

            let expectedHeightRatio: Double
            if hasUpperOrAscender && hasDescender {
                expectedHeightRatio = min(0.96, configuration.capHeightToEmRatio + 0.22)
            } else if hasUpperOrAscender {
                expectedHeightRatio = configuration.capHeightToEmRatio
            } else if hasDescender {
                expectedHeightRatio = min(0.90, configuration.xHeightToEmRatio + 0.22)
            } else {
                expectedHeightRatio = configuration.xHeightToEmRatio
            }

            impliedEms.append(pxH / max(0.30, expectedHeightRatio))
        }

        let totalCased = upperCount + lowerCount
        let uppercaseRatio: Double? = totalCased >= 4
            ? Double(upperCount) / Double(totalCased)
            : nil

        return OCRAnalysisStats(
            substantiveCount: substantiveCount,
            uppercaseRatio: uppercaseRatio,
            impliedEmHeightsPixels: impliedEms
        )
    }

    // MARK: - Numeric & Robust Statistical Helpers

    private static func weightedMedianHeight(of components: [ConnectedComponent]) -> Double {
        guard !components.isEmpty else { return 0.0 }
        let pairs = components.map { (h: Double($0.boundingBox.height), w: Double(max(1, $0.pixelCount))) }
            .sorted { $0.h < $1.h }
        let totalWeight = pairs.reduce(0.0) { $0 + $1.w }
        let halfWeight = totalWeight * 0.5
        var cumulative = 0.0
        for pair in pairs {
            cumulative += pair.w
            if cumulative >= halfWeight {
                return pair.h
            }
        }
        return pairs[pairs.count - 1].h
    }

    private static func continuousQuantile(sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0.0 }
        if sorted.count == 1 { return sorted[0] }
        let clampedP = min(1.0, max(0.0, p))
        let pos = clampedP * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Int(pos.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = pos - Double(lo)
        return sorted[lo] * (1.0 - frac) + sorted[hi] * frac
    }

    private static func parabolicPeakX(
        x0: Double,
        step: Double,
        fMinus: Double,
        fZero: Double,
        fPlus: Double
    ) -> Double {
        let denom = fMinus - 2.0 * fZero + fPlus
        guard abs(denom) > 1e-12 else { return x0 }
        let offset = 0.5 * (fMinus - fPlus) / denom
        let clampedOffset = min(0.5, max(-0.5, offset))
        return x0 + clampedOffset * step
    }

    private static func histogramMedian(_ histogram: [Int: Int], totalCount: Int) -> Double {
        let sortedBins = histogram.sorted { $0.key < $1.key }
        guard !sortedBins.isEmpty else { return 1.0 }
        let target = Double(totalCount) * 0.5
        var cumulative = 0
        for bin in sortedBins {
            let nextCum = cumulative + bin.value
            if Double(nextCum) >= target {
                let frac = (target - Double(cumulative)) / Double(max(1, bin.value))
                return (Double(bin.key) - 0.5) + frac
            }
            cumulative = nextCum
        }
        return Double(sortedBins[sortedBins.count - 1].key)
    }

    private static func filterMetricsOutliers(
        _ metrics: [PageGlyphMetrics],
        keyPath: KeyPath<PageGlyphMetrics, Double>
    ) -> [PageGlyphMetrics] {
        guard metrics.count >= 4 else { return metrics }
        let sortedVals = metrics.map { $0[keyPath: keyPath] }.sorted()
        let q1 = continuousQuantile(sorted: sortedVals, p: 0.25)
        let med = continuousQuantile(sorted: sortedVals, p: 0.50)
        let q3 = continuousQuantile(sorted: sortedVals, p: 0.75)
        guard med > 0.0 else { return metrics }

        let effectiveIQR = max(q3 - q1, med * 0.06)
        let lower = q1 - 1.5 * effectiveIQR
        let upper = q3 + 1.5 * effectiveIQR
        let maxDev = med * 0.30

        let filtered = metrics.filter { m in
            let v = m[keyPath: keyPath]
            return v >= lower && v <= upper && abs(v - med) <= maxDev
        }
        return filtered.isEmpty ? metrics : filtered
    }
}
