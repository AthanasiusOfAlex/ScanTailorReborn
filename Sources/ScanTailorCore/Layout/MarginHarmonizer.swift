import ScanTailorContracts

/// Book-wide statistical margin harmonizer and 3-tier page positioning engine.
///
/// Establishes the book's canonical text frame, runs Pass 2 canonical-width outlier rejection to trim
/// stray margin smudges, and positions each page according to the 3-tier policy.
///
/// The frame is the largest clean body text block (header to footer, edge to edge); the canvas is that block
/// plus the publication margins (by default 1/4 in top and bottom, 1/2 in left and right), not the
/// scanned paper size. Every page is centered left to right:
/// - **Tier 1 (`fullBody`)**: full text pages sit on the frame top, so running headers stay steady.
/// - **Tier 2 (`edgeAnchoredPartial`)**: pages with a running header hang from the top however short;
///   chapter openings that reach the foot of the text block sit on the frame bottom; other full-width
///   blocks keep their natural height.
/// - **Tier 3 (`standaloneFloating`)**: title pages, dedications, dividers and ornaments keep their
///   offset from the scan's text block, and stay centered if they were centered.
public struct MarginHarmonizer: Sendable {
    /// Logical book page side for recto/verso margin symmetry.
    public enum PageSide: String, Sendable, Equatable, Codable {
        case verso
        case recto
        case single
    }

    /// The 3-tier layout placement classification for a page.
    public enum PlacementTier: String, Sendable, Equatable, Codable {
        /// Full-body text page locked to the canonical text frame.
        case fullBody
        /// Chapter opening (top sinkage) or chapter ending (short bottom) anchored to the matching canonical edges.
        case edgeAnchoredPartial
        /// Standalone or floating page (title page, divider, epigraph, ornament, or blank) whose natural page-relative position is preserved.
        case standaloneFloating
    }

    /// Which vertical edge of a Tier 2 (`edgeAnchoredPartial`) page was pinned to the canonical frame.
    public enum VerticalAnchorEdge: String, Sendable, Equatable, Codable {
        /// The content top sits on the frame top (chapter ending: free space below).
        case top
        /// The content bottom sits on the frame bottom (chapter opening: free sinkage above).
        case bottom
        /// Neither edge matched; the page keeps its natural vertical position.
        case natural
    }

    public struct Configuration: Sendable, Equatable {
        /// Horizontal margin padding in pixels (at 600 DPI) around the canonical text block when auto-sizing the output canvas.
        public var canonicalHorizontalMarginAt600DPI: Int {
            get { margins.left.toPixels(atDPI: 600) }
            set {
                margins.left = PublicationMargins.Dimension(value: Double(newValue) / 600.0, unit: .inches)
                margins.right = PublicationMargins.Dimension(value: Double(newValue) / 600.0, unit: .inches)
            }
        }
        /// Vertical margin padding in pixels (at 600 DPI) around the canonical text block when auto-sizing the output canvas.
        public var canonicalVerticalMarginAt600DPI: Int {
            get { margins.top.toPixels(atDPI: 600) }
            set {
                margins.top = PublicationMargins.Dimension(value: Double(newValue) / 600.0, unit: .inches)
                margins.bottom = PublicationMargins.Dimension(value: Double(newValue) / 600.0, unit: .inches)
            }
        }
        /// Configurable publication margins (top, bottom, left, right, inner, outer).
        public var margins: PublicationMargins
        /// Optional explicit target output page trim size (`--page-size`), overriding automatic canvas sizing.
        public var targetPageSize: PhysicalSizeSpec?
        /// Optional explicit canonical text block size (`--content-box-size`), overriding the largest-body-box estimate.
        public var targetContentBoxSize: PhysicalSizeSpec?
        /// Maximum fractional width deviation from `canonicalFrame.width` for a page to qualify as full-width (`Tier 1` or `Tier 2`).
        public var fullWidthToleranceFraction: Double
        /// Maximum fractional height deviation from `canonicalFrame.height` for a page to qualify as `Tier 1 (fullBody)`.
        public var fullHeightToleranceFraction: Double
        /// Minimum fraction of `canonicalFrame.height` required for a full-width partial page to qualify as `Tier 2 (edgeAnchoredPartial)`.
        public var minPartialHeightFraction: Double
        /// Maximum fractional width excess above the 75th-percentile content width before Pass 2 outlier trimming triggers.
        public var pass2OutlierWidthExcessFraction: Double
        /// Maximum allowed fractional deviation from median content box dimension before IQR/median outlier exclusion (default: 0.25).
        public var canonicalDimensionOutlierToleranceFraction: Double
        /// Interquartile range (IQR) multiplier for canonical frame outlier filtering (default: 1.5).
        public var canonicalDimensionIQROutlierMultiplier: Double
        /// Relative spread of the size cluster that sets the canonical frame (default 0.02): the frame takes the
        /// largest body box within the densest window of this width, so noisy boxes above it do not inflate it.
        public var canonicalFrameClusterFraction: Double

        public init(
            margins: PublicationMargins = .publicationDefault,
            targetPageSize: PhysicalSizeSpec? = nil,
            targetContentBoxSize: PhysicalSizeSpec? = nil,
            canonicalHorizontalMarginAt600DPI: Int? = nil,
            canonicalVerticalMarginAt600DPI: Int? = nil,
            fullWidthToleranceFraction: Double = 0.08,
            fullHeightToleranceFraction: Double = 0.08,
            minPartialHeightFraction: Double = 0.22,
            pass2OutlierWidthExcessFraction: Double = 0.10,
            canonicalDimensionOutlierToleranceFraction: Double = 0.25,
            canonicalDimensionIQROutlierMultiplier: Double = 1.5,
            canonicalFrameClusterFraction: Double = 0.02
        ) {
            var m = margins
            if let h = canonicalHorizontalMarginAt600DPI {
                m.left = PublicationMargins.Dimension(value: Double(max(0, h)) / 600.0, unit: .inches)
                m.right = PublicationMargins.Dimension(value: Double(max(0, h)) / 600.0, unit: .inches)
            }
            if let v = canonicalVerticalMarginAt600DPI {
                m.top = PublicationMargins.Dimension(value: Double(max(0, v)) / 600.0, unit: .inches)
                m.bottom = PublicationMargins.Dimension(value: Double(max(0, v)) / 600.0, unit: .inches)
            }
            self.margins = m
            self.targetPageSize = targetPageSize
            self.targetContentBoxSize = targetContentBoxSize
            self.fullWidthToleranceFraction = min(max(0.01, fullWidthToleranceFraction), 0.30)
            self.fullHeightToleranceFraction = min(max(0.01, fullHeightToleranceFraction), 0.30)
            self.minPartialHeightFraction = min(max(0.05, minPartialHeightFraction), 0.85)
            self.pass2OutlierWidthExcessFraction = min(max(0.02, pass2OutlierWidthExcessFraction), 0.50)
            self.canonicalDimensionOutlierToleranceFraction = min(max(0.05, canonicalDimensionOutlierToleranceFraction), 1.0)
            self.canonicalDimensionIQROutlierMultiplier = min(max(0.5, canonicalDimensionIQROutlierMultiplier), 5.0)
            self.canonicalFrameClusterFraction = min(max(0.0, canonicalFrameClusterFraction), 0.5)
        }
    }

    /// Input descriptor for a single deskewed/dewarped page entering Pass 2 harmonization.
    public struct PageInput: Sendable, Equatable, Codable {
        /// Zero-based sequential page index in the output book.
        public let pageIndex: Int
        /// Logical side (`.verso`, `.recto`, or `.single`).
        public let side: PageSide
        /// Dimensions of the physical deskewed/dewarped page raster in pixels.
        public let pageSize: Size2I
        /// Scan resolution in DPI (typically 600).
        public let dpi: Int
        /// Pass 1 content box detection result.
        public let detection: ContentBoxDetector.DetectionResult
        /// Whether the page carries a confirmed running header. Such a page always hangs from the frame top, even
        /// when it holds only a few lines (`false` when header detection is off, and for inputs written before 7.1.1).
        public let hasRunningHeader: Bool

        public init(
            pageIndex: Int,
            side: PageSide,
            pageSize: Size2I,
            dpi: Int = 600,
            detection: ContentBoxDetector.DetectionResult,
            hasRunningHeader: Bool = false
        ) {
            self.pageIndex = pageIndex
            self.side = side
            self.pageSize = pageSize
            self.dpi = dpi
            self.detection = detection
            self.hasRunningHeader = hasRunningHeader
        }

        private enum CodingKeys: String, CodingKey {
            case pageIndex, side, pageSize, dpi, detection, hasRunningHeader
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pageIndex = try c.decode(Int.self, forKey: .pageIndex)
            side = try c.decode(PageSide.self, forKey: .side)
            pageSize = try c.decode(Size2I.self, forKey: .pageSize)
            dpi = try c.decode(Int.self, forKey: .dpi)
            detection = try c.decode(ContentBoxDetector.DetectionResult.self, forKey: .detection)
            hasRunningHeader = try c.decodeIfPresent(Bool.self, forKey: .hasRunningHeader) ?? false
        }
    }

    /// Computed layout plan for a single page on the canonical output canvas.
    public struct PageLayoutPlan: Sendable, Equatable, Codable {
        /// Zero-based sequential page index.
        public let pageIndex: Int
        /// Logical side of the page.
        public let side: PageSide
        /// Assigned 3-tier placement policy.
        public let tier: PlacementTier
        /// Whether Pass 2 canonical-width outlier trimming modified this page's content box.
        public var wasOutlierTrimmed: Bool
        /// Refined content bounding box in the source page's coordinate space (`nil` if blank page).
        public var sourceContentBox: Rect2I?
        /// Retained foreground cluster boxes in source page coordinates.
        public var retainedClusterBoxes: [Rect2I]
        /// Rejected noise cluster boxes in source page coordinates (including any Pass 2 trimmed smudges).
        public let rejectedClusterBoxes: [Rect2I]
        /// Target destination origin `(x, y)` on the canonical output canvas where `sourceContentBox.origin` is placed.
        public var destinationOrigin: Point2I
        /// Target canonical output canvas dimensions in pixels (at `dpi`, typically 600 DPI).
        public var canvasSize: Size2I
        /// For Tier 2 pages, which vertical edge was pinned to the canonical frame (`nil` for
        /// Tiers 1 and 3 and for plans written before Substep 6.1.2).
        public var verticalAnchorEdge: VerticalAnchorEdge?
        /// For dimensional outliers (Substep 6.2.1), the page size this page should get on its own canvas
        /// (`nil` for canonical pages and for plans written before 6.2.1).
        public var proposedCanvasSize: Size2I?

        /// Whether the page was classified as a dimensional outlier.
        public var isDimensionOutlier: Bool { proposedCanvasSize != nil }

        public init(
            pageIndex: Int,
            side: PageSide,
            tier: PlacementTier,
            wasOutlierTrimmed: Bool,
            sourceContentBox: Rect2I?,
            retainedClusterBoxes: [Rect2I],
            rejectedClusterBoxes: [Rect2I],
            destinationOrigin: Point2I,
            canvasSize: Size2I,
            verticalAnchorEdge: VerticalAnchorEdge? = nil,
            proposedCanvasSize: Size2I? = nil
        ) {
            self.verticalAnchorEdge = verticalAnchorEdge
            self.proposedCanvasSize = proposedCanvasSize
            self.pageIndex = pageIndex
            self.side = side
            self.tier = tier
            self.wasOutlierTrimmed = wasOutlierTrimmed
            self.sourceContentBox = sourceContentBox
            self.retainedClusterBoxes = retainedClusterBoxes
            self.rejectedClusterBoxes = rejectedClusterBoxes
            self.destinationOrigin = destinationOrigin
            self.canvasSize = canvasSize
        }
    }

    /// Book-wide harmonization result across all pages.
    public struct BookLayoutModel: Sendable, Equatable, Codable {
        /// Uniform output canvas dimensions in pixels (at processing DPI, typically 600 DPI).
        public let canvasSize: Size2I
        /// Canonical text frame for `.verso` (left) pages on the output canvas.
        public let versoCanonicalFrame: Rect2I
        /// Canonical text frame for `.recto` (right) and `.single` pages on the output canvas.
        public let rectoCanonicalFrame: Rect2I
        /// Per-page layout plans in page order.
        public let pagePlans: [PageLayoutPlan]

        public init(
            canvasSize: Size2I,
            versoCanonicalFrame: Rect2I,
            rectoCanonicalFrame: Rect2I,
            pagePlans: [PageLayoutPlan]
        ) {
            self.canvasSize = canvasSize
            self.versoCanonicalFrame = versoCanonicalFrame
            self.rectoCanonicalFrame = rectoCanonicalFrame
            self.pagePlans = pagePlans
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// The book's body text width that Pass 2 trims wider pages to (before the allowed excess): the explicit
    /// `--content-box-size` width, or the 75th percentile of the IQR-filtered widths of the pages' content boxes,
    /// leaving out boxes narrower than 35 % of the median page width when there are wider ones.
    /// - Parameter pages: The pages that share the book's size (dimensional outliers left out).
    /// - Returns: The width in pixels at the pages' DPI.
    public func canonicalWidthPrior(_ pages: [PageInput]) -> Int {
        guard let first = pages.first else { return 1 }
        let referenceDPI = max(72, first.dpi)
        if let explicitBox = configuration.targetContentBoxSize?.sizeInPixels(atDPI: referenceDPI) {
            return max(1, explicitBox.width)
        }
        let rawBoxes = pages.compactMap(\.detection.contentBox).filter { !$0.isEmpty }
        let medianPageWidth = Self.percentileInt(pages.map(\.pageSize.width), p: 0.50) ?? first.pageSize.width
        let substantialWidths = rawBoxes.map(\.width).filter { $0 >= medianPageWidth * 35 / 100 }
        let widthSamplesForPrior = substantialWidths.isEmpty ? rawBoxes.map(\.width) : substantialWidths
        let filteredWidthSamples = Self.filterOutliersIQR(
            widthSamplesForPrior,
            maxDeviationFraction: configuration.canonicalDimensionOutlierToleranceFraction,
            iqrMultiplier: configuration.canonicalDimensionIQROutlierMultiplier
        )
        return Self.percentileInt(filteredWidthSamples, p: 0.75) ?? (medianPageWidth * 70 / 100)
    }

    /// Performs Pass 2 book-wide statistical outlier rejection, estimates canonical text frames,
    /// and classifies & positions every page according to the 3-tier layout policy.
    ///
    /// - Parameter dimensionOutliers: Page indices classified as dimensional outliers (Substep 6.2.1). They are
    ///   left out of the median page size and the canonical frame, and are forced to Tier 3 with
    ///   `proposedCanvasSize` set to `outlierCanvasSizes[pageIndex]` (or their own size). When fewer than three
    ///   canonical pages (`minimumCanonicalPages`, 1 for a manual list) would remain, the set is ignored.
    /// - Parameter forcedTiers: Tiers an agent or user fixed for specific pages (Substep 6.3.1), keyed by page index.
    ///   A forced page is placed by its tier's rule whatever its measured size; automatic classification is skipped for it.
    public func harmonizeBook(
        pages: [PageInput],
        detector: ContentBoxDetector = ContentBoxDetector(),
        dimensionOutliers: Set<Int> = [],
        outlierCanvasSizes: [Int: Size2I] = [:],
        minimumCanonicalPages: Int = 3,
        forcedTiers: [Int: PlacementTier] = [:]
    ) -> BookLayoutModel {
        guard !pages.isEmpty else {
            if configuration.targetPageSize == nil && configuration.targetContentBoxSize == nil {
                let fallbackCanvas = Size2I(width: 3000, height: 4500)
                let fallbackFrame = Rect2I(x: 300, y: 360, width: 2400, height: 3780)
                return BookLayoutModel(
                    canvasSize: fallbackCanvas,
                    versoCanonicalFrame: fallbackFrame,
                    rectoCanonicalFrame: fallbackFrame,
                    pagePlans: []
                )
            }
            let fallbackDPI = 600
            let (vTop, vBot) = configuration.margins.verticalMargins(dpi: fallbackDPI)
            let vHoriz = configuration.margins.horizontalMargins(for: .verso, dpi: fallbackDPI)
            let rHoriz = configuration.margins.horizontalMargins(for: .recto, dpi: fallbackDPI)
            let explicitPage = configuration.targetPageSize?.sizeInPixels(atDPI: fallbackDPI)
            let explicitBox = configuration.targetContentBoxSize?.sizeInPixels(atDPI: fallbackDPI)
            let textW = explicitBox?.width ?? max(1, (explicitPage?.width ?? 3000) - min(vHoriz.left + vHoriz.right, rHoriz.left + rHoriz.right))
            let textH = explicitBox?.height ?? max(1, (explicitPage?.height ?? 4500) - (vTop + vBot))
            let canvasW = explicitPage?.width ?? max(textW + vHoriz.left + vHoriz.right, textW + rHoriz.left + rHoriz.right)
            let canvasH = explicitPage?.height ?? (textH + vTop + vBot)
            let clampedTextW = min(max(1, canvasW), max(1, textW))
            let clampedTextH = min(max(1, canvasH), max(1, textH))
            let topY = Self.proportionalOrigin(span: clampedTextH, canvasSpan: max(1, canvasH), leadingMargin: vTop, trailingMargin: vBot)
            let versoX = Self.proportionalOrigin(span: clampedTextW, canvasSpan: max(1, canvasW), leadingMargin: vHoriz.left, trailingMargin: vHoriz.right)
            let rectoX = Self.proportionalOrigin(span: clampedTextW, canvasSpan: max(1, canvasW), leadingMargin: rHoriz.left, trailingMargin: rHoriz.right)
            return BookLayoutModel(
                canvasSize: Size2I(width: max(1, canvasW), height: max(1, canvasH)),
                versoCanonicalFrame: Rect2I(x: versoX, y: topY, width: clampedTextW, height: clampedTextH),
                rectoCanonicalFrame: Rect2I(x: rectoX, y: topY, width: clampedTextW, height: clampedTextH),
                pagePlans: []
            )
        }

        let referenceDPI = max(72, pages[0].dpi)
        let (topMargin, bottomMargin) = configuration.margins.verticalMargins(dpi: referenceDPI)
        let versoMargins = configuration.margins.horizontalMargins(for: .verso, dpi: referenceDPI)
        let rectoMargins = configuration.margins.horizontalMargins(for: .recto, dpi: referenceDPI)

        let minHMargin = min(versoMargins.left + versoMargins.right, rectoMargins.left + rectoMargins.right)
        let minVMargin = topMargin + bottomMargin

        let explicitCanvasSize = configuration.targetPageSize?.sizeInPixels(atDPI: referenceDPI)
        let explicitContentBoxSize = configuration.targetContentBoxSize?.sizeInPixels(atDPI: referenceDPI)

        // Step 1: Collect raw non-empty content widths and heights to estimate the 75th-percentile
        // canonical width prior for Pass 2 smudge outlier rejection (or use explicit `--content-box-size` width).
        let canonicalCandidates = pages.filter { !dimensionOutliers.contains($0.pageIndex) }
        let outlierSet: Set<Int> = canonicalCandidates.count >= minimumCanonicalPages ? dimensionOutliers : []
        let statPages = outlierSet.isEmpty ? pages : canonicalCandidates
        let medianPageWidth = Self.percentileInt(statPages.map(\.pageSize.width), p: 0.50) ?? pages[0].pageSize.width
        let medianPageHeight = Self.percentileInt(statPages.map(\.pageSize.height), p: 0.50) ?? pages[0].pageSize.height
        let priorCanonicalWidth = canonicalWidthPrior(statPages)

        // Step 2: Run Pass 2 outlier refinement on any page whose raw content box exceeds
        // priorCanonicalWidth * (1 + pass2OutlierWidthExcessFraction).
        var refinedDetections: [ContentBoxDetector.DetectionResult] = []
        var outlierTrimFlags: [Bool] = []
        refinedDetections.reserveCapacity(pages.count)
        outlierTrimFlags.reserveCapacity(pages.count)

        for page in pages {
            // A dimensional outlier keeps its whole text block: its width is not the book's width.
            let refined = outlierSet.contains(page.pageIndex) ? page.detection : detector.refineWithCanonicalWidthPrior(
                page.detection,
                canonicalWidth: priorCanonicalWidth,
                maxWidthExcessFraction: configuration.pass2OutlierWidthExcessFraction
            )
            let trimmed = (refined.contentBox != page.detection.contentBox)
            refinedDetections.append(refined)
            outlierTrimFlags.append(trimmed)
        }

        // Step 3: The canonical text block is the largest refined body box of the main size cluster (unless
        // overridden via `targetContentBoxSize`), so the widest clean page touches the side margins and the tallest
        // touches the top and bottom margins. IQR and median-deviation rejection keep title pages and foldouts out;
        // the cluster keeps out boxes inflated by gutter shadows or scan-edge ink.
        let refinedBoxes = pages.indices
            .filter { !outlierSet.contains(pages[$0].pageIndex) }
            .compactMap { refinedDetections[$0].contentBox }
            .filter { !$0.isEmpty }
        let bodyCandidateBoxes = refinedBoxes.filter { box in
            box.width >= priorCanonicalWidth * 75 / 100
        }
        let referenceBoxes = bodyCandidateBoxes.isEmpty ? refinedBoxes : bodyCandidateBoxes

        let candidateWidths = referenceBoxes.map(\.width)
        let candidateHeights = referenceBoxes.map(\.height)

        let filteredWidths = Self.filterOutliersIQR(
            candidateWidths,
            maxDeviationFraction: configuration.canonicalDimensionOutlierToleranceFraction,
            iqrMultiplier: configuration.canonicalDimensionIQROutlierMultiplier
        )
        let filteredHeights = Self.filterOutliersIQR(
            candidateHeights,
            maxDeviationFraction: configuration.canonicalDimensionOutlierToleranceFraction,
            iqrMultiplier: configuration.canonicalDimensionIQROutlierMultiplier
        )

        let fallbackBaseWidth = explicitCanvasSize?.width ?? medianPageWidth
        let fallbackBaseHeight = explicitCanvasSize?.height ?? medianPageHeight
        let rawCanonicalTextWidth = explicitContentBoxSize?.width
            ?? Self.largestInMainCluster(filteredWidths, windowFraction: configuration.canonicalFrameClusterFraction)
            ?? max(1, fallbackBaseWidth - minHMargin)
        let rawCanonicalTextHeight = explicitContentBoxSize?.height
            ?? Self.largestInMainCluster(filteredHeights, windowFraction: configuration.canonicalFrameClusterFraction)
            ?? max(1, fallbackBaseHeight - minVMargin)

        let canvasSize: Size2I
        let canonicalTextWidth: Int
        let canonicalTextHeight: Int
        let canonicalTopY: Int
        let versoLeftX: Int
        let rectoLeftX: Int

        if let explicitCanvas = explicitCanvasSize {
            let canvasW = max(1, explicitCanvas.width)
            let canvasH = max(1, explicitCanvas.height)
            canvasSize = Size2I(width: canvasW, height: canvasH)
            canonicalTextWidth = min(canvasW, max(1, rawCanonicalTextWidth))
            canonicalTextHeight = min(canvasH, max(1, rawCanonicalTextHeight))
            canonicalTopY = Self.proportionalOrigin(
                span: canonicalTextHeight,
                canvasSpan: canvasH,
                leadingMargin: topMargin,
                trailingMargin: bottomMargin
            )
            versoLeftX = Self.proportionalOrigin(
                span: canonicalTextWidth,
                canvasSpan: canvasW,
                leadingMargin: versoMargins.left,
                trailingMargin: versoMargins.right
            )
            rectoLeftX = Self.proportionalOrigin(
                span: canonicalTextWidth,
                canvasSpan: canvasW,
                leadingMargin: rectoMargins.left,
                trailingMargin: rectoMargins.right
            )
        } else {
            // The canvas hugs the text block: the block plus the configured margins, whatever the scanned paper size.
            canonicalTextWidth = max(1, rawCanonicalTextWidth)
            canonicalTextHeight = max(1, rawCanonicalTextHeight)
            let neededVersoW = canonicalTextWidth + versoMargins.left + versoMargins.right
            let neededRectoW = canonicalTextWidth + rectoMargins.left + rectoMargins.right
            let canvasW = max(1, max(neededVersoW, neededRectoW))
            let canvasH = max(1, canonicalTextHeight + topMargin + bottomMargin)
            canvasSize = Size2I(width: canvasW, height: canvasH)
            canonicalTopY = topMargin
            versoLeftX = versoMargins.left
            rectoLeftX = rectoMargins.left
        }

        let versoFrame = Rect2I(
            x: versoLeftX,
            y: canonicalTopY,
            width: canonicalTextWidth,
            height: canonicalTextHeight
        )
        let rectoFrame = Rect2I(
            x: rectoLeftX,
            y: canonicalTopY,
            width: canonicalTextWidth,
            height: canonicalTextHeight
        )

        // Step 4: Where the text block sits on the scans, per side: the median edges of the full-size body boxes.
        // Partial and floating pages are placed relative to it, so binding offsets and uneven crops do not move them.
        func isFullSize(_ box: Rect2I) -> Bool {
            abs(Double(box.width - canonicalTextWidth)) / Double(canonicalTextWidth) <= configuration.fullWidthToleranceFraction
                && abs(Double(box.height - canonicalTextHeight)) / Double(canonicalTextHeight) <= configuration.fullHeightToleranceFraction
        }
        func medianFrame(_ boxes: [Rect2I]) -> Rect2I? {
            guard let minX = Self.percentileInt(boxes.map(\.minX), p: 0.5),
                  let minY = Self.percentileInt(boxes.map(\.minY), p: 0.5),
                  let maxX = Self.percentileInt(boxes.map(\.maxX), p: 0.5),
                  let maxY = Self.percentileInt(boxes.map(\.maxY), p: 0.5) else { return nil }
            return Rect2I(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
        }
        var fullSizeBoxesBySide: [PageSide: [Rect2I]] = [:]
        for (idx, page) in pages.enumerated() where !outlierSet.contains(page.pageIndex) {
            if let box = refinedDetections[idx].contentBox, !box.isEmpty, isFullSize(box) {
                fullSizeBoxesBySide[page.side, default: []].append(box)
            }
        }
        let pooledSourceFrame = medianFrame(fullSizeBoxesBySide.values.flatMap { $0 })
        let sourceFramesBySide = fullSizeBoxesBySide.compactMapValues { medianFrame($0) }
        func sourceFrame(for page: PageInput) -> Rect2I {
            if let frame = sourceFramesBySide[page.side] ?? pooledSourceFrame { return frame }
            // No full-size body page at all: assume the text block is centered on the scan.
            return Rect2I(
                x: (page.pageSize.width - canonicalTextWidth) / 2,
                y: (page.pageSize.height - canonicalTextHeight) / 2,
                width: canonicalTextWidth,
                height: canonicalTextHeight
            )
        }
        let edgeAnchorTolerance = max(24, Int((Double(canonicalTextHeight) * 0.12).rounded()))
        let centeredTolerance = max(referenceDPI * 3 / 10, canonicalTextWidth * 8 / 100)

        // Step 5: Classify each page into Tier 1, Tier 2, or Tier 3 and compute its target origin. Every page is
        // centered left to right in its frame, except a floating page whose text sits off to one side.
        var plans: [PageLayoutPlan] = []
        plans.reserveCapacity(pages.count)

        for (idx, page) in pages.enumerated() {
            let det = refinedDetections[idx]
            let targetFrame = (page.side == .verso) ? versoFrame : rectoFrame

            guard let box = det.contentBox, !box.isEmpty else {
                plans.append(
                    PageLayoutPlan(
                        pageIndex: page.pageIndex,
                        side: page.side,
                        tier: .standaloneFloating,
                        wasOutlierTrimmed: outlierTrimFlags[idx],
                        sourceContentBox: nil,
                        retainedClusterBoxes: [],
                        rejectedClusterBoxes: det.rejectedBoxes,
                        destinationOrigin: Point2I(x: targetFrame.minX, y: targetFrame.minY),
                        canvasSize: canvasSize,
                        proposedCanvasSize: outlierSet.contains(page.pageIndex)
                            ? (outlierCanvasSizes[page.pageIndex] ?? page.pageSize) : nil
                    )
                )
                continue
            }

            let widthRatioDiff = abs(Double(box.width - targetFrame.width)) / Double(max(1, targetFrame.width))
            let heightRatioDiff = abs(Double(box.height - targetFrame.height)) / Double(max(1, targetFrame.height))
            let heightRatio = Double(box.height) / Double(max(1, targetFrame.height))

            let isOutlier = outlierSet.contains(page.pageIndex)
            let forcedTier = forcedTiers[page.pageIndex]
            let hasHeader = page.hasRunningHeader && !isOutlier
            let matchesCanonicalWidth = !isOutlier && widthRatioDiff <= configuration.fullWidthToleranceFraction
            let matchesCanonicalHeight = !isOutlier && heightRatioDiff <= configuration.fullHeightToleranceFraction
            let tier: PlacementTier = forcedTier ?? {
                if matchesCanonicalWidth && matchesCanonicalHeight { return .fullBody }
                // A page with a running header always hangs from the top, however little text it has.
                if hasHeader { return .edgeAnchoredPartial }
                if matchesCanonicalWidth && heightRatio >= configuration.minPartialHeightFraction && box.height < targetFrame.height {
                    return .edgeAnchoredPartial
                }
                return .standaloneFloating
            }()

            let source = sourceFrame(for: page)
            let centeredX = Self.clampOrigin(
                targetFrame.minX + (targetFrame.width - box.width) / 2, span: box.width, canvasSpan: canvasSize.width
            )
            let topY = Self.clampOrigin(targetFrame.minY, span: box.height, canvasSpan: canvasSize.height)
            let naturalY = Self.clampOrigin(
                targetFrame.minY + (box.minY - source.minY), span: box.height, canvasSpan: canvasSize.height
            )
            let destOrigin: Point2I
            var anchorEdge: VerticalAnchorEdge? = nil

            switch tier {
            case .fullBody:
                // Tier 1 — full body page: centered, top on the frame top, so headers stay put across page turns.
                destOrigin = Point2I(x: centeredX, y: topY)
            case .edgeAnchoredPartial:
                // Tier 2 — partial page. A header page hangs from the top; otherwise a block that reaches the foot of
                // the text block (a chapter opening) sits on the frame bottom, and one that starts at its head (a
                // chapter ending) hangs from the top. Anything else keeps its natural height.
                let topDistance = abs(box.minY - source.minY)
                let bottomDistance = abs(box.maxY - source.maxY)
                if hasHeader {
                    anchorEdge = .top
                    destOrigin = Point2I(x: centeredX, y: topY)
                } else if bottomDistance <= topDistance && bottomDistance <= edgeAnchorTolerance {
                    anchorEdge = .bottom
                    let anchoredY = Self.clampOrigin(targetFrame.maxY - box.height, span: box.height, canvasSpan: canvasSize.height)
                    destOrigin = Point2I(x: centeredX, y: anchoredY)
                } else if topDistance <= edgeAnchorTolerance {
                    anchorEdge = .top
                    destOrigin = Point2I(x: centeredX, y: topY)
                } else {
                    anchorEdge = .natural
                    destOrigin = Point2I(x: centeredX, y: naturalY)
                }
            case .standaloneFloating:
                // Tier 3 — title pages, dedications, dividers, ornaments: keep the offset from the scan's text block.
                // Text centered on the scan stays centered; text off to one side keeps its offset from the center.
                let offsetFromCenter = (box.minX + box.width / 2) - (source.minX + source.width / 2)
                let x = abs(offsetFromCenter) <= centeredTolerance
                    ? centeredX
                    : Self.clampOrigin(
                        targetFrame.minX + targetFrame.width / 2 + offsetFromCenter - box.width / 2,
                        span: box.width, canvasSpan: canvasSize.width
                    )
                destOrigin = Point2I(x: x, y: naturalY)
            }

            plans.append(
                PageLayoutPlan(
                    pageIndex: page.pageIndex,
                    side: page.side,
                    tier: tier,
                    wasOutlierTrimmed: outlierTrimFlags[idx],
                    sourceContentBox: box,
                    retainedClusterBoxes: det.retainedClusters.map(\.exactBounds),
                    rejectedClusterBoxes: det.rejectedBoxes,
                    destinationOrigin: destOrigin,
                    canvasSize: canvasSize,
                    verticalAnchorEdge: anchorEdge,
                    proposedCanvasSize: isOutlier ? (outlierCanvasSizes[page.pageIndex] ?? page.pageSize) : nil
                )
            )
        }

        return BookLayoutModel(
            canvasSize: canvasSize,
            versoCanonicalFrame: versoFrame,
            rectoCanonicalFrame: rectoFrame,
            pagePlans: plans
        )
    }

    /// Renders a cleaned & harmonized 600 DPI `BinaryBitmap` on the canonical canvas according to `plan`.
    ///
    /// Only foreground pixels inside `plan.retainedClusterBoxes` (or `plan.sourceContentBox` when
    /// cluster boxes are empty) are copied to their harmonized position on the pure-white output canvas,
    /// guaranteeing that rejected margin noise and Pass 2 trimmed smudges are completely erased.
    public func renderPage(
        from sourceBitmap: borrowing BinaryBitmap,
        plan: PageLayoutPlan
    ) -> BinaryBitmap {
        let canvasW = max(1, plan.canvasSize.width)
        let canvasH = max(1, plan.canvasSize.height)
        var canvas = BinaryBitmap(width: canvasW, height: canvasH, initialBlack: false)

        guard let contentBox = plan.sourceContentBox, !contentBox.isEmpty else {
            return canvas
        }

        if !plan.retainedClusterBoxes.isEmpty {
            for clusterBox in plan.retainedClusterBoxes {
                guard let clampedCluster = clusterBox.clamped(to: contentBox) else { continue }
                let patch = sourceBitmap.cropped(to: clampedCluster)
                let destPt = Point2I(
                    x: plan.destinationOrigin.x + (clampedCluster.minX - contentBox.minX),
                    y: plan.destinationOrigin.y + (clampedCluster.minY - contentBox.minY)
                )
                canvas.blit(from: patch, at: destPt, blendMode: .or)
            }
        } else {
            let patch = sourceBitmap.cropped(to: contentBox)
            canvas.blit(from: patch, at: plan.destinationOrigin, blendMode: .replace)
        }

        return canvas
    }

    // MARK: - Statistical Helpers

    /// Filters an array of integer dimensions using Interquartile Range (IQR) and median deviation rules.
    ///
    /// Values outside `[Q1 - iqrMultiplier * IQR, Q3 + iqrMultiplier * IQR]` or deviating by more than
    /// `maxDeviationFraction` from the median are rejected.
    /// If all values would be rejected (e.g. extremely small or dispersed sample), returns the input values unchanged.
    public static func filterOutliersIQR(
        _ values: [Int],
        maxDeviationFraction: Double = 0.25,
        iqrMultiplier: Double = 1.5
    ) -> [Int] {
        guard values.count >= 3 else { return values }
        let sorted = values.sorted()
        guard let q1 = percentileInt(sorted, p: 0.25),
              let median = percentileInt(sorted, p: 0.50),
              let q3 = percentileInt(sorted, p: 0.75),
              median > 0 else {
            return values
        }

        let rawIQR = Double(max(0, q3 - q1))
        // Protect against zero/near-zero IQR in highly uniform pages by establishing a minimum scale proportional to the median.
        let effectiveIQR = max(rawIQR, Double(median) * 0.05)
        let lowerFence = Double(q1) - iqrMultiplier * effectiveIQR
        let upperFence = Double(q3) + iqrMultiplier * effectiveIQR
        let maxDeviation = Double(median) * maxDeviationFraction

        let filtered = sorted.filter { val in
            let dVal = Double(val)
            let withinIQRFence = dVal >= lowerFence && dVal <= upperFence
            let withinMedianTolerance = abs(dVal - Double(median)) <= maxDeviation
            return withinIQRFence && withinMedianTolerance
        }

        return filtered.isEmpty ? values : filtered
    }

    /// Returns the largest value of the densest cluster: the window `[v, v × (1 + windowFraction)]` holding the most
    /// values (ties go to the larger window).
    ///
    /// Printed text blocks share one size, so full pages bunch together while boxes swollen by noise spread out
    /// above them. When no two values share a window, the plain maximum is returned.
    /// - Returns: `nil` for an empty input.
    public static func largestInMainCluster(_ values: [Int], windowFraction: Double) -> Int? {
        let sorted = values.sorted()
        guard let maximum = sorted.last else { return nil }
        var best: (count: Int, top: Int)? = nil
        var end = 0
        for (start, low) in sorted.enumerated() {
            let limit = Double(low) * (1 + windowFraction)
            end = max(end, start)
            while end + 1 < sorted.count && Double(sorted[end + 1]) <= limit { end += 1 }
            let candidate = (count: end - start + 1, top: sorted[end])
            if let b = best, (candidate.count, candidate.top) < (b.count, b.top) { continue }
            best = candidate
        }
        guard let best, best.count >= 2 else { return maximum }
        return best.top
    }

    private static func percentileInt(_ values: [Int], p: Double) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clampedP = min(max(0.0, p), 1.0)
        let pos = clampedP * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Int(pos.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = pos - Double(lo)
        return Int((Double(sorted[lo]) * (1.0 - frac) + Double(sorted[hi]) * frac).rounded())
    }

    private static func clampOrigin(_ origin: Int, span: Int, canvasSpan: Int) -> Int {
        guard canvasSpan > span else { return 0 }
        return min(max(0, origin), canvasSpan - span)
    }

    private static func proportionalOrigin(
        span: Int,
        canvasSpan: Int,
        leadingMargin: Int,
        trailingMargin: Int
    ) -> Int {
        let remaining = max(0, canvasSpan - span)
        let marginSum = max(0, leadingMargin) + max(0, trailingMargin)
        guard marginSum > 0 else {
            return remaining / 2
        }
        let rawOrigin = Int((Double(remaining) * Double(max(0, leadingMargin)) / Double(marginSum)).rounded())
        return clampOrigin(rawOrigin, span: span, canvasSpan: canvasSpan)
    }
}
