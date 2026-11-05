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
        /// Inner split-edge exclusion zone fraction (`[0, 0.25]`, default `0.04`, i.e., 4% of slice width)
        /// masked prior to morphological closing on sliced sub-pages (`.leftVerso` right edge, `.rightRecto` left edge).
        public var splitEdgeExclusionFraction: Double
        /// Minimum foreground pixel count in the original bitmap for a cluster in the central zone to be retained.
        public var minClusterForegroundPixelsAt600DPI: Int
        /// Maximum vertical gap (as a fraction of page height) between the main text block and
        /// a running header, footer, or page number cluster.
        public var maxHeaderFooterGapFraction: Double
        /// Maximum horizontal overhang (as a fraction of page width) allowed for a small header/footer
        /// outside the main text block's horizontal span.
        public var headerFooterHorizontalToleranceFraction: Double
        /// Column groups cut off from the main text block by an empty gap of at least this fraction of the
        /// content width, and carrying little ink, are rejected (page-edge stack textures, gutter shadows).
        /// `0` disables the check.
        public var edgeNoiseIsolationGapFraction: Double
        /// Strict margins, for camera photos whose margins hold desk residue (mug rims, the paper's own edge,
        /// thumb-index tabs, outline curves of the page stack). Only clusters with real mass form the body;
        /// everything outside the body block must pass as a running header, footer or page number: horizontal
        /// (no taller than twice its width), inside the body's columns and within ``strictMarginGapFraction`` of
        /// the body height from it. Thin line art is removed before clustering, and the body is the text block
        /// found by fusing lines with a brick four times as tall.
        public var strictMargins: Bool
        /// Largest gap between the body and a header or footer in strict mode, as a fraction of the body height.
        public var strictMarginGapFraction: Double

        public init(
            cleanBordersFirst: Bool = true,
            closingBrickWidthAt600DPI: Int = 64,
            closingBrickHeightAt600DPI: Int = 14,
            outerEdgeMarginFraction: Double = 0.035,
            splitEdgeExclusionFraction: Double = 0.04,
            minClusterForegroundPixelsAt600DPI: Int = 36,
            maxHeaderFooterGapFraction: Double = 0.14,
            headerFooterHorizontalToleranceFraction: Double = 0.04,
            edgeNoiseIsolationGapFraction: Double = 0.01,
            strictMargins: Bool = false,
            strictMarginGapFraction: Double = 0.04
        ) {
            self.strictMargins = strictMargins
            self.strictMarginGapFraction = min(max(0.005, strictMarginGapFraction), 0.35)
            self.edgeNoiseIsolationGapFraction = edgeNoiseIsolationGapFraction <= 0 ? 0 : min(max(0.003, edgeNoiseIsolationGapFraction), 0.5)
            self.cleanBordersFirst = cleanBordersFirst
            self.closingBrickWidthAt600DPI = max(8, closingBrickWidthAt600DPI)
            self.closingBrickHeightAt600DPI = max(2, closingBrickHeightAt600DPI)
            self.outerEdgeMarginFraction = min(max(0.0, outerEdgeMarginFraction), 0.25)
            self.splitEdgeExclusionFraction = min(max(0.0, splitEdgeExclusionFraction), 0.25)
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

        /// Whether every retained cluster is shorter than `maxHeightInches`: paper fibres, dust and specks, but
        /// not a line of type, a page number or a drawing.
        /// - Parameters:
        ///   - dpi: Resolution of the bitmap the clusters were measured on.
        ///   - maxHeightInches: Tallest cluster still taken for a speck (default 0.1 in; on the sample books
        ///     specks reach 0.09 in and the smallest real content 0.11 in).
        /// - Returns: `true` also when nothing was retained.
        public func holdsOnlySpecks(dpi: Int, maxHeightInches: Double = 0.1) -> Bool {
            let limit = maxHeightInches * Double(dpi)
            return retainedClusters.allSatisfy { Double($0.exactBounds.height) < limit }
        }

        /// The same detection with nothing retained: the page is laid out as a blank page. The clusters it held
        /// are kept among the rejected boxes for the diagnostic overlays.
        public var blanked: DetectionResult {
            DetectionResult(
                contentBox: nil,
                mainBodyBox: nil,
                retainedClusters: [],
                rejectedBoxes: rejectedBoxes + retainedClusters.map(\.exactBounds),
                confidence: 1.0
            )
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Pass 1: Detects the page's content bounding box and separates true text/headers/page numbers
    /// from marginal noise.
    /// - Parameters:
    ///   - bitmap: Source 1-bit monochrome bitmap.
    ///   - dpi: Scan resolution in DPI (default: `600`).
    ///   - splitSide: Sliced page side (`.single`, `.leftVerso`, or `.rightRecto`). When `.leftVerso`
    ///     or `.rightRecto`, applies a pre-morphological exclusion mask along the inner cut margin.
    public func detect(
        in bitmap: borrowing BinaryBitmap,
        dpi: Int = 600,
        splitSide: PageSide = .single
    ) -> DetectionResult {
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

        let initialCleaned: BinaryBitmap
        if configuration.cleanBordersFirst {
            let cleaner = BorderAndSpeckleCleaner()
            initialCleaned = cleaner.clean(bitmap)
        } else {
            initialCleaned = copy bitmap
        }

        // Pre-morphological split-edge exclusion mask:
        // On sliced sub-pages (.leftVerso inner right margin, .rightRecto inner left margin),
        // mask out the inner split-edge exclusion zone and any residual vertical crease slivers
        // hugging the cut boundary prior to morphological closing (`closeBrick`).
        let splitExclusionWidth: Int
        if splitSide == .single || configuration.splitEdgeExclusionFraction <= 0.0 {
            splitExclusionWidth = 0
        } else {
            splitExclusionWidth = min(
                width / 4,
                max(1, Int((Double(width) * configuration.splitEdgeExclusionFraction).rounded()))
            )
        }

        var cleaned = initialCleaned
        var splitEdgeRejectedBoxes: [Rect2I] = []

        if splitExclusionWidth > 0 {
            let stripRect: Rect2I
            switch splitSide {
            case .rightRecto:
                stripRect = Rect2I(minX: 0, minY: 0, maxX: splitExclusionWidth, maxY: height)
            case .leftVerso:
                stripRect = Rect2I(minX: width - splitExclusionWidth, minY: 0, maxX: width, maxY: height)
            case .single:
                stripRect = Rect2I(minX: 0, minY: 0, maxX: 0, maxY: 0)
            }

            let stripCrop = cleaned.cropped(to: stripRect)
            if !stripCrop.isEmpty {
                let stripComponents = ConnectedComponentAnalyzer.extractComponents(from: stripCrop, connectivity: .eight)
                for comp in stripComponents where comp.pixelCount >= 4 {
                    let box = Rect2I(
                        minX: stripRect.minX + comp.boundingBox.minX,
                        minY: stripRect.minY + comp.boundingBox.minY,
                        maxX: stripRect.minX + comp.boundingBox.maxX,
                        maxY: stripRect.minY + comp.boundingBox.maxY
                    )
                    splitEdgeRejectedBoxes.append(box)
                }

                for y in 0..<height {
                    for x in stripRect.minX..<stripRect.maxX {
                        cleaned[x, y] = false
                    }
                }

                // Also erase any residual tall vertical crease sliver hugging the split-mask boundary
                // (e.g. when a thick or slightly tilted spine crease extended past splitExclusionWidth).
                let maxSliverWidth = max(24, splitExclusionWidth)
                let minSliverHeight = max(48, height / 15)
                var sliverBoxes: [Rect2I] = []
                cleaned = ConnectedComponentAnalyzer.filterComponents(in: cleaned, connectivity: .eight) { comp in
                    let bbox = comp.boundingBox
                    let hugsCutBoundary: Bool
                    switch splitSide {
                    case .rightRecto:
                        hugsCutBoundary = bbox.minX <= splitExclusionWidth + 2
                    case .leftVerso:
                        hugsCutBoundary = bbox.maxX >= width - splitExclusionWidth - 2
                    case .single:
                        hugsCutBoundary = false
                    }
                    let isVerticalCreaseSliver = hugsCutBoundary
                        && bbox.width <= maxSliverWidth
                        && bbox.height >= minSliverHeight
                        && bbox.height > bbox.width * 3
                    if isVerticalCreaseSliver {
                        sliverBoxes.append(bbox)
                        return false
                    }
                    return true
                }
                splitEdgeRejectedBoxes.append(contentsOf: sliverBoxes)
            }
        }

        // Strict margins: drop line art (the paper's own rim, outline curves of the page stack) before clustering,
        // so it cannot fuse with the text: a component spanning at least 0.4 in, under 8 % of its box inked and
        // thin (ink per spanned pixel under 32 at 600 DPI). Blurry text can join into a large sparse web through a
        // gutter shadow, but a web holding real text is far thicker than a stroke.
        var lineArt: [Rect2I] = []
        if configuration.strictMargins {
            let minSpan = max(16, Int((256.0 * scale).rounded()))
            let maxThickness = max(4.0, 32.0 * scale)
            cleaned = ConnectedComponentAnalyzer.filterComponents(in: cleaned, connectivity: .eight) { comp in
                let b = comp.boundingBox
                let span = max(b.width, b.height)
                let isLineArt = span >= minSpan && comp.pixelCount * 100 < b.width * b.height * 8
                    && Double(comp.pixelCount) <= Double(span) * maxThickness
                if isLineArt { lineArt.append(b) }
                return !isLineArt
            }
        }

        // Page-edge stack: the edges of the following leaves, seen past the page's outer edge, are a band of thin
        // vertical lines that can carry as much ink as the text and fuse with it when closed, so the isolation
        // check of step 4 cannot remove them. The band (see `edgeStackBands`) is erased before clustering; on a
        // page that shows nothing else the page is then blank.
        let edgeStackBoxes = Self.edgeStackBands(in: cleaned, splitSide: splitSide, scale: scale)
        for band in edgeStackBoxes {
            for y in 0..<height {
                for x in band.minX..<band.maxX { cleaned[x, y] = false }
            }
        }
        splitEdgeRejectedBoxes.append(contentsOf: edgeStackBoxes)

        // Extract fine connected components from the cleaned bitmap so we can compute exact bounds
        // and exact foreground pixel counts inside each morphologically fused cluster.
        let fineComponents = ConnectedComponentAnalyzer.extractComponents(from: cleaned, connectivity: .eight)
        guard !fineComponents.isEmpty else {
            return DetectionResult(
                contentBox: nil,
                mainBodyBox: nil,
                retainedClusters: [],
                rejectedBoxes: splitEdgeRejectedBoxes,
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
                rejectedBoxes: splitEdgeRejectedBoxes,
                confidence: 1.0
            )
        }

        let minClusterPx = max(4, Int((Double(configuration.minClusterForegroundPixelsAt600DPI) * areaScale).rounded()))
        // A speck (dust, a stray dot) is smaller than any glyph: its longer side is under 0.06 in. Specks never
        // set the content box; a lone dot of a line merges with its line when the clusters are closed.
        let minSpeckSpan = max(4, Int((36.0 * scale).rounded()))
        let edgeMarginX = Int((Double(width) * configuration.outerEdgeMarginFraction).rounded())
        let edgeMarginY = Int((Double(height) * configuration.outerEdgeMarginFraction).rounded())
        let leftEdgeMarginX = (splitSide == .rightRecto) ? max(edgeMarginX, splitExclusionWidth) : edgeMarginX
        let rightEdgeMarginX = (splitSide == .leftVerso) ? max(edgeMarginX, splitExclusionWidth) : edgeMarginX
        let interiorRect = Rect2I(
            minX: leftEdgeMarginX,
            minY: edgeMarginY,
            maxX: max(leftEdgeMarginX + 1, width - rightEdgeMarginX),
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
            let touchesOuterX = box.minX <= leftEdgeMarginX / 2 || box.maxX >= width - (rightEdgeMarginX / 2)
            let isTallThinBorderLine = touchesOuterX && box.height > box.width * 6 && box.width < max(12, width / 40)

            // Also check if a cluster sits entirely in the extreme outer margin strip
            let centerX = box.minX + box.width / 2
            let centerY = box.minY + box.height / 2
            let centerInInterior = interiorRect.contains(x: centerX, y: centerY)

            if !isTallThinBorderLine && isInInterior && centerInInterior && cluster.foregroundPixels >= minClusterPx
                && max(box.width, box.height) >= minSpeckSpan {
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
                rejectedBoxes: splitEdgeRejectedBoxes + allClusters.map(\.exactBounds),
                confidence: 0.9
            )
        }

        // Step 2: Among bodyCandidates, reject isolated horizontal margin smudges that are separated
        // from the main text mass by a wide blank gap and carry < 3% of the total foreground mass.
        let totalCandidateMass = bodyCandidates.reduce(0) { $0 + $1.foregroundPixels }
        let peakClusterMass = bodyCandidates.map(\.foregroundPixels).max() ?? 1

        // Find the core cluster(s) that carry substantial mass (>= 10% of peak cluster mass or wide text line)
        let strict = configuration.strictMargins
        var coreClusters = bodyCandidates.filter { cluster in
            cluster.foregroundPixels * 10 >= peakClusterMass || (!strict && cluster.exactBounds.width >= width / 5)
        }
        // Strict margins: the core is the text block, found by fusing lines with a brick four times as tall.
        // Clusters break apart once rules and rims are gone, and a mug rim can then rival a paragraph.
        if strict, let block = Self.textBlock(cleaned, fine: fineComponents, brickWidth: brickW, brickHeight: 4 * brickH) {
            let inBlock = bodyCandidates.filter { cluster in
                let box = cluster.exactBounds
                let inside = box.intersection(block).map { $0.width * $0.height } ?? 0
                return inside * 2 >= box.width * box.height
            }
            if !inBlock.isEmpty { coreClusters = inBlock }
        }

        var coreBox = (coreClusters.first ?? bodyCandidates[0]).exactBounds
        for c in coreClusters.dropFirst() {
            coreBox = coreBox.union(c.exactBounds)
        }

        let maxHorizGap = max(16, Int((Double(width) * 0.08).rounded()))
        let maxVertGap = max(24, Int((Double(height) * configuration.maxHeaderFooterGapFraction).rounded()))
        let horizTol = Int((Double(width) * configuration.headerFooterHorizontalToleranceFraction).rounded())

        var retainedBody: [Cluster] = []
        var rejectedBoxes: [Rect2I] = splitEdgeRejectedBoxes
        var marginCandidates = peripheralOrSmall

        for cluster in bodyCandidates {
            let box = cluster.exactBounds
            // Strict margins: a cluster that is neither core nor mostly inside the core block is judged as a
            // header, footer or page number below.
            if strict, !coreClusters.contains(cluster) {
                let inside = box.intersection(coreBox).map { $0.width * $0.height } ?? 0
                if inside * 2 < box.width * box.height {
                    marginCandidates.append(cluster)
                    continue
                }
            }
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
            rejectedBoxes = splitEdgeRejectedBoxes
            marginCandidates = peripheralOrSmall
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

        let strictVertGap = max(2 * brickH, Int((Double(mainBodyBox.height) * configuration.strictMarginGapFraction).rounded()))
        for cluster in marginCandidates {
            let box = cluster.exactBounds
            guard interiorRect.intersection(box) != nil, max(box.width, box.height) >= minSpeckSpan else {
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

            let plausibleHeaderOrPageNumber: Bool
            if strict {
                // The page may sit anywhere in a camera slice, so "centered" means under the body, not the slice.
                let area = max(1, box.width * box.height)
                let isLineArt = cluster.foregroundPixels * 100 < area * 8 && (box.width >= 4 * brickW || box.height >= 4 * brickH)
                let underBody = centerX >= mainBodyBox.minX && centerX <= mainBodyBox.maxX
                // Headers, footers and page numbers are horizontal type; a tall sliver is a crease or an edge.
                plausibleHeaderOrPageNumber = !isLineArt
                    && box.height <= 2 * box.width
                    && (withinBodyColumns || underBody)
                    && vDist <= strictVertGap
                    && cluster.foregroundPixels >= max(4, minClusterPx / 4)
            } else {
                plausibleHeaderOrPageNumber = (withinBodyColumns || nearPageCenterHorizontally)
                    && vDist <= maxVertGap
                    && cluster.foregroundPixels >= max(4, minClusterPx / 4)
            }

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

        // Step 4: Reject edge textures (page-edge stacks, gutter shadows) that sit behind an empty gap.
        if configuration.edgeNoiseIsolationGapFraction > 0,
           let area = finalContentBox.clamped(to: Rect2I(x: 0, y: 0, width: width, height: height)) {
            let counts = TextColumnAnalysis.columnInk(cleaned, area: area)
            if let extent = TextColumnAnalysis.mainTextExtent(
                counts: counts, areaHeight: area.height, gapFraction: configuration.edgeNoiseIsolationGapFraction
            ) {
                let keepRange = (area.minX + extent.lowerBound)..<(area.minX + extent.upperBound)
                let kept = retainedAll.filter { $0.exactBounds.maxX > keepRange.lowerBound && $0.exactBounds.minX < keepRange.upperBound }
                if !kept.isEmpty && kept.count < retainedAll.count {
                    for cluster in retainedAll where !kept.contains(cluster) {
                        rejectedBoxes.append(cluster.exactBounds)
                    }
                    retainedAll = kept
                    finalContentBox = kept[0].exactBounds
                    for c in kept.dropFirst() { finalContentBox = finalContentBox.union(c.exactBounds) }
                    let keptBody = retainedBody.filter { kept.contains($0) }
                    if let first = keptBody.first {
                        mainBodyBox = keptBody.dropFirst().reduce(first.exactBounds) { $0.union($1.exactBounds) }
                    }
                }
            }
        }

        // Line art removed outside the content box is reported as rejected (rules removed inside it are not noise).
        for box in lineArt {
            let inside = box.intersection(finalContentBox).map { $0.width * $0.height } ?? 0
            if inside * 2 < box.width * box.height { rejectedBoxes.append(box) }
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

    /// Full-height column bands holding a page-edge stack, at most one per outer side: the left third of a verso,
    /// the right third of a recto, either third of an unsplit page.
    ///
    /// The leaf edges are found in horizontal strips 0.5 in tall, so lines that meet at the foot or head of the
    /// stack still count one by one: a piece spans at least 80 % of its strip and is four times as tall as wide (a
    /// leaf edge or the board's dark edge; no glyph is that tall). A band qualifies when its pieces cover 40 % of the
    /// page height, average one and a half parallel lines per strip (one rule beside the text is not a stack), make
    /// it no wider than a quarter of the page, and carry at least half of its ink (ruled tables have more text than
    /// rules; broken leaf edges are the rest). The band then grows over broken leaf edges (slivers at least 0.2 in
    /// tall and four times as tall as wide, within 0.15 in of it and in the same outer third) and is widened by
    /// 0.05 in on each side.
    /// - Parameters:
    ///   - bitmap: The cleaned page.
    ///   - splitSide: Which half of the scan the page is, to pick its outer side.
    ///   - scale: The page's resolution divided by 600 dpi.
    /// - Returns: The bands, each as tall as the page.
    public static func edgeStackBands(in bitmap: borrowing BinaryBitmap, splitSide: PageSide, scale: Double) -> [Rect2I] {
        let width = bitmap.width
        let height = bitmap.height
        let stripHeight = max(20, Int((300.0 * scale).rounded()))
        let minPiece = stripHeight * 4 / 5
        let pad = max(2, Int((30.0 * scale).rounded()))
        let minSliver = max(8, Int((120.0 * scale).rounded()))
        let sliverReach = max(4, Int((90.0 * scale).rounded()))
        var pieces: [(box: Rect2I, pixels: Int, strip: Int)] = []
        var slivers: [Rect2I] = []
        var strip = 0
        while strip * stripHeight + minPiece <= height {
            let rect = Rect2I(minX: 0, minY: strip * stripHeight, maxX: width, maxY: min(height, (strip + 1) * stripHeight))
            for c in ConnectedComponentAnalyzer.extractComponents(from: bitmap.cropped(to: rect), connectivity: .eight) {
                let b = c.boundingBox
                guard b.height >= 4 * b.width, b.height >= minSliver else { continue }
                slivers.append(Rect2I(x: b.minX, y: rect.minY + b.minY, width: b.width, height: b.height))
                guard b.height >= minPiece else { continue }
                pieces.append((Rect2I(x: b.minX, y: rect.minY + b.minY, width: b.width, height: b.height), c.pixelCount, strip))
            }
            strip += 1
        }
        var sides: [(Rect2I) -> Bool] = []
        if splitSide != .rightRecto { sides.append { ($0.minX + $0.width / 2) * 3 < width } }
        if splitSide != .leftVerso { sides.append { ($0.minX + $0.width / 2) * 3 > 2 * width } }
        return sides.compactMap { onSide -> Rect2I? in
            let side = pieces.filter { onSide($0.box) }
            let strips = Set(side.map(\.strip)).count
            guard let first = side.first, strips * stripHeight * 5 >= height * 2, 2 * side.count >= 3 * strips else { return nil }
            var band = side.dropFirst().reduce(first.box) { $0.union($1.box) }
            guard band.width * 4 <= width else { return nil }
            let strokeInk = side.reduce(0) { $0 + $1.pixels }
            var bandInk = 0
            for y in 0..<height {
                for x in band.minX..<band.maxX where bitmap[x, y] { bandInk += 1 }
            }
            guard bandInk <= 2 * strokeInk else { return nil }
            var grown = true
            while grown {
                grown = false
                for s in slivers where onSide(s) && (s.maxX > band.maxX && s.minX <= band.maxX + sliverReach
                    || s.minX < band.minX && s.maxX >= band.minX - sliverReach) {
                    band = band.union(s)
                    grown = true
                }
            }
            return Rect2I(minX: max(0, band.minX - pad), minY: 0, maxX: min(width, band.maxX + pad), maxY: height)
        }
    }

    /// Box of the text block: clusters of `bitmap` closed with a `brickWidth × brickHeight` brick, grown from the
    /// heaviest by those with at least 10 % of its ink that share at least half their rows with the block so far
    /// (ink measured by the fine components centred in each).
    static func textBlock(_ bitmap: borrowing BinaryBitmap, fine: [ConnectedComponent], brickWidth: Int, brickHeight: Int) -> Rect2I? {
        let closed = BinaryMorphology.closeBrick(bitmap, width: brickWidth, height: brickHeight)
        let blocks = ConnectedComponentAnalyzer.extractComponents(from: closed, connectivity: .eight)
        guard !blocks.isEmpty else { return nil }
        var mass = [Int](repeating: 0, count: blocks.count)
        for component in fine {
            let center = Point2I(
                x: component.boundingBox.minX + component.boundingBox.width / 2,
                y: component.boundingBox.minY + component.boundingBox.height / 2
            )
            if let index = blocks.firstIndex(where: { $0.boundingBox.contains(center) }) { mass[index] += component.pixelCount }
        }
        guard let peak = mass.max(), peak > 0, let first = mass.firstIndex(of: peak) else { return nil }
        // Grow from the heaviest block by further text columns, which share its rows. Anything above or below
        // that the tall brick did not already fuse in (a mug on the desk, a distant footnote) is left to the
        // header and footer rules.
        var box = blocks[first].boundingBox
        for index in mass.indices.sorted(by: { mass[$0] > mass[$1] }) where index != first && mass[index] * 10 >= peak {
            let b = blocks[index].boundingBox
            let rows = min(b.maxY, box.maxY) - max(b.minY, box.minY)
            if rows * 2 >= b.height { box = box.union(b) }
        }
        return box
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
