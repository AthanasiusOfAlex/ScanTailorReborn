import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

@Suite("Substep 5.1.2 — Perspective Rectification & Sheet Cropping Tests")
struct PerspectiveRectificationTests {
    typealias Fixtures = DocumentQuadDetectorTests

    // MARK: - Camera Model

    /// Projects a `pageWidth × pageHeight` planar rectangle through a pinhole camera (principal
    /// point at the image center) and returns its image corners (TL, TR, BR, BL).
    static func projectPage(
        imageWidth: Int,
        imageHeight: Int,
        focal: Double,
        pageWidth: Double = 6,
        pageHeight: Double = 9,
        pitchDegrees: Double,
        yawDegrees: Double,
        rollDegrees: Double,
        fill: Double = 0.78
    ) -> [Point2D] {
        let (p, y, r) = (pitchDegrees * .pi / 180, yawDegrees * .pi / 180, rollDegrees * .pi / 180)
        let rx = [1, 0, 0, 0, cos(p), -sin(p), 0, sin(p), cos(p)]
        let ry = [cos(y), 0, sin(y), 0, 1, 0, -sin(y), 0, cos(y)]
        let rz = [cos(r), -sin(r), 0, sin(r), cos(r), 0, 0, 0, 1]
        func mul(_ a: [Double], _ b: [Double]) -> [Double] {
            (0..<9).map { k in (0..<3).reduce(0) { $0 + a[(k / 3) * 3 + $1] * b[$1 * 3 + k % 3] } }
        }
        let rotation = mul(rz, mul(ry, rx))
        let distance = pageHeight * focal / (fill * Double(imageHeight))
        let corners = [(-0.5, -0.5), (0.5, -0.5), (0.5, 0.5), (-0.5, 0.5)].map { (pageWidth * $0.0, pageHeight * $0.1) }
        return corners.map { (x, y) in
            let cx = rotation[0] * x + rotation[1] * y
            let cy = rotation[3] * x + rotation[4] * y
            let cz = rotation[6] * x + rotation[7] * y + distance
            return Point2D(x: focal * cx / cz + Double(imageWidth) / 2, y: focal * cy / cz + Double(imageHeight) / 2)
        }
    }

    static let keystoneWidth = 1400
    static let keystoneHeight = 1050
    static var keystoneFocal: Double { 0.9 * (Double(keystoneWidth * keystoneWidth + keystoneHeight * keystoneHeight)).squareRoot() }

    static func keystoneCorners() -> [Point2D] {
        projectPage(
            imageWidth: keystoneWidth, imageHeight: keystoneHeight, focal: keystoneFocal,
            pitchDegrees: 24, yawDegrees: -15, rollDegrees: 4
        )
    }

    static func keystoneImage() -> GrayscaleBuffer {
        let corners = keystoneCorners()
        return Fixtures.render(Fixtures.Scene(
            width: keystoneWidth,
            height: keystoneHeight,
            outline: corners,
            textQuad: corners,
            desk: Fixtures.woodDesk,
            lighting: Fixtures.vignette
        ))
    }

    static func flatbedImage() -> GrayscaleBuffer {
        let (width, height) = (1275, 1650)
        let frame = [
            Point2D(x: 0, y: 0), Point2D(x: Double(width), y: 0),
            Point2D(x: Double(width), y: Double(height)), Point2D(x: 0, y: Double(height)),
        ]
        return Fixtures.render(Fixtures.Scene(
            width: width, height: height, outline: frame, textQuad: frame,
            paperTone: 236, desk: { _, _ in 236 }, scannerLipWidth: 2, noiseSigma: 2.0
        ))
    }

    /// Maps unit-square page coordinates to image coordinates for the truth quadrangle.
    static func truthPoint(_ corners: [Point2D], u: Double, v: Double) -> Point2D {
        let m = Fixtures.squareToQuad(corners)
        let w = m[6] * u + m[7] * v + m[8]
        return Point2D(x: (m[0] * u + m[1] * v + m[2]) / w, y: (m[3] * u + m[4] * v + m[5]) / w)
    }

    static func pipeline(rectify: Bool = true) -> BookPipelineCoordinator {
        BookPipelineCoordinator(configuration: .init(
            processingDPI: 300,
            outputDPI: 150,
            splitMode: .singlePage,
            enableDewarp: false,
            enableAutomaticFontScaleCalibration: false,
            enablePerspectiveRectification: rectify
        ))
    }

    // MARK: - Tests

    @Test("Homography2D DLT: exact 4-point fit, inverse, composition, least squares, degeneracy, Codable")
    func homographyDLT() throws {
        let source = [Point2D(x: 0, y: 0), Point2D(x: 800, y: 0), Point2D(x: 800, y: 1200), Point2D(x: 0, y: 1200)]
        let destination = [Point2D(x: 213.4, y: 101.9), Point2D(x: 1250.2, y: 160.3), Point2D(x: 1102.7, y: 990.5), Point2D(x: 180.1, y: 1130.8)]
        let h = try #require(Homography2D(mapping: source, to: destination))
        for (p, q) in zip(source, destination) {
            #expect(try #require(h.transform(p)).distance(to: q) < 1e-9)
        }
        let inverse = try h.inverted()
        let probe = Point2D(x: 377.25, y: 911.5)
        let forward = try #require(h.transform(probe))
        let roundTrip = try #require(inverse.transform(forward))
        #expect(roundTrip.distance(to: probe) < 1e-9)
        let composed = h.concatenating(inverse)
        for (a, b) in zip(composed.matrix, Homography2D.identity.matrix) { #expect(abs(a - b) < 1e-12) }

        // Over-determined: 9 exact correspondences recover the same matrix.
        let grid = (0...2).flatMap { i in (0...2).map { j in Point2D(x: 400 * Double(i), y: 600 * Double(j)) } }
        let lsq = try #require(Homography2D(mapping: grid, to: grid.compactMap { h.transform($0) }))
        for (a, b) in zip(lsq.matrix, h.matrix) { #expect(abs(a - b) <= 1e-9 * max(1, abs(b))) }

        // Affine promotion agrees with AffineTransform2D.
        let affine = AffineTransform2D.rotation(radians: 0.3, center: Point2D(x: 10, y: 20))
        let promoted = Homography2D(affine)
        #expect(promoted.isAffine)
        #expect(try #require(promoted.transform(probe)).distance(to: affine.transform(probe)) < 1e-12)

        // Degenerate inputs.
        let collinear = [Point2D(x: 0, y: 0), Point2D(x: 1, y: 1), Point2D(x: 2, y: 2), Point2D(x: 0, y: 5)]
        #expect(Homography2D(mapping: collinear, to: destination) == nil)
        #expect(Homography2D(mapping: Array(source.prefix(3)), to: Array(destination.prefix(3))) == nil)
        #expect(throws: GeometryError.self) { try Homography2D(matrix: [1, 0, 0, 0, 1, 0, 0, 0]) }
        #expect(throws: GeometryError.self) { try Homography2D(matrix: [1, 2, 3, 2, 4, 6, 0, 0, 1]) }

        // Points on the line at infinity have no image.
        let horizon = try Homography2D(matrix: [1, 0, 0, 0, 1, 0, 0.01, 0, 1])
        #expect(horizon.transform(Point2D(x: -100, y: 7)) == nil)

        let data = try JSONEncoder().encode(h)
        #expect(try JSONDecoder().decode(Homography2D.self, from: data) == h)
        let bad = Data(#"{"matrix":[0,0,0,0,0,0,0,0,0]}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Homography2D.self, from: bad) }
    }

    @Test("Bilinear resampler: identity is lossless, out-of-source samples are white, DPI preserved")
    func resamplerIdentityAndBounds() {
        var pixels = ContiguousArray<UInt8>(repeating: 0, count: 37 * 23)
        for i in pixels.indices { pixels[i] = UInt8((i &* 97) % 251) }
        let buffer = GrayscaleBuffer(width: 37, height: 23, dpi: 412, pixels: pixels)

        let same = PerspectiveRectifier.resample(buffer, inverse: .identity, outputSize: Size2I(width: 37, height: 23))
        #expect(same == buffer)

        // Shift right by 10.5 px: the left 10 columns sample outside the source and must be white.
        let shift = Homography2D(AffineTransform2D.translation(tx: -10, ty: 0))
        let shifted = PerspectiveRectifier.resample(buffer, inverse: shift, outputSize: Size2I(width: 37, height: 23))
        #expect(shifted.dpi == 412)
        for y in 0..<23 {
            for x in 0..<9 { #expect(shifted[x, y] == 255) }
            for x in 10..<37 { #expect(shifted[x, y] == buffer[x - 10, y]) }
        }

        // Half-pixel offset averages horizontal neighbours.
        let half = Homography2D(AffineTransform2D.translation(tx: 0.5, ty: 0))
        let averaged = PerspectiveRectifier.resample(buffer, inverse: half, outputSize: Size2I(width: 36, height: 23))
        let expected = (Int(buffer[4, 7]) + Int(buffer[5, 7]) + 1) / 2
        #expect(abs(Int(averaged[4, 7]) - expected) <= 1)
    }

    @Test("Aspect recovery is exact for pinhole projections; assumed focal and page-size snapping")
    func aspectRecovery() throws {
        let size = Size2I(width: Self.keystoneWidth, height: Self.keystoneHeight)
        let poses: [(Double, Double, Double)] = [(24, -15, 4), (-18, 22, -6), (30, 10, 0), (8, -28, 12)]
        for (pitch, yaw, roll) in poses {
            let corners = Self.projectPage(
                imageWidth: size.width, imageHeight: size.height, focal: Self.keystoneFocal,
                pitchDegrees: pitch, yawDegrees: yaw, rollDegrees: roll
            )
            let quad = DocumentQuad(topLeft: corners[0], topRight: corners[1], bottomRight: corners[2], bottomLeft: corners[3])
            let estimate = try #require(PerspectiveRectifier.estimateAspectRatio(of: quad, imageSize: size))
            #expect(estimate.focalLengthSolved)
            #expect(abs(estimate.aspectRatio - 6.0 / 9.0) < 1e-6, "pose \(pitch),\(yaw),\(roll)")
            #expect(abs(estimate.focalLengthPixels / Self.keystoneFocal - 1) < 1e-6)
        }

        // Pure pitch leaves top and bottom parallel: the focal length is unidentifiable and the
        // assumed value is used (exact when it matches the true camera).
        let trapezoid = Self.projectPage(
            imageWidth: size.width, imageHeight: size.height, focal: Self.keystoneFocal,
            pitchDegrees: 25, yawDegrees: 0, rollDegrees: 0
        )
        let tQuad = DocumentQuad(topLeft: trapezoid[0], topRight: trapezoid[1], bottomRight: trapezoid[2], bottomLeft: trapezoid[3])
        let matching = PerspectiveRectifier.Configuration(assumedFocalLengthDiagonalFraction: 0.9)
        let assumed = try #require(PerspectiveRectifier.estimateAspectRatio(of: tQuad, imageSize: size, configuration: matching))
        #expect(!assumed.focalLengthSolved)
        #expect(abs(assumed.aspectRatio - 6.0 / 9.0) < 1e-6)
        let plan = try #require(PerspectiveRectifier.plan(for: tQuad, sourceSize: size, configuration: matching))
        #expect(plan.aspectSource == .assumedFocalLength)

        // A known page size snaps a near-miss aspect (single page or two-page spread).
        let skewed = DocumentQuad(
            topLeft: Point2D(x: 100, y: 100), topRight: Point2D(x: 720, y: 100),
            bottomRight: Point2D(x: 720, y: 1000), bottomLeft: Point2D(x: 100, y: 1000)
        )
        let octavo = PhysicalSizeSpec(width: 6, height: 9, unit: .inches)
        let snapped = try #require(PerspectiveRectifier.plan(for: skewed, sourceSize: size, targetPageSize: octavo))
        #expect(snapped.aspectSource == .pageSize)
        #expect(abs(snapped.aspectRatio - 6.0 / 9.0) < 1e-12)
        let spread = DocumentQuad(
            topLeft: Point2D(x: 50, y: 100), topRight: Point2D(x: 1300, y: 100),
            bottomRight: Point2D(x: 1300, y: 1000), bottomLeft: Point2D(x: 50, y: 1000)
        )
        let spreadPlan = try #require(PerspectiveRectifier.plan(for: spread, sourceSize: size, targetPageSize: octavo))
        #expect(spreadPlan.aspectSource == .pageSize)
        #expect(abs(spreadPlan.aspectRatio - 12.0 / 9.0) < 1e-12)
        let far = DocumentQuad(
            topLeft: Point2D(x: 100, y: 100), topRight: Point2D(x: 1100, y: 100),
            bottomRight: Point2D(x: 1100, y: 1000), bottomLeft: Point2D(x: 100, y: 1000)
        )
        #expect(try #require(PerspectiveRectifier.plan(for: far, sourceSize: size, targetPageSize: octavo)).aspectSource != .pageSize)

        // Non-convex / anticlockwise quads are refused.
        let flipped = DocumentQuad(topLeft: skewed.topRight, topRight: skewed.topLeft, bottomRight: skewed.bottomLeft, bottomLeft: skewed.bottomRight)
        #expect(PerspectiveRectifier.plan(for: flipped, sourceSize: size) == nil)
    }

    @Test("Keystone round trip: detected plan maps the true page grid within 1 px and recovers the aspect")
    func keystoneRoundTrip() throws {
        let image = Self.keystoneImage()
        let size = Size2I(width: image.width, height: image.height)
        let detection = DocumentQuadDetector().detect(in: image)
        #expect(detection.outcome == .detected, "flags: \(detection.flags)")
        let plan = try #require(PerspectiveRectifier.plan(for: detection, sourceSize: size))
        #expect(plan.aspectSource == .perspective)
        #expect(abs(plan.aspectRatio / (6.0 / 9.0) - 1) < 0.01, "aspect \(plan.aspectRatio)")

        // No edge is downsampled.
        let c = Self.keystoneCorners()
        #expect(Double(plan.outputSize.height) >= max(c[0].distance(to: c[3]), c[1].distance(to: c[2])) - 1)
        #expect(Double(plan.outputSize.width) >= max(c[0].distance(to: c[1]), c[3].distance(to: c[2])) - 1)

        let w = Double(plan.outputSize.width)
        let h = Double(plan.outputSize.height)
        var worst = 0.0
        for i in 0...4 {
            for j in 0...4 {
                let (u, v) = (Double(i) / 4, Double(j) / 4)
                let mapped = try #require(plan.sourceToRectified.transform(Self.truthPoint(c, u: u, v: v)))
                worst = max(worst, mapped.distance(to: Point2D(x: u * w, y: v * h)))
            }
        }
        #expect(worst <= 1.0, "worst grid error \(worst) px")
    }

    @Test("Rectified text lines are straight and horizontal")
    func straightLinePreservation() throws {
        let image = Self.keystoneImage()
        let detection = DocumentQuadDetector().detect(in: image)
        let plan = try #require(PerspectiveRectifier.plan(for: detection, sourceSize: Size2I(width: image.width, height: image.height)))
        let rectified = PerspectiveRectifier.rectify(image, plan: plan)
        #expect(rectified.width == plan.outputSize.width && rectified.height == plan.outputSize.height)
        #expect(rectified.dpi == image.dpi)

        let W = rectified.width
        let H = Double(rectified.height)
        let pitch = H * 0.86 / 42
        for k in [3, 20, 38] {
            let expectedY = H * (0.07 + (Double(k) + 0.46) / 42 * 0.86)
            var xs: [Double] = []
            var ys: [Double] = []
            var x0 = Int(0.12 * Double(W))
            while x0 + 24 <= Int(0.88 * Double(W)) {
                var sum = 0.0
                var weighted = 0.0
                let yLow = Int((expectedY - 0.3 * pitch).rounded(.down))
                let yHigh = Int((expectedY + 0.3 * pitch).rounded(.up))
                for y in yLow...yHigh {
                    for x in x0..<(x0 + 24) {
                        let weight = max(0.0, 200.0 - Double(rectified[x, y]))
                        sum += weight
                        weighted += weight * (Double(y) + 0.5)
                    }
                }
                if sum > 24 * 100 {
                    xs.append(Double(x0) + 12)
                    ys.append(weighted / sum)
                }
                x0 += 24
            }
            #expect(xs.count >= 10, "line \(k): \(xs.count) strips")
            let n = Double(xs.count)
            let mx = xs.reduce(0, +) / n
            let my = ys.reduce(0, +) / n
            let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
            let sxx = xs.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
            let slope = sxy / sxx
            let rms = (zip(xs, ys).reduce(0) { acc, p in
                let r = p.1 - (my + slope * (p.0 - mx))
                return acc + r * r
            } / n).squareRoot()
            #expect(rms <= 0.5, "line \(k) rms \(rms)")
            #expect(abs(slope) * Double(W) <= 1.5, "line \(k) slope \(slope)")
            #expect(abs(my - expectedY) <= 1.5, "line \(k) offset \(my - expectedY)")
        }
    }

    @Test("Full-frame and rejected detections pass through with no resampling")
    func passthrough() async throws {
        let flatbed = Self.flatbedImage()
        let size = Size2I(width: flatbed.width, height: flatbed.height)
        let detection = DocumentQuadDetector().detect(in: flatbed)
        #expect(detection.outcome == .fullFrame)
        #expect(PerspectiveRectifier.plan(for: detection, sourceSize: size) == nil)
        var rejected = detection
        rejected.outcome = .rejected
        #expect(PerspectiveRectifier.plan(for: rejected, sourceSize: size) == nil)

        let enabled = try await Self.pipeline(rectify: true).processGrayscalePages(
            [flatbed], writer: NullWriter(), accelerator: PortableComputeAccelerator()
        )
        let disabled = try await Self.pipeline(rectify: false).processGrayscalePages(
            [flatbed], writer: NullWriter(), accelerator: PortableComputeAccelerator()
        )
        let record = try #require(enabled.manifest.sourcePageGeometry.first)
        #expect(record.rectified == false)
        #expect(record.plan == nil)
        #expect(record.detection?.outcome == .fullFrame)
        #expect(record.rasterSize == size)
        #expect(disabled.manifest.sourcePageGeometry.first?.detection == nil)
        #expect(enabled.outputBitmapsAtOutputDPI == disabled.outputBitmapsAtOutputDPI)
        #expect(enabled.manifest.pages == disabled.manifest.pages)
    }

    @Test("Pipeline rectifies a keystoned desk photo ahead of split/deskew and crops the desk")
    func pipelineIntegration() async throws {
        let image = Self.keystoneImage()
        let output = try await Self.pipeline().processGrayscalePages(
            [image], writer: NullWriter(), accelerator: PortableComputeAccelerator()
        )
        let record = try #require(output.manifest.sourcePageGeometry.first)
        #expect(record.rectified)
        #expect(record.detection?.outcome == .detected)
        let plan = try #require(record.plan)
        #expect(abs(plan.aspectRatio / (6.0 / 9.0) - 1) < 0.01)
        #expect(output.manifest.sourcePageSplits.first?.layoutType == .singlePage)

        let page = try #require(output.cleanedBitmapsAtProcessingDPI.first)
        #expect(abs(page.width - plan.outputSize.width) <= 2 && abs(page.height - plan.outputSize.height) <= 2)
        #expect(try #require(output.manifest.pages.first).skewAngleDegrees.magnitude < 0.5)

        // The 3 % border band of the rectified page must be (almost) free of desk ink.
        let band = max(4, Int(0.03 * Double(min(page.width, page.height))))
        let strips = [
            Rect2I(x: 0, y: 0, width: page.width, height: band),
            Rect2I(x: 0, y: page.height - band, width: page.width, height: band),
            Rect2I(x: 0, y: 0, width: band, height: page.height),
            Rect2I(x: page.width - band, y: 0, width: band, height: page.height),
        ]
        for strip in strips {
            let density = Double(page.cropped(to: strip).countBlackPixels()) / Double(strip.width * strip.height)
            #expect(density < 0.01, "strip \(strip) density \(density)")
        }
        // Text survives in the interior.
        #expect(page.countBlackPixels() > page.width * page.height / 50)
    }

    @Test("Manifest overrides: disable, manual quad with raster rescaling, legacy decoding, CLI flag")
    func manifestOverrides() async throws {
        let image = Self.keystoneImage()
        let accelerator = PortableComputeAccelerator()
        let first = try await Self.pipeline().processGrayscalePages([image], writer: NullWriter(), accelerator: accelerator)

        // 1. disableRectification passes the page through and is carried forward.
        var manifest = first.manifest
        manifest.sourcePageGeometry[0].manualOverride = SourcePageGeometryOverride(disableRectification: true)
        let disabled = try await Self.pipeline().processGrayscalePages(
            [image], writer: NullWriter(), accelerator: accelerator, existingManifest: manifest
        )
        let disabledRecord = try #require(disabled.manifest.sourcePageGeometry.first)
        #expect(!disabledRecord.rectified)
        #expect(disabledRecord.detection?.outcome == .detected)
        #expect(disabledRecord.manualOverride?.disableRectification == true)
        #expect(disabled.cleanedBitmapsAtProcessingDPI.first?.width == image.width)

        // 2. A manual quad recorded against a half-size raster is rescaled to the current raster.
        let truth = Self.keystoneCorners()
        let half = truth.map { $0 * 0.5 }
        manifest.sourcePageGeometry[0].rasterSize = Size2I(width: image.width / 2, height: image.height / 2)
        manifest.sourcePageGeometry[0].manualOverride = SourcePageGeometryOverride(
            overrideQuad: DocumentQuad(topLeft: half[0], topRight: half[1], bottomRight: half[2], bottomLeft: half[3])
        )
        let manual = try await Self.pipeline(rectify: false).processGrayscalePages(
            [image], writer: NullWriter(), accelerator: accelerator, existingManifest: manifest
        )
        let manualRecord = try #require(manual.manifest.sourcePageGeometry.first)
        #expect(manualRecord.rectified, "an explicit quad applies even when automatic rectification is off")
        #expect(manualRecord.detection == nil)
        let appliedQuad = try #require(manualRecord.plan?.quad)
        #expect(Fixtures.maximumCornerError(appliedQuad, truth) < 1e-9)
        #expect(manualRecord.rasterSize == Size2I(width: image.width, height: image.height))

        // 3. JSON round trip, and manifests from before 5.1.2 decode with no geometry.
        let data = try JSONEncoder().encode(manual.manifest)
        #expect(try JSONDecoder().decode(BookProcessingManifest.self, from: data) == manual.manifest)
        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "sourcePageGeometry")
        let legacyManifest = try JSONDecoder().decode(
            BookProcessingManifest.self, from: try JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(legacyManifest.sourcePageGeometry.isEmpty)
        #expect(ScanTailorCLI.formatManifestSummary(manual.manifest).contains("Perspective Rectification: 1 rectified"))

        // 4. CLI flag.
        #expect(try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf"]).enablePerspectiveRectification)
        #expect(try !ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf", "--no-perspective"]).enablePerspectiveRectification)
        #expect(try !ScanTailorCLI.parseProcessOptions(["--no-quad", "in.pdf", "-o", "out.pdf"]).enablePerspectiveRectification)
    }
}

private struct NullWriter: PDFDocumentWriter, ~Copyable {
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap,
        dpi: Int,
        pageBoxPoints: Rect2D,
        ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {}

    consuming func finalize() throws(PDFWriteError) {}
}
