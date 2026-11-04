import ScanTailorContracts

/// Finds the gutter of a camera photo of an open book from the shape of the paper outline.
///
/// On a photo the two pages bend down into the spine, so the paper's top edge dips and its bottom edge rises
/// where they meet: the outline has a V-shaped notch at the fold. Column gaps inside a page have no notch.
/// The candidates are the text-free vertical gaps of the central band; the gap under the strongest notch is
/// the gutter, cut at the notch vertex when that falls inside the gap and at the gap's middle otherwise. When
/// the text runs right into the fold there is no gap, and a strong notch decides on its own.
///
/// Run it on the photo *before* desk masking, which paints the outline away. It returns `nil` when neither
/// signal is clear, so the caller can fall back to ``PageSplitEstimator/estimateSplit(in:mode:configuration:)``;
/// an exact cut from the adjustments file (`splitX`) overrides both.
public enum CameraGutterLocator {
    /// A located gutter.
    public struct Estimate: Sendable, Equatable {
        /// Which signal placed the cut.
        public enum Evidence: String, Sendable, Equatable, Codable {
            /// A text-free gap under a notch in the paper outline.
            case gapAndNotch
            /// The only text-free gap of the central band; the outline notch was weak or hidden.
            case singleGap
            /// A strong outline notch where the text runs into the fold (no text-free gap).
            case notchOnly
        }

        /// Cut position in full-resolution pixels.
        public var centerX: Double
        /// Cut position as a fraction of the photo width.
        public var normalizedCenterX: Double
        /// Which signal placed the cut.
        public var evidence: Evidence
        /// Depth of the outline notch at the cut, in percent of the photo height (top and bottom, two scales).
        public var notchStrength: Double
    }

    /// Tuning of ``locate(in:configuration:)``; the defaults were fitted on phone photos of open books.
    public struct Configuration: Sendable, Equatable {
        /// Horizontal band, as fractions of the width, that may hold the gutter.
        public var searchRange: ClosedRange<Double>
        /// Columns whose ink is at most this fraction of a typical text column count as text-free.
        public var gapInkRatio: Double
        /// Smallest notch strength (percent of height) that makes a gap the gutter.
        public var minGapNotch: Double
        /// Smallest notch strength, after the ink penalty, that places the gutter without a gap.
        public var minNotchOnlyScore: Double

        public init(
            searchRange: ClosedRange<Double> = 0.30...0.70,
            gapInkRatio: Double = 0.25,
            minGapNotch: Double = 1.2,
            minNotchOnlyScore: Double = 2.5
        ) {
            self.searchRange = searchRange
            self.gapInkRatio = gapInkRatio
            self.minGapNotch = minGapNotch
            self.minNotchOnlyScore = minNotchOnlyScore
        }
    }

    /// The paper outline of a camera photo, traced at a working resolution of at most 1200 px.
    ///
    /// From mid-height, each column is walked up and down until the brightness stays below 70 % of the paper
    /// just passed (a running reference copes with shading across the page) for a fiftieth of the height. The
    /// reference never drops below 75 % of the paper brightness in the middle of the photo, so a walk that starts
    /// on a uniform dark desk ends at once instead of adopting the desk as its paper. Over the paper the walk ends
    /// at its top and bottom edges; over the desk it ends almost at once.
    public struct Outline: Sendable {
        /// Size of the photo the outline was traced on.
        public let photoSize: Size2I
        /// Working raster size.
        public let width: Int
        public let height: Int
        /// Photo pixels per working pixel.
        public let scale: Double
        /// Paper top and bottom edge per working column (median of 7 columns), in working rows.
        public let top: [Double]
        public let bottom: [Double]
        /// Paper brightness: the 85th percentile of the middle of the photo.
        public let paperBrightness: Double
        let gray: [Double]
        let background: [Double]

        /// Traces the outline of `photo`; `nil` when the photo is too small to analyse.
        public init?(photo: borrowing GrayscaleBuffer) {
            var working = copy photo
            var scale = 1.0
            while max(working.width, working.height) > 1200 && working.width >= 64 && working.height >= 64 {
                working = SkewEstimator.downsampleGrayscale2x(working)
                scale *= 2.0
            }
            let w = working.width
            let h = working.height
            guard w >= 120, h >= 60 else { return nil }

            var gray = [Double](repeating: 0, count: w * h)
            working.pixels.withUnsafeBufferPointer { px in
                for y in 0..<h {
                    let row = y * working.rowBytes
                    for x in 0..<w { gray[y * w + x] = Double(px[row + x]) }
                }
            }
            let smooth = CameraGutterLocator.boxMean(CameraGutterLocator.boxMean(gray, w, h, rx: 2, ry: 2), w, h, rx: 3, ry: 0)

            var central: [Double] = []
            for y in stride(from: h * 3 / 10, to: h * 7 / 10, by: 2) {
                for x in stride(from: w * 3 / 10, to: w * 7 / 10, by: 2) { central.append(smooth[y * w + x]) }
            }
            central.sort()
            let paperBrightness = central.isEmpty ? 0 : central[central.count * 85 / 100]
            let referenceFloor = 0.75 * paperBrightness

            let run = max(4, h / 50)
            let window = max(8, h / 10)
            func edge(_ x: Int, _ step: Int) -> Int {
                var ring = [Double](repeating: 0, count: window)
                var filled = 0, head = 0, dark = 0
                var y = h / 2
                while y >= 0 && y < h {
                    let value = smooth[y * w + x]
                    var reference = max(value, referenceFloor)
                    for i in 0..<filled where ring[i] > reference { reference = ring[i] }
                    if value < reference * 0.70 {
                        dark += 1
                        if dark >= run { return y - step * run }
                    } else {
                        dark = 0
                        ring[head] = value
                        head = (head + 1) % window
                        filled = min(filled + 1, window)
                    }
                    y += step
                }
                return step < 0 ? 0 : h - 1
            }
            var rawTop = [Double](repeating: 0, count: w)
            var rawBottom = [Double](repeating: 0, count: w)
            for x in 0..<w {
                rawTop[x] = Double(edge(x, -1))
                rawBottom[x] = Double(edge(x, 1))
            }
            self.photoSize = Size2I(width: photo.width, height: photo.height)
            self.width = w
            self.height = h
            self.scale = scale
            self.top = CameraGutterLocator.medianFiltered(rawTop, radius: 3)
            self.bottom = CameraGutterLocator.medianFiltered(rawBottom, radius: 3)
            self.paperBrightness = paperBrightness
            self.gray = gray
            self.background = CameraGutterLocator.boxMean(gray, w, h, rx: 8, ry: 8)
        }
    }

    /// Locates the gutter of `photo`, or returns `nil` when the outline and the gaps do not agree on one.
    ///
    /// - Parameters:
    ///   - photo: The unmasked camera photo of a two-page spread.
    ///   - configuration: Tuning; see ``Configuration``.
    /// - Returns: The cut position and the evidence for it, or `nil`.
    public static func locate(in photo: borrowing GrayscaleBuffer, configuration: Configuration = Configuration()) -> Estimate? {
        Outline(photo: photo).flatMap { locate(in: $0, configuration: configuration) }
    }

    /// Locates the gutter from an already traced outline; see ``locate(in:configuration:)-(GrayscaleBuffer,_)``.
    public static func locate(in outline: Outline, configuration: Configuration = Configuration()) -> Estimate? {
        let w = outline.width
        let h = outline.height
        let scale = outline.scale
        let photoWidth = outline.photoSize.width
        let gray = outline.gray
        let background = outline.background
        let top = outline.top
        let bottom = outline.bottom

        // 1. Ink per column between the outline edges: a pixel is ink when darker than 80 % of its surroundings.
        let lo = max(1, Int(Double(w) * configuration.searchRange.lowerBound))
        let hi = min(w - 2, Int(Double(w) * configuration.searchRange.upperBound))
        guard lo < hi else { return nil }
        let halfCorridor = max(1, w / 400)
        let inset = h / 25
        var columnInk = [Double](repeating: 1, count: w)
        for x in max(lo, halfCorridor)...min(hi, w - 1 - halfCorridor) {
            let y0 = Int(top[x]) + inset
            let y1 = Int(bottom[x]) - inset
            guard y1 > y0 else { continue }
            var inked = 0
            for y in y0..<y1 {
                for dx in -halfCorridor...halfCorridor where gray[y * w + x + dx] < 0.8 * background[y * w + x + dx] {
                    inked += 1
                    break
                }
            }
            columnInk[x] = Double(inked) / Double(y1 - y0)
        }
        let typicalInk = median(Array(columnInk[lo...hi]))
        guard typicalInk > 0.02 else { return nil }   // no text to speak of
        var ratios = [Double](repeating: 9, count: w)
        for x in lo...hi { ratios[x] = columnInk[x] / typicalInk }
        let inkRatio = ratios

        // 2. Notch strength: the top edge must sit lower than on *both* sides (steps where a bright object
        //    meets the page do not count), the bottom edge higher; two scales, in percent of the height.
        let k1 = max(2, w / 60), k2 = max(4, w / 30)
        let cap = Double(h) * 0.04
        var notchProfile = [Double](repeating: -.greatestFiniteMagnitude, count: w)
        for x in max(k2, lo - w / 100)...min(w - 1 - k2, hi + w / 100) {
            var score = 0.0
            for k in [k1, k2] {
                let t = min(cap, min(top[x] - top[x - k], top[x] - top[x + k]))
                let b = min(cap, min(bottom[x - k] - bottom[x], bottom[x + k] - bottom[x]))
                score += max(t, -cap) + max(b, -cap)
            }
            notchProfile[x] = score / Double(h) * 100
        }
        let notch = notchProfile

        // 3. Text-free gaps, each with the strongest notch in or near it.
        struct Gap { var lower: Int; var upper: Int; var vertex: Int; var notch: Double }
        var gaps: [Gap] = []
        let pad = max(1, w / 100)
        var x = lo
        while x <= hi {
            guard inkRatio[x] <= configuration.gapInkRatio else { x += 1; continue }
            var end = x
            while end + 1 <= hi && inkRatio[end + 1] <= configuration.gapInkRatio { end += 1 }
            if end - x + 1 >= max(2, w / 200) {
                let range = max(lo, x - pad)...min(hi, end + pad)
                let vertex = range.max { notch[$0] < notch[$1] } ?? (x + end) / 2
                gaps.append(Gap(lower: x, upper: end, vertex: vertex, notch: notch[vertex]))
            }
            x = end + 1
        }

        func estimate(_ xw: Int, _ evidence: Estimate.Evidence) -> Estimate {
            let center = (Double(xw) + 0.5) * scale
            return Estimate(
                centerX: center,
                normalizedCenterX: min(max(center / Double(photoWidth), 0), 1),
                evidence: evidence,
                notchStrength: notch[xw]
            )
        }
        func cut(in gap: Gap) -> Int { (gap.lower...gap.upper).contains(gap.vertex) ? gap.vertex : (gap.lower + gap.upper) / 2 }

        if let best = gaps.max(by: { $0.notch < $1.notch }), best.notch >= configuration.minGapNotch {
            return estimate(cut(in: best), .gapAndNotch)
        }
        if gaps.count == 1, let only = gaps.first, only.upper - only.lower + 1 >= max(2, w / 100),
           (0.4...0.6).contains(Double(only.lower + only.upper) / 2 / Double(w)) {
            return estimate(cut(in: only), .singleGap)
        }
        func penalized(_ x: Int) -> Double { notch[x] - 1.5 * min(1.5, inkRatio[x]) }
        if let vertex = (lo...hi).max(by: { penalized($0) < penalized($1) }), penalized(vertex) >= configuration.minNotchOnlyScore {
            return estimate(vertex, .notchOnly)
        }
        return nil
    }

    /// Mean over a `(2rx+1)×(2ry+1)` window, shrunk at the borders (summed-area table).
    static func boxMean(_ source: [Double], _ w: Int, _ h: Int, rx: Int, ry: Int) -> [Double] {
        var table = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0.0
            for x in 0..<w {
                rowSum += source[y * w + x]
                table[(y + 1) * (w + 1) + x + 1] = table[y * (w + 1) + x + 1] + rowSum
            }
        }
        var out = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - ry), y1 = min(h, y + ry + 1)
            for x in 0..<w {
                let x0 = max(0, x - rx), x1 = min(w, x + rx + 1)
                let sum = table[y1 * (w + 1) + x1] - table[y0 * (w + 1) + x1] - table[y1 * (w + 1) + x0] + table[y0 * (w + 1) + x0]
                out[y * w + x] = sum / Double((x1 - x0) * (y1 - y0))
            }
        }
        return out
    }

    static func medianFiltered(_ values: [Double], radius: Int) -> [Double] {
        values.indices.map { i in median(Array(values[max(0, i - radius)...min(values.count - 1, i + radius)])) }
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
