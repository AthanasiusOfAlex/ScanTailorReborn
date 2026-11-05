import Foundation
import ScanTailorContracts

/// Decisions about the first and last pages of a book and about scans whose split disagrees with the rest of
/// the book (Substep 7.1.1d). Pure functions on sizes and verdicts; no pixels.
public enum BookEnds {
    /// Why a slice is left out of the output.
    public enum Verdict: String, Sendable, Equatable {
        /// Blank, and before the first page with content (an unnumbered flyleaf, a blank half of a title scan).
        case leadingBlank
        /// Blank, and after the last page with content.
        case trailingBlank
        /// A cover sheet added by a digital library.
        case coverSheet
        /// A printed cover (an odd-sized first or last scan), with `CoverHandling.strip`.
        case cover
    }

    /// Scans of one size that the book splits as spreads, but one of them was left whole because its own gutter
    /// was too faint (a title page beside a blank half).
    ///
    /// A scan qualifies when it is landscape, was not split, may still be split automatically, and at least three
    /// other scans of its size (within 5%) were split and make up at least three quarters of that group.
    /// - Parameters:
    ///   - sizes: Raster size of every scan.
    ///   - sliceCounts: How many pages each scan produced (1 = not split, 2 = split).
    ///   - eligible: Whether the scan's split is still up to the automatic decision (not forced, not vetoed).
    /// - Returns: Indices of the scans to split.
    public static func consensusSplitScans(sizes: [Size2I], sliceCounts: [Int], eligible: [Bool]) -> [Int] {
        func similar(_ a: Size2I, _ b: Size2I) -> Bool {
            abs(Double(a.width - b.width)) <= 0.05 * Double(a.width) && abs(Double(a.height - b.height)) <= 0.05 * Double(a.height)
        }
        var result: [Int] = []
        for i in sizes.indices where eligible[i] && sliceCounts[i] == 1 && sizes[i].width > sizes[i].height {
            let group = sizes.indices.filter { $0 != i && similar(sizes[$0], sizes[i]) }
            let split = group.filter { sliceCounts[$0] == 2 }.count
            if split >= 3 && split * 4 >= group.count * 3 { result.append(i) }
        }
        return result
    }

    /// The scans a library cover sheet can be on: the first two and the last.
    public static func coverSheetCandidates(scanCount: Int) -> [Int] {
        Array(Set([0, 1, scanCount - 1].filter { $0 >= 0 && $0 < scanCount })).sorted()
    }

    /// First or last scans whose size differs from the book's median by more than `tolerance` in width or height
    /// (a printed cover, a foldout). Empty for fewer than five scans.
    public static func printedCoverScans(sizes: [Size2I], tolerance: Double = 0.08) -> [Int] {
        guard sizes.count >= 5 else { return [] }
        let width = Double(sizes.map(\.width).sorted()[sizes.count / 2])
        let height = Double(sizes.map(\.height).sorted()[sizes.count / 2])
        return [0, sizes.count - 1].filter { i in
            abs(Double(sizes[i].width) - width) > tolerance * width || abs(Double(sizes[i].height) - height) > tolerance * height
        }
    }

    /// Which slices to leave out, in book order. A cover is always left out. A blank slice is left out only when
    /// no page with content lies before it (leading) or after it (trailing): a blank page between two pages keeps
    /// the book's recto/verso order and stays.
    public static func verdicts(isBlank: [Bool], isCover: [Verdict?]) -> [Verdict?] {
        let isContent = isBlank.indices.map { !isBlank[$0] && isCover[$0] == nil }
        let first = isContent.firstIndex(of: true)
        let last = isContent.lastIndex(of: true)
        return isBlank.indices.map { i in
            if let cover = isCover[i] { return cover }
            guard isBlank[i] else { return nil }
            guard let first, let last else { return .leadingBlank }
            if i < first { return .leadingBlank }
            if i > last { return .trailingBlank }
            return nil
        }
    }
}
