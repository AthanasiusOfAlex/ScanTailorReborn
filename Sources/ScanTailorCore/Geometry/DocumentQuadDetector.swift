import Foundation
import ScanTailorContracts

// MARK: - Document Quadrangle

/// A four-corner document boundary in source-pixel coordinates.
///
/// Coordinates are continuous: pixel `(i, j)` covers `[i, i + 1) × [j, j + 1)`, so the full frame of
/// a `W × H` raster spans `(0, 0)…(W, H)`. Corners are ordered screen-clockwise starting from the
/// corner nearest the image's top-left.
public struct DocumentQuad: Sendable, Equatable, Codable {
    public var topLeft: Point2D
    public var topRight: Point2D
    public var bottomRight: Point2D
    public var bottomLeft: Point2D

    /// Creates a quadrangle from its four corners.
    public init(topLeft: Point2D, topRight: Point2D, bottomRight: Point2D, bottomLeft: Point2D) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// The corners in order: top-left, top-right, bottom-right, bottom-left.
    public var corners: [Point2D] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    /// Enclosed area in square pixels.
    public var area: Double {
        abs(QuadDetectionKernels.signedArea(corners))
    }

    /// Smallest axis-aligned rectangle containing all four corners.
    public var boundingBox: Rect2D {
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return Rect2D(minX: xs.min() ?? 0, minY: ys.min() ?? 0, maxX: xs.max() ?? 0, maxY: ys.max() ?? 0)
    }

    /// Returns `true` when `point` lies inside or on the boundary of this (convex) quadrangle.
    public func contains(_ point: Point2D) -> Bool {
        let c = corners
        let orientation: Double = QuadDetectionKernels.signedArea(c) >= 0 ? 1.0 : -1.0
        for i in 0..<4 {
            let edge = c[(i + 1) % 4] - c[i]
            if orientation * QuadDetectionKernels.cross(edge, point - c[i]) < 0 {
                return false
            }
        }
        return true
    }

    /// The quadrangle covering an entire `width × height` raster.
    public static func fullFrame(width: Int, height: Int) -> DocumentQuad {
        let w = Double(width)
        let h = Double(height)
        return DocumentQuad(
            topLeft: Point2D(x: 0, y: 0),
            topRight: Point2D(x: w, y: 0),
            bottomRight: Point2D(x: w, y: h),
            bottomLeft: Point2D(x: 0, y: h)
        )
    }
}

// MARK: - Detection Result

/// Outcome, geometry, and diagnostics of a ``DocumentQuadDetector`` run.
///
/// Detection never throws. When no trustworthy boundary is found, ``quad`` is the full frame so
/// downstream stages can never crop page content by mistake; the rejected candidate (if any) is
/// kept in ``candidateQuad`` for diagnostics.
public struct DocumentQuadDetection: Sendable, Equatable, Codable {
    /// Classification of the detection.
    public enum Outcome: String, Sendable, Equatable, Codable {
        /// A document boundary against a desk or background was found and passed all checks.
        case detected
        /// The document fills the frame (e.g. a calibrated flatbed scan); nothing should be cropped.
        case fullFrame
        /// No trustworthy boundary was found; ``DocumentQuadDetection/flags`` names the reason.
        case rejected
    }

    /// A side of the document quadrangle.
    public enum Side: String, Sendable, Equatable, Codable, CaseIterable {
        case top
        case right
        case bottom
        case left
    }

    /// One scalar metric per quadrangle side.
    public struct SideMetrics: Sendable, Equatable, Codable {
        public var top: Double
        public var right: Double
        public var bottom: Double
        public var left: Double

        /// Creates per-side metrics.
        public init(top: Double, right: Double, bottom: Double, left: Double) {
            self.top = top
            self.right = right
            self.bottom = bottom
            self.left = left
        }

        /// All sides set to zero.
        public static let zero = SideMetrics(top: 0, right: 0, bottom: 0, left: 0)

        /// Accesses the metric for `side`.
        public subscript(side: Side) -> Double {
            get {
                switch side {
                case .top: top
                case .right: right
                case .bottom: bottom
                case .left: left
                }
            }
            set {
                switch side {
                case .top: top = newValue
                case .right: right = newValue
                case .bottom: bottom = newValue
                case .left: left = newValue
                }
            }
        }

        /// The smallest of the four values.
        public var minimum: Double {
            min(min(top, right), min(bottom, left))
        }

        /// The largest of the four values.
        public var maximum: Double {
            max(max(top, right), max(bottom, left))
        }
    }

    /// Classification of the detection.
    public var outcome: Outcome
    /// The quadrangle to use downstream: the detected boundary, or the full frame otherwise.
    public var quad: DocumentQuad
    /// The best candidate boundary, including rejected ones; `nil` when no candidate was formed.
    public var candidateQuad: DocumentQuad?
    /// Composite confidence in `[0, 1]`.
    public var confidence: Double
    /// Fraction of each side's length backed by a measured paper edge, in `[0, 1]`.
    public var sideSupport: SideMetrics
    /// Robust RMS distance of each side's edge samples from its fitted line, in source pixels.
    public var sideResidualPixels: SideMetrics
    /// Median paper-minus-desk brightness across the weakest side, in gray levels.
    public var boundaryContrast: Double
    /// Candidate (or region) area divided by the frame area.
    public var areaFraction: Double
    /// Diagnostic flags such as `occluded:left`, `lowContrastDesk`, `bentSide:top`, or `rejected:<reason>`.
    public var flags: [String]

    /// Creates a detection result.
    public init(
        outcome: Outcome,
        quad: DocumentQuad,
        candidateQuad: DocumentQuad? = nil,
        confidence: Double,
        sideSupport: SideMetrics = .zero,
        sideResidualPixels: SideMetrics = .zero,
        boundaryContrast: Double = 0,
        areaFraction: Double = 0,
        flags: [String] = []
    ) {
        self.outcome = outcome
        self.quad = quad
        self.candidateQuad = candidateQuad
        self.confidence = confidence
        self.sideSupport = sideSupport
        self.sideResidualPixels = sideResidualPixels
        self.boundaryContrast = boundaryContrast
        self.areaFraction = areaFraction
        self.flags = flags
    }

    /// `true` when ``outcome`` is ``Outcome/detected``.
    public var isDetected: Bool {
        outcome == .detected
    }

    private enum CodingKeys: String, CodingKey {
        case outcome, quad, candidateQuad, confidence, sideSupport, sideResidualPixels
        case boundaryContrast, areaFraction, flags
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.outcome = try container.decode(Outcome.self, forKey: .outcome)
        self.quad = try container.decode(DocumentQuad.self, forKey: .quad)
        self.candidateQuad = try container.decodeIfPresent(DocumentQuad.self, forKey: .candidateQuad)
        self.confidence = try container.decode(Double.self, forKey: .confidence)
        self.sideSupport = try container.decodeIfPresent(SideMetrics.self, forKey: .sideSupport) ?? .zero
        self.sideResidualPixels = try container.decodeIfPresent(SideMetrics.self, forKey: .sideResidualPixels) ?? .zero
        self.boundaryContrast = try container.decodeIfPresent(Double.self, forKey: .boundaryContrast) ?? 0
        self.areaFraction = try container.decodeIfPresent(Double.self, forKey: .areaFraction) ?? 0
        self.flags = try container.decodeIfPresent([String].self, forKey: .flags) ?? []
    }
}

// MARK: - Detector

/// Detects the four-corner boundary of a document photographed or scanned against a desk.
///
/// The detector combines a region hypothesis with edge evidence:
///
/// 1. **Working raster** — the input is area-averaged by an integer factor so its long side is at
///    most ``Configuration/workingLongSide``; all thresholds are relative to that raster.
/// 2. **Paper region** — each pixel is scored `localMean − localStd` (paper is bright *and* smooth,
///    wood is darker and textured), split by Otsu, closed, filtered to the dominant components,
///    and hole-filled. Its convex hull is reduced to the maximum-area inscribed quadrangle.
/// 3. **Multi-scale Canny** — edges are kept only when they persist across the
///    ``Configuration/edgeScales``, point from dark outside to bright inside, and actually separate
///    region from non-region (which rejects text and wood grain).
/// 4. **Robust side fitting** — each side is refit by deterministic RANSAC + total least squares.
///    Sides whose two end segments disagree in angle (the dip of an open book's top/bottom edge
///    at the spine) are flagged as bent and use corner-local segment lines instead.
/// 5. **Full-resolution refinement** — lines are refit to sub-pixel edge positions found along
///    perpendicular profiles in the source raster; corners are adjacent-line intersections, so an
///    occluded corner is extrapolated from the visible parts of its two sides.
/// 6. **Validation** — convexity, corner angles, side proportions, area, side support, boundary
///    contrast, and a composite confidence decide between ``DocumentQuadDetection/Outcome/detected``,
///    ``DocumentQuadDetection/Outcome/fullFrame``, and ``DocumentQuadDetection/Outcome/rejected``.
public struct DocumentQuadDetector: Sendable {

    /// Tunable parameters for ``DocumentQuadDetector``.
    public struct Configuration: Sendable, Equatable, Codable {
        /// Maximum long side of the working raster in pixels (`256…4096`, default `1024`).
        public var workingLongSide: Int
        /// Gaussian σ values (working pixels) of the Canny scales; the smallest localizes edges.
        public var edgeScales: [Double]
        /// Smallest accepted document area as a fraction of the frame.
        public var minimumAreaFraction: Double
        /// Region-hull area fraction at or above which the document is considered to fill the frame.
        public var fullFrameAreaFraction: Double
        /// Smallest accepted per-side edge support.
        public var minimumSideSupport: Double
        /// Largest accepted deviation of any interior corner angle from 90°.
        public var maximumCornerAngleDeviationDegrees: Double
        /// Smallest confidence reported as ``DocumentQuadDetection/Outcome/detected``.
        public var minimumConfidence: Double
        /// Smallest accepted paper-minus-desk contrast in gray levels.
        public var minimumBoundaryContrast: Double

        /// Creates a configuration; out-of-range values are clamped to safe bounds.
        public init(
            workingLongSide: Int = 1024,
            edgeScales: [Double] = [1.0, 2.0, 4.0],
            minimumAreaFraction: Double = 0.15,
            fullFrameAreaFraction: Double = 0.96,
            minimumSideSupport: Double = 0.35,
            maximumCornerAngleDeviationDegrees: Double = 35.0,
            minimumConfidence: Double = 0.55,
            minimumBoundaryContrast: Double = 12.0
        ) {
            self.workingLongSide = min(4096, max(256, workingLongSide))
            let scales = edgeScales.filter { $0.isFinite && $0 > 0 }.map { min(16.0, max(0.5, $0)) }.sorted()
            self.edgeScales = scales.isEmpty ? [1.0, 2.0, 4.0] : scales
            self.minimumAreaFraction = min(0.9, max(0.01, minimumAreaFraction))
            self.fullFrameAreaFraction = min(1.0, max(0.5, fullFrameAreaFraction))
            self.minimumSideSupport = min(1.0, max(0.0, minimumSideSupport))
            self.maximumCornerAngleDeviationDegrees = min(80.0, max(5.0, maximumCornerAngleDeviationDegrees))
            self.minimumConfidence = min(1.0, max(0.0, minimumConfidence))
            self.minimumBoundaryContrast = min(128.0, max(1.0, minimumBoundaryContrast))
        }

        private enum CodingKeys: String, CodingKey {
            case workingLongSide, edgeScales, minimumAreaFraction, fullFrameAreaFraction
            case minimumSideSupport, maximumCornerAngleDeviationDegrees, minimumConfidence
            case minimumBoundaryContrast
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Configuration()
            self.init(
                workingLongSide: try container.decodeIfPresent(Int.self, forKey: .workingLongSide) ?? defaults.workingLongSide,
                edgeScales: try container.decodeIfPresent([Double].self, forKey: .edgeScales) ?? defaults.edgeScales,
                minimumAreaFraction: try container.decodeIfPresent(Double.self, forKey: .minimumAreaFraction) ?? defaults.minimumAreaFraction,
                fullFrameAreaFraction: try container.decodeIfPresent(Double.self, forKey: .fullFrameAreaFraction) ?? defaults.fullFrameAreaFraction,
                minimumSideSupport: try container.decodeIfPresent(Double.self, forKey: .minimumSideSupport) ?? defaults.minimumSideSupport,
                maximumCornerAngleDeviationDegrees: try container.decodeIfPresent(Double.self, forKey: .maximumCornerAngleDeviationDegrees)
                    ?? defaults.maximumCornerAngleDeviationDegrees,
                minimumConfidence: try container.decodeIfPresent(Double.self, forKey: .minimumConfidence) ?? defaults.minimumConfidence,
                minimumBoundaryContrast: try container.decodeIfPresent(Double.self, forKey: .minimumBoundaryContrast)
                    ?? defaults.minimumBoundaryContrast
            )
        }
    }

    /// The detector's configuration.
    public let configuration: Configuration

    /// Creates a detector.
    /// - Parameter configuration: Detection parameters.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Detects the document quadrangle in a grayscale raster.
    ///
    /// - Parameter image: The full camera frame or scan, before any splitting or cropping.
    /// - Returns: The detection. Its ``DocumentQuadDetection/quad`` is the full frame unless the
    ///   outcome is ``DocumentQuadDetection/Outcome/detected``.
    public func detect(in image: borrowing GrayscaleBuffer) -> DocumentQuadDetection {
        let width = image.width
        let height = image.height
        guard min(width, height) >= Self.minimumImageSide else {
            return Self.rejection(width: width, height: height, reason: "imageTooSmall")
        }
        return image.pixels.withUnsafeBufferPointer { pixels in
            analyze(pixels, width: width, height: height)
        }
    }

    // MARK: - Constants

    private static let minimumImageSide = 32
    private static let ringPaperFractionForFullFrame = 0.8
    private static let minimumRegionFillRatio = 0.75
    private static let lowContrastDeskThreshold = 45.0
    private static let occludedSupportThreshold = 0.85
    private static let bentSideAngleDegrees = 1.5
    private static let bentSegmentSupport = 0.6
    private static let segmentFraction = 0.4

    private typealias K = QuadDetectionKernels
    private typealias Side = DocumentQuadDetection.Side

    // MARK: - Pipeline

    private func analyze(_ pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int) -> DocumentQuadDetection {
        let cfg = configuration
        let factor = max(1, Int((Double(max(width, height)) / Double(cfg.workingLongSide)).rounded(.up)))
        let working = K.downsample(pixels, width: width, height: height, factor: factor)
        let w = working.width
        let h = working.height
        guard min(w, h) >= 16 else {
            return Self.rejection(width: width, height: height, reason: "imageTooSmall")
        }
        let f = Double(factor)
        let relativeScale = Double(max(w, h)) / 1024.0

        // Stage 2: paper region hypothesis.
        let statRadius = max(2, Int((4.0 * relativeScale).rounded()))
        let stats = K.boxStatistics(working.values, width: w, height: h, radius: statRadius)
        var score = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            score[i] = stats.mean[i] - stats.std[i]
        }
        guard let otsu = K.otsu(score), otsu.highMean - otsu.lowMean >= cfg.minimumBoundaryContrast else {
            return Self.rejection(width: width, height: height, reason: "insufficientContrast")
        }
        // Dark text forms its own class, so a single Otsu split can separate "text" from
        // "desk + paper" when the desk is light. If the first split leaves the border ring paper-like,
        // try splitting the bright class again and adopt it only when that exposes a desk border.
        var separation = otsu.highMean - otsu.lowMean
        var paperClass = Self.paperMask(score, threshold: otsu.threshold)
        var ring = Self.ringPaperFraction(paperClass, width: w, height: h)
        if ring >= Self.ringPaperFractionForFullFrame,
           let upper = K.otsu(score.filter { $0 > Float(otsu.threshold) }),
           upper.highMean - upper.lowMean >= cfg.minimumBoundaryContrast {
            let candidateMask = Self.paperMask(score, threshold: upper.threshold)
            let candidateRing = Self.ringPaperFraction(candidateMask, width: w, height: h)
            if candidateRing < Self.ringPaperFractionForFullFrame {
                paperClass = candidateMask
                ring = candidateRing
                separation = upper.highMean - upper.lowMean
            }
        }
        let closeRadius = max(2, Int((5.0 * relativeScale).rounded()))
        let dilated = K.squareMorphology(paperClass, width: w, height: h, radius: closeRadius, isErosion: false)
        let closed = K.squareMorphology(dilated, width: w, height: h, radius: closeRadius, isErosion: true)

        let components = K.connectedComponents(closed, width: w, height: h)
        let largestArea = components.areas.max() ?? 0
        guard largestArea > 0 else {
            return Self.rejection(width: width, height: height, reason: "noPaperRegion")
        }
        let minimumComponentArea = max(Int(0.01 * Double(w * h)), largestArea / 4)
        let keep = components.areas.map { $0 >= minimumComponentArea }
        var selected = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) where components.labels[i] != 0 && keep[Int(components.labels[i])] {
            selected[i] = 1
        }
        let region = K.fillHoles(selected, width: w, height: h)

        // Convex hull of the region (row extents at pixel-boundary coordinates).
        var hullInput: [Point2D] = []
        hullInput.reserveCapacity(4 * h)
        for y in 0..<h {
            var first = -1
            var last = -1
            for x in 0..<w where region[y * w + x] != 0 {
                if first < 0 { first = x }
                last = x
            }
            guard first >= 0 else { continue }
            let y0 = Double(y)
            let y1 = Double(y + 1)
            hullInput.append(Point2D(x: Double(first), y: y0))
            hullInput.append(Point2D(x: Double(first), y: y1))
            hullInput.append(Point2D(x: Double(last + 1), y: y0))
            hullInput.append(Point2D(x: Double(last + 1), y: y1))
        }
        let hull = K.convexHull(hullInput)
        let hullFraction = K.signedArea(hull) / Double(w * h)

        if hullFraction >= cfg.fullFrameAreaFraction {
            if ring >= Self.ringPaperFractionForFullFrame {
                return DocumentQuadDetection(
                    outcome: .fullFrame,
                    quad: .fullFrame(width: width, height: height),
                    confidence: ring,
                    boundaryContrast: separation,
                    areaFraction: min(1.0, hullFraction),
                    flags: ["noDeskDetected"]
                )
            }
            return Self.rejection(width: width, height: height, reason: "frameFillingRegionWithoutPaperBorder", areaFraction: hullFraction)
        }

        let simplified = K.simplifyClosedPolygon(hull, tolerance: 1.0, maxVertices: 48)
        guard let rawQuad = K.maximumAreaQuad(simplified) else {
            return Self.rejection(width: width, height: height, reason: "degenerateRegion", areaFraction: hullFraction)
        }
        let initial = Self.orderedCorners(rawQuad)
        let initialFull = initial.map { $0 * f }
        let initialQuad = Self.quad(from: initialFull)
        let initialFraction = abs(K.signedArea(initial)) / Double(w * h)
        guard initialFraction >= cfg.minimumAreaFraction else {
            return Self.rejection(
                width: width, height: height, reason: "regionTooSmall",
                candidate: initialQuad, areaFraction: initialFraction
            )
        }
        let fillRatio = Self.fillRatio(region, width: w, height: h, quad: initial)
        guard fillRatio >= Self.minimumRegionFillRatio else {
            return Self.rejection(
                width: width, height: height, reason: "regionNotQuadrilateral",
                candidate: initialQuad, areaFraction: initialFraction
            )
        }

        // Stage 3: multi-scale Canny with persistence.
        let edgePoints = Self.persistentEdges(working.values, width: w, height: h, scales: cfg.edgeScales)

        // Stage 4: robust side fitting at working resolution.
        var flags: [String] = []
        var startLines: [K.Line] = []
        var endLines: [K.Line] = []
        var refinements: [[K.EdgeRefinement]] = []
        for sideIndex in 0..<4 {
            let side = Side.allCases[sideIndex]
            let a = initial[sideIndex]
            let b = initial[(sideIndex + 1) % 4]
            let fit = Self.fitSide(
                edgePoints, chordStart: a, chordEnd: b, region: region, width: w, height: h,
                seed: 0x5CA7_7A11_0000 &+ UInt64(sideIndex)
            )
            if fit.isBent { flags.append("bentSide:\(side.rawValue)") }

            // Stage 5: full-resolution refinement.
            let aFull = a * f
            let bFull = b * f
            let radius = 2 * factor + 2
            let chordLength = K.length(bFull - aFull)
            let trim = max(0.02, Double(2 * radius + 4) / max(1.0, chordLength))
            let ranges: [ClosedRange<Double>] = fit.isBent
                ? [trim...Self.segmentFraction, (1.0 - Self.segmentFraction)...(1.0 - trim)]
                : [trim...(1.0 - trim)]
            let workingLines = fit.isBent ? [fit.startLine, fit.endLine] : [fit.fullLine]
            var sideRefinements: [K.EdgeRefinement] = []
            for (range, workingLine) in zip(ranges, workingLines) {
                let fullLine = workingLine.scaled(by: f)
                guard let coarse = K.refineEdge(
                    pixels, width: width, height: height, line: fullLine,
                    chordStart: aFull, chordEnd: bFull, tRange: range,
                    searchRadius: radius, contrastOffset: Double(2 * factor + 3), spacing: f
                ) else {
                    sideRefinements.append(K.EdgeRefinement(
                        line: fullLine, inlierCount: 0, sampleCount: 1, rmsResidual: 0, medianContrast: 0
                    ))
                    continue
                }
                let fine = K.refineEdge(
                    pixels, width: width, height: height, line: coarse.line,
                    chordStart: aFull, chordEnd: bFull, tRange: range,
                    searchRadius: factor + 2, contrastOffset: Double(2 * factor + 3), spacing: f
                ) ?? coarse
                sideRefinements.append(fine)
            }
            startLines.append(sideRefinements[0].line)
            endLines.append(sideRefinements[sideRefinements.count - 1].line)
            refinements.append(sideRefinements)
        }

        // Corners: corner i is the start of side i and the end of side i − 1.
        let diagonal = Double(width * width + height * height).squareRoot()
        let cornerNames = ["topLeft", "topRight", "bottomRight", "bottomLeft"]
        var corners: [Point2D] = []
        var fallbackCount = 0
        for i in 0..<4 {
            let incoming = endLines[(i + 3) % 4]
            let outgoing = startLines[i]
            if let p = incoming.intersection(with: outgoing), p.distance(to: initialFull[i]) <= 0.1 * diagonal {
                corners.append(p)
            } else {
                corners.append(initialFull[i])
                flags.append("cornerFallback:\(cornerNames[i])")
                fallbackCount += 1
            }
        }
        let candidate = Self.quad(from: corners)

        // Stage 6: metrics and validation.
        var support = DocumentQuadDetection.SideMetrics.zero
        var residual = DocumentQuadDetection.SideMetrics.zero
        var contrast = Double.infinity
        for (sideIndex, sideRefinements) in refinements.enumerated() {
            let side = Side.allCases[sideIndex]
            let inliers = sideRefinements.reduce(0) { $0 + $1.inlierCount }
            let samples = sideRefinements.reduce(0) { $0 + $1.sampleCount }
            support[side] = samples > 0 ? Double(inliers) / Double(samples) : 0
            let rmsValues = sideRefinements.filter { $0.inlierCount > 0 }.map(\.rmsResidual)
            residual[side] = rmsValues.isEmpty ? 0 : rmsValues.reduce(0, +) / Double(rmsValues.count)
            for refinement in sideRefinements {
                contrast = min(contrast, refinement.inlierCount > 0 ? refinement.medianContrast : 0)
            }
            if !flags.contains("bentSide:\(side.rawValue)") && support[side] < Self.occludedSupportThreshold {
                flags.append("occluded:\(side.rawValue)")
            }
        }
        if !contrast.isFinite { contrast = 0 }
        if contrast < Self.lowContrastDeskThreshold { flags.append("lowContrastDesk") }

        let areaFraction = candidate.area / Double(width * height)
        let maximumAngleDeviation = Self.maximumAngleDeviationDegrees(corners)
        var rejectionReason: String?
        if K.signedArea(corners) <= 0 || !Self.isConvex(corners) {
            rejectionReason = "nonConvexQuad"
        } else if maximumAngleDeviation > cfg.maximumCornerAngleDeviationDegrees {
            rejectionReason = "cornerAngleOutOfRange"
        } else if !Self.hasPlausibleProportions(corners) {
            rejectionReason = "implausibleProportions"
        } else if areaFraction < cfg.minimumAreaFraction {
            rejectionReason = "regionTooSmall"
        } else if !Self.cornersNearFrame(corners, width: width, height: height) {
            rejectionReason = "cornerOutsideFrame"
        } else if let weakest = Side.allCases.first(where: { support[$0] < cfg.minimumSideSupport }) {
            rejectionReason = "weakSide:\(weakest.rawValue)"
        } else if contrast < cfg.minimumBoundaryContrast {
            rejectionReason = "insufficientBoundaryContrast"
        }

        let meanSupport = (support.top + support.right + support.bottom + support.left) / 4.0
        let effectiveSupport = 0.5 * (meanSupport + support.minimum)
        let supportFactor = Self.clamp01((effectiveSupport - 0.25) / 0.5)
        let workingResidual = (residual.top + residual.right + residual.bottom + residual.left) / (4.0 * f)
        let residualFactor = 1.0 / (1.0 + (workingResidual / 0.75) * (workingResidual / 0.75))
        let contrastFactor = Self.clamp01((contrast - 8.0) / 40.0)
        let angleRatio = maximumAngleDeviation / cfg.maximumCornerAngleDeviationDegrees
        let geometryFactor = Self.clamp01(1.0 - angleRatio * angleRatio)
        var confidence = pow(supportFactor * residualFactor * contrastFactor * geometryFactor, 0.25)
        confidence *= pow(0.5, Double(fallbackCount))
        if confidence.isNaN { confidence = 0 }

        if rejectionReason == nil && confidence < cfg.minimumConfidence {
            rejectionReason = "lowConfidence"
        }
        if let reason = rejectionReason {
            flags.append("rejected:\(reason)")
            return DocumentQuadDetection(
                outcome: .rejected,
                quad: .fullFrame(width: width, height: height),
                candidateQuad: candidate,
                confidence: confidence,
                sideSupport: support,
                sideResidualPixels: residual,
                boundaryContrast: contrast,
                areaFraction: areaFraction,
                flags: flags
            )
        }
        return DocumentQuadDetection(
            outcome: .detected,
            quad: candidate,
            candidateQuad: candidate,
            confidence: confidence,
            sideSupport: support,
            sideResidualPixels: residual,
            boundaryContrast: contrast,
            areaFraction: areaFraction,
            flags: flags
        )
    }

    // MARK: - Edge Evidence

    private struct EdgePoint {
        var position: Point2D
        var gx: Float
        var gy: Float
    }

    /// Canny edges at the finest scale that reappear (within `round(σ/2)` px) in at least half of
    /// the coarser scales, with the finest-scale gradient for polarity tests.
    private static func persistentEdges(_ values: [Float], width w: Int, height h: Int, scales: [Double]) -> [EdgePoint] {
        let cannyScales = scales.map { sigma in
            K.canny(K.gaussianBlur(values, width: w, height: h, sigma: sigma), width: w, height: h)
        }
        guard let finest = cannyScales.first else { return [] }
        let coarse = zip(scales.dropFirst(), cannyScales.dropFirst()).map { sigma, scale in
            K.squareMorphology(scale.edges, width: w, height: h, radius: max(1, Int((sigma / 2.0).rounded())), isErosion: false)
        }
        let required = (coarse.count + 1) / 2
        var points: [EdgePoint] = []
        for i in 0..<(w * h) where finest.edges[i] != 0 {
            var hits = 0
            for map in coarse where map[i] != 0 { hits += 1 }
            guard hits >= required else { continue }
            points.append(EdgePoint(
                position: Point2D(x: Double(i % w) + 0.5, y: Double(i / w) + 0.5),
                gx: finest.gx[i],
                gy: finest.gy[i]
            ))
        }
        return points
    }

    private struct SideFit {
        var fullLine: K.Line
        var startLine: K.Line
        var endLine: K.Line
        var isBent: Bool
    }

    /// Fits one side from edge points near the chord whose gradient points inward and which
    /// separate region (inside) from non-region (outside).
    private static func fitSide(
        _ edges: [EdgePoint],
        chordStart a: Point2D,
        chordEnd b: Point2D,
        region: [UInt8],
        width w: Int,
        height h: Int,
        seed: UInt64
    ) -> SideFit {
        let chord = b - a
        let length = max(1.0, K.length(chord))
        let u = chord / length
        let chordLine = K.Line(point: a, direction: u)
        let inward = chordLine.inwardNormal
        let band = max(6.0, 0.05 * length)

        func regionValue(_ p: Point2D) -> UInt8 {
            let x = Int(p.x.rounded(.down))
            let y = Int(p.y.rounded(.down))
            guard x >= 0 && x < w && y >= 0 && y < h else { return 0 }
            return region[y * w + x]
        }

        var candidates: [(point: Point2D, t: Double)] = []
        for e in edges {
            let d = e.position - a
            let t = K.dot(d, u) / length
            guard t >= -0.03 && t <= 1.03 else { continue }
            guard abs(K.dot(d, inward)) <= band else { continue }
            let gx = Double(e.gx)
            let gy = Double(e.gy)
            let magnitude = (gx * gx + gy * gy).squareRoot()
            guard magnitude > 0, (gx * inward.x + gy * inward.y) / magnitude >= 0.7 else { continue }
            guard regionValue(e.position + inward * 3.0) == 1, regionValue(e.position - inward * 3.0) == 0 else { continue }
            candidates.append((e.position, t))
        }

        let maxAngle = 12.0 * .pi / 180.0
        func fit(_ range: ClosedRange<Double>, seedOffset: UInt64) -> (line: K.Line, support: Double)? {
            let points = candidates.filter { range.contains($0.t) }.map(\.point)
            guard let result = K.ransacLine(
                points, reference: chordLine, maxAngle: maxAngle, tolerance: 1.5,
                iterations: 256, seed: seed &+ seedOffset
            ) else { return nil }
            let support = K.chordCoverage(of: result.inliers, chordStart: a, chordEnd: b, tRange: range, binSize: 2.0)
            return (result.line, support)
        }

        let full = fit(0.0...1.0, seedOffset: 0)?.line ?? chordLine
        let start = fit(0.0...segmentFraction, seedOffset: 101)
        let end = fit((1.0 - segmentFraction)...1.0, seedOffset: 202)
        var isBent = false
        if let start, let end, start.support >= bentSegmentSupport, end.support >= bentSegmentSupport,
           start.line.angle(to: end.line) * 180.0 / .pi > bentSideAngleDegrees {
            isBent = true
        }
        return SideFit(
            fullLine: full,
            startLine: isBent ? start?.line ?? full : full,
            endLine: isBent ? end?.line ?? full : full,
            isBent: isBent
        )
    }

    // MARK: - Geometry Helpers

    /// Rotates a positively oriented quad so its first vertex is the one nearest the top-left.
    private static func orderedCorners(_ quad: [Point2D]) -> [Point2D] {
        var corners = quad
        if K.signedArea(corners) < 0 { corners.reverse() }
        let start = corners.indices.min { corners[$0].x + corners[$0].y < corners[$1].x + corners[$1].y } ?? 0
        return (0..<4).map { corners[(start + $0) % 4] }
    }

    private static func quad(from corners: [Point2D]) -> DocumentQuad {
        DocumentQuad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
    }

    private static func isConvex(_ corners: [Point2D]) -> Bool {
        for i in 0..<4 {
            let e0 = corners[(i + 1) % 4] - corners[i]
            let e1 = corners[(i + 2) % 4] - corners[(i + 1) % 4]
            if K.cross(e0, e1) <= 0 { return false }
        }
        return true
    }

    private static func maximumAngleDeviationDegrees(_ corners: [Point2D]) -> Double {
        var worst = 0.0
        for i in 0..<4 {
            let previous = corners[(i + 3) % 4] - corners[i]
            let next = corners[(i + 1) % 4] - corners[i]
            let denominator = K.length(previous) * K.length(next)
            guard denominator > 0 else { return 90.0 }
            let angle = acos(min(1.0, max(-1.0, K.dot(previous, next) / denominator))) * 180.0 / .pi
            worst = max(worst, abs(angle - 90.0))
        }
        return worst
    }

    private static func hasPlausibleProportions(_ corners: [Point2D]) -> Bool {
        let lengths = (0..<4).map { K.length(corners[($0 + 1) % 4] - corners[$0]) }
        let topBottom = min(lengths[0], lengths[2]) / max(1e-9, max(lengths[0], lengths[2]))
        let leftRight = min(lengths[1], lengths[3]) / max(1e-9, max(lengths[1], lengths[3]))
        return topBottom >= 0.4 && leftRight >= 0.4
    }

    private static func cornersNearFrame(_ corners: [Point2D], width: Int, height: Int) -> Bool {
        let marginX = 0.05 * Double(width)
        let marginY = 0.05 * Double(height)
        return corners.allSatisfy {
            $0.x >= -marginX && $0.x <= Double(width) + marginX && $0.y >= -marginY && $0.y <= Double(height) + marginY
        }
    }

    /// Fraction of region pixels among all pixel centers inside `quad` (working coordinates).
    private static func fillRatio(_ region: [UInt8], width w: Int, height h: Int, quad: [Point2D]) -> Double {
        let lines = (0..<4).map { i -> K.Line in
            let d = quad[(i + 1) % 4] - quad[i]
            return K.Line(point: quad[i], direction: d / max(1e-9, K.length(d)))
        }
        let xs = quad.map(\.x)
        let ys = quad.map(\.y)
        let x0 = max(0, Int((xs.min() ?? 0).rounded(.down)))
        let x1 = min(w - 1, Int((xs.max() ?? 0).rounded(.up)))
        let y0 = max(0, Int((ys.min() ?? 0).rounded(.down)))
        let y1 = min(h - 1, Int((ys.max() ?? 0).rounded(.up)))
        guard x0 <= x1 && y0 <= y1 else { return 0 }
        var inside = 0
        var filled = 0
        for y in y0...y1 {
            for x in x0...x1 {
                let p = Point2D(x: Double(x) + 0.5, y: Double(y) + 0.5)
                guard lines.allSatisfy({ $0.signedDistance(p) >= 0 }) else { continue }
                inside += 1
                if region[y * w + x] != 0 { filled += 1 }
            }
        }
        return inside > 0 ? Double(filled) / Double(inside) : 0
    }

    private static func paperMask(_ score: [Float], threshold: Int) -> [UInt8] {
        let t = Float(threshold)
        return score.map { $0 > t ? UInt8(1) : UInt8(0) }
    }

    /// Fraction of paper-class pixels in the ring between 1 % and 3 % inset from the frame border
    /// (skipping thin scanner lips at the very edge).
    private static func ringPaperFraction(_ mask: [UInt8], width w: Int, height h: Int) -> Double {
        let inner = max(1, Int(0.01 * Double(min(w, h))))
        let outer = max(inner + 1, Int(0.03 * Double(min(w, h))))
        guard h - inner > inner, w - inner > inner else { return 0 }
        var total = 0
        var paper = 0
        func count(_ y: Int, _ xs: Range<Int>) {
            for x in xs {
                total += 1
                if mask[y * w + x] != 0 { paper += 1 }
            }
        }
        for y in inner..<(h - inner) {
            if y < outer || y >= h - outer {
                count(y, inner..<(w - inner))
            } else {
                count(y, inner..<min(outer, w - inner))
                count(y, max(outer, w - outer)..<(w - inner))
            }
        }
        return total > 0 ? Double(paper) / Double(total) : 0
    }

    private static func clamp01(_ value: Double) -> Double {
        value.isNaN ? 0 : min(1.0, max(0.0, value))
    }

    private static func rejection(
        width: Int,
        height: Int,
        reason: String,
        candidate: DocumentQuad? = nil,
        areaFraction: Double = 0
    ) -> DocumentQuadDetection {
        DocumentQuadDetection(
            outcome: .rejected,
            quad: .fullFrame(width: width, height: height),
            candidateQuad: candidate,
            confidence: 0,
            areaFraction: areaFraction,
            flags: ["rejected:\(reason)"]
        )
    }
}
