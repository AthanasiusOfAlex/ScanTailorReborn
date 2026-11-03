import Foundation
import ScanTailorContracts

/// Internal raster, edge, and geometry primitives backing ``DocumentQuadDetector``.
///
/// Every routine is a pure function over value-typed buffers, so the detector stays `Sendable`
/// and deterministic. Coordinates are continuous pixel coordinates: pixel `(i, j)` covers
/// `[i, i + 1) × [j, j + 1)` and its center is `(i + 0.5, j + 0.5)`.
enum QuadDetectionKernels {

    // MARK: - Deterministic Random Numbers

    /// SplitMix64 generator used to make RANSAC sampling reproducible across runs and machines.
    struct SplitMix64: Sendable {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        mutating func nextIndex(below upperBound: Int) -> Int {
            Int(next() % UInt64(upperBound))
        }
    }

    // MARK: - Vector Helpers

    @inline(__always)
    static func dot(_ a: Point2D, _ b: Point2D) -> Double {
        a.x * b.x + a.y * b.y
    }

    @inline(__always)
    static func cross(_ a: Point2D, _ b: Point2D) -> Double {
        a.x * b.y - a.y * b.x
    }

    @inline(__always)
    static func length(_ a: Point2D) -> Double {
        (a.x * a.x + a.y * a.y).squareRoot()
    }

    /// Signed shoelace area. Positive for the screen-clockwise order TL → TR → BR → BL (y down).
    static func signedArea(_ polygon: [Point2D]) -> Double {
        guard polygon.count >= 3 else { return 0.0 }
        var sum = 0.0
        for i in 0..<polygon.count {
            sum += cross(polygon[i], polygon[(i + 1) % polygon.count])
        }
        return 0.5 * sum
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : 0.5 * (sorted[mid - 1] + sorted[mid])
    }

    // MARK: - Lines

    /// An oriented infinite line with a unit direction.
    ///
    /// For a side traversed screen-clockwise, ``inwardNormal`` points into the quadrangle.
    struct Line: Sendable, Equatable {
        var point: Point2D
        var direction: Point2D

        var inwardNormal: Point2D {
            Point2D(x: -direction.y, y: direction.x)
        }

        func signedDistance(_ p: Point2D) -> Double {
            QuadDetectionKernels.dot(p - point, inwardNormal)
        }

        func projection(of p: Point2D) -> Point2D {
            point + direction * QuadDetectionKernels.dot(p - point, direction)
        }

        func intersection(with other: Line) -> Point2D? {
            let denominator = QuadDetectionKernels.cross(direction, other.direction)
            guard abs(denominator) > 1e-9 else { return nil }
            let s = QuadDetectionKernels.cross(other.point - point, other.direction) / denominator
            return point + direction * s
        }

        /// Unsigned angle in radians between the two line directions, in `[0, π/2]`.
        func angle(to other: Line) -> Double {
            let c = abs(QuadDetectionKernels.dot(direction, other.direction))
            return acos(min(1.0, c))
        }

        func scaled(by factor: Double) -> Line {
            Line(point: point * factor, direction: direction)
        }
    }

    /// Total-least-squares line fit, oriented to agree with `reference`.
    static func fitLine(_ points: [Point2D], orientedLike reference: Point2D) -> Line? {
        guard points.count >= 2 else { return nil }
        var mx = 0.0
        var my = 0.0
        for p in points {
            mx += p.x
            my += p.y
        }
        let n = Double(points.count)
        mx /= n
        my /= n
        var sxx = 0.0
        var syy = 0.0
        var sxy = 0.0
        for p in points {
            let dx = p.x - mx
            let dy = p.y - my
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        guard sxx + syy > 1e-9 else { return nil }
        let theta = 0.5 * atan2(2.0 * sxy, sxx - syy)
        var u = Point2D(x: cos(theta), y: sin(theta))
        if dot(u, reference) < 0 { u = -u }
        return Line(point: Point2D(x: mx, y: my), direction: u)
    }

    /// Deterministic RANSAC line fit followed by total-least-squares refinement on the inliers.
    ///
    /// - Parameters:
    ///   - points: Candidate edge positions.
    ///   - reference: Prior line; hypotheses deviating more than `maxAngle` from it are rejected.
    ///   - maxAngle: Maximum angular deviation from `reference`, in radians.
    ///   - tolerance: Inlier distance in pixels.
    ///   - iterations: Number of two-point hypotheses.
    ///   - seed: RANSAC seed.
    /// - Returns: The refined line and its inliers, or `nil` when fewer than two points exist.
    static func ransacLine(
        _ points: [Point2D],
        reference: Line,
        maxAngle: Double,
        tolerance: Double,
        iterations: Int,
        seed: UInt64
    ) -> (line: Line, inliers: [Point2D])? {
        guard points.count >= 2 else { return nil }
        var rng = SplitMix64(seed: seed)
        let cosMax = cos(maxAngle)
        var bestCount = 0
        var bestCost = Double.infinity
        var bestLine: Line?

        for _ in 0..<iterations {
            let i = rng.nextIndex(below: points.count)
            let j = rng.nextIndex(below: points.count)
            guard i != j else { continue }
            let delta = points[j] - points[i]
            let len = length(delta)
            guard len >= 4.0 else { continue }
            var u = delta / len
            if dot(u, reference.direction) < 0 { u = -u }
            guard dot(u, reference.direction) >= cosMax else { continue }
            let candidate = Line(point: points[i], direction: u)
            var count = 0
            var cost = 0.0
            for p in points {
                let r = abs(candidate.signedDistance(p))
                if r <= tolerance {
                    count += 1
                    cost += r
                }
            }
            if count > bestCount || (count == bestCount && cost < bestCost) {
                bestCount = count
                bestCost = cost
                bestLine = candidate
            }
        }

        guard var current = bestLine else { return nil }
        var inliers = points.filter { abs(current.signedDistance($0)) <= tolerance }
        for _ in 0..<3 {
            guard inliers.count >= 2, let refit = fitLine(inliers, orientedLike: reference.direction) else { break }
            current = refit
            inliers = points.filter { abs(current.signedDistance($0)) <= tolerance }
        }
        return (current, inliers)
    }

    /// Fraction of `binSize`-pixel bins along the chord `start → end` (restricted to `tRange`)
    /// that contain at least one inlier.
    static func chordCoverage(
        of inliers: [Point2D],
        chordStart start: Point2D,
        chordEnd end: Point2D,
        tRange: ClosedRange<Double>,
        binSize: Double
    ) -> Double {
        let chord = end - start
        let len = length(chord)
        guard len > 1.0 else { return 0.0 }
        let u = chord / len
        let span = len * (tRange.upperBound - tRange.lowerBound)
        let binCount = max(1, Int(span / binSize))
        var occupied = [Bool](repeating: false, count: binCount)
        for p in inliers {
            let t = dot(p - start, u) / len
            guard tRange.contains(t) else { continue }
            let bin = min(binCount - 1, Int((t - tRange.lowerBound) / (tRange.upperBound - tRange.lowerBound) * Double(binCount)))
            occupied[bin] = true
        }
        return Double(occupied.lazy.filter { $0 }.count) / Double(binCount)
    }

    // MARK: - Raster Primitives

    /// Area-averages the source by an integer factor. Trailing rows/columns that do not fill a
    /// whole block are dropped, so working coordinate `x` maps exactly to source `x · factor`.
    static func downsample(
        _ pixels: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        factor: Int
    ) -> (width: Int, height: Int, values: [Float]) {
        let w = max(1, width / factor)
        let h = max(1, height / factor)
        var out = [Float](repeating: 0, count: w * h)
        let inverse = 1.0 / Float(factor * factor)
        var rowSums = [Int](repeating: 0, count: w)
        out.withUnsafeMutableBufferPointer { dstBuffer in
            rowSums.withUnsafeMutableBufferPointer { sumBuffer in
                let dst = dstBuffer.baseAddress!
                let sums = sumBuffer.baseAddress!
                let src = pixels.baseAddress!
                var y = 0
                while y < h {
                    sums.update(repeating: 0, count: w)
                    var dy = 0
                    while dy < factor {
                        let row = src + (y * factor + dy) * width
                        var x = 0
                        while x < w {
                            let block = row + x * factor
                            var acc = 0
                            var dx = 0
                            while dx < factor {
                                acc += Int(block[dx])
                                dx += 1
                            }
                            sums[x] += acc
                            x += 1
                        }
                        dy += 1
                    }
                    let outRow = dst + y * w
                    var x = 0
                    while x < w {
                        outRow[x] = Float(sums[x]) * inverse
                        x += 1
                    }
                    y += 1
                }
            }
        }
        return (w, h, out)
    }

    /// Local mean and standard deviation over a `(2r + 1)²` window (clipped at the borders).
    static func boxStatistics(
        _ values: [Float],
        width w: Int,
        height h: Int,
        radius r: Int
    ) -> (mean: [Float], std: [Float]) {
        let stride = w + 1
        var sum = [Double](repeating: 0, count: stride * (h + 1))
        var sumSq = [Double](repeating: 0, count: stride * (h + 1))
        values.withUnsafeBufferPointer { src in
            sum.withUnsafeMutableBufferPointer { s in
                sumSq.withUnsafeMutableBufferPointer { q in
                    for y in 0..<h {
                        var rowSum = 0.0
                        var rowSq = 0.0
                        for x in 0..<w {
                            let v = Double(src[y * w + x])
                            rowSum += v
                            rowSq += v * v
                            s[(y + 1) * stride + x + 1] = s[y * stride + x + 1] + rowSum
                            q[(y + 1) * stride + x + 1] = q[y * stride + x + 1] + rowSq
                        }
                    }
                }
            }
        }
        var mean = [Float](repeating: 0, count: w * h)
        var std = [Float](repeating: 0, count: w * h)
        sum.withUnsafeBufferPointer { s in
            sumSq.withUnsafeBufferPointer { q in
                mean.withUnsafeMutableBufferPointer { m in
                    std.withUnsafeMutableBufferPointer { sd in
                        for y in 0..<h {
                            let y0 = max(0, y - r)
                            let y1 = min(h, y + r + 1)
                            for x in 0..<w {
                                let x0 = max(0, x - r)
                                let x1 = min(w, x + r + 1)
                                let area = Double((y1 - y0) * (x1 - x0))
                                let total = s[y1 * stride + x1] - s[y0 * stride + x1] - s[y1 * stride + x0] + s[y0 * stride + x0]
                                let totalSq = q[y1 * stride + x1] - q[y0 * stride + x1] - q[y1 * stride + x0] + q[y0 * stride + x0]
                                let mu = total / area
                                let variance = max(0.0, totalSq / area - mu * mu)
                                m[y * w + x] = Float(mu)
                                sd[y * w + x] = Float(variance.squareRoot())
                            }
                        }
                    }
                }
            }
        }
        return (mean, std)
    }

    /// Separable Gaussian blur with clamp-to-edge borders.
    ///
    /// The horizontal pass convolves a replicate-padded copy of each row; the vertical pass
    /// accumulates whole clamped rows, so neither inner loop needs per-tap bounds handling.
    static func gaussianBlur(_ values: [Float], width w: Int, height h: Int, sigma: Double) -> [Float] {
        let radius = max(1, Int((3.0 * sigma).rounded(.up)))
        let taps = 2 * radius + 1
        var kernel = [Float](repeating: 0, count: taps)
        var total: Float = 0
        for k in 0..<taps {
            let offset = Double(k - radius)
            let v = Float(exp(-offset * offset / (2.0 * sigma * sigma)))
            kernel[k] = v
            total += v
        }
        for k in 0..<taps { kernel[k] /= total }

        var temp = [Float](repeating: 0, count: w * h)
        var out = [Float](repeating: 0, count: w * h)
        var padded = [Float](repeating: 0, count: w + 2 * radius)
        kernel.withUnsafeBufferPointer { kernelBuffer in
            let ker = kernelBuffer.baseAddress!
            values.withUnsafeBufferPointer { sourceBuffer in
                temp.withUnsafeMutableBufferPointer { tempBuffer in
                    padded.withUnsafeMutableBufferPointer { paddedBuffer in
                        let src = sourceBuffer.baseAddress!
                        let tmp = tempBuffer.baseAddress!
                        let line = paddedBuffer.baseAddress!
                        var y = 0
                        while y < h {
                            let row = src + y * w
                            var i = 0
                            while i < radius {
                                line[i] = row[0]
                                line[radius + w + i] = row[w - 1]
                                i += 1
                            }
                            (line + radius).update(from: row, count: w)
                            let dst = tmp + y * w
                            var x = 0
                            while x < w {
                                let p = line + x
                                var acc: Float = 0
                                var k = 0
                                while k < taps {
                                    acc += ker[k] * p[k]
                                    k += 1
                                }
                                dst[x] = acc
                                x += 1
                            }
                            y += 1
                        }
                    }
                }
            }
            temp.withUnsafeBufferPointer { tempBuffer in
                out.withUnsafeMutableBufferPointer { outBuffer in
                    let tmp = tempBuffer.baseAddress!
                    let dstBase = outBuffer.baseAddress!
                    var y = 0
                    while y < h {
                        let dst = dstBase + y * w
                        var k = 0
                        while k < taps {
                            let sy = min(max(y + k - radius, 0), h - 1)
                            let srcRow = tmp + sy * w
                            let weight = ker[k]
                            var x = 0
                            while x < w {
                                dst[x] += weight * srcRow[x]
                                x += 1
                            }
                            k += 1
                        }
                        y += 1
                    }
                }
            }
        }
        return out
    }

    // MARK: - Canny Edge Detection

    /// Edge map and gradient field produced by one Canny scale.
    struct CannyScale: Sendable {
        var edges: [UInt8]
        var gx: [Float]
        var gy: [Float]
    }

    /// Canny edge detection on a pre-smoothed image: Sobel gradients, non-maximum suppression,
    /// and hysteresis with thresholds derived from the median gradient magnitude (a robust noise
    /// estimate), so the detector adapts to the desk's contrast instead of using fixed constants.
    static func canny(_ smoothed: [Float], width w: Int, height h: Int) -> CannyScale {
        let n = w * h
        var gx = [Float](repeating: 0, count: n)
        var gy = [Float](repeating: 0, count: n)
        var mag = [Float](repeating: 0, count: n)
        smoothed.withUnsafeBufferPointer { s in
            gx.withUnsafeMutableBufferPointer { gxp in
                gy.withUnsafeMutableBufferPointer { gyp in
                    mag.withUnsafeMutableBufferPointer { mp in
                        for y in 1..<(h - 1) {
                            for x in 1..<(w - 1) {
                                let i = y * w + x
                                let a = s[i - w - 1], b = s[i - w], c = s[i - w + 1]
                                let d = s[i - 1], f = s[i + 1]
                                let g = s[i + w - 1], hh = s[i + w], k = s[i + w + 1]
                                let dx = ((c + 2 * f + k) - (a + 2 * d + g)) * 0.125
                                let dy = ((g + 2 * hh + k) - (a + 2 * b + c)) * 0.125
                                gxp[i] = dx
                                gyp[i] = dy
                                mp[i] = (dx * dx + dy * dy).squareRoot()
                            }
                        }
                    }
                }
            }
        }

        // Median magnitude via a 0.05-wide histogram (values above 100 share the last bin).
        let binCount = 2001
        var histogram = [Int](repeating: 0, count: binCount)
        for v in mag {
            histogram[min(binCount - 1, Int(v * 20.0))] += 1
        }
        var cumulative = 0
        var medianBin = 0
        for (bin, count) in histogram.enumerated() {
            cumulative += count
            if cumulative * 2 >= n {
                medianBin = bin
                break
            }
        }
        let noise = max(0.25, Double(medianBin) / 20.0)
        let low = Float(3.0 * noise)
        let high = Float(6.0 * noise)

        // Non-maximum suppression along the quantized gradient direction.
        var state = [UInt8](repeating: 0, count: n) // 0 none, 1 weak, 2 strong
        var stack: [Int] = []
        mag.withUnsafeBufferPointer { mp in
            gx.withUnsafeBufferPointer { gxp in
                gy.withUnsafeBufferPointer { gyp in
                    state.withUnsafeMutableBufferPointer { st in
                        let tan22: Float = 0.414_213_56
                        for y in 1..<(h - 1) {
                            for x in 1..<(w - 1) {
                                let i = y * w + x
                                let m = mp[i]
                                guard m >= low else { continue }
                                let ax = abs(gxp[i])
                                let ay = abs(gyp[i])
                                let n1: Float
                                let n2: Float
                                if ay <= tan22 * ax {
                                    n1 = mp[i - 1]
                                    n2 = mp[i + 1]
                                } else if ax <= tan22 * ay {
                                    n1 = mp[i - w]
                                    n2 = mp[i + w]
                                } else if (gxp[i] > 0) == (gyp[i] > 0) {
                                    n1 = mp[i - w - 1]
                                    n2 = mp[i + w + 1]
                                } else {
                                    n1 = mp[i - w + 1]
                                    n2 = mp[i + w - 1]
                                }
                                guard m >= n1 && m > n2 else { continue }
                                if m >= high {
                                    st[i] = 2
                                    stack.append(i)
                                } else {
                                    st[i] = 1
                                }
                            }
                        }
                    }
                }
            }
        }

        // Hysteresis: promote weak maxima 8-connected to strong ones.
        while let i = stack.popLast() {
            let x = i % w
            let y = i / w
            for dy in -1...1 {
                let yy = y + dy
                guard yy >= 0 && yy < h else { continue }
                for dx in -1...1 {
                    let xx = x + dx
                    guard xx >= 0 && xx < w else { continue }
                    let j = yy * w + xx
                    if state[j] == 1 {
                        state[j] = 2
                        stack.append(j)
                    }
                }
            }
        }
        let edges = state.map { $0 == 2 ? UInt8(1) : UInt8(0) }
        return CannyScale(edges: edges, gx: gx, gy: gy)
    }

    // MARK: - Thresholding

    /// Otsu threshold over values clamped to `[0, 255]`.
    ///
    /// - Returns: The threshold bin (class 1 is `value > threshold`) and both class means, or `nil`
    ///   when the histogram cannot be split into two non-empty classes.
    static func otsu(_ values: [Float]) -> (threshold: Int, lowMean: Double, highMean: Double)? {
        var histogram = [Int](repeating: 0, count: 256)
        for v in values {
            histogram[Int(min(255, max(0, v)))] += 1
        }
        let total = Double(values.count)
        var totalSum = 0.0
        for (bin, count) in histogram.enumerated() { totalSum += Double(bin * count) }
        var weightLow = 0.0
        var sumLow = 0.0
        var bestVariance = -1.0
        var best: (Int, Double, Double)?
        for t in 0..<255 {
            weightLow += Double(histogram[t])
            sumLow += Double(t * histogram[t])
            let weightHigh = total - weightLow
            guard weightLow > 0 && weightHigh > 0 else { continue }
            let meanLow = sumLow / weightLow
            let meanHigh = (totalSum - sumLow) / weightHigh
            let variance = weightLow * weightHigh * (meanLow - meanHigh) * (meanLow - meanHigh)
            if variance > bestVariance {
                bestVariance = variance
                best = (t, meanLow, meanHigh)
            }
        }
        return best.map { (threshold: $0.0, lowMean: $0.1, highMean: $0.2) }
    }

    // MARK: - Binary Morphology on Byte Masks

    /// Separable square dilation (`isErosion == false`) or erosion of a 0/1 byte mask.
    /// Out-of-bounds pixels count as 0 for dilation and 1 for erosion.
    static func squareMorphology(_ mask: [UInt8], width w: Int, height h: Int, radius r: Int, isErosion: Bool) -> [UInt8] {
        guard r > 0 else { return mask }
        var temp = [UInt8](repeating: 0, count: w * h)
        var out = [UInt8](repeating: 0, count: w * h)
        var prefix = [Int](repeating: 0, count: max(w, h) + 1)
        // Dilation: any set pixel in the window. Erosion: no unset in-bounds pixel in the window
        // (out-of-bounds pixels count as set), i.e. count == in-bounds window size.
        mask.withUnsafeBufferPointer { maskBuffer in
            temp.withUnsafeMutableBufferPointer { tempBuffer in
                out.withUnsafeMutableBufferPointer { outBuffer in
                    prefix.withUnsafeMutableBufferPointer { prefixBuffer in
                        let src = maskBuffer.baseAddress!
                        let tmp = tempBuffer.baseAddress!
                        let dst = outBuffer.baseAddress!
                        let pre = prefixBuffer.baseAddress!
                        var y = 0
                        while y < h {
                            let row = src + y * w
                            pre[0] = 0
                            var x = 0
                            while x < w {
                                pre[x + 1] = pre[x] + Int(row[x])
                                x += 1
                            }
                            let outRow = tmp + y * w
                            x = 0
                            while x < w {
                                let x0 = x - r < 0 ? 0 : x - r
                                let x1 = x + r + 1 > w ? w : x + r + 1
                                let count = pre[x1] - pre[x0]
                                outRow[x] = isErosion ? (count == x1 - x0 ? 1 : 0) : (count > 0 ? 1 : 0)
                                x += 1
                            }
                            y += 1
                        }
                        var x = 0
                        while x < w {
                            pre[0] = 0
                            var y = 0
                            while y < h {
                                pre[y + 1] = pre[y] + Int(tmp[y * w + x])
                                y += 1
                            }
                            y = 0
                            while y < h {
                                let y0 = y - r < 0 ? 0 : y - r
                                let y1 = y + r + 1 > h ? h : y + r + 1
                                let count = pre[y1] - pre[y0]
                                dst[y * w + x] = isErosion ? (count == y1 - y0 ? 1 : 0) : (count > 0 ? 1 : 0)
                                y += 1
                            }
                            x += 1
                        }
                    }
                }
            }
        }
        return out
    }

    /// 4-connected component labelling. Labels start at 1; background is 0.
    static func connectedComponents(_ mask: [UInt8], width w: Int, height h: Int) -> (labels: [Int32], areas: [Int]) {
        var labels = [Int32](repeating: 0, count: w * h)
        var areas: [Int] = [0]
        var stack: [Int] = []
        for start in 0..<(w * h) where mask[start] != 0 && labels[start] == 0 {
            let label = Int32(areas.count)
            var area = 0
            labels[start] = label
            stack.append(start)
            while let i = stack.popLast() {
                area += 1
                let x = i % w
                let y = i / w
                if x > 0, mask[i - 1] != 0, labels[i - 1] == 0 { labels[i - 1] = label; stack.append(i - 1) }
                if x < w - 1, mask[i + 1] != 0, labels[i + 1] == 0 { labels[i + 1] = label; stack.append(i + 1) }
                if y > 0, mask[i - w] != 0, labels[i - w] == 0 { labels[i - w] = label; stack.append(i - w) }
                if y < h - 1, mask[i + w] != 0, labels[i + w] == 0 { labels[i + w] = label; stack.append(i + w) }
            }
            areas.append(area)
        }
        return (labels, areas)
    }

    /// Fills every background region of `mask` that is not 4-connected to the image border.
    static func fillHoles(_ mask: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        var outside = [UInt8](repeating: 0, count: w * h)
        var stack: [Int] = []
        func seed(_ i: Int) {
            if mask[i] == 0 && outside[i] == 0 {
                outside[i] = 1
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
        return outside.map { $0 == 0 ? 1 : 0 }
    }

    // MARK: - Convex Hull & Quadrangle Reduction

    /// Andrew's monotone-chain convex hull, returned in screen-clockwise order (positive
    /// ``signedArea(_:)`` in y-down coordinates) without collinear vertices.
    static func convexHull(_ points: [Point2D]) -> [Point2D] {
        let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard sorted.count >= 3 else { return sorted }
        var lower: [Point2D] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 1] - lower[lower.count - 2], p - lower[lower.count - 2]) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [Point2D] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 1] - upper[upper.count - 2], p - upper[upper.count - 2]) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        var hull = Array(lower.dropLast()) + Array(upper.dropLast())
        if signedArea(hull) < 0 { hull.reverse() }
        return hull
    }

    /// Removes near-collinear vertices of a closed convex polygon (smallest deviation first)
    /// until every remaining vertex deviates by more than `tolerance` and at most `maxVertices` remain.
    static func simplifyClosedPolygon(_ polygon: [Point2D], tolerance: Double, maxVertices: Int) -> [Point2D] {
        var poly = polygon
        while poly.count > 4 {
            var bestIndex = 0
            var bestDeviation = Double.infinity
            for i in 0..<poly.count {
                let prev = poly[(i + poly.count - 1) % poly.count]
                let next = poly[(i + 1) % poly.count]
                let chord = next - prev
                let len = length(chord)
                let deviation = len > 1e-9 ? abs(cross(chord, poly[i] - prev)) / len : 0.0
                if deviation < bestDeviation {
                    bestDeviation = deviation
                    bestIndex = i
                }
            }
            if bestDeviation > tolerance && poly.count <= maxVertices { break }
            poly.remove(at: bestIndex)
        }
        return poly
    }

    /// The maximum-area quadrangle whose vertices are taken from a convex polygon, preserving order.
    static func maximumAreaQuad(_ polygon: [Point2D]) -> [Point2D]? {
        let n = polygon.count
        guard n >= 4 else { return nil }
        var bestArea = 0.0
        var best: [Int] = []
        for a in 0..<(n - 3) {
            for b in (a + 1)..<(n - 2) {
                for c in (b + 1)..<(n - 1) {
                    let ac = polygon[c] - polygon[a]
                    for d in (c + 1)..<n {
                        let area = 0.5 * abs(cross(ac, polygon[d] - polygon[b]))
                        if area > bestArea {
                            bestArea = area
                            best = [a, b, c, d]
                        }
                    }
                }
            }
        }
        guard best.count == 4, bestArea > 0 else { return nil }
        return best.map { polygon[$0] }
    }

    // MARK: - Full-Resolution Edge Refinement

    /// Bilinear sample at continuous coordinates (pixel centers at `i + 0.5`), clamped to the frame.
    @inline(__always)
    static func sample(_ pixels: UnsafeBufferPointer<UInt8>, width: Int, height: Int, at p: Point2D) -> Double {
        let fx = min(max(p.x - 0.5, 0.0), Double(width - 1))
        let fy = min(max(p.y - 0.5, 0.0), Double(height - 1))
        let x0 = Int(fx)
        let y0 = Int(fy)
        let x1 = min(x0 + 1, width - 1)
        let y1 = min(y0 + 1, height - 1)
        let ax = fx - Double(x0)
        let ay = fy - Double(y0)
        let p00 = Double(pixels[y0 * width + x0])
        let p10 = Double(pixels[y0 * width + x1])
        let p01 = Double(pixels[y1 * width + x0])
        let p11 = Double(pixels[y1 * width + x1])
        return (p00 * (1 - ax) + p10 * ax) * (1 - ay) + (p01 * (1 - ax) + p11 * ax) * ay
    }

    /// Result of refining one side (or side segment) against the full-resolution raster.
    struct EdgeRefinement: Sendable, Equatable {
        var line: Line
        var inlierCount: Int
        var sampleCount: Int
        var rmsResidual: Double
        var medianContrast: Double

        var support: Double {
            sampleCount > 0 ? Double(inlierCount) / Double(sampleCount) : 0.0
        }
    }

    /// Refines a paper-edge line by locating, along short profiles perpendicular to the line,
    /// the sub-pixel position of the strongest dark-outside → bright-inside transition, then
    /// refitting robustly (iterative MAD-trimmed total least squares).
    ///
    /// - Parameters:
    ///   - pixels: Full-resolution raster.
    ///   - width: Raster width.
    ///   - height: Raster height.
    ///   - line: Initial line whose ``Line/inwardNormal`` points into the paper.
    ///   - chordStart: Side start corner; profiles are placed at projections of chord points.
    ///   - chordEnd: Side end corner.
    ///   - tRange: Chord parameter range to sample.
    ///   - searchRadius: Half-length of each profile in pixels.
    ///   - contrastOffset: Distance either side of the edge used to measure paper/desk contrast.
    ///   - spacing: Distance between profiles in pixels.
    static func refineEdge(
        _ pixels: UnsafeBufferPointer<UInt8>,
        width: Int,
        height: Int,
        line: Line,
        chordStart: Point2D,
        chordEnd: Point2D,
        tRange: ClosedRange<Double>,
        searchRadius: Int,
        contrastOffset: Double,
        spacing: Double
    ) -> EdgeRefinement? {
        let chord = chordEnd - chordStart
        let chordLength = length(chord)
        let span = tRange.upperBound - tRange.lowerBound
        guard chordLength > 1.0, span > 0 else { return nil }
        let sampleCount = max(8, Int(chordLength * span / spacing))
        let normal = line.inwardNormal
        let profileCount = 2 * searchRadius + 3
        var profile = [Double](repeating: 0, count: profileCount)
        var candidates: [(point: Point2D, peak: Double, contrast: Double)] = []
        candidates.reserveCapacity(sampleCount)

        for k in 0..<sampleCount {
            let t = tRange.lowerBound + span * (Double(k) + 0.5) / Double(sampleCount)
            let base = line.projection(of: chordStart + chord * t)
            for j in 0..<profileCount {
                profile[j] = sample(pixels, width: width, height: height, at: base + normal * Double(j - searchRadius - 1))
            }
            var bestJ = 1
            var bestDerivative = -Double.infinity
            for j in 1...(2 * searchRadius + 1) {
                let derivative = profile[j + 1] - profile[j - 1]
                if derivative > bestDerivative {
                    bestDerivative = derivative
                    bestJ = j
                }
            }
            guard bestDerivative > 0 else { continue }
            var delta = 0.0
            if bestJ >= 2 && bestJ <= 2 * searchRadius {
                let dm = profile[bestJ] - profile[bestJ - 2]
                let dp = profile[bestJ + 2] - profile[bestJ]
                let denominator = dm - 2.0 * bestDerivative + dp
                if denominator < -1e-9 {
                    delta = min(0.5, max(-0.5, 0.5 * (dm - dp) / denominator))
                }
            }
            let offset = Double(bestJ - searchRadius - 1) + delta
            let edge = base + normal * offset
            let contrast = sample(pixels, width: width, height: height, at: edge + normal * contrastOffset)
                - sample(pixels, width: width, height: height, at: edge - normal * contrastOffset)
            candidates.append((edge, bestDerivative, contrast))
        }

        let peakFloor = max(2.0, 0.35 * median(candidates.map(\.peak)))
        let accepted = candidates.filter { $0.peak >= peakFloor && $0.contrast > 0 }
        let points = accepted.map(\.point)
        guard var current = fitLine(points, orientedLike: line.direction) else { return nil }
        var inlierMask = [Bool](repeating: true, count: points.count)
        for _ in 0..<4 {
            let residuals = points.map { abs(current.signedDistance($0)) }
            let tolerance = min(2.0, max(0.6, 3.0 * 1.4826 * median(residuals)))
            inlierMask = residuals.map { $0 <= tolerance }
            let inliers = zip(points, inlierMask).compactMap { $0.1 ? $0.0 : nil }
            guard let refit = fitLine(inliers, orientedLike: line.direction) else { break }
            current = refit
        }
        var sumSq = 0.0
        var inlierCount = 0
        var contrasts: [Double] = []
        for (i, keep) in inlierMask.enumerated() where keep {
            let r = current.signedDistance(points[i])
            sumSq += r * r
            inlierCount += 1
            contrasts.append(accepted[i].contrast)
        }
        guard inlierCount >= 2 else { return nil }
        return EdgeRefinement(
            line: current,
            inlierCount: inlierCount,
            sampleCount: sampleCount,
            rmsResidual: (sumSq / Double(inlierCount)).squareRoot(),
            medianContrast: median(contrasts)
        )
    }
}
