import Foundation
import ScanTailorContracts

/// Metadata describing a single connected foreground component in a `BinaryBitmap`.
public struct ConnectedComponent: Sendable, Equatable, Hashable, Codable {
    /// Zero-based sequential identifier of the component.
    public let id: Int

    /// Minimal integer bounding box `[minX, maxX) x [minY, maxY)` enclosing the component.
    public let boundingBox: Rect2I

    /// Total number of black (`1`) foreground pixels in the component.
    public let pixelCount: Int

    /// A representative black pixel belonging to the component.
    public let seedPoint: Point2I

    /// Creates a connected component descriptor.
    public init(id: Int, boundingBox: Rect2I, pixelCount: Int, seedPoint: Point2I) {
        self.id = id
        self.boundingBox = boundingBox
        self.pixelCount = pixelCount
        self.seedPoint = seedPoint
    }

    /// Ratio of foreground pixels to bounding box area (`pixelCount / area`), in `(0, 1]`.
    public var density: Double {
        let area = boundingBox.area
        guard area > 0 else { return 0 }
        return Double(pixelCount) / Double(area)
    }

    /// Aspect ratio of the bounding box (`width / height`).
    public var aspectRatio: Double {
        guard boundingBox.height > 0 else { return 0 }
        return Double(boundingBox.width) / Double(boundingBox.height)
    }
}

/// A connected component paired with its isolated cropped 1-bit foreground mask.
///
/// Mirrors the output of ScanTailor-Advanced `imageproc::ConnCompEraser`.
public struct ConnectedComponentWithMask: Sendable, Equatable {
    /// The component's geometric and pixel statistics.
    public let component: ConnectedComponent

    /// Cropped `BinaryBitmap` of dimensions `component.boundingBox.size` containing only this component's pixels.
    public let mask: BinaryBitmap

    public init(component: ConnectedComponent, mask: BinaryBitmap) {
        self.component = component
        self.mask = mask
    }
}

/// High-speed connected-component extraction and filtering engine (adapted from ScanTailor-Advanced `ConnCompEraser`).
///
/// Scans 64-bit packed words to skip empty background regions in $O(W \cdot H / 64)$ and uses bit-level
/// neighbor masks during flood extraction so each black foreground pixel is visited exactly once.
public enum ConnectedComponentAnalyzer {

    /// Extracts all connected foreground components from `bitmap`.
    /// - Parameters:
    ///   - bitmap: Source 1-bit bitmap (`1` = foreground).
    ///   - connectivity: Neighbor connectivity (`.four` or `.eight`). Default is `.eight`.
    /// - Returns: Array of `ConnectedComponent` descriptors in raster scan order.
    public static func extractComponents(
        from bitmap: borrowing BinaryBitmap,
        connectivity: Connectivity = .eight
    ) -> [ConnectedComponent] {
        var working = copy bitmap
        let width = working.width
        let height = working.height
        let wordsPerRow = working.wordsPerRow

        var components: [ConnectedComponent] = []
        var stack = ContiguousArray<Point2I>()
        stack.reserveCapacity(256)

        working.withUnsafeMutableWords { words in
            for y in 0..<height {
                let rowBase = y * wordsPerRow
                for col in 0..<wordsPerRow {
                    let wordIdx = rowBase + col
                    while words[wordIdx] != 0 {
                        let firstBit = words[wordIdx].leadingZeroBitCount
                        let startX = (col << 6) + firstBit
                        let startY = y

                        // Clear starting pixel
                        words[wordIdx] &= ~(UInt64(1) << (63 - firstBit))

                        let seed = Point2I(x: startX, y: startY)
                        stack.removeAll(keepingCapacity: true)
                        stack.append(seed)

                        var minX = startX
                        var maxX = startX
                        var minY = startY
                        var maxY = startY
                        var count = 0

                        while let pt = stack.popLast() {
                            count += 1
                            let px = pt.x
                            let py = pt.y
                            if px < minX { minX = px }
                            if px > maxX { maxX = px }
                            if py < minY { minY = py }
                            if py > maxY { maxY = py }

                            enqueueAndClearNeighbors(
                                px: px,
                                py: py,
                                width: width,
                                height: height,
                                wordsPerRow: wordsPerRow,
                                connectivity: connectivity,
                                words: &words,
                                stack: &stack
                            )
                        }

                        let comp = ConnectedComponent(
                            id: components.count,
                            boundingBox: Rect2I(minX: minX, minY: minY, maxX: maxX + 1, maxY: maxY + 1),
                            pixelCount: count,
                            seedPoint: seed
                        )
                        components.append(comp)
                    }
                }
            }
        }

        return components
    }

    /// Extracts all connected foreground components along with their isolated cropped 1-bit masks.
    /// - Parameters:
    ///   - bitmap: Source 1-bit bitmap (`1` = foreground).
    ///   - connectivity: Neighbor connectivity (default: `.eight`).
    /// - Returns: Array of `ConnectedComponentWithMask` in raster scan order.
    public static func extractComponentsWithMasks(
        from bitmap: borrowing BinaryBitmap,
        connectivity: Connectivity = .eight
    ) -> [ConnectedComponentWithMask] {
        var working = copy bitmap
        let width = working.width
        let height = working.height
        let wordsPerRow = working.wordsPerRow

        var results: [ConnectedComponentWithMask] = []
        var stack = ContiguousArray<Point2I>()
        stack.reserveCapacity(256)
        var componentPixels = ContiguousArray<Point2I>()
        componentPixels.reserveCapacity(256)

        working.withUnsafeMutableWords { words in
            for y in 0..<height {
                let rowBase = y * wordsPerRow
                for col in 0..<wordsPerRow {
                    let wordIdx = rowBase + col
                    while words[wordIdx] != 0 {
                        let firstBit = words[wordIdx].leadingZeroBitCount
                        let startX = (col << 6) + firstBit
                        let startY = y

                        words[wordIdx] &= ~(UInt64(1) << (63 - firstBit))

                        let seed = Point2I(x: startX, y: startY)
                        stack.removeAll(keepingCapacity: true)
                        componentPixels.removeAll(keepingCapacity: true)
                        stack.append(seed)

                        var minX = startX
                        var maxX = startX
                        var minY = startY
                        var maxY = startY

                        while let pt = stack.popLast() {
                            componentPixels.append(pt)
                            let px = pt.x
                            let py = pt.y
                            if px < minX { minX = px }
                            if px > maxX { maxX = px }
                            if py < minY { minY = py }
                            if py > maxY { maxY = py }

                            enqueueAndClearNeighbors(
                                px: px,
                                py: py,
                                width: width,
                                height: height,
                                wordsPerRow: wordsPerRow,
                                connectivity: connectivity,
                                words: &words,
                                stack: &stack
                            )
                        }

                        let bbox = Rect2I(minX: minX, minY: minY, maxX: maxX + 1, maxY: maxY + 1)
                        var mask = BinaryBitmap(width: bbox.width, height: bbox.height, initialBlack: false)
                        for pt in componentPixels {
                            mask[pt.x - minX, pt.y - minY] = true
                        }

                        let comp = ConnectedComponent(
                            id: results.count,
                            boundingBox: bbox,
                            pixelCount: componentPixels.count,
                            seedPoint: seed
                        )
                        results.append(ConnectedComponentWithMask(component: comp, mask: mask))
                    }
                }
            }
        }

        return results
    }

    /// Filters connected components in `bitmap`, keeping only those that satisfy `predicate`.
    /// - Parameters:
    ///   - bitmap: Source 1-bit bitmap.
    ///   - connectivity: Neighbor connectivity (default: `.eight`).
    ///   - predicate: Closure returning `true` if the component should be retained, or `false` to erase it.
    /// - Returns: Filtered `BinaryBitmap`.
    public static func filterComponents(
        in bitmap: borrowing BinaryBitmap,
        connectivity: Connectivity = .eight,
        keep predicate: (ConnectedComponent) -> Bool
    ) -> BinaryBitmap {
        var working = copy bitmap
        var output = copy bitmap
        let width = working.width
        let height = working.height
        let wordsPerRow = working.wordsPerRow

        var compId = 0
        var stack = ContiguousArray<Point2I>()
        stack.reserveCapacity(256)
        var componentPixels = ContiguousArray<Point2I>()
        componentPixels.reserveCapacity(256)

        working.withUnsafeMutableWords { words in
            for y in 0..<height {
                let rowBase = y * wordsPerRow
                for col in 0..<wordsPerRow {
                    let wordIdx = rowBase + col
                    while words[wordIdx] != 0 {
                        let firstBit = words[wordIdx].leadingZeroBitCount
                        let startX = (col << 6) + firstBit
                        let startY = y

                        words[wordIdx] &= ~(UInt64(1) << (63 - firstBit))

                        let seed = Point2I(x: startX, y: startY)
                        stack.removeAll(keepingCapacity: true)
                        componentPixels.removeAll(keepingCapacity: true)
                        stack.append(seed)

                        var minX = startX
                        var maxX = startX
                        var minY = startY
                        var maxY = startY

                        while let pt = stack.popLast() {
                            componentPixels.append(pt)
                            let px = pt.x
                            let py = pt.y
                            if px < minX { minX = px }
                            if px > maxX { maxX = px }
                            if py < minY { minY = py }
                            if py > maxY { maxY = py }

                            enqueueAndClearNeighbors(
                                px: px,
                                py: py,
                                width: width,
                                height: height,
                                wordsPerRow: wordsPerRow,
                                connectivity: connectivity,
                                words: &words,
                                stack: &stack
                            )
                        }

                        let comp = ConnectedComponent(
                            id: compId,
                            boundingBox: Rect2I(minX: minX, minY: minY, maxX: maxX + 1, maxY: maxY + 1),
                            pixelCount: componentPixels.count,
                            seedPoint: seed
                        )
                        compId += 1

                        if !predicate(comp) {
                            for pt in componentPixels {
                                output[pt.x, pt.y] = false
                            }
                        }
                    }
                }
            }
        }

        return output
    }

    /// Removes isolated salt-and-pepper foreground speckles containing at most `maxSpecklePixels` black pixels.
    /// - Parameters:
    ///   - bitmap: Source binary bitmap.
    ///   - maxSpecklePixels: Maximum pixel count of a component to be considered noise and erased.
    ///   - connectivity: Neighbor connectivity (default: `.eight`).
    /// - Returns: Despeckled `BinaryBitmap`.
    public static func despeckle(
        _ bitmap: borrowing BinaryBitmap,
        maxSpecklePixels: Int,
        connectivity: Connectivity = .eight
    ) -> BinaryBitmap {
        guard maxSpecklePixels > 0 else { return copy bitmap }
        return filterComponents(in: bitmap, connectivity: connectivity) { comp in
            comp.pixelCount > maxSpecklePixels
        }
    }

    // MARK: - Internal Fast Neighbor Extraction

    @inline(__always)
    private static func enqueueAndClearNeighbors(
        px: Int,
        py: Int,
        width: Int,
        height: Int,
        wordsPerRow: Int,
        connectivity: Connectivity,
        words: inout UnsafeMutableBufferPointer<UInt64>,
        stack: inout ContiguousArray<Point2I>
    ) {
        switch connectivity {
        case .eight:
            let col = px >> 6
            let bitInWord = px & 63

            // Fast path when {px - 1, px, px + 1} all reside inside the same 64-bit word (96.8% of pixels)
            if bitInWord > 0 && bitInWord < 63 {
                let mask3 = UInt64(0b111) << (62 - bitInWord)
                let minRow = max(0, py - 1)
                let maxRow = min(height - 1, py + 1)
                let baseX = col << 6

                for ny in minRow...maxRow {
                    let wIdx = ny * wordsPerRow + col
                    var hits = words[wIdx] & mask3
                    if hits != 0 {
                        words[wIdx] &= ~hits
                        while hits != 0 {
                            let shift = hits.trailingZeroBitCount
                            let nx = baseX + (63 - shift)
                            stack.append(Point2I(x: nx, y: ny))
                            hits &= hits &- 1
                        }
                    }
                }
            } else {
                // Word-boundary pixel
                let minY = max(0, py - 1)
                let maxY = min(height - 1, py + 1)
                let minX = max(0, px - 1)
                let maxX = min(width - 1, px + 1)

                for ny in minY...maxY {
                    let rowBase = ny * wordsPerRow
                    for nx in minX...maxX {
                        let wIdx = rowBase + (nx >> 6)
                        let mask = UInt64(1) << (63 - (nx & 63))
                        if (words[wIdx] & mask) != 0 {
                            words[wIdx] &= ~mask
                            stack.append(Point2I(x: nx, y: ny))
                        }
                    }
                }
            }

        case .four:
            // North
            if py > 0 {
                let wIdx = (py - 1) * wordsPerRow + (px >> 6)
                let mask = UInt64(1) << (63 - (px & 63))
                if (words[wIdx] & mask) != 0 {
                    words[wIdx] &= ~mask
                    stack.append(Point2I(x: px, y: py - 1))
                }
            }
            // South
            if py + 1 < height {
                let wIdx = (py + 1) * wordsPerRow + (px >> 6)
                let mask = UInt64(1) << (63 - (px & 63))
                if (words[wIdx] & mask) != 0 {
                    words[wIdx] &= ~mask
                    stack.append(Point2I(x: px, y: py + 1))
                }
            }
            // West
            if px > 0 {
                let nx = px - 1
                let wIdx = py * wordsPerRow + (nx >> 6)
                let mask = UInt64(1) << (63 - (nx & 63))
                if (words[wIdx] & mask) != 0 {
                    words[wIdx] &= ~mask
                    stack.append(Point2I(x: nx, y: py))
                }
            }
            // East
            if px + 1 < width {
                let nx = px + 1
                let wIdx = py * wordsPerRow + (nx >> 6)
                let mask = UInt64(1) << (63 - (nx & 63))
                if (words[wIdx] & mask) != 0 {
                    words[wIdx] &= ~mask
                    stack.append(Point2I(x: nx, y: py))
                }
            }
        }
    }
}
