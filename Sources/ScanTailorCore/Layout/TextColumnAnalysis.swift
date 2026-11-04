import ScanTailorContracts

/// Column-projection helpers that separate a page's text block from vertical streaks (page-edge stacks,
/// gutter shadows, rules) and from isolated edge noise.
///
/// Inside a text block every pixel column is crossed by many text lines, so no column is empty over its
/// whole height; edge textures, in contrast, sit behind a clear empty gap.
enum TextColumnAnalysis {
    /// Black pixels per column over the rows of `area`.
    static func columnInk(_ bitmap: borrowing BinaryBitmap, area: Rect2I) -> [Int] {
        guard area.width > 0, area.height > 0 else { return [] }
        var counts = [Int](repeating: 0, count: area.width)
        let wordsPerRow = bitmap.wordsPerRow
        bitmap.withUnsafeWords { words in
            for y in area.minY..<area.maxY {
                let rowBase = y * wordsPerRow
                for w in (area.minX / 64)...((area.maxX - 1) / 64) {
                    let lo = max(area.minX, w * 64) - w * 64
                    let hi = min(area.maxX, w * 64 + 64) - w * 64
                    let mask = (UInt64.max >> lo) & ~(UInt64.max >> hi)
                    var v = words[rowBase + w] & mask
                    while v != 0 {
                        let bit = v.leadingZeroBitCount
                        counts[w * 64 + bit - area.minX] += 1
                        v &= ~(UInt64(1) << UInt64(63 - bit))
                    }
                }
            }
        }
        return counts
    }

    /// Absolute x ranges of columns inked over at least `fraction` of the area height, merged and widened by
    /// two columns. Empty when the streaks would cover more than 15% of the width (an illustration or border).
    static func streakRanges(counts: [Int], area: Rect2I, fraction: Double) -> [Range<Int>] {
        guard fraction > 0, area.height > 0 else { return [] }
        let threshold = Int((fraction * Double(area.height)).rounded(.up))
        var ranges: [Range<Int>] = []
        for (offset, count) in counts.enumerated() where count >= threshold {
            let x = area.minX + offset
            if let last = ranges.last, x - last.upperBound <= 4 {
                ranges[ranges.count - 1] = last.lowerBound..<(x + 1)
            } else {
                ranges.append(x..<(x + 1))
            }
        }
        ranges = ranges.map { max(area.minX, $0.lowerBound - 2)..<min(area.maxX, $0.upperBound + 2) }
        let total = ranges.reduce(0) { $0 + $1.count }
        return Double(total) <= 0.15 * Double(area.width) ? ranges : []
    }

    /// Offsets (relative to the area's left edge) of the main text block, or `nil` when nothing needs trimming.
    ///
    /// Column groups separated by an empty gap of at least `gapFraction` of the width are compared by ink;
    /// groups carrying under 20% of the main group's ink are dropped.
    static func mainTextExtent(counts: [Int], areaHeight: Int, gapFraction: Double) -> Range<Int>? {
        guard gapFraction > 0, areaHeight >= 32, counts.count >= 64 else { return nil }
        let occupiedMin = max(2, Int((0.003 * Double(areaHeight)).rounded(.up)))
        let minGap = max(8, Int((gapFraction * Double(counts.count)).rounded()))
        var groups: [(range: Range<Int>, mass: Int)] = []
        var start: Int? = nil
        var lastOccupied = -1
        var mass = 0
        for (offset, count) in counts.enumerated() where count >= occupiedMin {
            if let s = start, offset - lastOccupied - 1 >= minGap {
                groups.append((s..<(lastOccupied + 1), mass))
                start = offset
                mass = 0
            } else if start == nil {
                start = offset
            }
            mass += count
            lastOccupied = offset
        }
        if let s = start { groups.append((s..<(lastOccupied + 1), mass)) }
        guard groups.count > 1, let main = groups.map(\.mass).max() else { return nil }
        let kept = groups.filter { Double($0.mass) >= 0.2 * Double(main) }
        guard let first = kept.first, let last = kept.last else { return nil }
        let extent = first.range.lowerBound..<last.range.upperBound
        return extent.count < counts.count ? extent : nil
    }
}
