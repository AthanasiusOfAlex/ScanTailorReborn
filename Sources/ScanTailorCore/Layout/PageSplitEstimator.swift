import Foundation
import ScanTailorContracts

/// Classification of whether an input scan represents a single page or a two-page spread.
public enum SpreadLayoutType: String, Sendable, Equatable, Codable {
    case singlePage
    case twoPageSpread
}

/// Policy controlling how `PageSplitEstimator` decides between single-page and two-page spreads.
public enum PageSplitMode: String, Sendable, Equatable, Codable {
    case automatic
    case singlePage
    case twoPageSpread
}

/// Identifies which side of a scan a split page slice originated from.
public enum PageSide: String, Sendable, Equatable, Codable {
    case single
    case leftVerso
    case rightRecto
}

/// Parametric representation of a gutter split line across a two-page spread.
///
/// The line passes through `(centerX, height / 2)` at angle `tiltDegrees` clockwise from the
/// vertical axis:
/// $$x(y) = \text{centerX} - \left(y - \frac{H}{2}\right)\tan(\phi)$$
public struct GutterSplitLine: Sendable, Equatable, Codable {
    public let centerX: Double
    public let normalizedCenterX: Double
    public let tiltDegrees: Double

    public init(centerX: Double, normalizedCenterX: Double, tiltDegrees: Double = 0.0) {
        self.centerX = centerX
        self.normalizedCenterX = normalizedCenterX
        self.tiltDegrees = tiltDegrees
    }

    @inlinable
    public func x(atY y: Double, height: Int) -> Double {
        let halfHeight = Double(height) * 0.5
        let radians = tiltDegrees * .pi / 180.0
        return centerX - (y - halfHeight) * tan(radians)
    }

    public func polyLine(height: Int) -> PolyLine2D {
        let h = Double(max(1, height))
        return PolyLine2D(points: [
            Point2D(x: x(atY: 0.0, height: height), y: 0.0),
            Point2D(x: x(atY: h * 0.5, height: height), y: h * 0.5),
            Point2D(x: x(atY: h, height: height), y: h)
        ])
    }
}

/// Result of analyzing a scanned page or spread for gutter splitting.
public struct PageSplitDecision: Sendable, Equatable, Codable {
    public let layoutType: SpreadLayoutType
    public let splitLine: GutterSplitLine?
    public let confidence: Double

    public init(layoutType: SpreadLayoutType, splitLine: GutterSplitLine?, confidence: Double) {
        self.layoutType = layoutType
        self.splitLine = splitLine
        self.confidence = confidence
    }
}

/// A cropped grayscale page produced by splitting an input scan.
public struct SplitPageSlice: Sendable, Equatable {
    public let side: PageSide
    public let buffer: GrayscaleBuffer
    public let sourceBounds: Rect2I

    public init(side: PageSide, buffer: GrayscaleBuffer, sourceBounds: Rect2I) {
        self.side = side
        self.buffer = buffer
        self.sourceBounds = sourceBounds
    }
}

/// Detects dual-page spreads, locates the gutter or dark spine crease, and splits spreads into
/// separate left (verso) and right (recto) pages.
public struct PageSplitEstimator: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var minimumTwoPageAspectRatio: Double
        public var definiteTwoPageAspectRatio: Double
        public var searchRangeNormalized: ClosedRange<Double>
        public var maxTiltDegrees: Double
        public var tiltStepDegrees: Double

        public init(
            minimumTwoPageAspectRatio: Double = 1.12,
            definiteTwoPageAspectRatio: Double = 1.32,
            searchRangeNormalized: ClosedRange<Double> = 0.30...0.70,
            maxTiltDegrees: Double = 10.0,
            tiltStepDegrees: Double = 0.5
        ) {
            self.minimumTwoPageAspectRatio = minimumTwoPageAspectRatio
            self.definiteTwoPageAspectRatio = definiteTwoPageAspectRatio
            self.searchRangeNormalized = searchRangeNormalized
            self.maxTiltDegrees = maxTiltDegrees
            self.tiltStepDegrees = tiltStepDegrees
        }
    }

    public init() {}

    /// Estimates whether `buffer` is a single page or a two-page spread and locates the gutter line.
    public static func estimateSplit(
        in buffer: borrowing GrayscaleBuffer,
        mode: PageSplitMode = .automatic,
        configuration: Configuration = Configuration()
    ) -> PageSplitDecision {
        let origWidth = buffer.width
        let origHeight = buffer.height
        guard origWidth >= 16 && origHeight >= 16 else {
            return PageSplitDecision(layoutType: .singlePage, splitLine: nil, confidence: 1.0)
        }
        if mode == .singlePage {
            return PageSplitDecision(layoutType: .singlePage, splitLine: nil, confidence: 1.0)
        }

        // 1. Downsample to working resolution (max dimension <= 1200) for fast layout analysis.
        var working = copy buffer
        var scaleFactor = 1.0
        while max(working.width, working.height) > 1200 && working.width >= 64 && working.height >= 64 {
            working = SkewEstimator.downsampleGrayscale2x(working)
            scaleFactor *= 2.0
        }

        let w = working.width
        let h = working.height
        let binary = SkewEstimator.binarizeForLayoutAnalysis(working)

        // 2. Build horizontal ink profiles across vertical slices (bands) and a spine-shadow profile.
        let bandCount = 16
        let yStart = max(0, Int((Double(h) * 0.08).rounded(.down)))
        let yEnd = min(h, max(yStart + 1, Int((Double(h) * 0.92).rounded(.up))))
        let activeHeight = max(1, yEnd - yStart)

        var bandInk = [Int](repeating: 0, count: bandCount * w)
        var bandCenterY = [Double](repeating: 0.0, count: bandCount)
        for b in 0..<bandCount {
            let by0 = yStart + (b * activeHeight) / bandCount
            let by1 = max(by0 + 1, yStart + ((b + 1) * activeHeight) / bandCount)
            bandCenterY[b] = Double(by0 + by1) * 0.5
            for y in by0..<min(h, by1) {
                for x in 0..<w where binary[x, y] {
                    bandInk[b * w + x] += 1
                }
            }
        }

        // Compute dark spine crease contrast per (band, x): compares narrow center darkness to flanking background.
        // A true spine shadow/crease is vertically continuous across most rows of the band (including inter-line spaces),
        // whereas text columns only darken the rows occupied by horizontal text strokes.
        var bandSpineContrast = [Double](repeating: 0.0, count: bandCount * w)
        let flankOffset = max(4, min(24, w / 25))
        working.pixels.withUnsafeBufferPointer { pixels in
            let stride = working.rowBytes
            for b in 0..<bandCount {
                let by0 = yStart + (b * activeHeight) / bandCount
                let by1 = min(h, max(by0 + 1, yStart + ((b + 1) * activeHeight) / bandCount))
                let rowCount = max(1, by1 - by0)
                let rows = Double(rowCount)
                for x in flankOffset..<(w - flankOffset) {
                    var centerSum = 0
                    var leftFlankSum = 0
                    var rightFlankSum = 0
                    var darkRowCount = 0
                    for y in by0..<by1 {
                        let rowBase = y * stride
                        let cVal = Int(pixels[rowBase + x])
                        let lVal = Int(pixels[rowBase + x - flankOffset])
                        let rVal = Int(pixels[rowBase + x + flankOffset])
                        centerSum += cVal
                        leftFlankSum += lVal
                        rightFlankSum += rVal
                        let rowFlank = (lVal + rVal) / 2
                        if rowFlank - cVal >= 14 {
                            darkRowCount += 1
                        }
                    }
                    // Require vertical continuity (>= 75% of rows in the band darkened) so periodic text lines
                    // are never mistaken for a continuous vertical spine shadow.
                    guard darkRowCount * 4 >= rowCount * 3 else { continue }
                    let centerMean = Double(centerSum) / rows
                    let flankMean = Double(leftFlankSum + rightFlankSum) / (2.0 * rows)
                    let dip = max(0.0, flankMean - centerMean)
                    bandSpineContrast[b * w + x] = dip
                }
            }
        }

        // 3. Search over tilt angles and candidate gutter centers.
        let minX = max(4, Int((Double(w) * configuration.searchRangeNormalized.lowerBound).rounded(.down)))
        let maxX = min(w - 5, Int((Double(w) * configuration.searchRangeNormalized.upperBound).rounded(.up)))
        guard minX <= maxX else {
            return PageSplitDecision(layoutType: .singlePage, splitLine: nil, confidence: 0.5)
        }

        let corridorHalfWidth = max(1, w / 160)
        let flankWindow = max(6, w / 20)
        let halfH = Double(h) * 0.5
        let stepDeg = max(0.25, configuration.tiltStepDegrees)
        let maxTilt = max(0.0, configuration.maxTiltDegrees)

        var bestCost = Double.greatestFiniteMagnitude
        var bestCenterX = Double(w) * 0.5
        var bestTiltDeg = 0.0
        var bestValleyClearance = 0.0

        var tilt = -maxTilt
        while tilt <= maxTilt + 1e-9 {
            let tanPhi = tan(tilt * .pi / 180.0)

            // Precompute smoothed corridor ink and spine score per (band, x).
            for cx in minX...maxX {
                var corridorInkSum = 0.0
                var flankInkSum = 0.0
                var spineBonusSum = 0.0
                var gapMidpointOffsetSum = 0.0
                var validBands = 0
                var spineConsistentBands = 0

                for b in 0..<bandCount {
                    let y = bandCenterY[b]
                    let xAtBand = Int((Double(cx) - (y - halfH) * tanPhi).rounded())
                    if xAtBand < corridorHalfWidth + flankWindow || xAtBand >= w - corridorHalfWidth - flankWindow {
                        continue
                    }
                    validBands += 1
                    let rowOffset = b * w

                    var cInk = 0
                    for dx in -corridorHalfWidth...corridorHalfWidth {
                        cInk += bandInk[rowOffset + xAtBand + dx]
                    }
                    let corridorDensity = Double(cInk) / Double(2 * corridorHalfWidth + 1)

                    var lInk = 0
                    var rInk = 0
                    for dx in 1...flankWindow {
                        lInk += bandInk[rowOffset + xAtBand - corridorHalfWidth - dx]
                        rInk += bandInk[rowOffset + xAtBand + corridorHalfWidth + dx]
                    }
                    let flankDensity = Double(lInk + rInk) / Double(2 * flankWindow)

                    let spineDip = bandSpineContrast[rowOffset + xAtBand]
                    if spineDip > 18.0 {
                        spineConsistentBands += 1
                        spineBonusSum += spineDip
                    }

                    // If this band has a spine crease (dark vertical line flanked by lighter paper),
                    // do not penalize the dark pixels of the spine crease itself.
                    if spineDip > 25.0 && corridorDensity > flankDensity {
                        corridorInkSum += max(0.0, corridorDensity - spineDip * 0.25)
                    } else {
                        corridorInkSum += corridorDensity
                    }
                    flankInkSum += flankDensity
                }

                guard validBands >= bandCount / 2 else { continue }

                // Measure inner-margin gap midpoint alignment on bands with text on both sides.
                let textThreshold = max(1, (activeHeight / bandCount) / 14)
                var gapBandCount = 0
                for b in 0..<bandCount {
                    let y = bandCenterY[b]
                    let xAtBand = Int((Double(cx) - (y - halfH) * tanPhi).rounded())
                    if xAtBand < minX || xAtBand > maxX { continue }
                    let rowOffset = b * w

                    // Only measure gap edges when the corridor itself is mostly clear or is a narrow spine line.
                    let spineDip = bandSpineContrast[rowOffset + xAtBand]
                    let scanRadius = spineDip > 25.0 ? max(3, corridorHalfWidth + 2) : 0

                    var leftEdge: Int? = nil
                    let leftSearchLimit = max(4, Int(Double(w) * 0.12))
                    var lx = xAtBand - scanRadius
                    while lx >= leftSearchLimit {
                        if bandInk[rowOffset + lx] >= textThreshold {
                            leftEdge = lx
                            break
                        }
                        lx -= 1
                    }

                    var rightEdge: Int? = nil
                    let rightSearchLimit = min(w - 5, Int(Double(w) * 0.88))
                    var rx = xAtBand + scanRadius
                    while rx <= rightSearchLimit {
                        if bandInk[rowOffset + rx] >= textThreshold {
                            rightEdge = rx
                            break
                        }
                        rx += 1
                    }

                    if let le = leftEdge, let re = rightEdge, (re - le) >= max(4, w / 40) {
                        let midpoint = Double(le + re) * 0.5
                        gapMidpointOffsetSum += abs(Double(xAtBand) - midpoint) / Double(w)
                        gapBandCount += 1
                    }
                }

                let meanCorridorInk = corridorInkSum / Double(validBands)
                let meanFlankInk = flankInkSum / Double(validBands)
                let spineFactor = spineConsistentBands >= (validBands * 2 / 3)
                    ? (spineBonusSum / Double(validBands)) * 0.08
                    : 0.0
                let gapPenalty = gapBandCount > 0
                    ? (gapMidpointOffsetSum / Double(gapBandCount)) * 18.0
                    : 2.5
                let centerPrior = abs(Double(cx) / Double(w) - 0.5) * 1.8
                let tiltPrior = abs(tilt) * 0.015

                let cost = meanCorridorInk * 3.5 + gapPenalty + centerPrior + tiltPrior - spineFactor
                if cost < bestCost {
                    bestCost = cost
                    bestCenterX = Double(cx)
                    bestTiltDeg = tilt
                    bestValleyClearance = max(0.0, meanFlankInk - meanCorridorInk) + spineFactor
                }
            }

            tilt += stepDeg
        }

        let fullCenterX = (bestCenterX + 0.5) * scaleFactor
        let normalizedCenterX = min(max(fullCenterX / Double(origWidth), 0.0), 1.0)
        let splitLine = GutterSplitLine(
            centerX: fullCenterX,
            normalizedCenterX: normalizedCenterX,
            tiltDegrees: bestTiltDeg
        )

        if mode == .twoPageSpread {
            return PageSplitDecision(layoutType: .twoPageSpread, splitLine: splitLine, confidence: 0.95)
        }

        // 4. Automatic single-page vs two-page classification.
        let aspectRatio = Double(origWidth) / Double(origHeight)
        if aspectRatio < configuration.minimumTwoPageAspectRatio {
            return PageSplitDecision(layoutType: .singlePage, splitLine: nil, confidence: 0.95)
        }

        // Compute left vs right page ink mass outside the central gutter corridor.
        var leftMass = 0
        var rightMass = 0
        var centerCorridorMass = 0
        let corridorRadius = max(2, w / 60)
        for b in 0..<bandCount {
            let y = bandCenterY[b]
            let splitX = Int((bestCenterX - (y - halfH) * tan(bestTiltDeg * .pi / 180.0)).rounded())
            let rowOffset = b * w
            for x in 0..<w {
                let ink = bandInk[rowOffset + x]
                if abs(x - splitX) <= corridorRadius {
                    centerCorridorMass += ink
                } else if x < splitX - corridorRadius {
                    leftMass += ink
                } else {
                    rightMass += ink
                }
            }
        }

        let totalSideMass = max(1, leftMass + rightMass)
        let balanceRatio = Double(min(leftMass, rightMass)) / Double(max(1, max(leftMass, rightMass)))
        let sideMeanPerCol = Double(totalSideMass) / Double(max(1, w - 2 * corridorRadius - 1))
        let corridorMeanPerCol = Double(centerCorridorMass) / Double(2 * corridorRadius + 1)

        let hasClearGutter = corridorMeanPerCol < sideMeanPerCol * 0.45 || bestValleyClearance > 0.8
        let isDefinitelyWide = aspectRatio >= configuration.definiteTwoPageAspectRatio

        if (isDefinitelyWide && hasClearGutter) || (balanceRatio >= 0.15 && hasClearGutter && aspectRatio >= 1.18) {
            let confidence = min(1.0, max(0.6, 0.5 + 0.3 * (1.0 - corridorMeanPerCol / max(1.0, sideMeanPerCol)) + 0.2 * balanceRatio))
            return PageSplitDecision(layoutType: .twoPageSpread, splitLine: splitLine, confidence: confidence)
        }

        return PageSplitDecision(layoutType: .singlePage, splitLine: nil, confidence: 0.85)
    }

    /// Splits `buffer` into one (`.single`) or two (`.leftVerso`, `.rightRecto`) page slices.
    public static func split(
        _ buffer: borrowing GrayscaleBuffer,
        using decision: PageSplitDecision,
        backgroundFill: UInt8 = 255
    ) -> [SplitPageSlice] {
        let width = buffer.width
        let height = buffer.height
        guard decision.layoutType == .twoPageSpread, let splitLine = decision.splitLine, width >= 2, height >= 1 else {
            let bounds = Rect2I(x: 0, y: 0, width: width, height: height)
            return [SplitPageSlice(side: .single, buffer: copy buffer, sourceBounds: bounds)]
        }

        var rowSplitX = [Int](repeating: width / 2, count: height)
        var minSplitX = width - 1
        var maxSplitX = 1

        for y in 0..<height {
            let rawX = Int(splitLine.x(atY: Double(y) + 0.5, height: height).rounded())
            let clampedX = min(max(rawX, 1), width - 1)
            rowSplitX[y] = clampedX
            if clampedX < minSplitX { minSplitX = clampedX }
            if clampedX > maxSplitX { maxSplitX = clampedX }
        }

        let leftWidth = max(1, maxSplitX)
        let rightStartX = min(width - 1, minSplitX)
        let rightWidth = max(1, width - rightStartX)

        var leftPixels = ContiguousArray<UInt8>(repeating: backgroundFill, count: leftWidth * height)
        var rightPixels = ContiguousArray<UInt8>(repeating: backgroundFill, count: rightWidth * height)

        buffer.pixels.withUnsafeBufferPointer { src in
            let srcStride = buffer.rowBytes
            for y in 0..<height {
                let splitX = rowSplitX[y]
                let srcRow = y * srcStride

                // Left slice: copy columns 0..<splitX, mask splitX..<leftWidth with backgroundFill.
                let leftCopyCount = min(splitX, leftWidth)
                let leftDstRow = y * leftWidth
                for x in 0..<leftCopyCount {
                    leftPixels[leftDstRow + x] = src[srcRow + x]
                }

                // Right slice: copy columns splitX..<width into (splitX - rightStartX)..<rightWidth.
                let rightDstRow = y * rightWidth
                let startCol = max(splitX, rightStartX)
                for x in startCol..<width {
                    rightPixels[rightDstRow + (x - rightStartX)] = src[srcRow + x]
                }
            }
        }

        let leftBuffer = GrayscaleBuffer(width: leftWidth, height: height, dpi: buffer.dpi, pixels: leftPixels)
        let rightBuffer = GrayscaleBuffer(width: rightWidth, height: height, dpi: buffer.dpi, pixels: rightPixels)

        return [
            SplitPageSlice(
                side: .leftVerso,
                buffer: leftBuffer,
                sourceBounds: Rect2I(x: 0, y: 0, width: leftWidth, height: height)
            ),
            SplitPageSlice(
                side: .rightRecto,
                buffer: rightBuffer,
                sourceBounds: Rect2I(x: rightStartX, y: 0, width: rightWidth, height: height)
            )
        ]
    }
}
