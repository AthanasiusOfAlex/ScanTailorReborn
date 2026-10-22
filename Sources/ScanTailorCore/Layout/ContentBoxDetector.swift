import ScanTailorContracts

/// Isolates the true page content bounding box (including running headers, footers, and page numbers)
/// while rejecting margin smudges, punch-holes, scanner edge artifacts, and cross-gutter bleed.
///
/// Adapted from ScanTailor-Advanced `filters/select_content/ContentBoxFinder`, augmented with
/// Pass 2 book-wide canonical width prior refinement.
public struct ContentBoxDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Whether to run `BorderAndSpeckleCleaner` before clustering if the caller hasn't already.
        public var cleanBordersFirst: Bool
        /// Horizontal closing brick width (at 600 DPI) to fuse characters into words/lines.
        public var closingBrickWidthAt600DPI: Int
        /// Vertical closing brick height (at 600 DPI) to fuse diacritics and adjacent baselines.
        public var closingBrickHeightAt600DPI: Int
        /// Outer page margin fraction (`[0, 0.2]`) treated as the peripheral noise danger zone.
        public var outerEdgeMarginFraction: Double
        /// Minimum foreground pixel count in the original bitmap for a cluster in the central zone to be retained.
        public var minClusterForegroundPixelsAt600DPI: Int
        /// Maximum vertical gap (as a fraction of page height) between the main text block and
        /// a running header, footer, or page number cluster.
        public var maxHeaderFooterGapFraction: Double
        /// Maximum horizontal overhang (as a fraction of page width) allowed for a small header/footer
        /// outside the main text block's horizontal span.
        public var headerFooterHorizontalToleranceFraction: Double

        public init(
            cleanBordersFirst: Bool = true,
            closingBrickWidthAt600DPI: Int = 64,
            closingBrickHeightAt600DPI: Int = 14,
            outerEdgeMarginFraction: Double = 0.035,
            minClusterForegroundPixelsAt600DPI: Int = 36,
            maxHeaderFooterGapFraction: Double = 0.14,
            headerFooterHorizontalToleranceFraction: Double = 0.04
        ) {
            self.cleanBordersFirst = cleanBordersFirst
            self.closingBrickWidthAt600DPI = max(8, closingBrickWidthAt600DPI)
            self.closingBrickHeightAt600DPI = max(2, closingBrickHeightAt600DPI)
            self.outerEdgeMarginFraction = min(max(0.0, outerEdgeMarginFraction), 0.25)
            self.minClusterForegroundPixelsAt600DPI = max(4, minClusterForegroundPixelsAt600DPI)
            self.maxHeaderFooterGapFraction = min(max(0.02, maxHeaderFooterGapFraction), 0.35)
            self.headerFooterHorizontalToleranceFraction = min(max(0.0, headerFooterHorizontalToleranceFraction), 0.20)
        }
    }

    /// A morphologically fused cluster with its exact original foreground bounds and pixel mass.
    public struct Cluster: Sendable, Equatable, Codable {
        /// Exact bounding box of original foreground pixels inside this cluster.
        public let exactBounds: Rect2I
        /// Number of original black foreground pixels inside `exactBounds` belonging to this cluster.
        public let foregroundPixels: Int

        public init(exactBounds: Rect2I, foregroundPixels: Int) {
            self.exactBounds = exactBounds
            self.foregroundPixels = foregroundPixels
        }
    }

    /// Result of Pass 1 or Pass 2 content box detection on a single page.
    public struct DetectionResult: Sendable, Equatable, Codable {
        /// Total content bounding box enclosing body text, running headers, footers, and page numbers (`nil` if blank).
        public let contentBox: Rect2I?
        /// Bounding box of the primary body text cluster(s), excluding isolated small header/footer clusters (`nil` if blank).
        public let mainBodyBox: Rect2I?
        /// Retained content clusters (each with exact foreground bounds and pixel count).
        public let retainedClusters: [Cluster]
        /// Rejected margin noise / smudge bounding boxes (for diagnostic overlays).
        public let rejectedBoxes: [Rect2I]
        /// Detection confidence in `[0, 1]`.
        public let confidence: Double

        public init(
            contentBox: Rect2I?,
            mainBodyBox: Rect2I?,
            retainedClusters: [Cluster],
            rejectedBoxes: [Rect2I],
            confidence: Double
        ) {
            self.contentBox = contentBox
            self.mainBodyBox = mainBodyBox
            self.retainedClusters = retainedClusters
            self.rejectedBoxes = rejectedBoxes
            self.confidence = min(max(0.0, confidence), 1.0)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Pass 1: Detects the page's content bounding box and separates true text/headers/page numbers
    /// from marginal noise.
    public func detect(in bitmap: borrowing BinaryBitmap, dpi: Int = 600) -> DetectionResult {
        let width = bitmap.width
        let height = bitmap.height
        guard width > 4 && height > 4 else {
            return DetectionResult(
                contentBox: nil,
                mainBodyBox: nil,
                retainedClusters: [],
                rejectedBoxes: [],
                confidence: 1.0
            )
        }

        let scale = Double(max(72, dpi)) / 600.0
        let areaScale = scale * scale

        let cleaned: BinaryBitmap
        if configuration.cleanBordersFirst {
            let cleaner = BorderAndSpeckleCleaner()
            cleaned = cleaner.clean(bitmap)
        } else {
            cleaned = copy bitmap
        }

        // Extract fine connected components from the cleaned bitmap so we can compute exact bounds
        // and exact foreground pixel counts inside each morphologically fused cluster.
        let fineComponents = ConnectedComponentAnalyzer.extractComponents(from: cleaned, connectivity: .eight)
        guard !fineComponents.isEmpty else {
            return DetectionResult(
                contentBox: nil,
                mainBodyBox: nil,
                retainedClusters: [],
                rejectedBoxes: [],
                confidence: 1.0
            )
        }

        let brickW = max(5, Int((Double(configuration.closingBrickWidthAt600DPI) * scale).rounded()))
        let brickH = max(3, Int((Double(configuration.closingBrickHeightAt600DPI) * scale).rounded()))
        let closed = BinaryMorphology.closeBrick(cleaned, width: brickW, height: brickH)
        let coarseComponents = ConnectedComponentAnalyzer.extractComponents(from: closed, connectivity: .eight)

        // Map each fine component to the coarse cluster that encloses its seed point / bounding box.
        var clusterBounds = [Rect2I?](repeating: nil, count: coarseComponents.count)
        var clusterPixels = [Int](repeating: 0, count: coarseComponents.count)

        for fine in fineComponents {
            let centerPt = Point2I(
                x: fine.boundingBox.minX + fine.boundingBox.width / 2,
                y: fine.boundingBox.minY + fine.boundingBox.height / 2
            )
            var matchedIdx: Int? = nil
            for (idx, coarse) in coarseComponents.enumerated() {
                if coarse.boundingBox.contains(centerPt) || coarse.boundingBox.intersection(fine.boundingBox) != nil {
                    matchedIdx = idx
                    break
                }
            }
            if let idx = matchedIdx {
                clusterBounds[idx] = clusterBounds[idx]?.union(fine.boundingBox) ?? fine.boundingBox
                clusterPixels[idx] += fine.pixelCount
            }
        }

        var allClusters: [Cluster] = []
        allClusters.reserveCapacity(coarseComponents.count)
        for idx in 0..<coarseComponents.count {
            if let exact = clusterBounds[idx], clusterPixels[idx] > 0 {
                allClusters.append(Cluster(exactBounds: exact, foregroundPixels: clusterPixels[idx]))
            }
        }

        guard !allClusters.isEmpty else {
            return DetectionResult(
                contentBox: nil,
                mainBodyBox: nil,
                retainedClusters: [],
                rejectedBoxes: [],
                confidence: 1.0
            )
        }

        let minClusterPx = max(4, Int((Double(configuration.minClusterForegroundPixelsAt600DPI) * areaScale).rounded()))
        let edgeMarginX = Int((Double(width) * configuration.outerEdgeMarginFraction).rounded())
        let edgeMarginY = Int((Double(height) * configuration.outerEdgeMarginFraction).rounded())
        let interiorRect = Rect2I(
            minX: edgeMarginX,
            minY: edgeMarginY,
            maxX: max(edgeMarginX + 1, width - edgeMarginX),
            maxY: max(edgeMarginY + 1, height - edgeMarginY)
        )

        // Step 1: Identify candidate body/line clusters vs. obvious peripheral garbage.
        // A cluster is a strong body candidate if:
        // - It has >= minClusterPx foreground pixels,
        // - It is not a thin vertical border line along the left/right edges,
        // - Its bounding box intersects the safe interior region.
        var bodyCandidates: [Cluster] = []
        var peripheralOrSmall: [Cluster] = []

        for cluster in allClusters {
            let box = cluster.exactBounds
            let isInInterior = interiorRect.intersection(box) != nil
            let touchesOuterX = box.minX <= edgeMarginX / 2 || box.maxX >= width - (edgeMarginX / 2)
            let isTallThinBorderLine = touchesOuterX && box.height > box.width * 6 && box.width < max(12, width / 40)

            // Also check if a cluster sits entirely in the extreme outer margin strip
            let centerX = box.minX + box.width / 2
            let centerY = box.minY + box.height / 2
            let centerInInterior = interiorRect.contains(x: centerX, y: centerY)

            if !isTallThinBorderLine && isInInterior && centerInInterior && cluster.foregroundPixels >= minClusterPx {
                bodyCandidates.append(cluster)
            } else {
                peripheralOrSmall.append(cluster)
            }
        }

        // If the page only has small text (e.g. a brief epigraph or ornament), promote interior clusters.
        if bodyCandidates.isEmpty {
            for cluster in allClusters {
                if interiorRect.intersection(cluster.exactBounds) != nil && cluster.foregroundPixels >= max(3, minClusterPx / 3) {
                    bodyCandidates.append(cluster)
                }
            }
        }

        guard !bodyCandidates.isEmpty else {
            return DetectionResult(
                contentBox: nil,
                mainBodyBox: nil,
                retainedClusters: [],
                rejectedBoxes: allClusters.map(\.exactBounds),
                confidence: 0.9
            )
        }

        // Step 2: Among bodyCandidates, reject isolated horizontal margin smudges that are separated
        // from the main text mass by a wide blank gap and carry < 3% of the total foreground mass.
        let totalCandidateMass = bodyCandidates.reduce(0) { $0 + $1.foregroundPixels }
        let peakClusterMass = bodyCandidates.map(\.foregroundPixels).max() ?? 1

        // Find the core cluster(s) that carry substantial mass (>= 10% of peak cluster mass or wide text line)
        let coreClusters = bodyCandidates.filter { cluster in
            cluster.foregroundPixels * 10 >= peakClusterMass || cluster.exactBounds.width >= width / 5
        }

        var coreBox = (coreClusters.first ?? bodyCandidates[0]).exactBounds
        for c in coreClusters.dropFirst() {
            coreBox = coreBox.union(c.exactBounds)
        }

        let maxHorizGap = max(16, Int((Double(width) * 0.08).rounded()))
        let maxVertGap = max(24, Int((Double(height) * configuration.maxHeaderFooterGapFraction).rounded()))
        let horizTol = Int((Double(width) * configuration.headerFooterHorizontalToleranceFraction).rounded())

        var retainedBody: [Cluster] = []
        var rejectedBoxes: [Rect2I] = []

        for cluster in bodyCandidates {
            let box = cluster.exactBounds
            // Horizontal distance from coreBox
            let hDist: Int
            if box.maxX < coreBox.minX {
                hDist = coreBox.minX - box.maxX
            } else if box.minX > coreBox.maxX {
                hDist = box.minX - coreBox.maxX
            } else {
                hDist = 0
            }

            // A small cluster far out in the left/right margin (outside the core text column) is a margin smudge
            let isSmallMarginOutlier = hDist > maxHorizGap
                && cluster.foregroundPixels * 25 < totalCandidateMass
                && box.width < width / 6

            if isSmallMarginOutlier {
                rejectedBoxes.append(box)
            } else {
                retainedBody.append(cluster)
            }
        }

        if retainedBody.isEmpty {
            retainedBody = bodyCandidates
            rejectedBoxes.removeAll()
        }

        var mainBodyBox = retainedBody[0].exactBounds
        for c in retainedBody.dropFirst() {
            mainBodyBox = mainBodyBox.union(c.exactBounds)
        }

        // Step 3: Evaluate smaller/peripheral clusters to rescue running headers, footers, and page numbers
        // (which may consist of just 1-3 digits above or below the main body text, or centered horizontally).
        var retainedAll = retainedBody
        let pageCenterX = width / 2
        let centerBandHalfW = max(width / 6, mainBodyBox.width / 2)

        for cluster in peripheralOrSmall {
            let box = cluster.exactBounds
            guard interiorRect.intersection(box) != nil else {
                rejectedBoxes.append(box)
                continue
            }

            let centerX = box.minX + box.width / 2
            let withinBodyColumns = box.minX >= (mainBodyBox.minX - horizTol) && box.maxX <= (mainBodyBox.maxX + horizTol)
            let nearPageCenterHorizontally = abs(centerX - pageCenterX) <= centerBandHalfW

            let vDist: Int
            if box.maxY < mainBodyBox.minY {
                vDist = mainBodyBox.minY - box.maxY
            } else if box.minY > mainBodyBox.maxY {
                vDist = box.minY - mainBodyBox.maxY
            } else {
                vDist = 0
            }

            let plausibleHeaderOrPageNumber = (withinBodyColumns || nearPageCenterHorizontally)
                && vDist <= maxVertGap
                && cluster.foregroundPixels >= max(4, minClusterPx / 4)

            if plausibleHeaderOrPageNumber {
                retainedAll.append(cluster)
            } else {
                rejectedBoxes.append(box)
            }
        }

        var finalContentBox = retainedAll[0].exactBounds
        for c in retainedAll.dropFirst() {
            finalContentBox = finalContentBox.union(c.exactBounds)
        }

        let retainedMass = retainedAll.reduce(0) { $0 + $1.foregroundPixels }
        let rejectedMass = allClusters.reduce(0) { $0 + $1.foregroundPixels } - retainedMass
        let confidence: Double
        if retainedMass + rejectedMass > 0 {
            let ratio = Double(retainedMass) / Double(retainedMass + max(0, rejectedMass))
            confidence = min(1.0, max(0.5, ratio))
        } else {
            confidence = 1.0
        }

        return DetectionResult(
            contentBox: finalContentBox,
            mainBodyBox: mainBodyBox,
            retainedClusters: retainedAll,
            rejectedBoxes: rejectedBoxes,
            confidence: confidence
        )
    }

    /// Pass 2 Book-Wide Outlier Rejection:
    /// If a page's Pass 1 content box width exceeds `canonicalWidth * (1 + maxWidthExcessFraction)`
    /// due to a stray margin smudge or thumb mark, finds the optimal horizontal band of width
    /// `allowedMaxWidth` that maximizes enclosed foreground pixel mass and trims clusters outside
    /// that band while preserving headers, footers, and page numbers inside it.
    public func refineWithCanonicalWidthPrior(
        _ detection: DetectionResult,
        canonicalWidth: Int,
        maxWidthExcessFraction: Double = 0.10
    ) -> DetectionResult {
        guard canonicalWidth > 0,
              let currentBox = detection.contentBox,
              detection.retainedClusters.count > 1 else {
            return detection
        }

        let allowedMaxWidth = Int((Double(canonicalWidth) * (1.0 + max(0.0, maxWidthExcessFraction))).rounded())
        guard currentBox.width > allowedMaxWidth else {
            return detection
        }

        // Collect candidate left edges from existing cluster minX and (maxX - allowedMaxWidth).
        var candidateLefts: [Int] = []
        for c in detection.retainedClusters {
            candidateLefts.append(c.exactBounds.minX)
            candidateLefts.append(c.exactBounds.maxX - allowedMaxWidth)
        }

        var bestMass = -1
        var bestRetained: [Cluster] = []
        var bestLeft = currentBox.minX

        for left in candidateLefts {
            let right = left + allowedMaxWidth
            var mass = 0
            var inside: [Cluster] = []
            for c in detection.retainedClusters {
                // Keep clusters that lie within [left, right]
                if c.exactBounds.minX >= left && c.exactBounds.maxX <= right {
                    mass += c.foregroundPixels
                    inside.append(c)
                }
            }
            if mass > bestMass || (mass == bestMass && abs(left - currentBox.minX) < abs(bestLeft - currentBox.minX)) {
                bestMass = mass
                bestRetained = inside
                bestLeft = left
            }
        }

        let totalMass = detection.retainedClusters.reduce(0) { $0 + $1.foregroundPixels }
        // Only apply the trim if the optimal canonical-width window retains at least 80% of the page's foreground mass.
        guard !bestRetained.isEmpty, bestMass * 100 >= totalMass * 80 else {
            return detection
        }

        var newRejected = detection.rejectedBoxes
        for c in detection.retainedClusters {
            if !bestRetained.contains(c) {
                newRejected.append(c.exactBounds)
            }
        }

        var newContentBox = bestRetained[0].exactBounds
        for c in bestRetained.dropFirst() {
            newContentBox = newContentBox.union(c.exactBounds)
        }

        return DetectionResult(
            contentBox: newContentBox,
            mainBodyBox: newContentBox,
            retainedClusters: bestRetained,
            rejectedBoxes: newRejected,
            confidence: detection.confidence
        )
    }
}
