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
    public let isDarkCrease: Bool

    public init(
        centerX: Double,
        normalizedCenterX: Double,
        tiltDegrees: Double = 0.0,
        isDarkCrease: Bool = false
    ) {
        self.centerX = centerX
        self.normalizedCenterX = normalizedCenterX
        self.tiltDegrees = tiltDegrees
        self.isDarkCrease = isDarkCrease
    }

    private enum CodingKeys: String, CodingKey {
        case centerX
        case normalizedCenterX
        case tiltDegrees
        case isDarkCrease
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.centerX = try container.decode(Double.self, forKey: .centerX)
        self.normalizedCenterX = try container.decode(Double.self, forKey: .normalizedCenterX)
        self.tiltDegrees = try container.decode(Double.self, forKey: .tiltDegrees)
        self.isDarkCrease = try container.decodeIfPresent(Bool.self, forKey: .isDarkCrease) ?? false
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
    public let gutterTrimWidth: Int

    public init(
        side: PageSide,
        buffer: GrayscaleBuffer,
        sourceBounds: Rect2I,
        gutterTrimWidth: Int = 0
    ) {
        self.side = side
        self.buffer = buffer
        self.sourceBounds = sourceBounds
        self.gutterTrimWidth = gutterTrimWidth
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
        /// Central gutter strip trimming width in pixels physically removed between split pages (default: `24`).
        public var gutterTrimWidth: Int

        public init(
            minimumTwoPageAspectRatio: Double = 1.12,
            definiteTwoPageAspectRatio: Double = 1.32,
            searchRangeNormalized: ClosedRange<Double> = 0.30...0.70,
            maxTiltDegrees: Double = 10.0,
            tiltStepDegrees: Double = 0.5,
            gutterTrimWidth: Int = 24
        ) {
            self.minimumTwoPageAspectRatio = minimumTwoPageAspectRatio
            self.definiteTwoPageAspectRatio = definiteTwoPageAspectRatio
            self.searchRangeNormalized = searchRangeNormalized
            self.maxTiltDegrees = maxTiltDegrees
            self.tiltStepDegrees = tiltStepDegrees
            self.gutterTrimWidth = max(0, gutterTrimWidth)
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

        // Compute dark spine crease contrast and vertical continuity per (band, x).
        // A true spine shadow/crease is vertically continuous across most rows of the band (including inter-line spaces),
        // whereas text columns only darken the rows occupied by horizontal text strokes.
        // We use a 3x3 smoothed center luminance to bridge 1-bit halftone stipple dots while preserving inter-line whitespace,
        // and multi-offset symmetric paper flanks to handle both narrow rules and wider shadows.
        var bandSpineContrast = [Double](repeating: 0.0, count: bandCount * w)
        var bandDarkContinuity = [Double](repeating: 0.0, count: bandCount * w)
        var bandCreaseCenter = [Double](repeating: 0.0, count: bandCount * w)
        var bandCreaseOffset = [Double](repeating: 1.0, count: bandCount * w)
        var bandCreaseLeft = [Int](repeating: 0, count: bandCount * w)
        var bandCreaseRight = [Int](repeating: 0, count: bandCount * w)

        let d1 = max(4, w / 60)
        let d2 = max(8, w / 32)
        let d3 = max(14, min(36, w / 18))
        let maxCreaseWidth = max(6, w / 14)

        working.pixels.withUnsafeBufferPointer { pixels in
            let stride = working.rowBytes
            for b in 0..<bandCount {
                let by0 = yStart + (b * activeHeight) / bandCount
                let by1 = min(h, max(by0 + 1, yStart + ((b + 1) * activeHeight) / bandCount))
                let rowCount = max(1, by1 - by0)
                let rows = Double(rowCount)
                let rowOffset = b * w
                var rawContrast = [Double](repeating: 0.0, count: w)

                for x in d3..<(w - d3) {
                    var dipSum = 0.0
                    var darkRowCount = 0
                    for y in by0..<by1 {
                        let yPrev = max(0, y - 1) * stride
                        let yCurr = y * stride
                        let yNext = min(h - 1, y + 1) * stride

                        let rPrev = Int(pixels[yPrev + x - 1]) + 2 * Int(pixels[yPrev + x]) + Int(pixels[yPrev + x + 1])
                        let rCurr = Int(pixels[yCurr + x - 1]) + 2 * Int(pixels[yCurr + x]) + Int(pixels[yCurr + x + 1])
                        let rNext = Int(pixels[yNext + x - 1]) + 2 * Int(pixels[yNext + x]) + Int(pixels[yNext + x + 1])
                        let cSmooth = Double(rPrev + 2 * rCurr + rNext) / 16.0

                        let lPaper = max(Int(pixels[yCurr + x - d1]), max(Int(pixels[yCurr + x - d2]), Int(pixels[yCurr + x - d3])))
                        let rPaper = max(Int(pixels[yCurr + x + d1]), max(Int(pixels[yCurr + x + d2]), Int(pixels[yCurr + x + d3])))
                        let symFlank = Double(min(lPaper, rPaper))
                        let dip = max(0.0, symFlank - cSmooth)
                        dipSum += dip

                        let hasBinaryInk = binary[x - 1, y] || binary[x, y] || binary[x + 1, y]
                        if dip >= 8.0 || (hasBinaryInk && symFlank >= 180.0 && dip >= 5.0) {
                            darkRowCount += 1
                        }
                    }

                    let continuity = Double(darkRowCount) / rows
                    let meanDip = dipSum / rows
                    bandDarkContinuity[rowOffset + x] = continuity
                    if continuity >= 0.70 && meanDip >= 8.0 {
                        rawContrast[x] = meanDip * continuity
                    }
                }

                // Identify contiguous dark crease runs in this band and compute intensity-weighted centroid mu_b.
                var x = d3
                while x < w - d3 {
                    if rawContrast[x] > 0.0 {
                        let runStart = x
                        var runEnd = x
                        while runEnd + 1 < w - d3 && rawContrast[runEnd + 1] > 0.0 {
                            runEnd += 1
                        }
                        let runWidth = runEnd - runStart + 1
                        if runWidth <= maxCreaseWidth {
                            var weightedSum = 0.0
                            var weightTotal = 0.0
                            for u in runStart...runEnd {
                                let wVal = rawContrast[u]
                                weightedSum += Double(u) * wVal
                                weightTotal += wVal
                            }
                            let mu = weightTotal > 0.0 ? weightedSum / weightTotal : Double(runStart + runEnd) * 0.5
                            let halfSpan = max(1.5, Double(runWidth) * 0.5)
                            for u in runStart...runEnd {
                                bandSpineContrast[rowOffset + u] = rawContrast[u]
                                bandCreaseCenter[rowOffset + u] = mu
                                bandCreaseOffset[rowOffset + u] = abs(Double(u) - mu) / halfSpan
                                bandCreaseLeft[rowOffset + u] = runStart
                                bandCreaseRight[rowOffset + u] = runEnd
                            }
                        }
                        x = runEnd + 1
                    } else {
                        x += 1
                    }
                }
            }
        }

        // 3. Search over tilt angles and candidate gutter centers (Dual-Mode: White Valley vs. Dark Crease).
        let minX = max(4, Int((Double(w) * configuration.searchRangeNormalized.lowerBound).rounded(.down)))
        let maxX = min(w - 5, Int((Double(w) * configuration.searchRangeNormalized.upperBound).rounded(.up)))
        guard minX <= maxX else {
            return PageSplitDecision(layoutType: .singlePage, splitLine: nil, confidence: 0.5)
        }

        let corridorHalfWidth = max(1, w / 160)
        let flankWindow = max(6, w / 20)
        let halfH = Double(h) * 0.5
        let stepDeg = max(0.125, min(0.25, configuration.tiltStepDegrees))
        let maxTilt = max(0.0, configuration.maxTiltDegrees)

        var bestCost = Double.greatestFiniteMagnitude
        var bestCenterX = Double(w) * 0.5
        var bestTiltDeg = 0.0
        var bestValleyClearance = 0.0

        var bestCreaseCost = Double.greatestFiniteMagnitude
        var bestCreaseCenterX = Double(w) * 0.5
        var bestCreaseTiltDeg = 0.0
        var bestCreaseStrength = 0.0
        var bestVerticalContinuity = 0.0
        var foundDarkCrease = false

        var tilt = -maxTilt
        while tilt <= maxTilt + 1e-9 {
            let tanPhi = tan(tilt * .pi / 180.0)

            for cx in minX...maxX {
                var corridorInkSum = 0.0
                var flankInkSum = 0.0
                var spineBonusSum = 0.0
                var continuitySum = 0.0
                var creaseOffsetSum = 0.0
                var gapMidpointOffsetSum = 0.0
                var validBands = 0
                var creaseBandCount = 0

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

                    let spineScore = bandSpineContrast[rowOffset + xAtBand]
                    let continuity = bandDarkContinuity[rowOffset + xAtBand]
                    continuitySum += continuity

                    if spineScore > 0.0 {
                        creaseBandCount += 1
                        spineBonusSum += spineScore
                        creaseOffsetSum += bandCreaseOffset[rowOffset + xAtBand]
                    } else {
                        creaseOffsetSum += 1.5
                    }

                    corridorInkSum += corridorDensity
                    flankInkSum += flankDensity
                }

                guard validBands >= bandCount / 2 else { continue }

                // Measure inner-margin gap midpoint alignment on bands with text on both sides.
                // When inside a dark crease run, step outside the full crease bounds before scanning for text edges.
                let textThreshold = max(1, (activeHeight / bandCount) / 14)
                var gapBandCount = 0
                for b in 0..<bandCount {
                    let y = bandCenterY[b]
                    let xAtBand = Int((Double(cx) - (y - halfH) * tanPhi).rounded())
                    if xAtBand < minX || xAtBand > maxX { continue }
                    let rowOffset = b * w

                    let spineScore = bandSpineContrast[rowOffset + xAtBand]
                    let leftStart = spineScore > 0.0
                        ? bandCreaseLeft[rowOffset + xAtBand] - max(2, corridorHalfWidth)
                        : xAtBand
                    let rightStart = spineScore > 0.0
                        ? bandCreaseRight[rowOffset + xAtBand] + max(2, corridorHalfWidth)
                        : xAtBand

                    var leftEdge: Int? = nil
                    let leftSearchLimit = max(4, Int(Double(w) * 0.12))
                    var lx = leftStart
                    while lx >= leftSearchLimit {
                        if bandInk[rowOffset + lx] >= textThreshold {
                            leftEdge = lx
                            break
                        }
                        lx -= 1
                    }

                    var rightEdge: Int? = nil
                    let rightSearchLimit = min(w - 5, Int(Double(w) * 0.88))
                    var rx = rightStart
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
                let meanSpineScore = spineBonusSum / Double(validBands)
                let meanContinuity = continuitySum / Double(validBands)
                let meanCreaseOffset = creaseOffsetSum / Double(validBands)
                let gapPenalty = gapBandCount > 0
                    ? (gapMidpointOffsetSum / Double(gapBandCount)) * 18.0
                    : 2.5
                let normX = Double(cx) / Double(w)
                let centerPrior = abs(normX - 0.5) * 1.8
                let tiltPrior = abs(tilt) * 0.015

                // Mode A: White Valley cost (penalizes corridor ink)
                let valleyCost = meanCorridorInk * 3.5 + gapPenalty + centerPrior + tiltPrior
                if valleyCost < bestCost {
                    bestCost = valleyCost
                    bestCenterX = Double(cx)
                    bestTiltDeg = tilt
                    bestValleyClearance = max(0.0, meanFlankInk - meanCorridorInk)
                }

                // Mode B: Dark Crease cost (maximizes alignment with continuous dark crease midline mu_b)
                let isCentralCreaseZone = mode == .twoPageSpread || (normX >= 0.36 && normX <= 0.64)
                if isCentralCreaseZone && meanContinuity >= 0.75 && creaseBandCount * 4 >= validBands * 3 && meanSpineScore >= 10.0 {
                    let creaseCost = meanCreaseOffset * 6.0
                        + gapPenalty * 0.35
                        + centerPrior
                        + tiltPrior
                        - meanSpineScore * 0.12
                        - meanContinuity * 2.0
                    if creaseCost < bestCreaseCost {
                        bestCreaseCost = creaseCost
                        bestCreaseCenterX = Double(cx)
                        bestCreaseTiltDeg = tilt
                        bestCreaseStrength = meanSpineScore
                        bestVerticalContinuity = meanContinuity
                        foundDarkCrease = true
                    }
                }
            }

            tilt += stepDeg
        }

        // Select between Dark Crease Mode and White Valley Mode.
        let useDarkCrease = foundDarkCrease && bestCreaseStrength >= 12.0 && bestVerticalContinuity >= 0.75
        let chosenCenterX = useDarkCrease ? bestCreaseCenterX : bestCenterX
        let chosenTiltDeg = useDarkCrease ? bestCreaseTiltDeg : bestTiltDeg

        let fullCenterX = (chosenCenterX + 0.5) * scaleFactor
        let normalizedCenterX = min(max(fullCenterX / Double(origWidth), 0.0), 1.0)
        let splitLine = GutterSplitLine(
            centerX: fullCenterX,
            normalizedCenterX: normalizedCenterX,
            tiltDegrees: chosenTiltDeg,
            isDarkCrease: useDarkCrease
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
        let corridorRadius = useDarkCrease ? max(4, w / 28) : max(2, w / 60)
        for b in 0..<bandCount {
            let y = bandCenterY[b]
            let splitX = Int((chosenCenterX - (y - halfH) * tan(chosenTiltDeg * .pi / 180.0)).rounded())
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

        if useDarkCrease && balanceRatio >= 0.10 {
            let confidence = min(1.0, max(0.80, 0.55 + 0.25 * bestVerticalContinuity + 0.20 * balanceRatio))
            return PageSplitDecision(layoutType: .twoPageSpread, splitLine: splitLine, confidence: confidence)
        }

        let hasClearGutter = corridorMeanPerCol < sideMeanPerCol * 0.45 || bestValleyClearance > 0.8
        let isDefinitelyWide = aspectRatio >= configuration.definiteTwoPageAspectRatio

        if (isDefinitelyWide && hasClearGutter) || (balanceRatio >= 0.15 && hasClearGutter && aspectRatio >= 1.18) {
            let confidence = min(1.0, max(0.6, 0.5 + 0.3 * (1.0 - corridorMeanPerCol / max(1.0, sideMeanPerCol)) + 0.2 * balanceRatio))
            return PageSplitDecision(layoutType: .twoPageSpread, splitLine: splitLine, confidence: confidence)
        }

        return PageSplitDecision(layoutType: .singlePage, splitLine: nil, confidence: 0.85)
    }

    /// Splits a camera photo of an open book at the fold found by ``CameraGutterLocator``.
    ///
    /// The cut is a vertical line. Returns `nil` when `mode` is `.singlePage`, when an automatic photo is too
    /// narrow to hold two pages, or when the locator finds no clear gutter; callers then fall back to
    /// ``estimateSplit(in:mode:configuration:)``.
    /// - Parameters:
    ///   - outline: The paper outline of the photo, traced before desk masking.
    ///   - mode: Split policy.
    ///   - configuration: Supplies the minimum two-page aspect ratio.
    public static func estimateCameraSplit(
        outline: CameraGutterLocator.Outline,
        mode: PageSplitMode = .automatic,
        configuration: Configuration = Configuration()
    ) -> PageSplitDecision? {
        let size = outline.photoSize
        guard mode != .singlePage, size.height > 0 else { return nil }
        if mode == .automatic && Double(size.width) / Double(size.height) < configuration.minimumTwoPageAspectRatio { return nil }
        guard let gutter = CameraGutterLocator.locate(in: outline) else { return nil }
        let confidence: Double
        switch gutter.evidence {
        case .gapAndNotch: confidence = 0.9
        case .singleGap, .notchOnly: confidence = 0.75
        }
        return PageSplitDecision(
            layoutType: .twoPageSpread,
            splitLine: GutterSplitLine(centerX: gutter.centerX, normalizedCenterX: gutter.normalizedCenterX),
            confidence: confidence
        )
    }

    /// Splits `buffer` into one (`.single`) or two (`.leftVerso`, `.rightRecto`) page slices.
    ///
    /// - Parameters:
    ///   - buffer: The input grayscale page or spread.
    ///   - decision: Page split decision containing layout classification and gutter line geometry.
    ///   - gutterTrimWidth: Central gutter strip trimming width in pixels physically removed
    ///     between left and right page slices to excise spine creases (default: `24`).
    ///   - backgroundFill: Grayscale value used to fill masked boundary wedges (default: `255`, white).
    public static func split(
        _ buffer: borrowing GrayscaleBuffer,
        using decision: PageSplitDecision,
        gutterTrimWidth: Int = 24,
        backgroundFill: UInt8 = 255
    ) -> [SplitPageSlice] {
        let width = buffer.width
        let height = buffer.height
        guard decision.layoutType == .twoPageSpread, let splitLine = decision.splitLine, width >= 2, height >= 1 else {
            let bounds = Rect2I(x: 0, y: 0, width: width, height: height)
            return [SplitPageSlice(side: .single, buffer: copy buffer, sourceBounds: bounds, gutterTrimWidth: 0)]
        }

        let maxTrim = max(0, width - 4)
        let trim = min(max(0, gutterTrimWidth), maxTrim)
        let leftTrim = trim / 2
        let rightTrim = trim - leftTrim

        var rowLeftCutX = [Int](repeating: width / 2, count: height)
        var rowRightCutX = [Int](repeating: width / 2, count: height)
        var maxLeftCutX = 0
        var minRightCutX = width

        for y in 0..<height {
            let rawX = Int(splitLine.x(atY: Double(y) + 0.5, height: height).rounded())
            let clampedX = min(max(rawX, 0), width)

            let cutLeft = max(0, min(clampedX - leftTrim, width))
            let cutRight = min(width, max(clampedX + rightTrim, 0))

            rowLeftCutX[y] = cutLeft
            rowRightCutX[y] = cutRight

            if cutLeft > maxLeftCutX { maxLeftCutX = cutLeft }
            if cutRight < minRightCutX { minRightCutX = cutRight }
        }

        let leftWidth = max(1, maxLeftCutX)
        let rightStartX = min(width - 1, max(0, minRightCutX))
        let rightWidth = max(1, width - rightStartX)

        var leftPixels = ContiguousArray<UInt8>(repeating: backgroundFill, count: leftWidth * height)
        var rightPixels = ContiguousArray<UInt8>(repeating: backgroundFill, count: rightWidth * height)

        buffer.pixels.withUnsafeBufferPointer { src in
            let srcStride = buffer.rowBytes
            for y in 0..<height {
                let srcRow = y * srcStride

                // Left slice: copy columns 0..<cutLeft, mask cutLeft..<leftWidth with backgroundFill.
                let cutLeft = rowLeftCutX[y]
                let leftCopyCount = min(cutLeft, leftWidth)
                let leftDstRow = y * leftWidth
                for x in 0..<leftCopyCount {
                    leftPixels[leftDstRow + x] = src[srcRow + x]
                }

                // Right slice: copy columns cutRight..<width into (cutRight - rightStartX)..<rightWidth.
                let cutRight = rowRightCutX[y]
                let startCol = max(cutRight, rightStartX)
                let rightDstRow = y * rightWidth
                if startCol < width {
                    for x in startCol..<width {
                        rightPixels[rightDstRow + (x - rightStartX)] = src[srcRow + x]
                    }
                }
            }
        }

        let leftBuffer = GrayscaleBuffer(width: leftWidth, height: height, dpi: buffer.dpi, pixels: leftPixels)
        let rightBuffer = GrayscaleBuffer(width: rightWidth, height: height, dpi: buffer.dpi, pixels: rightPixels)

        return [
            SplitPageSlice(
                side: .leftVerso,
                buffer: leftBuffer,
                sourceBounds: Rect2I(x: 0, y: 0, width: leftWidth, height: height),
                gutterTrimWidth: trim
            ),
            SplitPageSlice(
                side: .rightRecto,
                buffer: rightBuffer,
                sourceBounds: Rect2I(x: rightStartX, y: 0, width: rightWidth, height: height),
                gutterTrimWidth: trim
            )
        ]
    }
}
