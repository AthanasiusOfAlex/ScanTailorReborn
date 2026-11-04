import ScanTailorContracts

/// Telemetry of a ``CameraPaperMasker`` pass.
public struct CameraPaperMaskResult: Sendable, Equatable, Codable {
    /// Fraction of the photo replaced with paper tone, in `[0, 1]`.
    public var maskedFraction: Double
    /// Left and right edges of the paper as fractions of the photo width.
    public var paperLeft: Double
    public var paperRight: Double

    public init(maskedFraction: Double, paperLeft: Double, paperRight: Double) {
        self.maskedFraction = maskedFraction
        self.paperLeft = paperLeft
        self.paperRight = paperRight
    }
}

/// Crops a camera photo of an open book to its paper: everything outside the outline traced by
/// ``CameraGutterLocator/Outline`` (the desk, mugs, a keyboard, the book's cover) is filled with an inpainted
/// paper tone, so later stages see only the pages.
///
/// Paper columns are those whose traced paper height is at least 80 % of the typical height across the middle
/// of the photo; over the desk the trace ends almost at once. Within them, rows above the top edge and below the
/// bottom edge are filled. A trace that stops early on a dark mark inside the page makes the paper look smaller
/// in a few columns, so an edge lying more than a fortieth of the height inside the median edge of the columns
/// within a fortieth of the width is replaced by that median; every other column keeps its traced edge, so the
/// mask follows a curled rim and the fold notch without leaving wedges of desk behind.
public enum CameraPaperMasker {
    /// Masks `page` (same size as the photo `outline` was traced on), or returns `nil` when the outline is not
    /// trustworthy or leaves nothing to mask.
    public static func mask(
        _ page: borrowing GrayscaleBuffer,
        outline: CameraGutterLocator.Outline
    ) -> (page: GrayscaleBuffer, result: CameraPaperMaskResult)? {
        let w = outline.width
        let h = outline.height
        guard page.width == outline.photoSize.width, page.height == outline.photoSize.height else { return nil }

        // 1. Paper columns: the run of tall columns around the middle, bridging short interruptions.
        let heights = (0..<w).map { outline.bottom[$0] - outline.top[$0] }
        let typical = CameraGutterLocator.median(Array(heights[(w * 3 / 10)...(w * 7 / 10)]))
        guard typical >= Double(h) * 0.3 else { return nil }
        let isPaper = heights.map { $0 >= typical * 0.8 }
        let bridge = max(2, w / 50)
        guard let seed = (0..<w).min(by: { (isPaper[$0] ? 0 : 1, abs($0 - w / 2)) < (isPaper[$1] ? 0 : 1, abs($1 - w / 2)) }),
              isPaper[seed] else { return nil }
        func extend(_ step: Int) -> Int {
            var last = seed
            var x = seed + step
            while x >= 0 && x < w && abs(x - last) <= bridge + 1 {
                if isPaper[x] { last = x }
                x += step
            }
            return last
        }
        let left = extend(-1)
        let right = extend(1)
        guard right - left >= w / 4 else { return nil }

        // 2. Early stops inside the page are repaired from the neighbouring columns.
        let reach = max(2, w / 40)
        let tolerance = Double(max(2, h / 40))
        var top = [Double](repeating: 0, count: w)
        var bottom = [Double](repeating: Double(h), count: w)
        for x in left...right {
            let lo = max(left, x - reach), hi = min(right, x + reach)
            let medianTop = CameraGutterLocator.median(Array(outline.top[lo...hi]))
            let medianBottom = CameraGutterLocator.median(Array(outline.bottom[lo...hi]))
            top[x] = outline.top[x] > medianTop + tolerance ? medianTop : outline.top[x]
            bottom[x] = (outline.bottom[x] < medianBottom - tolerance ? medianBottom : outline.bottom[x]) + 1
        }
        var masked = [UInt8](repeating: 0, count: w * h)
        var maskedCount = 0
        for y in 0..<h {
            for x in 0..<w where x < left || x > right || Double(y) < top[x] || Double(y) >= bottom[x] {
                masked[y * w + x] = 1
                maskedCount += 1
            }
        }
        guard maskedCount * 100 >= w * h else { return nil }

        // 3. Inpaint the masked area from the bare paper next to it (text and any desk left beside the widened
        //    edges do not count), then write it back at full resolution.
        let paperFloor = 0.75 * outline.paperBrightness
        let values = ContiguousArray(outline.gray.map { Float($0) })
        let weights = ContiguousArray(zip(masked, outline.gray).map { $0 == 0 && $1 >= paperFloor ? Float(1) : Float(0) })
        let paperTone = Float(outline.paperBrightness)
        let filled = BackgroundNormalizer.inpaintAndSmoothNormalized2D(
            values: values, weights: weights, width: w, height: h, sigma: 1.5, fallbackValue: paperTone
        )

        let width = page.width
        let height = page.height
        let factor = max(1, Int(outline.scale.rounded()))
        var pixels = page.pixels
        var written = 0
        pixels.withUnsafeMutableBufferPointer { dst in
            for py in 0..<height {
                let by = min(h - 1, py / factor)
                let gy = min(Double(h - 1), max(0, (Double(py) + 0.5) / Double(factor) - 0.5))
                let y0 = Int(gy), y1 = min(h - 1, y0 + 1)
                let fy = Float(gy - Double(y0))
                for px in 0..<width {
                    let bx = min(w - 1, px / factor)
                    guard masked[by * w + bx] != 0 else { continue }
                    let gx = min(Double(w - 1), max(0, (Double(px) + 0.5) / Double(factor) - 0.5))
                    let x0 = Int(gx), x1 = min(w - 1, x0 + 1)
                    let fx = Float(gx - Double(x0))
                    let upper = filled[y0 * w + x0] * (1 - fx) + filled[y0 * w + x1] * fx
                    let lower = filled[y1 * w + x0] * (1 - fx) + filled[y1 * w + x1] * fx
                    let value = upper * (1 - fy) + lower * fy
                    dst[py * page.rowBytes + px] = UInt8(min(255, max(0, value.rounded())))
                    written += 1
                }
            }
        }
        let result = CameraPaperMaskResult(
            maskedFraction: Double(written) / Double(width * height),
            paperLeft: Double(left) / Double(w),
            paperRight: Double(right + 1) / Double(w)
        )
        return (GrayscaleBuffer(width: width, height: height, dpi: page.dpi, pixels: pixels), result)
    }
}
