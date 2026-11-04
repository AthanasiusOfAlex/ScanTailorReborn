import Foundation
import ScanTailorContracts

/// Permission slip that lets ``BorderAndSpeckleCleaner`` run its macro-cluster border fallback.
///
/// The fallback is deliberately *off* unless the caller passes a context: it is only safe to
/// excise a large dark block touching the page edge when upstream geometry says the table
/// surface was probably not handled (marginal quadrangle confidence, capped desk masking, …).
public struct MacroBorderContext: Sendable, Equatable, Codable {
    /// Page edges on which a macro border may be excised. The gutter side of a split slice is
    /// never eligible.
    public var eligibleSides: Set<DocumentQuadDetection.Side>
    /// Human-readable reasons the fallback was engaged (e.g. `quad:marginal`, `mask:capped:depth`).
    public var triggers: [String]

    public init(eligibleSides: Set<DocumentQuadDetection.Side>, triggers: [String]) {
        self.eligibleSides = eligibleSides
        self.triggers = triggers
    }
}

/// Telemetry from one run of the macro-cluster border fallback. Present only when the fallback
/// was engaged; `nil` in a page record means it never ran.
public struct MacroBorderResult: Sendable, Equatable, Codable {
    /// Reasons the fallback was engaged (copied from the ``MacroBorderContext``).
    public var triggers: [String]
    /// Fraction of the page's pixels erased by the fallback.
    public var excisedFraction: Double
    /// Excised depth, as a fraction of the page dimension perpendicular to each side.
    public var excisedDepthBySide: DocumentQuadDetection.SideMetrics
    /// Candidates examined and refused, as `"<side>:<reason>"`
    /// (`tooDeep`, `shortSpan`, `notSolid`, `textLike`).
    public var rejectedCandidates: [String]

    /// `true` when at least one block was erased.
    public var didExcise: Bool { excisedFraction > 0 }

    public init(
        triggers: [String],
        excisedFraction: Double = 0,
        excisedDepthBySide: DocumentQuadDetection.SideMetrics = .zero,
        rejectedCandidates: [String] = []
    ) {
        self.triggers = triggers
        self.excisedFraction = excisedFraction
        self.excisedDepthBySide = excisedDepthBySide
        self.rejectedCandidates = rejectedCandidates
    }
}

/// Per-page policy for the macro-cluster border fallback, stored in a manual override.
public enum BorderFallbackPolicy: String, Sendable, Equatable, Codable {
    /// Engage only when upstream geometry is marginal (the default).
    case automatic
    /// Always engage on every non-gutter side, even on pages the pipeline considered confident.
    case forced
    /// Never engage.
    case disabled
}

extension BorderAndSpeckleCleaner {

    /// Tuning for the macro-cluster border fallback.
    public struct MacroBorderConfiguration: Sendable, Equatable, Codable {
        /// Master switch (default `true`). Even when enabled it only runs with a ``MacroBorderContext``.
        public var enabled: Bool
        /// Short side of the page divided by this gives the analysis cell size. Default `64`.
        public var cellDivisor: Int
        /// Minimum black-pixel density for a cell to count as solid dark. Body text is far below
        /// this at cell scale. Default `0.55`.
        public var darkCellDensity: Double
        /// Minimum density for a cell to count as *textured* dark. Binarized wood grain is a noisy
        /// ~40 % black, far below ``darkCellDensity``; whether such a region is desk or text is decided
        /// by ``maxBlankRowFraction``. Default `0.30`.
        public var texturedCellDensity: Double
        /// Maximum fraction of a candidate's pixel rows that are blank (under 2 % black). Text has
        /// blank rows between lines (typically over 40 %); a solid block or binarized grain has almost
        /// none. Candidates above this are refused as `textLike`. Default `0.15`.
        public var maxBlankRowFraction: Double
        /// Maximum density for a cell to count as empty paper. Default `0.05`.
        public var emptyCellDensity: Double
        /// How far from the page edge (fraction of the page dimension) a block may start, provided
        /// everything between it and the edge is empty. Bridges the masker's paint band and deskew fill.
        /// Default `0.10`.
        public var maxDetachedGapRatio: Double
        /// Candidates reaching deeper than this fraction of the page dimension are refused as
        /// probable full-bleed content. Default `0.35`.
        public var maxDepthRatio: Double
        /// Minimum extent along the page edge, as a fraction of the page dimension. Default `0.15`.
        public var minSpanRatio: Double
        /// Minimum fraction of dark cells between the block's start and its inner extent. Default `0.85`.
        public var minSolidity: Double

        public init(
            enabled: Bool = true,
            cellDivisor: Int = 64,
            darkCellDensity: Double = 0.55,
            texturedCellDensity: Double = 0.30,
            maxBlankRowFraction: Double = 0.15,
            emptyCellDensity: Double = 0.05,
            maxDetachedGapRatio: Double = 0.10,
            maxDepthRatio: Double = 0.35,
            minSpanRatio: Double = 0.15,
            minSolidity: Double = 0.85
        ) {
            self.enabled = enabled
            self.cellDivisor = min(256, max(16, cellDivisor))
            self.darkCellDensity = min(0.95, max(0.2, darkCellDensity))
            self.texturedCellDensity = min(0.9, max(0.1, texturedCellDensity))
            self.maxBlankRowFraction = min(0.6, max(0.0, maxBlankRowFraction))
            self.emptyCellDensity = min(0.3, max(0.0, emptyCellDensity))
            self.maxDetachedGapRatio = min(0.3, max(0.0, maxDetachedGapRatio))
            self.maxDepthRatio = min(0.6, max(0.1, maxDepthRatio))
            self.minSpanRatio = min(0.9, max(0.05, minSpanRatio))
            self.minSolidity = min(1.0, max(0.5, minSolidity))
        }
    }

    /// Runs the standard cleanup, plus the macro-cluster border fallback when `fallback` is given.
    ///
    /// With a `nil` context this is identical to ``clean(_:)`` and returns a `nil` result.
    /// - Parameters:
    ///   - bitmap: Source 1-bit bitmap (`1` = black ink).
    ///   - fallback: Engagement context from upstream geometry telemetry, or `nil` for high confidence.
    /// - Returns: The cleaned bitmap and fallback telemetry (`nil` when the fallback did not run).
    public func clean(
        _ bitmap: borrowing BinaryBitmap,
        fallback: MacroBorderContext?
    ) -> (bitmap: BinaryBitmap, result: MacroBorderResult?) {
        guard let fallback, configuration.macroBorder.enabled, !fallback.eligibleSides.isEmpty else {
            return (clean(bitmap), nil)
        }
        var current = copy bitmap
        if configuration.removeBorders {
            current = removeScanBorders(from: current)
        }
        let (stripped, result) = removeMacroBorderBlocks(from: current, context: fallback)
        current = stripped
        if configuration.despeckle && configuration.maxSpecklePixels > 0 {
            current = despecklePreservingDiacritics(current)
        }
        return (current, result)
    }

    /// Excises large, solid, edge-anchored dark blocks beyond the standard border-strip limit.
    ///
    /// The page is reduced to a coarse grid of black densities. For each eligible side, every
    /// grid line (row for left/right, column for top/bottom) is scanned inward from the edge:
    /// the leading cells must be empty paper for no more than `maxDetachedGapRatio` of the
    /// page, then a solid run of dark cells must follow. Contiguous valid lines form a
    /// candidate, which is erased only if it is deeper than the standard strip limit, no
    /// deeper than `maxDepthRatio`, and spans at least `minSpanRatio` of the edge.
    public func removeMacroBorderBlocks(
        from bitmap: borrowing BinaryBitmap,
        context: MacroBorderContext
    ) -> (bitmap: BinaryBitmap, result: MacroBorderResult) {
        let cfg = configuration.macroBorder
        var result = MacroBorderResult(triggers: context.triggers)
        let width = bitmap.width
        let height = bitmap.height
        guard width >= 64, height >= 64 else { return (copy bitmap, result) }

        let cell = max(4, min(width, height) / cfg.cellDivisor)
        let cols = (width + cell - 1) / cell
        let rows = (height + cell - 1) / cell

        // Black density per cell; a cell is dark when solid or at least textured-dense (the blank-row
        // test on whole candidates later separates grain from text).
        var density = [Double](repeating: 0, count: cols * rows)
        var isDark = [Bool](repeating: false, count: cols * rows)
        for cy in 0..<rows {
            let y0 = cy * cell
            let y1 = min(height, y0 + cell)
            for cx in 0..<cols {
                let x0 = cx * cell
                let x1 = min(width, x0 + cell)
                var black = 0
                for y in y0..<y1 {
                    for x in x0..<x1 where bitmap[x, y] { black += 1 }
                }
                let d = Double(black) / Double((x1 - x0) * (y1 - y0))
                density[cy * cols + cx] = d
                isDark[cy * cols + cx] = d >= cfg.texturedCellDensity
            }
        }

        var output = copy bitmap
        var erasedRects: [(x0: Int, y0: Int, x1: Int, y1: Int)] = []
        var ringRects: [(x0: Int, y0: Int, x1: Int, y1: Int)] = []
        let stripLimit = configuration.maxBorderStripThicknessRatio

        for side in DocumentQuadDetection.Side.allCases where context.eligibleSides.contains(side) {
            let horizontalSide = (side == .left || side == .right)
            let lineCount = horizontalSide ? rows : cols
            let depthCount = horizontalSide ? cols : rows
            let pageDepth = horizontalSide ? width : height
            let gapCells = Int((cfg.maxDetachedGapRatio * Double(depthCount)).rounded(.up))

            func cellDensity(line: Int, depth: Int) -> Double {
                switch side {
                case .left: return density[line * cols + depth]
                case .right: return density[line * cols + (cols - 1 - depth)]
                case .top: return density[depth * cols + line]
                case .bottom: return density[(rows - 1 - depth) * cols + line]
                }
            }

            func cellIsDark(line: Int, depth: Int) -> Bool {
                switch side {
                case .left: return isDark[line * cols + depth]
                case .right: return isDark[line * cols + (cols - 1 - depth)]
                case .top: return isDark[depth * cols + line]
                case .bottom: return isDark[(rows - 1 - depth) * cols + line]
                }
            }

            // Per line: nil when no solid block anchors at this edge, else the inner depth (cells,
            // counted from the page edge) of the contiguous solid run.
            var lineDepth = [Int?](repeating: nil, count: lineCount)
            var lineSolid = [Bool](repeating: true, count: lineCount)
            for line in 0..<lineCount {
                var start: Int?
                var d = 0
                while d < depthCount && d <= gapCells {
                    let v = cellDensity(line: line, depth: d)
                    if cellIsDark(line: line, depth: d) { start = d; break }
                    if d > 1 && v > cfg.emptyCellDensity { break }
                    d += 1
                }
                guard let s = start else { continue }

                var end = s
                var darkCount = 0
                var j = s
                var missesInARow = 0
                while j < depthCount {
                    if cellIsDark(line: line, depth: j) {
                        end = j
                        darkCount += 1
                        missesInARow = 0
                    } else {
                        missesInARow += 1
                        if missesInARow >= 2 { break }
                    }
                    j += 1
                }
                lineDepth[line] = end + 1
                lineSolid[line] = Double(darkCount) / Double(end - s + 1) >= cfg.minSolidity
            }

            // Group lines with a (solid) anchored block into runs, bridging single-line gaps.
            var runs: [(start: Int, end: Int)] = []
            var runStart: Int?
            var lastValid = -10
            for line in 0..<lineCount {
                let valid = lineDepth[line] != nil
                if valid {
                    if runStart == nil { runStart = line }
                    lastValid = line
                } else if let rs = runStart, line - lastValid > 1 {
                    runs.append((rs, lastValid))
                    runStart = nil
                }
            }
            if let rs = runStart { runs.append((rs, lastValid)) }

            for run in runs {
                var maxDepth = 0
                var solidLines = 0
                var validLines = 0
                for line in run.start...run.end {
                    guard let depth = lineDepth[line] else { continue }
                    maxDepth = max(maxDepth, depth)
                    validLines += 1
                    if lineSolid[line] { solidLines += 1 }
                }
                let depthFraction = Double(maxDepth * cell) / Double(pageDepth)
                // Blocks inside the standard strip limit belong to `removeScanBorders`.
                guard depthFraction > stripLimit else { continue }

                let spanFraction = Double((run.end - run.start + 1) * cell) / Double(horizontalSide ? height : width)
                let name = side.rawValue
                if depthFraction > cfg.maxDepthRatio {
                    result.rejectedCandidates.append("\(name):tooDeep")
                    continue
                }
                if spanFraction < cfg.minSpanRatio {
                    result.rejectedCandidates.append("\(name):shortSpan")
                    continue
                }
                if Double(solidLines) / Double(max(1, validLines)) < cfg.minSolidity {
                    result.rejectedCandidates.append("\(name):notSolid")
                    continue
                }
                let candidateRect = Self.macroRect(
                    side: side, run: run, maxDepth: maxDepth, cell: cell, pageWidth: width, pageHeight: height
                )
                if Self.blankRowFraction(of: candidateRect, in: bitmap) > cfg.maxBlankRowFraction {
                    result.rejectedCandidates.append("\(name):textLike")
                    continue
                }

                let rect = candidateRect
                erasedRects.append(rect)
                ringRects.append((
                    max(0, rect.x0 - cell), max(0, rect.y0 - cell),
                    min(width, rect.x1 + cell), min(height, rect.y1 + cell)
                ))
                result.excisedDepthBySide[side] = max(result.excisedDepthBySide[side], depthFraction)
            }
        }

        guard !erasedRects.isEmpty else { return (output, result) }

        let before = output.countBlackPixels()
        for r in erasedRects {
            for y in r.y0..<r.y1 {
                for x in r.x0..<r.x1 where output[x, y] {
                    output.setPixel(x: x, y: y, isBlack: false)
                }
            }
        }
        // Fringe fragments of the block that straddle the cell boundary: erase components that now
        // lie entirely inside the ring around an excised rectangle. A glyph reaching beyond it is kept whole.
        output = ConnectedComponentAnalyzer.filterComponents(
            in: output,
            connectivity: configuration.connectivity
        ) { comp in
            let b = comp.boundingBox
            for ring in ringRects
            where b.minX >= ring.x0 && b.maxX <= ring.x1 && b.minY >= ring.y0 && b.maxY <= ring.y1 {
                return false
            }
            return true
        }
        let after = output.countBlackPixels()
        result.excisedFraction = Double(max(0, before - after)) / Double(width * height)
        return (output, result)
    }

    private static func macroRect(
        side: DocumentQuadDetection.Side,
        run: (start: Int, end: Int),
        maxDepth: Int,
        cell: Int,
        pageWidth: Int,
        pageHeight: Int
    ) -> (x0: Int, y0: Int, x1: Int, y1: Int) {
        let horizontalSide = (side == .left || side == .right)
        let a0 = run.start * cell
        let a1 = min(horizontalSide ? pageHeight : pageWidth, (run.end + 1) * cell)
        let depthPx = min(horizontalSide ? pageWidth : pageHeight, maxDepth * cell)
        switch side {
        case .left: return (0, a0, depthPx, a1)
        case .right: return (pageWidth - depthPx, a0, pageWidth, a1)
        case .top: return (a0, 0, a1, depthPx)
        case .bottom: return (a0, pageHeight - depthPx, a1, pageHeight)
        }
    }

    /// Fraction of the rectangle's pixel rows containing (almost) no black — text has line gaps.
    private static func blankRowFraction(
        of rect: (x0: Int, y0: Int, x1: Int, y1: Int),
        in bitmap: borrowing BinaryBitmap
    ) -> Double {
        let rowWidth = rect.x1 - rect.x0
        let rowCount = rect.y1 - rect.y0
        guard rowWidth > 0, rowCount > 0 else { return 0 }
        let limit = max(1, rowWidth / 50)
        var blank = 0
        for y in rect.y0..<rect.y1 {
            var black = 0
            for x in rect.x0..<rect.x1 where bitmap[x, y] {
                black += 1
                if black >= limit { break }
            }
            if black < limit { blank += 1 }
        }
        return Double(blank) / Double(rowCount)
    }
}
