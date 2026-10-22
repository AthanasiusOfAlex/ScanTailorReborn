import Foundation
import ScanTailorContracts

/// Traces curved horizontal text lines across a binarized page to provide geometric constraints
/// for 3D cubic-sheet dewarping (`CylindricalDewarpSolver`).
///
/// Combines ScanTailor-Advanced's connected-component filtering and column-slice baseline sampling
/// with `lmmx/page-dewarp`'s bidirectional horizontal component chaining and Huber-reweighted
/// cubic smoothing to reject ascenders, descenders, and punctuation outliers.
public struct TextLineTracer: Sendable {

    /// Configuration parameters for text-line extraction and baseline smoothing.
    public struct Configuration: Sendable, Equatable {
        /// Minimum candidate component height in pixels (default: `6`).
        public var minComponentHeight: Int

        /// Maximum candidate component height as a fraction of image height (default: `0.08`).
        public var maxComponentHeightFraction: Double

        /// Maximum candidate component width as a fraction of image width (default: `0.45`).
        public var maxComponentWidthFraction: Double

        /// Maximum horizontal gap between consecutive components in a line, as a multiple of median character height (default: `4.5`).
        public var maxHorizontalGapFactor: Double

        /// Maximum vertical centerline offset between adjacent linked components, as a multiple of median character height (default: `0.85`).
        public var maxVerticalOffsetFactor: Double

        /// Maximum local slope angle (in degrees) between adjacent linked components (default: `25.0`).
        public var maxLocalSlopeDegrees: Double

        /// Minimum number of connected components required to form a valid text line (default: `4`).
        public var minComponentsPerLine: Int

        /// Minimum horizontal span of a traced text line as a fraction of the page width (default: `0.15`).
        public var minLineSpanFraction: Double

        /// Minimum absolute horizontal span in pixels (default: `80.0`).
        public var minLineSpanPixels: Double

        /// Horizontal step in pixels between output polyline vertices (default: `16.0`).
        public var sampleStepPixels: Double

        public init(
            minComponentHeight: Int = 6,
            maxComponentHeightFraction: Double = 0.08,
            maxComponentWidthFraction: Double = 0.45,
            maxHorizontalGapFactor: Double = 4.5,
            maxVerticalOffsetFactor: Double = 0.85,
            maxLocalSlopeDegrees: Double = 25.0,
            minComponentsPerLine: Int = 4,
            minLineSpanFraction: Double = 0.15,
            minLineSpanPixels: Double = 80.0,
            sampleStepPixels: Double = 16.0
        ) {
            self.minComponentHeight = max(2, minComponentHeight)
            self.maxComponentHeightFraction = max(0.01, min(0.5, maxComponentHeightFraction))
            self.maxComponentWidthFraction = max(0.05, min(0.95, maxComponentWidthFraction))
            self.maxHorizontalGapFactor = max(1.0, maxHorizontalGapFactor)
            self.maxVerticalOffsetFactor = max(0.2, maxVerticalOffsetFactor)
            self.maxLocalSlopeDegrees = max(5.0, min(60.0, maxLocalSlopeDegrees))
            self.minComponentsPerLine = max(2, minComponentsPerLine)
            self.minLineSpanFraction = max(0.02, min(0.9, minLineSpanFraction))
            self.minLineSpanPixels = max(16.0, minLineSpanPixels)
            self.sampleStepPixels = max(4.0, sampleStepPixels)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Traces smooth horizontal text-line polylines across `bitmap`.
    /// - Parameter bitmap: Binarized page image (`1` = black foreground ink).
    /// - Returns: Array of `PolyLine2D` curves ordered top-to-bottom.
    public func traceLines(in bitmap: borrowing BinaryBitmap) -> [PolyLine2D] {
        let width = bitmap.width
        let height = bitmap.height
        guard width >= 32, height >= 32 else { return [] }

        let allComponents = ConnectedComponentAnalyzer.extractComponents(from: bitmap, connectivity: .eight)
        guard !allComponents.isEmpty else { return [] }

        let maxCompH = max(configuration.minComponentHeight + 2, Int(Double(height) * configuration.maxComponentHeightFraction))
        let maxCompW = max(16, Int(Double(width) * configuration.maxComponentWidthFraction))

        // Initial coarse filter to estimate dominant character height
        let initialCandidates = allComponents.filter { comp in
            let w = comp.boundingBox.width
            let h = comp.boundingBox.height
            guard h >= configuration.minComponentHeight && h <= maxCompH else { return false }
            guard w >= 2 && w <= maxCompW else { return false }
            guard comp.pixelCount >= 4 else { return false }
            let aspect = Double(w) / Double(h)
            return aspect >= 0.08 && aspect <= 12.0 && comp.density >= 0.06
        }

        guard initialCandidates.count >= configuration.minComponentsPerLine else { return [] }

        // Compute median component height
        let sortedHeights = initialCandidates.map { Double($0.boundingBox.height) }.sorted()
        let medianHeight = sortedHeights[sortedHeights.count / 2]

        // Refine candidates around the dominant character scale
        let minRefinedH = max(Double(configuration.minComponentHeight), medianHeight * 0.35)
        let maxRefinedH = min(Double(maxCompH), medianHeight * 3.0)

        var candidates = initialCandidates.filter { comp in
            let h = Double(comp.boundingBox.height)
            return h >= minRefinedH && h <= maxRefinedH
        }
        guard candidates.count >= configuration.minComponentsPerLine else { return [] }

        // Sort candidates left-to-right by horizontal center
        candidates.sort { (a: ConnectedComponent, b: ConnectedComponent) in
            let midXA = a.boundingBox.minX + a.boundingBox.maxX
            let midXB = b.boundingBox.minX + b.boundingBox.maxX
            if midXA != midXB {
                return midXA < midXB
            }
            return (a.boundingBox.minY + a.boundingBox.maxY) < (b.boundingBox.minY + b.boundingBox.maxY)
        }

        // Bidirectional nearest-neighbor chaining into horizontal text lines
        let chains = buildComponentChains(candidates: candidates, medianHeight: medianHeight)
        let minRequiredSpan = min(
            Double(width) * 0.75,
            max(configuration.minLineSpanPixels, Double(width) * configuration.minLineSpanFraction)
        )

        var tracedLines: [(meanY: Double, polyline: PolyLine2D)] = []
        tracedLines.reserveCapacity(chains.count)

        for chain in chains {
            guard chain.count >= configuration.minComponentsPerLine else { continue }
            var chainMinX = Int.max
            var chainMaxX = Int.min
            for idx in chain {
                let box = candidates[idx].boundingBox
                if box.minX < chainMinX { chainMinX = box.minX }
                if box.maxX > chainMaxX { chainMaxX = box.maxX }
            }
            let span = Double(chainMaxX - chainMinX)
            guard span >= minRequiredSpan else { continue }

            if let line = fitSmoothPolyline(
                chain: chain,
                candidates: candidates,
                bitmap: bitmap,
                medianHeight: medianHeight
            ) {
                let meanY = line.points.reduce(0.0) { $0 + $1.y } / Double(line.points.count)
                tracedLines.append((meanY: meanY, polyline: line))
            }
        }

        tracedLines.sort { $0.meanY < $1.meanY }
        return tracedLines.map(\.polyline)
    }

    // MARK: - Component Chaining

    private func buildComponentChains(
        candidates: [ConnectedComponent],
        medianHeight: Double
    ) -> [[Int]] {
        let n = candidates.count
        let maxGap = configuration.maxHorizontalGapFactor * medianHeight
        let maxOverlap = 0.45 * medianHeight
        let maxVertOffset = configuration.maxVerticalOffsetFactor * medianHeight
        let maxSlope = tan(configuration.maxLocalSlopeDegrees * .pi / 180.0)

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
                    // Since candidates are sorted by midX, once minX - maxX exceeds maxGap + maxCompWidth we can stop
                    if Double(boxJ.minX - boxI.maxX) > maxGap + medianHeight * 4.0 {
                        break
                    }
                    continue
                }
                if gapX < -maxOverlap { continue }

                let cyJ = 0.5 * Double(boxJ.minY + boxJ.maxY)
                let dy = abs(cyJ - cyI)
                if dy > maxVertOffset { continue }

                let dx = max(cxJ - cxI, medianHeight * 0.5)
                if (dy / dx) > maxSlope { continue }

                // Vertical overlap check or tight centerline alignment
                let overlapY = min(boxI.maxY, boxJ.maxY) - max(boxI.minY, boxJ.minY)
                if overlapY <= 0 && dy > medianHeight * 0.45 { continue }

                // Distance cost penalizing vertical deviation more heavily than horizontal gap
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

        // Keep only mutual best matches (i -> j and j -> i)
        var visited = [Bool](repeating: false, count: n)
        var chains: [[Int]] = []

        for i in 0..<n {
            if visited[i] { continue }
            // Start at the leftmost node of a mutual chain
            let prev = bestLeft[i]
            if prev != -1 && bestRight[prev] == i {
                continue
            }

            var chain: [Int] = []
            var curr = i
            while curr != -1 && !visited[curr] {
                visited[curr] = true
                chain.append(curr)
                let next = bestRight[curr]
                if next != -1 && bestLeft[next] == curr {
                    curr = next
                } else {
                    break
                }
            }
            if chain.count >= configuration.minComponentsPerLine {
                chains.append(chain)
            }
        }

        return chains
    }

    // MARK: - Subpixel Column Sampling & Robust Cubic Fitting

    private func fitSmoothPolyline(
        chain: [Int],
        candidates: [ConnectedComponent],
        bitmap: borrowing BinaryBitmap,
        medianHeight: Double
    ) -> PolyLine2D? {
        // Collect column-wise vertical centerline samples across all components in the chain
        var samples: [Point2D] = []
        samples.reserveCapacity(chain.count * 4)

        for idx in chain {
            let box = candidates[idx].boundingBox
            let w = box.width
            // Sample up to 5 columns per component (or every column for narrow glyphs)
            let step = max(1, w / 4)
            var x = box.minX
            while x < box.maxX {
                var minY = Int.max
                var maxY = Int.min
                for y in box.minY..<box.maxY {
                    if bitmap[x, y] {
                        if y < minY { minY = y }
                        if y > maxY { maxY = y }
                    }
                }
                if minY <= maxY {
                    // Use the vertical midpoint of the glyph column slice
                    let centerY = 0.5 * Double(minY + maxY)
                    samples.append(Point2D(x: Double(x) + 0.5, y: centerY))
                }
                x += step
            }
        }

        guard samples.count >= 4 else { return nil }

        let minX = samples.first!.x
        let maxX = samples.last!.x
        let spanX = maxX - minX
        guard spanX >= configuration.minLineSpanPixels else { return nil }

        let midX = 0.5 * (minX + maxX)
        let halfSpan = max(1.0, 0.5 * spanX)

        // Fit cubic polynomial y(u) = c0 + c1*u + c2*u^2 + c3*u^3 where u = (x - midX) / halfSpan in [-1, 1]
        // using Iteratively Reweighted Least Squares (IRLS) with Huber weights to ignore ascenders/descenders
        var weights = [Double](repeating: 1.0, count: samples.count)
        var coeffs: (Double, Double, Double, Double) = (0, 0, 0, 0)
        let huberDelta = max(1.5, 0.25 * medianHeight)

        for _ in 0..<5 {
            guard let fitted = solveWeightedCubic(
                samples: samples,
                weights: weights,
                midX: midX,
                halfSpan: halfSpan
            ) else {
                return nil
            }
            coeffs = fitted

            for i in 0..<samples.count {
                let u = (samples[i].x - midX) / halfSpan
                let predY = coeffs.0 + u * (coeffs.1 + u * (coeffs.2 + u * coeffs.3))
                let absRes = abs(samples[i].y - predY)
                if absRes <= huberDelta {
                    weights[i] = 1.0
                } else {
                    weights[i] = huberDelta / absRes
                }
            }
        }

        // Sample the fitted smooth curve at uniform horizontal steps
        let numSegments = max(2, Int(ceil(spanX / configuration.sampleStepPixels)))
        let stepX = spanX / Double(numSegments)
        var points: [Point2D] = []
        points.reserveCapacity(numSegments + 1)

        for k in 0...numSegments {
            let x = min(maxX, minX + Double(k) * stepX)
            let u = (x - midX) / halfSpan
            let y = coeffs.0 + u * (coeffs.1 + u * (coeffs.2 + u * coeffs.3))
            points.append(Point2D(x: x, y: y))
        }

        return PolyLine2D(points: points)
    }

    private func solveWeightedCubic(
        samples: [Point2D],
        weights: [Double],
        midX: Double,
        halfSpan: Double
    ) -> (Double, Double, Double, Double)? {
        // Normal equations (A^T W A) c = A^T W y for basis [1, u, u^2, u^3]
        var ata = [Double](repeating: 0.0, count: 16)
        var aty = [Double](repeating: 0.0, count: 4)

        for i in 0..<samples.count {
            let w = weights[i]
            let u = (samples[i].x - midX) / halfSpan
            let u2 = u * u
            let u3 = u2 * u
            let basis = (1.0, u, u2, u3)
            let bArr = [basis.0, basis.1, basis.2, basis.3]
            let y = samples[i].y

            for r in 0..<4 {
                let wb = w * bArr[r]
                aty[r] += wb * y
                for c in r..<4 {
                    ata[r * 4 + c] += wb * bArr[c]
                }
            }
        }

        // Fill lower triangle and add tiny Tikhonov regularization on higher-order terms
        ata[2 * 4 + 2] += 1e-6
        ata[3 * 4 + 3] += 1e-5
        for r in 1..<4 {
            for c in 0..<r {
                ata[r * 4 + c] = ata[c * 4 + r]
            }
        }

        // Solve 4x4 linear system via Gaussian elimination with partial pivoting
        for col in 0..<4 {
            var pivotRow = col
            var maxVal = abs(ata[col * 4 + col])
            for row in (col + 1)..<4 {
                let v = abs(ata[row * 4 + col])
                if v > maxVal {
                    maxVal = v
                    pivotRow = row
                }
            }
            guard maxVal > 1e-12 else { return nil }

            if pivotRow != col {
                for k in col..<4 {
                    let tmp = ata[col * 4 + k]
                    ata[col * 4 + k] = ata[pivotRow * 4 + k]
                    ata[pivotRow * 4 + k] = tmp
                }
                let tmpY = aty[col]
                aty[col] = aty[pivotRow]
                aty[pivotRow] = tmpY
            }

            let pivot = ata[col * 4 + col]
            for row in (col + 1)..<4 {
                let factor = ata[row * 4 + col] / pivot
                ata[row * 4 + col] = 0.0
                for k in (col + 1)..<4 {
                    ata[row * 4 + k] -= factor * ata[col * 4 + k]
                }
                aty[row] -= factor * aty[col]
            }
        }

        var sol = [Double](repeating: 0.0, count: 4)
        for row in stride(from: 3, through: 0, by: -1) {
            var sum = aty[row]
            for k in (row + 1)..<4 {
                sum -= ata[row * 4 + k] * sol[k]
            }
            sol[row] = sum / ata[row * 4 + row]
        }

        return (sol[0], sol[1], sol[2], sol[3])
    }
}
