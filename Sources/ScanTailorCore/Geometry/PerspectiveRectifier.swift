import Foundation
import ScanTailorContracts

// MARK: - Rectification Plan

/// Geometry of a perspective rectification: the source quadrangle, the recovered physical aspect
/// ratio, the rectified raster size, and the homographies between the two frames.
///
/// Both frames use continuous pixel coordinates (pixel `(i, j)` covers `[i, i + 1) × [j, j + 1)`).
/// The quadrangle's corners map exactly onto the rectified raster's corners
/// `(0, 0)`, `(W, 0)`, `(W, H)`, `(0, H)`.
public struct RectificationPlan: Sendable, Equatable, Codable {
    /// How the rectified aspect ratio was determined.
    public enum AspectSource: String, Sendable, Equatable, Codable {
        /// Recovered from the quadrangle with a focal length solved from its vanishing points.
        case perspective
        /// Recovered from the quadrangle with an assumed focal length (the focal length is not
        /// identifiable from a parallelogram or a one-axis trapezoid).
        case assumedFocalLength
        /// Snapped to the single-page or two-page-spread aspect of the known `--page-size`.
        case pageSize
    }

    /// Source quadrangle (TL, TR, BR, BL) in source-raster pixels.
    public var quad: DocumentQuad
    /// Rectified width ÷ height.
    public var aspectRatio: Double
    /// Provenance of ``aspectRatio``.
    public var aspectSource: AspectSource
    /// Focal length in source pixels used for aspect recovery.
    public var focalLengthPixels: Double
    /// Rectified raster size in pixels.
    public var outputSize: Size2I
    /// Maps source-raster points to rectified-raster points.
    public var sourceToRectified: Homography2D
    /// Maps rectified-raster points to source-raster points (used for inverse sampling).
    public var rectifiedToSource: Homography2D

    public init(
        quad: DocumentQuad,
        aspectRatio: Double,
        aspectSource: AspectSource,
        focalLengthPixels: Double,
        outputSize: Size2I,
        sourceToRectified: Homography2D,
        rectifiedToSource: Homography2D
    ) {
        self.quad = quad
        self.aspectRatio = aspectRatio
        self.aspectSource = aspectSource
        self.focalLengthPixels = focalLengthPixels
        self.outputSize = outputSize
        self.sourceToRectified = sourceToRectified
        self.rectifiedToSource = rectifiedToSource
    }
}

// MARK: - Perspective Rectifier

/// Removes camera keystoning by mapping a detected document quadrangle onto an upright rectangle
/// and cropping the desk away.
///
/// The rectified aspect ratio is recovered with the Zhang–He whiteboard method (pinhole camera,
/// square pixels, principal point at the image center); the output resolution is chosen so that
/// no quadrangle edge is downsampled. Resampling is bilinear and pure Swift.
public enum PerspectiveRectifier {
    /// Tuning parameters.
    public struct Configuration: Sendable, Equatable, Codable {
        /// Maximum rectified pixel count as a multiple of the source pixel count (default `1.25`).
        public var maximumPixelGrowth: Double
        /// Relative tolerance for snapping to a known page-size aspect (default `0.15`).
        public var pageSizeSnapTolerance: Double
        /// Focal length (as a fraction of the image diagonal) assumed when it cannot be solved
        /// from the quadrangle, and the plausible solved range `[0.3, 4]` × diagonal otherwise
        /// (default `0.8`, typical of phone main cameras).
        public var assumedFocalLengthDiagonalFraction: Double

        public init(
            maximumPixelGrowth: Double = 1.25,
            pageSizeSnapTolerance: Double = 0.15,
            assumedFocalLengthDiagonalFraction: Double = 0.8
        ) {
            self.maximumPixelGrowth = min(max(0.25, maximumPixelGrowth), 4.0)
            self.pageSizeSnapTolerance = min(max(0.0, pageSizeSnapTolerance), 0.5)
            self.assumedFocalLengthDiagonalFraction = min(max(0.3, assumedFocalLengthDiagonalFraction), 4.0)
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Configuration()
            self.init(
                maximumPixelGrowth: try c.decodeIfPresent(Double.self, forKey: .maximumPixelGrowth) ?? d.maximumPixelGrowth,
                pageSizeSnapTolerance: try c.decodeIfPresent(Double.self, forKey: .pageSizeSnapTolerance) ?? d.pageSizeSnapTolerance,
                assumedFocalLengthDiagonalFraction: try c.decodeIfPresent(Double.self, forKey: .assumedFocalLengthDiagonalFraction)
                    ?? d.assumedFocalLengthDiagonalFraction
            )
        }
    }

    static let minimumSolvedFocalFraction = 0.3
    static let maximumSolvedFocalFraction = 4.0

    // MARK: Aspect Recovery

    /// Recovers the physical width ÷ height of the planar rectangle imaged as `quad`.
    ///
    /// - Parameters:
    ///   - quad: Imaged rectangle corners.
    ///   - imageSize: Source raster size; its center is used as the principal point and its
    ///     diagonal scales the focal-length plausibility range.
    ///   - configuration: Tuning parameters.
    /// - Returns: The aspect ratio, the focal length used, and whether that focal length was
    ///   solved (`true`) or assumed (`false`); `nil` for a degenerate quadrangle.
    public static func estimateAspectRatio(
        of quad: DocumentQuad,
        imageSize: Size2I,
        configuration: Configuration = Configuration()
    ) -> (aspectRatio: Double, focalLengthPixels: Double, focalLengthSolved: Bool)? {
        let cx = Double(imageSize.width) / 2
        let cy = Double(imageSize.height) / 2
        let diagonal = (Double(imageSize.width * imageSize.width + imageSize.height * imageSize.height)).squareRoot()
        guard diagonal > 0 else { return nil }

        // Homogeneous corners relative to the principal point, scaled by the diagonal for conditioning.
        func h(_ p: Point2D) -> SIMD3<Double> { SIMD3((p.x - cx) / diagonal, (p.y - cy) / diagonal, 1) }
        func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
            SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }

        let m1 = h(quad.topLeft), m2 = h(quad.topRight), m3 = h(quad.bottomLeft), m4 = h(quad.bottomRight)
        let k2Denominator = dot(cross(m2, m4), m3)
        let k3Denominator = dot(cross(m3, m4), m2)
        guard abs(k2Denominator) > 1e-12, abs(k3Denominator) > 1e-12 else { return nil }
        let k2 = dot(cross(m1, m4), m3) / k2Denominator
        let k3 = dot(cross(m1, m4), m2) / k3Denominator
        let n2 = k2 * m2 - m1
        let n3 = k3 * m3 - m1

        // Focal length (in diagonal units) from the orthogonality of the two rectangle edges.
        var focal = configuration.assumedFocalLengthDiagonalFraction
        var solved = false
        let zz = n2.z * n3.z
        if abs(zz) > 1e-10 {
            let f2 = -(n2.x * n3.x + n2.y * n3.y) / zz
            if f2.isFinite, f2 > 0 {
                let f = f2.squareRoot()
                if f >= minimumSolvedFocalFraction && f <= maximumSolvedFocalFraction {
                    focal = f
                    solved = true
                }
            }
        }
        let f2 = focal * focal
        let widthSquared = n2.x * n2.x + n2.y * n2.y + f2 * n2.z * n2.z
        let heightSquared = n3.x * n3.x + n3.y * n3.y + f2 * n3.z * n3.z
        guard widthSquared > 0, heightSquared > 0 else { return nil }
        let ratio = (widthSquared / heightSquared).squareRoot()
        guard ratio.isFinite, ratio > 0 else { return nil }
        return (ratio, focal * diagonal, solved)
    }

    // MARK: Planning

    /// Plans the rectification of a detection result.
    ///
    /// - Returns: `nil` for `fullFrame` and `rejected` outcomes (pass the page through untouched),
    ///   otherwise the plan for ``DocumentQuadDetection/quad``.
    public static func plan(
        for detection: DocumentQuadDetection,
        sourceSize: Size2I,
        targetPageSize: PhysicalSizeSpec? = nil,
        configuration: Configuration = Configuration()
    ) -> RectificationPlan? {
        guard detection.outcome == .detected else { return nil }
        return plan(for: detection.quad, sourceSize: sourceSize, targetPageSize: targetPageSize, configuration: configuration)
    }

    /// Plans the rectification of an explicit quadrangle (for example, a manual override).
    ///
    /// - Parameters:
    ///   - quad: Source quadrangle (TL, TR, BR, BL), screen-clockwise.
    ///   - sourceSize: Source raster size.
    ///   - targetPageSize: Known physical page size; when the recovered aspect lies within
    ///     ``Configuration/pageSizeSnapTolerance`` of its single-page or two-page-spread aspect, it
    ///     snaps to that aspect.
    ///   - configuration: Tuning parameters.
    /// - Returns: The plan, or `nil` for a degenerate or non-convex quadrangle.
    public static func plan(
        for quad: DocumentQuad,
        sourceSize: Size2I,
        targetPageSize: PhysicalSizeSpec? = nil,
        configuration: Configuration = Configuration()
    ) -> RectificationPlan? {
        guard sourceSize.width > 0, sourceSize.height > 0, isConvexClockwise(quad),
              let estimate = estimateAspectRatio(of: quad, imageSize: sourceSize, configuration: configuration)
        else { return nil }

        var ratio = estimate.aspectRatio
        var source: RectificationPlan.AspectSource = estimate.focalLengthSolved ? .perspective : .assumedFocalLength
        if let page = targetPageSize, page.width > 0, page.height > 0 {
            let single = page.width / page.height
            let candidates = [single, 2 * single]
            if let best = candidates.min(by: { abs(log(ratio / $0)) < abs(log(ratio / $1)) }),
               abs(ratio / best - 1) <= configuration.pageSizeSnapTolerance {
                ratio = best
                source = .pageSize
            }
        }

        // Size so that no quad edge is downsampled, then cap total growth.
        let c = quad.corners
        let horizontal = max(c[0].distance(to: c[1]), c[3].distance(to: c[2]))
        let vertical = max(c[0].distance(to: c[3]), c[1].distance(to: c[2]))
        var scale = max(horizontal / ratio, vertical)
        let sourcePixels = Double(sourceSize.width) * Double(sourceSize.height)
        let maximumPixels = configuration.maximumPixelGrowth * sourcePixels
        if ratio * scale * scale > maximumPixels {
            scale = (maximumPixels / ratio).squareRoot()
        }
        let outputSize = Size2I(
            width: max(1, Int((ratio * scale).rounded())),
            height: max(1, Int(scale.rounded()))
        )

        let w = Double(outputSize.width)
        let hgt = Double(outputSize.height)
        let rectangle = [Point2D(x: 0, y: 0), Point2D(x: w, y: 0), Point2D(x: w, y: hgt), Point2D(x: 0, y: hgt)]
        guard let forward = Homography2D(mapping: c, to: rectangle),
              let inverse = try? forward.inverted()
        else { return nil }

        return RectificationPlan(
            quad: quad,
            aspectRatio: ratio,
            aspectSource: source,
            focalLengthPixels: estimate.focalLengthPixels,
            outputSize: outputSize,
            sourceToRectified: forward,
            rectifiedToSource: inverse
        )
    }

    // MARK: Resampling

    /// Rectifies `buffer` according to `plan` with bilinear interpolation.
    ///
    /// Each output pixel center `(u + 0.5, v + 0.5)` is mapped through
    /// ``RectificationPlan/rectifiedToSource`` and sampled between source pixel centers; samples
    /// falling more than half a pixel outside the source raster are paper white (`255`). The
    /// source DPI is preserved.
    public static func rectify(_ buffer: borrowing GrayscaleBuffer, plan: RectificationPlan) -> GrayscaleBuffer {
        resample(buffer, inverse: plan.rectifiedToSource, outputSize: plan.outputSize)
    }

    /// Resamples `buffer` into `outputSize` where each output point `p` samples the source at
    /// `inverse(p)`.
    public static func resample(
        _ buffer: borrowing GrayscaleBuffer,
        inverse: Homography2D,
        outputSize: Size2I
    ) -> GrayscaleBuffer {
        let outW = max(1, outputSize.width)
        let outH = max(1, outputSize.height)
        let srcW = buffer.width
        let srcH = buffer.height
        var output = ContiguousArray<UInt8>(repeating: 255, count: outW * outH)
        guard srcW > 0, srcH > 0 else {
            return GrayscaleBuffer(width: outW, height: outH, dpi: buffer.dpi, pixels: output)
        }
        let m = inverse.matrix
        let maxX = Double(srcW) - 0.5
        let maxY = Double(srcH) - 0.5

        buffer.pixels.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                for v in 0..<outH {
                    let py = Double(v) + 0.5
                    var nx = m[0] * 0.5 + m[1] * py + m[2]
                    var ny = m[3] * 0.5 + m[4] * py + m[5]
                    var nw = m[6] * 0.5 + m[7] * py + m[8]
                    let row = v * outW
                    var u = 0
                    while u < outW {
                        defer {
                            nx += m[0]
                            ny += m[3]
                            nw += m[6]
                            u += 1
                        }
                        guard abs(nw) > 1e-12 else { continue }
                        let invW = 1.0 / nw
                        let sx = nx * invW
                        let sy = ny * invW
                        guard sx >= -0.5, sy >= -0.5, sx <= maxX + 1, sy <= maxY + 1 else { continue }
                        // Index space: pixel centers at integer positions.
                        let fx = min(max(sx - 0.5, 0), Double(srcW - 1))
                        let fy = min(max(sy - 0.5, 0), Double(srcH - 1))
                        let x0 = Int(fx)
                        let y0 = Int(fy)
                        let x1 = min(x0 + 1, srcW - 1)
                        let y1 = min(y0 + 1, srcH - 1)
                        let ax = fx - Double(x0)
                        let ay = fy - Double(y0)
                        let top = Double(src[y0 * srcW + x0]) * (1 - ax) + Double(src[y0 * srcW + x1]) * ax
                        let bottom = Double(src[y1 * srcW + x0]) * (1 - ax) + Double(src[y1 * srcW + x1]) * ax
                        let value = top * (1 - ay) + bottom * ay
                        dst[row + u] = UInt8(min(255.0, max(0.0, value + 0.5)))
                    }
                }
            }
        }
        return GrayscaleBuffer(width: outW, height: outH, dpi: buffer.dpi, pixels: output)
    }

    // MARK: Helpers

    /// Whether the quadrangle is strictly convex and screen-clockwise (TL → TR → BR → BL).
    static func isConvexClockwise(_ quad: DocumentQuad) -> Bool {
        let c = quad.corners
        guard c.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        for i in 0..<4 {
            let a = c[(i + 1) % 4] - c[i]
            let b = c[(i + 2) % 4] - c[(i + 1) % 4]
            if QuadDetectionKernels.cross(a, b) <= 0 { return false }
        }
        return true
    }
}
