import ScanTailorContracts

/// Book-wide statistical margin harmonizer and 3-tier page positioning engine.
///
/// Establishes canonical Verso/Recto text frames across a multi-page book, runs Pass 2
/// canonical-width outlier rejection to trim stray margin smudges, and positions each page
/// according to the 3-tier policy:
/// - **Tier 1 (`fullBody`)**: Locks full-body text pages to the canonical text frame so margins
///   and running headers remain steady across page turns.
/// - **Tier 2 (`edgeAnchoredPartial`)**: Anchors matching edges on partial pages (e.g. chapter
///   openings with top sinkage or chapter endings with bottom whitespace) while preserving natural
///   sinkage on the free edge.
/// - **Tier 3 (`standaloneFloating`)**: Preserves the natural page-relative coordinates of
///   standalone title pages, half-titles, chapter dividers, epigraphs, and ornaments rather than
///   force-centering or pushing them to the top/bottom margin.
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
        /// Optional explicit canonical text block size (`--content-box-size`), overriding statistical 85th-percentile estimation.
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
            canonicalDimensionIQROutlierMultiplier: Double = 1.5
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

        public init(
            pageIndex: Int,
            side: PageSide,
            pageSize: Size2I,
            dpi: Int = 600,
            detection: ContentBoxDetector.DetectionResult
        ) {
            self.pageIndex = pageIndex
            self.side = side
            self.pageSize = pageSize
            self.dpi = dpi
            self.detection = detection
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
        public let canvasSize: Size2I
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

    /// Performs Pass 2 book-wide statistical outlier rejection, estimates canonical text frames,
    /// and classifies & positions every page according to the 3-tier layout policy.
    ///
    /// - Parameter dimensionOutliers: Page indices classified as dimensional outliers (Substep 6.2.1). They are
    ///   left out of the median page size and the canonical frame, and are forced to Tier 3 with
    ///   `proposedCanvasSize` set to `outlierCanvasSizes[pageIndex]` (or their own size). When fewer than three
    ///   canonical pages would remain, the set is ignored.
    public func harmonizeBook(
        pages: [PageInput],
        detector: ContentBoxDetector = ContentBoxDetector(),
        dimensionOutliers: Set<Int> = [],
        outlierCanvasSizes: [Int: Size2I] = [:]
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
        let outlierSet: Set<Int> = canonicalCandidates.count >= 3 ? dimensionOutliers : []
        let statPages = outlierSet.isEmpty ? pages : canonicalCandidates
        let rawBoxes = statPages.compactMap(\.detection.contentBox).filter { !$0.isEmpty }
        let medianPageWidth = Self.percentileInt(statPages.map(\.pageSize.width), p: 0.50) ?? pages[0].pageSize.width
        let medianPageHeight = Self.percentileInt(statPages.map(\.pageSize.height), p: 0.50) ?? pages[0].pageSize.height

        let priorCanonicalWidth: Int
        if let explicitBox = explicitContentBoxSize {
            priorCanonicalWidth = max(1, explicitBox.width)
        } else {
            // Filter out tiny standalone boxes (e.g., < 35% of page width) when computing the body-width prior
            // if substantial body pages exist.
            let substantialWidths = rawBoxes.map(\.width).filter { $0 >= medianPageWidth * 35 / 100 }
            let widthSamplesForPrior = substantialWidths.isEmpty ? rawBoxes.map(\.width) : substantialWidths
            let filteredWidthSamples = Self.filterOutliersIQR(
                widthSamplesForPrior,
                maxDeviationFraction: configuration.canonicalDimensionOutlierToleranceFraction,
                iqrMultiplier: configuration.canonicalDimensionIQROutlierMultiplier
            )
            priorCanonicalWidth = Self.percentileInt(filteredWidthSamples, p: 0.75) ?? (medianPageWidth * 70 / 100)
        }

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

        // Step 3: Estimate canonical text width W_canon and height H_canon from the 85th percentile
        // of refined body-candidate boxes (unless overridden via `targetContentBoxSize`), with IQR and
        // median deviation outlier rejection to prevent standalone title pages or oversize foldouts from
        // expanding the canonical text frame.
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
            ?? Self.percentileInt(filteredWidths, p: 0.85)
            ?? max(1, fallbackBaseWidth - minHMargin)
        let rawCanonicalTextHeight = explicitContentBoxSize?.height
            ?? Self.percentileInt(filteredHeights, p: 0.85)
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
        } else if explicitContentBoxSize != nil {
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
        } else {
            canonicalTextWidth = max(1, rawCanonicalTextWidth)
            canonicalTextHeight = max(1, rawCanonicalTextHeight)
            // Determine uniform output canvas size:
            // Large enough to accommodate the median physical page size and the canonical text block + configured margins.
            let neededVersoW = canonicalTextWidth + versoMargins.left + versoMargins.right
            let neededRectoW = canonicalTextWidth + rectoMargins.left + rectoMargins.right
            let canvasWidth = max(medianPageWidth, max(neededVersoW, neededRectoW))
            let canvasHeight = max(medianPageHeight, canonicalTextHeight + topMargin + bottomMargin)
            canvasSize = Size2I(width: max(1, canvasWidth), height: max(1, canvasHeight))
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

        // Step 4: Classify each page into Tier 1, Tier 2, or Tier 3 and compute its target origin.
        var plans: [PageLayoutPlan] = []
        plans.reserveCapacity(pages.count)

        for (idx, page) in pages.enumerated() {
            let det = refinedDetections[idx]
            let targetFrame = (page.side == .verso) ? versoFrame : rectoFrame

            // Physical-to-canvas reference offset (maps physical page center to canonical canvas center).
            let physicalOffsetX = (canvasSize.width - page.pageSize.width) / 2
            let physicalOffsetY = (canvasSize.height - page.pageSize.height) / 2

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
            let matchesCanonicalWidth = !isOutlier && widthRatioDiff <= configuration.fullWidthToleranceFraction
            let matchesCanonicalHeight = !isOutlier && heightRatioDiff <= configuration.fullHeightToleranceFraction

            let tier: PlacementTier
            let destOrigin: Point2I
            var anchorEdge: VerticalAnchorEdge? = nil

            if matchesCanonicalWidth && matchesCanonicalHeight {
                // Tier 1 — Full Body Page:
                // Lock to the canonical text frame origin so left/right margins and running headers
                // stay rock-steady across page turns.
                tier = .fullBody
                destOrigin = Point2I(
                    x: Self.clampOrigin(targetFrame.minX, span: box.width, canvasSpan: canvasSize.width),
                    y: Self.clampOrigin(targetFrame.minY, span: box.height, canvasSpan: canvasSize.height)
                )
            } else if !isOutlier && matchesCanonicalWidth && heightRatio >= configuration.minPartialHeightFraction && box.height < targetFrame.height {
                // Tier 2 — Edge-Anchored Partial Page (e.g. chapter start with top sinkage or chapter end):
                // Compare how closely the physical top edge vs. physical bottom edge of `box` matches `targetFrame`.
                let naturalTopY = box.minY + physicalOffsetY
                let naturalBottomY = box.maxY + physicalOffsetY

                let topDistToCanon = abs(naturalTopY - targetFrame.minY)
                let bottomDistToCanon = abs(naturalBottomY - targetFrame.maxY)
                let edgeAnchorTol = max(24, Int((Double(targetFrame.height) * 0.12).rounded()))

                if bottomDistToCanon <= topDistToCanon && bottomDistToCanon <= edgeAnchorTol {
                    // Chapter opening with top sinkage: anchor bottom edge to targetFrame.maxY
                    // (preserving natural top sinkage!).
                    tier = .edgeAnchoredPartial
                    anchorEdge = .bottom
                    let anchoredY = Self.clampOrigin(
                        targetFrame.maxY - box.height,
                        span: box.height,
                        canvasSpan: canvasSize.height
                    )
                    destOrigin = Point2I(x: targetFrame.minX, y: anchoredY)
                } else if topDistToCanon <= edgeAnchorTol {
                    // Chapter ending with bottom whitespace: anchor top edge to targetFrame.minY.
                    tier = .edgeAnchoredPartial
                    anchorEdge = .top
                    destOrigin = Point2I(x: targetFrame.minX, y: targetFrame.minY)
                } else {
                    // Full-width block floating vertically at a custom position: keep natural Y, lock X to canonical margin.
                    tier = .edgeAnchoredPartial
                    anchorEdge = .natural
                    let clampedY = Self.clampOrigin(naturalTopY, span: box.height, canvasSpan: canvasSize.height)
                    destOrigin = Point2I(x: targetFrame.minX, y: clampedY)
                }
            } else {
                // Tier 3 — Standalone / Floating Page (title pages, half-titles, chapter dividers,
                // epigraphs, dedications, colophons, ornaments):
                // Preserve where the content naturally sits relative to the physical page reference frame,
                // clamping only if needed to prevent clipping.
                tier = .standaloneFloating
                let naturalX = Self.clampOrigin(
                    box.minX + physicalOffsetX,
                    span: box.width,
                    canvasSpan: canvasSize.width
                )
                let naturalY = Self.clampOrigin(
                    box.minY + physicalOffsetY,
                    span: box.height,
                    canvasSpan: canvasSize.height
                )
                destOrigin = Point2I(x: naturalX, y: naturalY)
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
