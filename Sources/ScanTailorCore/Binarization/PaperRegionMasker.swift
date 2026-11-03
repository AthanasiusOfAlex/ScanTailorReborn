import Foundation
import ScanTailorContracts

// MARK: - Desk Mask Result

/// Outcome and telemetry of a ``PaperRegionMasker`` pass over one page.
public struct DeskMaskResult: Sendable, Equatable, Codable {
    /// How much of the page, if any, ``PaperRegionMasker`` replaced with paper-toned fill.
    public enum Mode: String, Sendable, Equatable, Codable {
        /// Small border slivers or gutter wedges were filled (the usual case after rectification).
        case residual
        /// A substantial desk/background area was filled (no rectification, or a rejected/disabled
        /// detection), so the depth and coverage caps that protect edge-touching content do not apply.
        case full
        /// Nothing was masked: the page had no detectable desk, insufficient paper/desk contrast,
        /// or masking would have exceeded the residual coverage cap.
        case skipped
    }

    /// Masking extent actually applied.
    public var mode: Mode
    /// Fraction of page pixels replaced with fill, in `[0, 1]`.
    public var maskedFraction: Double
    /// Maximum inward reach of the mask from each side, as a fraction of that side's dimension.
    public var maskedDepthBySide: DocumentQuadDetection.SideMetrics
    /// Mean raw brightness of the classified paper region (working-raster gray levels).
    public var paperBrightness: Double
    /// Mean raw brightness of the classified desk region (working-raster gray levels).
    public var deskBrightness: Double
    /// Diagnostic flags: `skipped:<reason>`, `capped:depth`, `capped:coverage`.
    public var flags: [String]

    /// Creates a desk mask result.
    public init(
        mode: Mode,
        maskedFraction: Double,
        maskedDepthBySide: DocumentQuadDetection.SideMetrics = .zero,
        paperBrightness: Double = 0,
        deskBrightness: Double = 0,
        flags: [String] = []
    ) {
        self.mode = mode
        self.maskedFraction = maskedFraction
        self.maskedDepthBySide = maskedDepthBySide
        self.paperBrightness = paperBrightness
        self.deskBrightness = deskBrightness
        self.flags = flags
    }

    /// A result reporting that nothing was masked.
    public static func skipped(reason: String) -> DeskMaskResult {
        DeskMaskResult(mode: .skipped, maskedFraction: 0, flags: ["skipped:\(reason)"])
    }

    private enum CodingKeys: String, CodingKey {
        case mode, maskedFraction, maskedDepthBySide, paperBrightness, deskBrightness, flags
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try c.decode(Mode.self, forKey: .mode)
        self.maskedFraction = try c.decode(Double.self, forKey: .maskedFraction)
        self.maskedDepthBySide = try c.decodeIfPresent(DocumentQuadDetection.SideMetrics.self, forKey: .maskedDepthBySide) ?? .zero
        self.paperBrightness = try c.decodeIfPresent(Double.self, forKey: .paperBrightness) ?? 0
        self.deskBrightness = try c.decodeIfPresent(Double.self, forKey: .deskBrightness) ?? 0
        self.flags = try c.decodeIfPresent([String].self, forKey: .flags) ?? []
    }
}

// MARK: - Paper Region Masker

/// Fills table/desk and other non-paper background with a paper-toned estimate before background
/// normalization and adaptive binarization, so dark wooden surfaces never form macro-clusters.
///
/// The classifier reuses the same `localMean − localStd` paper/desk separation as
/// ``DocumentQuadDetector`` (bright, smooth paper vs. darker, textured desk), but only the
/// background actually touching the image border is masked: a flood fill from the border through
/// non-paper pixels, so interior dark content (illustrations, ink) that never reaches the edge is
/// never touched. Before anything is masked, the candidate boundary must have a genuinely sharp
/// edge — local variance right at the boundary must exceed the paper's own baseline variance a
/// little further out — which passes a real desk (however low-contrast, like a laminate) while
/// rejecting a smooth illumination gradient or vignette that a brightness-only split could
/// otherwise mistake for one. A thin full-resolution band around the coarse boundary is then
/// re-tested pixel by pixel against the paper/desk brightness midpoint, so text sitting close to
/// the true paper edge survives while the boundary itself tracks the source raster precisely.
///
/// On a page where the desk covers a large fraction of the frame (no rectification, or a
/// rejected/disabled detection), the full extent found is masked (``DeskMaskResult/Mode/full``),
/// unless the "paper" region itself fails to form a solid, bounded block (texture that merely
/// resembles paper over most of the frame, such as bare wood grain with no document at all), in
/// which case nothing is masked. On a page where only small residual slivers remain (the usual case
/// after rectification), masking is restricted to a thin band near each edge and capped in total
/// area (``DeskMaskResult/Mode/residual``), so a mistaken classification can only leave desk visible
/// for Substep 5.2.2 to clean up — never silently erase page content.
public enum PaperRegionMasker {
    /// Tuning parameters.
    public struct Configuration: Sendable, Equatable, Codable {
        /// Maximum long side of the working raster in pixels (default `1024`).
        public var workingLongSide: Int
        /// Smallest accepted paper-minus-desk brightness gap; below this, masking is skipped
        /// (default `10.0`).
        public var minimumBoundaryContrast: Double
        /// Desk area fraction (of the working raster) above which masking is treated as
        /// ``DeskMaskResult/Mode/full`` rather than ``DeskMaskResult/Mode/residual`` (default `0.25`).
        public var residualModeAreaThreshold: Double
        /// In residual mode, how far from each edge masking may reach, as a fraction of that edge's
        /// dimension (default `0.08`).
        public var residualDepthFraction: Double
        /// In residual mode, the largest total masked area fraction allowed; masking is skipped
        /// entirely (and the page flagged) if the depth-restricted mask would still exceed this
        /// (default `0.15`).
        public var residualAreaCap: Double
        /// Minimum amount, in local-standard-deviation gray levels, by which local variance right at
        /// the candidate paper/desk boundary must exceed the paper's own baseline variance further
        /// away, to be trusted as a real edge. Guards against a smooth illumination gradient (a
        /// shadowed corner, a spine-shadow ramp) being mistaken for a desk: a gradient has no actual
        /// discontinuity, so variance right at an arbitrary threshold crossing along it is no higher
        /// than anywhere else (default `3.0`).
        public var minimumBoundarySharpnessStd: Double

        /// Creates a configuration; out-of-range values are clamped to safe bounds.
        public init(
            workingLongSide: Int = 1024,
            minimumBoundaryContrast: Double = 10.0,
            residualModeAreaThreshold: Double = 0.25,
            residualDepthFraction: Double = 0.08,
            residualAreaCap: Double = 0.15,
            minimumBoundarySharpnessStd: Double = 3.0
        ) {
            self.workingLongSide = min(4096, max(256, workingLongSide))
            self.minimumBoundaryContrast = min(128.0, max(1.0, minimumBoundaryContrast))
            self.residualModeAreaThreshold = min(0.9, max(0.05, residualModeAreaThreshold))
            self.residualDepthFraction = min(0.5, max(0.01, residualDepthFraction))
            self.residualAreaCap = min(0.9, max(0.01, residualAreaCap))
            self.minimumBoundarySharpnessStd = min(64.0, max(0.0, minimumBoundarySharpnessStd))
        }

        private enum CodingKeys: String, CodingKey {
            case workingLongSide, minimumBoundaryContrast, residualModeAreaThreshold
            case residualDepthFraction, residualAreaCap, minimumBoundarySharpnessStd
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Configuration()
            self.init(
                workingLongSide: try c.decodeIfPresent(Int.self, forKey: .workingLongSide) ?? d.workingLongSide,
                minimumBoundaryContrast: try c.decodeIfPresent(Double.self, forKey: .minimumBoundaryContrast) ?? d.minimumBoundaryContrast,
                residualModeAreaThreshold: try c.decodeIfPresent(Double.self, forKey: .residualModeAreaThreshold) ?? d.residualModeAreaThreshold,
                residualDepthFraction: try c.decodeIfPresent(Double.self, forKey: .residualDepthFraction) ?? d.residualDepthFraction,
                residualAreaCap: try c.decodeIfPresent(Double.self, forKey: .residualAreaCap) ?? d.residualAreaCap,
                minimumBoundarySharpnessStd: try c.decodeIfPresent(Double.self, forKey: .minimumBoundarySharpnessStd) ?? d.minimumBoundarySharpnessStd
            )
        }
    }

    private static let ringFullFrameThreshold = 0.8
    private static let fullFrameAreaFraction = 0.96
    private typealias K = QuadDetectionKernels

    /// Masks the desk/background of `page`, filling it with a paper-toned estimate.
    ///
    /// - Parameters:
    ///   - page: Source grayscale page (typically already perspective-rectified).
    ///   - configuration: Tuning parameters.
    /// - Returns: The (possibly unchanged) page and the masking telemetry.
    public static func mask(
        _ page: borrowing GrayscaleBuffer,
        configuration: Configuration = Configuration()
    ) -> (page: GrayscaleBuffer, result: DeskMaskResult) {
        let width = page.width
        let height = page.height
        let cfg = configuration
        guard width > 0, height > 0 else { return (page.copy(), .skipped(reason: "imageTooSmall")) }

        let factor = max(1, Int((Double(max(width, height)) / Double(cfg.workingLongSide)).rounded(.up)))
        let downsampled = page.pixels.withUnsafeBufferPointer { pixels in
            K.downsample(pixels, width: width, height: height, factor: factor)
        }
        let w = downsampled.width
        let h = downsampled.height
        let values = downsampled.values
        guard min(w, h) >= 8 else { return (page.copy(), .skipped(reason: "imageTooSmall")) }

        let relativeScale = Double(max(w, h)) / 1024.0
        let statRadius = max(2, Int((4.0 * relativeScale).rounded()))
        let stats = K.boxStatistics(values, width: w, height: h, radius: statRadius)
        var score = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { score[i] = stats.mean[i] - stats.std[i] }

        guard let otsu = K.otsu(score), otsu.highMean - otsu.lowMean >= cfg.minimumBoundaryContrast else {
            return (page.copy(), .skipped(reason: "insufficientContrast"))
        }

        // As in DocumentQuadDetector: a single Otsu split can group a light desk with dark text when
        // text forms its own class. Retry on the bright class and adopt it only if that exposes a
        // desk-like border.
        var paperClass = paperMask(score, threshold: otsu.threshold)
        var ring = ringPaperFraction(paperClass, width: w, height: h)
        if ring >= ringFullFrameThreshold,
           let upper = K.otsu(score.filter { $0 > Float(otsu.threshold) }),
           upper.highMean - upper.lowMean >= cfg.minimumBoundaryContrast {
            let candidate = paperMask(score, threshold: upper.threshold)
            let candidateRing = ringPaperFraction(candidate, width: w, height: h)
            if candidateRing < ringFullFrameThreshold {
                paperClass = candidate
                ring = candidateRing
            }
        }
        guard ring < ringFullFrameThreshold else {
            return (page.copy(), .skipped(reason: "fullFrame"))
        }

        let nonPaper = paperClass.map { $0 == 0 ? UInt8(1) : UInt8(0) }
        let deskRegion = borderConnectedRegion(nonPaper, width: w, height: h)
        guard deskRegion.contains(1) else { return (page.copy(), .skipped(reason: "noDesk")) }

        // A brightness-only split can separate a smooth illumination gradient (a shadowed corner, a
        // spine-shadow ramp on a page with no real desk at all) into two "classes" exactly as it
        // would a genuine desk, so brightness contrast alone cannot be trusted. What a gradient
        // never has, and a real desk edge always does, is sharpness: a physical paper edge is a
        // step, so local variance spikes right at the boundary even when the desk itself is smooth
        // (a low-contrast laminate), while a gradient's "boundary" is just an arbitrary threshold
        // crossing along a continuous ramp, where local variance stays the same as everywhere else
        // along it. This compares paper-side local variance right at the boundary (`nearPaperRing`)
        // against paper-side local variance one more `boundaryBandRadius` further out
        // (`farPaperRing`, the paper's own baseline, unaffected by the boundary) — restricted to
        // ``paperClass`` in both rings so a text-dense interior far from this boundary never factors
        // in, since text pixels are excluded from ``paperClass`` by construction.
        let boundaryBandRadius = max(2, statRadius)
        let nearDilated = K.squareMorphology(deskRegion, width: w, height: h, radius: boundaryBandRadius, isErosion: false)
        let farDilated = K.squareMorphology(deskRegion, width: w, height: h, radius: 2 * boundaryBandRadius, isErosion: false)
        var nearPaperRing = [UInt8](repeating: 0, count: w * h)
        var farPaperRing = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            if nearDilated[i] != 0, deskRegion[i] == 0, paperClass[i] != 0 { nearPaperRing[i] = 1 }
            if farDilated[i] != 0, nearDilated[i] == 0, paperClass[i] != 0 { farPaperRing[i] = 1 }
        }
        guard let nearStd = meanOrNil(stats.std, where: nearPaperRing, width: w, height: h),
              let farStd = meanOrNil(stats.std, where: farPaperRing, width: w, height: h),
              nearStd >= farStd + cfg.minimumBoundarySharpnessStd
        else {
            return (page.copy(), .skipped(reason: "noSharpBoundary"))
        }

        let deskAreaFraction = Double(deskRegion.reduce(0) { $0 + Int($1) }) / Double(w * h)
        let mode: DeskMaskResult.Mode = deskAreaFraction > cfg.residualModeAreaThreshold ? .full : .residual
        // A substantial "desk" region is only trusted when the "paper" class also forms a solid,
        // bounded block: a desk region covering nearly the whole frame, or a paper class whose
        // convex hull spans nearly the whole frame without the clean border ring just ruled out,
        // means no reliable paper island was found at all (a non-document photo — bare wood grain
        // texture-splits into two classes just like this — or a classification failure), not a
        // legitimate mostly-desk page. Masking almost everything would erase content instead of a
        // desk. This does not apply in residual mode, where the desk region is small by definition
        // and a hull near 1.0 is the expected, legitimate case (a rectified page with a small
        // residual border defect).
        if mode == .full {
            guard deskAreaFraction <= 0.95, convexHullAreaFraction(paperClass, width: w, height: h) < Self.fullFrameAreaFraction else {
                return (page.copy(), .skipped(reason: "noPaper"))
            }
        }

        var finalMask = deskRegion
        var flags: [String] = []
        if mode == .residual {
            let band = depthBandMask(width: w, height: h, fraction: cfg.residualDepthFraction)
            let restricted = zip(finalMask, band).map { $0 != 0 && $1 != 0 ? UInt8(1) : UInt8(0) }
            if restricted != finalMask { flags.append("capped:depth") }
            finalMask = restricted
            let coverage = Double(finalMask.reduce(0) { $0 + Int($1) }) / Double(w * h)
            if coverage > cfg.residualAreaCap {
                flags.append("capped:coverage")
                return (page.copy(), DeskMaskResult(mode: .skipped, maskedFraction: 0, flags: flags + ["skipped:coverageCapExceeded"]))
            }
        }
        guard finalMask.contains(1) else {
            return (page.copy(), DeskMaskResult(mode: .skipped, maskedFraction: 0, flags: flags + ["skipped:coverageCapExceeded"]))
        }

        let paperBrightness = meanBrightness(values, where: paperClass, width: w, height: h)
        let deskBrightness = meanBrightness(values, where: finalMask, width: w, height: h)
        let midpoint = (paperBrightness + deskBrightness) / 2.0

        // Full-resolution boundary refinement: shrink by one working pixel for safety, then regrow
        // through a thin band only where the full-resolution pixel is darker than the midpoint.
        let safeMaskWorking = K.squareMorphology(finalMask, width: w, height: h, radius: 1, isErosion: true)
        let dilatedWorking = K.squareMorphology(finalMask, width: w, height: h, radius: 1, isErosion: false)
        var bandWorking = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) { bandWorking[i] = (dilatedWorking[i] != 0 && safeMaskWorking[i] == 0) ? 1 : 0 }

        let fillWeights = finalMask.map { $0 != 0 ? Float(0) : Float(1) }
        let filledWorking = Array(BackgroundNormalizer.inpaintAndSmoothNormalized2D(
            values: ContiguousArray(values),
            weights: ContiguousArray(fillWeights),
            width: w,
            height: h,
            sigma: 1.5,
            fallbackValue: Float(paperBrightness)
        ))

        var outPixels = page.pixels
        var maskedCount = 0
        page.pixels.withUnsafeBufferPointer { src in
            outPixels.withUnsafeMutableBufferPointer { dst in
                for py in 0..<height {
                    let blockY = min(h - 1, py / factor)
                    for px in 0..<width {
                        let blockX = min(w - 1, px / factor)
                        let blockIndex = blockY * w + blockX
                        var isDesk = safeMaskWorking[blockIndex] != 0
                        if !isDesk, bandWorking[blockIndex] != 0 {
                            isDesk = Double(src[py * width + px]) < midpoint
                        }
                        guard isDesk else { continue }
                        maskedCount += 1
                        let gx = (Double(px) + 0.5) / Double(factor) - 0.5
                        let gy = (Double(py) + 0.5) / Double(factor) - 0.5
                        let fillValue = sampleGrid(filledWorking, width: w, height: h, x: gx, y: gy)
                        dst[py * width + px] = UInt8(min(255.0, max(0.0, fillValue.rounded())))
                    }
                }
            }
        }

        let result = DeskMaskResult(
            mode: mode,
            maskedFraction: Double(maskedCount) / Double(width * height),
            maskedDepthBySide: sideDepthFractions(finalMask, width: w, height: h),
            paperBrightness: paperBrightness,
            deskBrightness: deskBrightness,
            flags: flags
        )
        return (GrayscaleBuffer(width: width, height: height, dpi: page.dpi, pixels: outPixels), result)
    }

    // MARK: - Helpers

    private static func paperMask(_ score: [Float], threshold: Int) -> [UInt8] {
        let t = Float(threshold)
        return score.map { $0 > t ? UInt8(1) : UInt8(0) }
    }

    /// Fraction of paper-class pixels in the ring between 1 % and 3 % inset from the frame border.
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

    /// Convex hull area of `mask`, as a fraction of `width × height` (same row-extent construction
    /// `DocumentQuadDetector` uses to test whether a region fills the frame).
    private static func convexHullAreaFraction(_ mask: [UInt8], width w: Int, height h: Int) -> Double {
        var hullInput: [Point2D] = []
        hullInput.reserveCapacity(4 * h)
        for y in 0..<h {
            var first = -1
            var last = -1
            for x in 0..<w where mask[y * w + x] != 0 {
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
        guard !hullInput.isEmpty else { return 0 }
        let hull = K.convexHull(hullInput)
        return K.signedArea(hull) / Double(w * h)
    }

    /// Flood fill of `nonPaper == 1` pixels starting from the image border.
    private static func borderConnectedRegion(_ nonPaper: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var region = [UInt8](repeating: 0, count: w * h)
        var stack: [Int] = []
        func seed(_ i: Int) {
            if nonPaper[i] != 0 && region[i] == 0 {
                region[i] = 1
                stack.append(i)
            }
        }
        for x in 0..<w {
            seed(x)
            seed((h - 1) * w + x)
        }
        for y in 0..<h {
            seed(y * w)
            seed(y * w + w - 1)
        }
        while let i = stack.popLast() {
            let x = i % w
            let y = i / w
            if x > 0 { seed(i - 1) }
            if x < w - 1 { seed(i + 1) }
            if y > 0 { seed(i - w) }
            if y < h - 1 { seed(i + w) }
        }
        return region
    }

    /// `1` within `fraction` of any edge (top/bottom relative to height, left/right to width).
    private static func depthBandMask(width w: Int, height h: Int, fraction: Double) -> [UInt8] {
        var mask = [UInt8](repeating: 0, count: w * h)
        let vertical = max(1, Int((fraction * Double(h)).rounded(.up)))
        let horizontal = max(1, Int((fraction * Double(w)).rounded(.up)))
        for y in 0..<h {
            let inVerticalBand = y < vertical || y >= h - vertical
            for x in 0..<w {
                if inVerticalBand || x < horizontal || x >= w - horizontal {
                    mask[y * w + x] = 1
                }
            }
        }
        return mask
    }

    private static func meanBrightness(_ values: [Float], where mask: [UInt8], width w: Int, height h: Int) -> Double {
        var sum = 0.0
        var count = 0
        for i in 0..<(w * h) where mask[i] != 0 {
            sum += Double(values[i])
            count += 1
        }
        return count > 0 ? sum / Double(count) : 200.0
    }

    /// Mean of `values` over `mask == 1`, or `nil` when the mask selects no pixels.
    private static func meanOrNil(_ values: [Float], where mask: [UInt8], width w: Int, height h: Int) -> Double? {
        var sum = 0.0
        var count = 0
        for i in 0..<(w * h) where mask[i] != 0 {
            sum += Double(values[i])
            count += 1
        }
        return count > 0 ? sum / Double(count) : nil
    }

    /// Maximum inward reach of `mask` from each side, as a fraction of that side's dimension.
    private static func sideDepthFractions(_ mask: [UInt8], width w: Int, height h: Int) -> DocumentQuadDetection.SideMetrics {
        var top = 0, bottom = 0, left = 0, right = 0
        for x in 0..<w {
            var y = 0
            while y < h && mask[y * w + x] != 0 { y += 1 }
            top = max(top, y)
            var y2 = h - 1
            var count = 0
            while y2 >= 0 && mask[y2 * w + x] != 0 { count += 1; y2 -= 1 }
            bottom = max(bottom, count)
        }
        for y in 0..<h {
            var x = 0
            while x < w && mask[y * w + x] != 0 { x += 1 }
            left = max(left, x)
            var x2 = w - 1
            var count = 0
            while x2 >= 0 && mask[y * w + x2] != 0 { count += 1; x2 -= 1 }
            right = max(right, count)
        }
        return DocumentQuadDetection.SideMetrics(
            top: Double(top) / Double(h),
            right: Double(right) / Double(w),
            bottom: Double(bottom) / Double(h),
            left: Double(left) / Double(w)
        )
    }

    /// Bilinear sample of a `w × h` grid at continuous grid coordinates, clamped to the frame.
    private static func sampleGrid(_ grid: [Float], width w: Int, height h: Int, x: Double, y: Double) -> Double {
        let fx = min(max(x, 0.0), Double(w - 1))
        let fy = min(max(y, 0.0), Double(h - 1))
        let x0 = Int(fx)
        let y0 = Int(fy)
        let x1 = min(x0 + 1, w - 1)
        let y1 = min(y0 + 1, h - 1)
        let ax = fx - Double(x0)
        let ay = fy - Double(y0)
        let g00 = Double(grid[y0 * w + x0])
        let g10 = Double(grid[y0 * w + x1])
        let g01 = Double(grid[y1 * w + x0])
        let g11 = Double(grid[y1 * w + x1])
        return (g00 * (1 - ax) + g10 * ax) * (1 - ay) + (g01 * (1 - ax) + g11 * ax) * ay
    }
}

private extension GrayscaleBuffer {
    /// An explicit (non-mutating-looking) copy, for returning a `borrowing` parameter unchanged.
    func copy() -> GrayscaleBuffer {
        GrayscaleBuffer(width: width, height: height, dpi: dpi, pixels: pixels)
    }
}
