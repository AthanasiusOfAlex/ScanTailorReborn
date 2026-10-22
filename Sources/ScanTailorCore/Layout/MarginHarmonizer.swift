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

    public struct Configuration: Sendable, Equatable {
        /// Horizontal margin padding in pixels (at 600 DPI) around the canonical text block when auto-sizing the output canvas.
        public var canonicalHorizontalMarginAt600DPI: Int
        /// Vertical margin padding in pixels (at 600 DPI) around the canonical text block when auto-sizing the output canvas.
        public var canonicalVerticalMarginAt600DPI: Int
        /// Maximum fractional width deviation from `canonicalFrame.width` for a page to qualify as full-width (`Tier 1` or `Tier 2`).
        public var fullWidthToleranceFraction: Double
        /// Maximum fractional height deviation from `canonicalFrame.height` for a page to qualify as `Tier 1 (fullBody)`.
        public var fullHeightToleranceFraction: Double
        /// Minimum fraction of `canonicalFrame.height` required for a full-width partial page to qualify as `Tier 2 (edgeAnchoredPartial)`.
        public var minPartialHeightFraction: Double
        /// Maximum fractional width excess above the 75th-percentile content width before Pass 2 outlier trimming triggers.
        public var pass2OutlierWidthExcessFraction: Double

        public init(
            canonicalHorizontalMarginAt600DPI: Int = 300,
            canonicalVerticalMarginAt600DPI: Int = 360,
            fullWidthToleranceFraction: Double = 0.08,
            fullHeightToleranceFraction: Double = 0.08,
            minPartialHeightFraction: Double = 0.22,
            pass2OutlierWidthExcessFraction: Double = 0.10
        ) {
            self.canonicalHorizontalMarginAt600DPI = max(0, canonicalHorizontalMarginAt600DPI)
            self.canonicalVerticalMarginAt600DPI = max(0, canonicalVerticalMarginAt600DPI)
            self.fullWidthToleranceFraction = min(max(0.01, fullWidthToleranceFraction), 0.30)
            self.fullHeightToleranceFraction = min(max(0.01, fullHeightToleranceFraction), 0.30)
            self.minPartialHeightFraction = min(max(0.05, minPartialHeightFraction), 0.85)
            self.pass2OutlierWidthExcessFraction = min(max(0.02, pass2OutlierWidthExcessFraction), 0.50)
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
        public let wasOutlierTrimmed: Bool
        /// Refined content bounding box in the source page's coordinate space (`nil` if blank page).
        public let sourceContentBox: Rect2I?
        /// Retained foreground cluster boxes in source page coordinates.
        public let retainedClusterBoxes: [Rect2I]
        /// Rejected noise cluster boxes in source page coordinates (including any Pass 2 trimmed smudges).
        public let rejectedClusterBoxes: [Rect2I]
        /// Target destination origin `(x, y)` on the canonical output canvas where `sourceContentBox.origin` is placed.
        public let destinationOrigin: Point2I
        /// Target canonical output canvas dimensions in pixels (at `dpi`, typically 600 DPI).
        public let canvasSize: Size2I

        public init(
            pageIndex: Int,
            side: PageSide,
            tier: PlacementTier,
            wasOutlierTrimmed: Bool,
            sourceContentBox: Rect2I?,
            retainedClusterBoxes: [Rect2I],
            rejectedClusterBoxes: [Rect2I],
            destinationOrigin: Point2I,
            canvasSize: Size2I
        ) {
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
    public func harmonizeBook(
        pages: [PageInput],
        detector: ContentBoxDetector = ContentBoxDetector()
    ) -> BookLayoutModel {
        guard !pages.isEmpty else {
            let fallbackCanvas = Size2I(width: 3000, height: 4500)
            let fallbackFrame = Rect2I(x: 300, y: 360, width: 2400, height: 3780)
            return BookLayoutModel(
                canvasSize: fallbackCanvas,
                versoCanonicalFrame: fallbackFrame,
                rectoCanonicalFrame: fallbackFrame,
                pagePlans: []
            )
        }

        let referenceDPI = max(72, pages[0].dpi)
        let dpiScale = Double(referenceDPI) / 600.0
        let hMargin = Int((Double(configuration.canonicalHorizontalMarginAt600DPI) * dpiScale).rounded())
        let vMargin = Int((Double(configuration.canonicalVerticalMarginAt600DPI) * dpiScale).rounded())

        // Step 1: Collect raw non-empty content widths and heights to estimate the 75th-percentile
        // canonical width prior for Pass 2 smudge outlier rejection.
        let rawBoxes = pages.compactMap(\.detection.contentBox).filter { !$0.isEmpty }
        let medianPageWidth = Self.percentileInt(pages.map(\.pageSize.width), p: 0.50) ?? pages[0].pageSize.width
        let medianPageHeight = Self.percentileInt(pages.map(\.pageSize.height), p: 0.50) ?? pages[0].pageSize.height

        // Filter out tiny standalone boxes (e.g., < 35% of page width) when computing the body-width prior
        // if substantial body pages exist.
        let substantialWidths = rawBoxes.map(\.width).filter { $0 >= medianPageWidth * 35 / 100 }
        let widthSamplesForPrior = substantialWidths.isEmpty ? rawBoxes.map(\.width) : substantialWidths
        let priorCanonicalWidth = Self.percentileInt(widthSamplesForPrior, p: 0.75) ?? (medianPageWidth * 70 / 100)

        // Step 2: Run Pass 2 outlier refinement on any page whose raw content box exceeds
        // priorCanonicalWidth * (1 + pass2OutlierWidthExcessFraction).
        var refinedDetections: [ContentBoxDetector.DetectionResult] = []
        var outlierTrimFlags: [Bool] = []
        refinedDetections.reserveCapacity(pages.count)
        outlierTrimFlags.reserveCapacity(pages.count)

        for page in pages {
            let refined = detector.refineWithCanonicalWidthPrior(
                page.detection,
                canonicalWidth: priorCanonicalWidth,
                maxWidthExcessFraction: configuration.pass2OutlierWidthExcessFraction
            )
            let trimmed = (refined.contentBox != page.detection.contentBox)
            refinedDetections.append(refined)
            outlierTrimFlags.append(trimmed)
        }

        // Step 3: Estimate canonical text width W_canon and height H_canon from the 85th percentile
        // of refined body-candidate boxes.
        let refinedBoxes = refinedDetections.compactMap(\.contentBox).filter { !$0.isEmpty }
        let bodyCandidateBoxes = refinedBoxes.filter { box in
            box.width >= priorCanonicalWidth * 75 / 100
        }
        let referenceBoxes = bodyCandidateBoxes.isEmpty ? refinedBoxes : bodyCandidateBoxes

        let canonicalTextWidth = Self.percentileInt(referenceBoxes.map(\.width), p: 0.85)
            ?? max(1, medianPageWidth - 2 * hMargin)
        let canonicalTextHeight = Self.percentileInt(referenceBoxes.map(\.height), p: 0.85)
            ?? max(1, medianPageHeight - 2 * vMargin)

        // Determine uniform output canvas size:
        // Large enough to accommodate the median physical page size and the canonical text block + margins.
        let canvasWidth = max(medianPageWidth, canonicalTextWidth + 2 * hMargin)
        let canvasHeight = max(medianPageHeight, canonicalTextHeight + 2 * vMargin)
        let canvasSize = Size2I(width: max(1, canvasWidth), height: max(1, canvasHeight))

        // Estimate typical physical top margin and horizontal offset for Verso and Recto body pages
        // so the canonical frame sits naturally where full body pages sit on the physical page.
        var versoLeftMargins: [Int] = []
        var rectoLeftMargins: [Int] = []
        var bodyTopMargins: [Int] = []

        for (idx, page) in pages.enumerated() {
            guard let box = refinedDetections[idx].contentBox else { continue }
            let widthDiff = abs(box.width - canonicalTextWidth)
            let heightDiff = abs(box.height - canonicalTextHeight)
            let isNearFullWidth = Double(widthDiff) <= Double(canonicalTextWidth) * configuration.fullWidthToleranceFraction
            let isNearFullHeight = Double(heightDiff) <= Double(canonicalTextHeight) * configuration.fullHeightToleranceFraction

            if isNearFullWidth {
                let offsetX = (canvasSize.width - page.pageSize.width) / 2
                let mappedMinX = box.minX + offsetX
                switch page.side {
                case .verso:
                    versoLeftMargins.append(mappedMinX)
                case .recto, .single:
                    rectoLeftMargins.append(mappedMinX)
                }
            }
            if isNearFullWidth && isNearFullHeight {
                let offsetY = (canvasSize.height - page.pageSize.height) / 2
                bodyTopMargins.append(box.minY + offsetY)
            }
        }

        let centeredX = max(0, (canvasSize.width - canonicalTextWidth) / 2)
        let centeredY = max(0, (canvasSize.height - canonicalTextHeight) / 2)

        let canonicalTopY = Self.clampOrigin(
            Self.percentileInt(bodyTopMargins, p: 0.50) ?? centeredY,
            span: canonicalTextHeight,
            canvasSpan: canvasSize.height
        )
        let versoLeftX = Self.clampOrigin(
            Self.percentileInt(versoLeftMargins, p: 0.50) ?? centeredX,
            span: canonicalTextWidth,
            canvasSpan: canvasSize.width
        )
        let rectoLeftX = Self.clampOrigin(
            Self.percentileInt(rectoLeftMargins, p: 0.50) ?? centeredX,
            span: canonicalTextWidth,
            canvasSpan: canvasSize.width
        )

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
                        canvasSize: canvasSize
                    )
                )
                continue
            }

            let widthRatioDiff = abs(Double(box.width - targetFrame.width)) / Double(max(1, targetFrame.width))
            let heightRatioDiff = abs(Double(box.height - targetFrame.height)) / Double(max(1, targetFrame.height))
            let heightRatio = Double(box.height) / Double(max(1, targetFrame.height))

            let matchesCanonicalWidth = widthRatioDiff <= configuration.fullWidthToleranceFraction
            let matchesCanonicalHeight = heightRatioDiff <= configuration.fullHeightToleranceFraction

            let tier: PlacementTier
            let destOrigin: Point2I

            if matchesCanonicalWidth && matchesCanonicalHeight {
                // Tier 1 — Full Body Page:
                // Lock to the canonical text frame origin so left/right margins and running headers
                // stay rock-steady across page turns.
                tier = .fullBody
                destOrigin = Point2I(x: targetFrame.minX, y: targetFrame.minY)
            } else if matchesCanonicalWidth && heightRatio >= configuration.minPartialHeightFraction && box.height < targetFrame.height {
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
                    let anchoredY = Self.clampOrigin(
                        targetFrame.maxY - box.height,
                        span: box.height,
                        canvasSpan: canvasSize.height
                    )
                    destOrigin = Point2I(x: targetFrame.minX, y: anchoredY)
                } else if topDistToCanon <= edgeAnchorTol {
                    // Chapter ending with bottom whitespace: anchor top edge to targetFrame.minY.
                    tier = .edgeAnchoredPartial
                    destOrigin = Point2I(x: targetFrame.minX, y: targetFrame.minY)
                } else {
                    // Full-width block floating vertically at a custom position: keep natural Y, lock X to canonical margin.
                    tier = .edgeAnchoredPartial
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
                    canvasSize: canvasSize
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

    // MARK: - Private Statistical Helpers

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
}
