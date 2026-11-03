import Foundation
import ScanTailorContracts
@testable import ScanTailorCore
import Testing

@Suite("Substep 5.1.1 — Document Quadrangle Detection Tests")
struct DocumentQuadDetectorTests {

    // MARK: - Synthetic Camera Scene Renderer

    /// Description of a synthetic camera capture. Geometry is in output pixels; textures and
    /// lighting are evaluated in reference coordinates (`pixel / scale`) so a scene rendered at
    /// different scales shows the same physical content.
    struct Scene {
        var width: Int
        var height: Int
        var scale: Double = 1.0
        /// Paper outline polygon (output pixels, screen-clockwise). Empty means no paper.
        var outline: [Point2D]
        /// Corners (TL, TR, BR, BL) that map the unit square to the page for typesetting.
        var textQuad: [Point2D]?
        var textColumns: [ClosedRange<Double>] = [0.1...0.9]
        var paperTone: Double = 222
        var gutterU: Double?
        var desk: (Double, Double) -> Double
        /// Multiplicative lighting over normalized reference coordinates in `[0, 1]²`.
        var lighting: (Double, Double) -> Double = { _, _ in 1.0 }
        var occluders: [(center: Point2D, rx: Double, ry: Double, tone: Double)] = []
        var scannerLipWidth: Int = 0
        var noiseSigma: Double = 3.0
        var seed: UInt64 = 0x51CE
    }

    static func woodDesk(_ x: Double, _ y: Double) -> Double {
        let warp = 9.0 * sin(2 * .pi * x / 430 + 0.7) + 4.0 * sin(2 * .pi * x / 123 + 2.1) + 3.0 * sin(2 * .pi * y / 610)
        let rings = sin(2 * .pi * (y + warp) / 15.0)
        let fine = sin(2 * .pi * (y + 0.5 * warp) / 4.3 + x / 90.0)
        return 92 + 24 * rings + 6 * fine
    }

    static func laminateDesk(_ x: Double, _ y: Double) -> Double {
        186 + 4 * sin(2 * .pi * x / 260) * sin(2 * .pi * y / 190)
    }

    static func vignette(_ x: Double, _ y: Double) -> Double {
        1.0 - 0.12 * ((x - 0.5) * (x - 0.5) + (y - 0.5) * (y - 0.5)) / 0.5
    }

    /// Projective map of the unit square onto `quad` (Heckbert's square-to-quad), returned as a
    /// row-major 3×3 matrix.
    static func squareToQuad(_ q: [Point2D]) -> [Double] {
        let (x0, y0, x1, y1, x2, y2, x3, y3) = (q[0].x, q[0].y, q[1].x, q[1].y, q[2].x, q[2].y, q[3].x, q[3].y)
        let dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3
        let dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3
        let den = dx1 * dy2 - dx2 * dy1
        let g = (dx3 * dy2 - dx2 * dy3) / den
        let h = (dx1 * dy3 - dx3 * dy1) / den
        return [x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
                y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
                g, h, 1]
    }

    static func inverse3x3(_ m: [Double]) -> [Double] {
        let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
        let A = e * i - f * h, B = -(d * i - f * g), C = d * h - e * g
        let det = a * A + b * B + c * C
        return [A / det, -(b * i - c * h) / det, (b * f - c * e) / det,
                B / det, (a * i - c * g) / det, -(a * f - c * d) / det,
                C / det, -(a * h - b * g) / det, (a * e - b * d) / det]
    }

    /// Exact-in-x, 8-sub-row anti-aliased polygon coverage.
    static func polygonCoverage(_ polygon: [Point2D], width: Int, height: Int) -> [Double] {
        var coverage = [Double](repeating: 0, count: width * height)
        guard polygon.count >= 3 else { return coverage }
        let subRows = 8
        let weight = 1.0 / Double(subRows)
        var rowCoverage = [Double](repeating: 0, count: width)
        var difference = [Double](repeating: 0, count: width + 1)
        for y in 0..<height {
            for x in 0..<width { rowCoverage[x] = 0 }
            for x in 0...width { difference[x] = 0 }
            for s in 0..<subRows {
                let sy = Double(y) + (Double(s) + 0.5) * weight
                var xs: [Double] = []
                for i in 0..<polygon.count {
                    let a = polygon[i]
                    let b = polygon[(i + 1) % polygon.count]
                    if (a.y <= sy && b.y > sy) || (b.y <= sy && a.y > sy) {
                        xs.append(a.x + (sy - a.y) * (b.x - a.x) / (b.y - a.y))
                    }
                }
                xs.sort()
                var k = 0
                while k + 1 < xs.count {
                    let xa = max(0.0, xs[k])
                    let xb = min(Double(width), xs[k + 1])
                    k += 2
                    guard xb > xa else { continue }
                    let ia = Int(xa)
                    let ib = Int(xb)
                    if ia == ib {
                        rowCoverage[ia] += (xb - xa) * weight
                    } else {
                        rowCoverage[ia] += (Double(ia + 1) - xa) * weight
                        difference[ia + 1] += weight
                        difference[ib] -= weight
                        if ib < width { rowCoverage[ib] += (xb - Double(ib)) * weight }
                    }
                }
            }
            var running = 0.0
            for x in 0..<width {
                running += difference[x]
                coverage[y * width + x] = min(1.0, rowCoverage[x] + running)
            }
        }
        return coverage
    }

    static func isInk(u: Double, v: Double, columns: [ClosedRange<Double>]) -> Bool {
        guard columns.contains(where: { $0.contains(u) }), v >= 0.07 && v <= 0.93 else { return false }
        let lineCoordinate = (v - 0.07) / 0.86 * 42.0
        let fraction = lineCoordinate - lineCoordinate.rounded(.down)
        guard fraction >= 0.3 && fraction < 0.62 else { return false }
        let line = Int(lineCoordinate.rounded(.down))
        let word = Int((u * 55.0).rounded(.down))
        guard (line &* 7919 &+ word &* 104_729) % 5 != 0 else { return false }
        let letter = u * 260.0
        return letter - letter.rounded(.down) < 0.55
    }

    /// 4096 deterministic unit-variance Gaussian samples (Irwin–Hall of 4 uniforms, rescaled).
    static let unitNoise: [Double] = {
        var rng = QuadDetectionKernels.SplitMix64(seed: 0xA015E)
        let scale = 1.0 / (4.0 / 12.0).squareRoot()
        return (0..<4096).map { _ in
            var sum = 0.0
            for _ in 0..<4 { sum += Double(rng.next() >> 11) / Double(1 << 53) }
            return (sum - 2.0) * scale
        }
    }()

    static func render(_ scene: Scene) -> GrayscaleBuffer {
        let w = scene.width
        let h = scene.height
        let coverage = polygonCoverage(scene.outline, width: w, height: h)
        let inverseHomography = scene.textQuad.map { inverse3x3(squareToQuad($0)) }
        let referenceWidth = Double(w) / scene.scale
        let referenceHeight = Double(h) / scene.scale
        var linear = [Double](repeating: 0, count: w * h)

        linear.withUnsafeMutableBufferPointer { out in
            coverage.withUnsafeBufferPointer { cov in
                for y in 0..<h {
                    let py = Double(y) + 0.5
                    let yr = py / scene.scale
                    for x in 0..<w {
                        let px = Double(x) + 0.5
                        let xr = px / scene.scale
                        let c = cov[y * w + x]
                        var value = c < 1.0 ? scene.desk(xr, yr) : 0.0
                        if c > 0 {
                            var paper = scene.paperTone
                            if let m = inverseHomography {
                                let den = m[6] * px + m[7] * py + m[8]
                                let u = (m[0] * px + m[1] * py + m[2]) / den
                                let v = (m[3] * px + m[4] * py + m[5]) / den
                                if isInk(u: u, v: v, columns: scene.textColumns) { paper *= 0.22 }
                                if let gutter = scene.gutterU {
                                    let g = (u - gutter) / 0.015
                                    paper *= 1.0 - 0.35 * exp(-g * g)
                                }
                            }
                            value = value * (1 - c) + paper * c
                        }
                        for occluder in scene.occluders {
                            let dx = (px - occluder.center.x) / occluder.rx
                            let dy = (py - occluder.center.y) / occluder.ry
                            let r = (dx * dx + dy * dy).squareRoot()
                            let alpha = min(1.0, max(0.0, (1.0 - r) * min(occluder.rx, occluder.ry) + 0.5))
                            if alpha > 0 {
                                let tone = occluder.tone * (0.9 + 0.1 * max(0.0, 1.0 - r))
                                value = value * (1 - alpha) + tone * alpha
                            }
                        }
                        value *= scene.lighting(xr / referenceWidth, yr / referenceHeight)
                        if x < scene.scannerLipWidth || y < scene.scannerLipWidth { value = 70 }
                        out[y * w + x] = value
                    }
                }
            }
        }

        // Separable 3×3 binomial optical PSF ([1 2 1] ⊗ [1 2 1] / 16), then sensor noise.
        var horizontal = [Double](repeating: 0, count: w * h)
        var pixels = ContiguousArray<UInt8>(repeating: 0, count: w * h)
        var rng = QuadDetectionKernels.SplitMix64(seed: scene.seed)
        linear.withUnsafeBufferPointer { src in
            horizontal.withUnsafeMutableBufferPointer { hor in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        let left = src[row + (x > 0 ? x - 1 : 0)]
                        let right = src[row + (x < w - 1 ? x + 1 : w - 1)]
                        hor[row + x] = left + 2 * src[row + x] + right
                    }
                }
            }
        }
        horizontal.withUnsafeBufferPointer { hor in
            unitNoise.withUnsafeBufferPointer { noise in
                pixels.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        let up = (y > 0 ? y - 1 : 0) * w
                        let row = y * w
                        let down = (y < h - 1 ? y + 1 : h - 1) * w
                        for x in 0..<w {
                            let blurred = (hor[up + x] + 2 * hor[row + x] + hor[down + x]) / 16.0
                            let value = blurred + scene.noiseSigma * noise[Int(rng.next() >> 52)]
                            dst[row + x] = UInt8(min(255.0, max(0.0, value.rounded())))
                        }
                    }
                }
            }
        }
        return GrayscaleBuffer(width: w, height: h, dpi: 300, pixels: pixels)
    }

    static func maximumCornerError(_ quad: DocumentQuad, _ truth: [Point2D]) -> Double {
        zip(quad.corners, truth).map { $0.distance(to: $1) }.max() ?? .infinity
    }

    // MARK: - Fixtures

    static let woodCorners = [
        Point2D(x: 260, y: 170), Point2D(x: 1530, y: 210), Point2D(x: 1610, y: 1220), Point2D(x: 190, y: 1170)
    ]

    static func woodScene(scale: Double = 1.0, occluded: Bool = false) -> (scene: Scene, truth: [Point2D]) {
        let corners = woodCorners.map { $0 * scale }
        var scene = Scene(
            width: Int(1800 * scale),
            height: Int(1350 * scale),
            scale: scale,
            outline: corners,
            textQuad: corners,
            desk: woodDesk,
            lighting: vignette
        )
        if occluded {
            scene.occluders = [
                (Point2D(x: 228, y: 620) * scale, 55 * scale, 140 * scale, 135),
                (Point2D(x: 200, y: 1160) * scale, 75 * scale, 65 * scale, 140),
            ]
        }
        return (scene, corners)
    }

    // MARK: - Tests

    @Test("Keystoned page on a wooden desk is detected to sub-pixel corner accuracy")
    func cameraSpreadOnWoodenDesk() {
        let (scene, truth) = Self.woodScene()
        let detection = DocumentQuadDetector().detect(in: Self.render(scene))

        #expect(detection.outcome == .detected, "flags: \(detection.flags)")
        #expect(Self.maximumCornerError(detection.quad, truth) <= 0.5, "quad: \(detection.quad)")
        #expect(detection.confidence >= 0.8)
        #expect(detection.sideSupport.minimum >= 0.9)
        #expect(!detection.flags.contains("lowContrastDesk"))
        #expect(!detection.flags.contains { $0.hasPrefix("occluded") || $0.hasPrefix("bentSide") })
    }

    @Test("Light laminate desk with a lighting ramp is still detected and flagged as low contrast")
    func lowContrastDesk() {
        let corners = [
            Point2D(x: 300, y: 140), Point2D(x: 1500, y: 190), Point2D(x: 1560, y: 1240), Point2D(x: 240, y: 1200)
        ]
        let scene = Scene(
            width: 1800,
            height: 1350,
            outline: corners,
            textQuad: corners,
            desk: Self.laminateDesk,
            lighting: { x, _ in 1.0 + 0.04 * (2.0 * x - 1.0) }
        )
        let detection = DocumentQuadDetector().detect(in: Self.render(scene))

        #expect(detection.outcome == .detected, "flags: \(detection.flags)")
        #expect(Self.maximumCornerError(detection.quad, corners) <= 1.0, "quad: \(detection.quad)")
        #expect(detection.flags.contains("lowContrastDesk"))
        #expect(detection.boundaryContrast >= 20 && detection.boundaryContrast < 45)
        #expect(detection.confidence >= 0.55)
    }

    @Test("Thumbs over a side and a corner are bridged and the hidden corner is extrapolated")
    func partialOcclusion() {
        let (scene, truth) = Self.woodScene(occluded: true)
        let detection = DocumentQuadDetector().detect(in: Self.render(scene))

        #expect(detection.outcome == .detected, "flags: \(detection.flags)")
        #expect(Self.maximumCornerError(detection.quad, truth) <= 1.0, "quad: \(detection.quad)")
        #expect(detection.flags.contains("occluded:left"))
        #expect(detection.sideSupport.left < 0.85 && detection.sideSupport.left >= 0.35)
        #expect(detection.sideSupport.top >= 0.9)
    }

    @Test("Calibrated flatbed scan with no desk reports a full frame and never crops")
    func calibratedScanWithoutDesk() {
        let width = 1275
        let height = 1650
        let frame = [
            Point2D(x: 0, y: 0), Point2D(x: Double(width), y: 0),
            Point2D(x: Double(width), y: Double(height)), Point2D(x: 0, y: Double(height))
        ]
        let scene = Scene(
            width: width,
            height: height,
            outline: frame,
            textQuad: frame,
            paperTone: 236,
            desk: { _, _ in 236 },
            scannerLipWidth: 2,
            noiseSigma: 2.0
        )
        let detection = DocumentQuadDetector().detect(in: Self.render(scene))

        #expect(detection.outcome == .fullFrame, "flags: \(detection.flags)")
        #expect(detection.quad == DocumentQuad.fullFrame(width: width, height: height))
        #expect(detection.flags.contains("noDeskDetected"))
    }

    @Test("Images without a document are rejected with a full-frame fallback")
    func rejectsImagesWithoutDocument() {
        let woodOnly = Self.render(Scene(width: 1200, height: 900, outline: [], desk: Self.woodDesk, lighting: Self.vignette))
        let wood = DocumentQuadDetector().detect(in: woodOnly)
        #expect(wood.outcome == .rejected, "flags: \(wood.flags)")
        #expect(wood.quad == DocumentQuad.fullFrame(width: 1200, height: 900))
        #expect(wood.confidence < 0.55)
        #expect(wood.flags.contains { $0.hasPrefix("rejected:") })

        let grey = Self.render(Scene(width: 800, height: 600, outline: [], desk: { _, _ in 128 }))
        let plain = DocumentQuadDetector().detect(in: grey)
        #expect(plain.outcome == .rejected)
        #expect(plain.flags == ["rejected:insufficientContrast"])
        #expect(plain.quad == DocumentQuad.fullFrame(width: 800, height: 600))
    }

    @Test("Open-book spread with spine dips uses corner-local lines on bent sides")
    func openBookSpreadWithBentEdges() {
        let tl = Point2D(x: 150, y: 190)
        let tr = Point2D(x: 1650, y: 170)
        let br = Point2D(x: 1680, y: 1180)
        let bl = Point2D(x: 120, y: 1200)
        let spineTop = (tl + tr) * 0.5 + Point2D(x: 0, y: 34)
        let spineBottom = (br + bl) * 0.5 - Point2D(x: 0, y: 30)
        let scene = Scene(
            width: 1800,
            height: 1350,
            outline: [tl, spineTop, tr, br, spineBottom, bl],
            textQuad: [tl, tr, br, bl],
            textColumns: [0.06...0.46, 0.54...0.94],
            gutterU: 0.5,
            desk: Self.woodDesk,
            lighting: Self.vignette
        )
        let detection = DocumentQuadDetector().detect(in: Self.render(scene))

        #expect(detection.outcome == .detected, "flags: \(detection.flags)")
        #expect(Self.maximumCornerError(detection.quad, [tl, tr, br, bl]) <= 1.0, "quad: \(detection.quad)")
        #expect(detection.flags.contains("bentSide:top"))
        #expect(detection.flags.contains("bentSide:bottom"))
        #expect(!detection.flags.contains("bentSide:left") && !detection.flags.contains("bentSide:right"))
    }

    @Test("Detection is resolution-invariant and deterministic")
    func scaleInvarianceAndDeterminism() {
        let full = Self.woodScene(scale: 1.0)
        let half = Self.woodScene(scale: 0.5)
        let detector = DocumentQuadDetector()
        let fullImage = Self.render(full.scene)
        let fullDetection = detector.detect(in: fullImage)
        let halfDetection = detector.detect(in: Self.render(half.scene))

        #expect(fullDetection.outcome == .detected)
        #expect(halfDetection.outcome == .detected)
        #expect(Self.maximumCornerError(halfDetection.quad, half.truth) <= 0.75, "quad: \(halfDetection.quad)")
        let normalizedDifference = zip(fullDetection.quad.corners, halfDetection.quad.corners)
            .map { $0.distance(to: $1 * 2.0) }
            .max() ?? .infinity
        #expect(normalizedDifference <= 1.5)

        #expect(detector.detect(in: fullImage) == fullDetection)
    }

    @Test("Codable round-trips, partial configurations decode with defaults, degenerate inputs are safe")
    func codableAndDegenerateInputs() throws {
        let (scene, _) = Self.woodScene(scale: 0.5)
        let detection = DocumentQuadDetector().detect(in: Self.render(scene))
        let data = try JSONEncoder().encode(detection)
        #expect(try JSONDecoder().decode(DocumentQuadDetection.self, from: data) == detection)

        let minimal = #"{"outcome":"rejected","quad":{"topLeft":{"x":0,"y":0},"topRight":{"x":4,"y":0},"bottomRight":{"x":4,"y":3},"bottomLeft":{"x":0,"y":3}},"confidence":0}"#
        let decodedMinimal = try JSONDecoder().decode(DocumentQuadDetection.self, from: Data(minimal.utf8))
        #expect(decodedMinimal.flags.isEmpty && decodedMinimal.candidateQuad == nil)

        let configuration = try JSONDecoder().decode(
            DocumentQuadDetector.Configuration.self,
            from: Data(#"{"minimumConfidence":0.7,"edgeScales":[]}"#.utf8)
        )
        #expect(configuration.minimumConfidence == 0.7)
        #expect(configuration.edgeScales == [1.0, 2.0, 4.0])
        #expect(configuration.workingLongSide == 1024)
        let roundTripped = try JSONDecoder().decode(
            DocumentQuadDetector.Configuration.self,
            from: try JSONEncoder().encode(configuration)
        )
        #expect(roundTripped == configuration)

        let tiny = DocumentQuadDetector().detect(in: GrayscaleBuffer(width: 16, height: 16, dpi: 300, initialValue: 200))
        #expect(tiny.outcome == .rejected && tiny.flags == ["rejected:imageTooSmall"])
        #expect(tiny.quad == DocumentQuad.fullFrame(width: 16, height: 16))

        let quad = DocumentQuad.fullFrame(width: 10, height: 8)
        #expect(quad.area == 80 && quad.contains(Point2D(x: 5, y: 4)) && !quad.contains(Point2D(x: 11, y: 4)))
        #expect(quad.boundingBox == Rect2D(x: 0, y: 0, width: 10, height: 8))
    }
}
