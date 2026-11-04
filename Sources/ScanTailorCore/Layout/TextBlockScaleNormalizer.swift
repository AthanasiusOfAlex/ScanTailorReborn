import ScanTailorContracts

/// Brings camera-photographed pages to one text-block size (Substep 7.1.1b-i).
///
/// A phone photo of an open book shows the two pages at different scales: the page nearer the lens looks larger,
/// and the page curving into the gutter looks narrower. Flatbed scans keep every page at one scale, so the layout
/// can trust a text block's measured size; on camera pages it cannot, and a page photographed 11 % narrower is
/// taken for a short page and left floating. This type measures the book's typical text block on the camera pages
/// and resamples each of them, width and height separately, so its block matches.
///
/// - A **full page** (width and height both within ``Configuration/fullSizeTolerance`` of the typical block) gets
///   its own factors.
/// - A **short page** of full width (a chapter ending) is scaled by its width; its height factor is the width
///   factor times the typical ratio of height to width factors on the full pages.
/// - Any other page (a title, a divider, a nearly empty page) borrows the factors of a page from the same photo.
///
/// Every factor is clamped to ``Configuration/scaleRange``. Pages whose factors are within half a percent of 1 are
/// left alone.
public enum TextBlockScaleNormalizer {
    public struct Configuration: Sendable, Equatable {
        /// Allowed factor on each axis.
        public var scaleRange: ClosedRange<Double>
        /// Largest relative difference from the typical block, on each axis, for a page to count as full.
        public var fullSizeTolerance: Double
        /// Fewest full pages needed to trust the typical block; with fewer, nothing is scaled.
        public var minimumFullPages: Int

        public init(scaleRange: ClosedRange<Double> = 0.8...1.25, fullSizeTolerance: Double = 0.2, minimumFullPages: Int = 2) {
            self.scaleRange = scaleRange
            self.fullSizeTolerance = fullSizeTolerance
            self.minimumFullPages = max(1, minimumFullPages)
        }
    }

    /// One page offered for scaling.
    public struct PageInput: Sendable, Equatable {
        /// Pages from the same photo share a group (the source scan index); a page without a usable block
        /// borrows the factors of another page in its group.
        public var group: Int
        /// The detected text block, in page pixels.
        public var contentBox: Rect2I?
        /// Whether the page may be scaled (a camera photo without a manual content box).
        public var isEligible: Bool

        public init(group: Int, contentBox: Rect2I?, isEligible: Bool) {
            self.group = group
            self.contentBox = contentBox
            self.isEligible = isEligible
        }
    }

    /// The horizontal (`width`) and vertical (`height`) factor for each page, in input order; `nil` leaves a page
    /// as it is.
    public static func scales(for pages: [PageInput], configuration: Configuration = Configuration()) -> [Size2D?] {
        var result = [Size2D?](repeating: nil, count: pages.count)
        let boxes: [Rect2I?] = pages.map { page in
            guard page.isEligible, let box = page.contentBox, !box.isEmpty else { return nil }
            return box
        }
        let present = boxes.compactMap { $0 }
        guard let widest = present.map(\.width).max() else { return result }

        // The typical block: medians of the substantial boxes, then of the full pages around them.
        let substantial = present.filter { $0.width * 2 >= widest }
        let tolerance = configuration.fullSizeTolerance
        func isFull(_ box: Rect2I, width: Double, height: Double) -> Bool {
            abs(Double(box.width) / width - 1) <= tolerance && abs(Double(box.height) / height - 1) <= tolerance
        }
        let roughWidth = median(substantial.map { Double($0.width) })
        let roughHeight = median(substantial.map { Double($0.height) })
        let full = present.filter { isFull($0, width: roughWidth, height: roughHeight) }
        guard full.count >= configuration.minimumFullPages else { return result }
        let targetWidth = median(full.map { Double($0.width) })
        let targetHeight = median(full.map { Double($0.height) })
        let aspect = median(full.map { (targetHeight / Double($0.height)) / (targetWidth / Double($0.width)) })

        func clamp(_ value: Double) -> Double {
            min(configuration.scaleRange.upperBound, max(configuration.scaleRange.lowerBound, value))
        }
        for (index, box) in boxes.enumerated() {
            guard let box else { continue }
            let sx = clamp(targetWidth / Double(box.width))
            if isFull(box, width: targetWidth, height: targetHeight) {
                result[index] = Size2D(width: sx, height: clamp(targetHeight / Double(box.height)))
            } else if abs(Double(box.width) / targetWidth - 1) <= tolerance && Double(box.height) < targetHeight {
                result[index] = Size2D(width: sx, height: clamp(sx * aspect))
            }
        }
        // Pages with no usable block of their own borrow from their photo.
        for index in pages.indices where pages[index].isEligible && result[index] == nil {
            result[index] = pages.indices.first { $0 != index && pages[$0].group == pages[index].group && result[$0] != nil }
                .flatMap { result[$0] }
        }
        return result.map { scale in
            guard let scale, abs(scale.width - 1) > 0.005 || abs(scale.height - 1) > 0.005 else { return nil }
            return scale
        }
    }

    /// The size of a `size` page after scaling by `scale`.
    public static func scaledSize(_ size: Size2I, by scale: Size2D) -> Size2I {
        Size2I(
            width: max(1, Int((Double(size.width) * scale.width).rounded())),
            height: max(1, Int((Double(size.height) * scale.height).rounded()))
        )
    }

    /// `rect` scaled about the page origin, grown outward to whole pixels and kept inside a page of `bounds`.
    public static func scaled(_ rect: Rect2I, by scale: Size2D, within bounds: Size2I) -> Rect2I {
        let minX = Int((Double(rect.minX) * scale.width).rounded(.down))
        let minY = Int((Double(rect.minY) * scale.height).rounded(.down))
        let maxX = Int((Double(rect.maxX) * scale.width).rounded(.up))
        let maxY = Int((Double(rect.maxY) * scale.height).rounded(.up))
        return Rect2I(
            minX: min(max(0, minX), bounds.width), minY: min(max(0, minY), bounds.height),
            maxX: min(max(0, maxX), bounds.width), maxY: min(max(0, maxY), bounds.height)
        )
    }

    /// A detection result with every box scaled to match a page resampled by `scale` to `bounds`.
    public static func scaled(
        _ detection: ContentBoxDetector.DetectionResult, by scale: Size2D, within bounds: Size2I
    ) -> ContentBoxDetector.DetectionResult {
        let area = scale.width * scale.height
        return ContentBoxDetector.DetectionResult(
            contentBox: detection.contentBox.map { scaled($0, by: scale, within: bounds) },
            mainBodyBox: detection.mainBodyBox.map { scaled($0, by: scale, within: bounds) },
            retainedClusters: detection.retainedClusters.map {
                ContentBoxDetector.Cluster(
                    exactBounds: scaled($0.exactBounds, by: scale, within: bounds),
                    foregroundPixels: max(1, Int((Double($0.foregroundPixels) * area).rounded()))
                )
            },
            rejectedBoxes: detection.rejectedBoxes.map { scaled($0, by: scale, within: bounds) },
            confidence: detection.confidence
        )
    }

    /// Resamples a 1-bit page by `scale`: each output pixel interpolates the four nearest source pixels
    /// bilinearly and is black when the result reaches one half, so strokes keep their weight and edges stay
    /// smooth.
    public static func resample(_ bitmap: borrowing BinaryBitmap, by scale: Size2D) -> BinaryBitmap {
        let source = Size2I(width: bitmap.width, height: bitmap.height)
        let size = scaledSize(source, by: scale)
        var output = BinaryBitmap(width: size.width, height: size.height, initialBlack: false)

        func taps(_ count: Int, sourceCount: Int, factor: Double) -> (lo: [Int], hi: [Int], fraction: [Float]) {
            var lo = [Int](repeating: 0, count: count)
            var hi = [Int](repeating: 0, count: count)
            var fraction = [Float](repeating: 0, count: count)
            for i in 0..<count {
                let position = min(Double(sourceCount - 1), max(0, (Double(i) + 0.5) / factor - 0.5))
                lo[i] = Int(position)
                hi[i] = min(sourceCount - 1, lo[i] + 1)
                fraction[i] = Float(position - Double(lo[i]))
            }
            return (lo, hi, fraction)
        }
        let columns = taps(size.width, sourceCount: source.width, factor: scale.width)
        let rows = taps(size.height, sourceCount: source.height, factor: scale.height)
        let sourceStride = bitmap.wordsPerRow
        let outputStride = output.wordsPerRow
        let words = bitmap.words
        let rowIsEmpty = (0..<source.height).map { y in
            words[(y * sourceStride)..<((y + 1) * sourceStride)].allSatisfy { $0 == 0 }
        }

        words.withUnsafeBufferPointer { src in
            output.words.withUnsafeMutableBufferPointer { dst in
                @inline(__always) func ink(_ rowStart: Int, _ x: Int) -> Float {
                    Float((src[rowStart + (x >> 6)] >> UInt64(63 - (x & 63))) & 1)
                }
                for y in 0..<size.height {
                    let upperRow = rows.lo[y], lowerRow = rows.hi[y]
                    if rowIsEmpty[upperRow] && rowIsEmpty[lowerRow] { continue }
                    let upper = upperRow * sourceStride, lower = lowerRow * sourceStride
                    let fy = rows.fraction[y]
                    for x in 0..<size.width {
                        let x0 = columns.lo[x], x1 = columns.hi[x], fx = columns.fraction[x]
                        let a = ink(upper, x0), b = ink(upper, x1), c = ink(lower, x0), d = ink(lower, x1)
                        let sum = a + b + c + d
                        guard sum > 0 else { continue }
                        let value = sum == 4 ? 1 : (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy
                        if value >= 0.5 {
                            dst[y * outputStride + (x >> 6)] |= UInt64(1) << UInt64(63 - (x & 63))
                        }
                    }
                }
            }
        }
        return output
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
