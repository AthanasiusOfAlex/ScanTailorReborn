import ScanTailorContracts

/// Whether a processed page belongs to the book's consensus page size (Substep 6.2.1).
public enum DimensionClass: String, Sendable, Equatable, Codable, CaseIterable {
    /// An ordinary page of the book: it shares the canonical canvas and frame.
    case canonical
    /// A page whose dimensions differ from the book's: a cover, plate, foldout, or landscape table.
    case outlier
}

/// Why a page is a dimensional outlier.
public enum DimensionOutlierKind: String, Sendable, Equatable, Codable {
    /// The page is wider or taller than the book's typical page.
    case oversize
    /// The page is narrower or shorter than the book's typical page.
    case undersize
    /// The page is landscape in a portrait book, or the reverse.
    case orientation
    /// The page size is normal, but its text block is larger than the book's text block can hold.
    case contentOverflow
    /// The page was marked as an outlier through a manual override.
    case manual
}

/// Per-page outcome of the consensus-dimension clustering.
public struct PageDimensionRecord: Sendable, Equatable, Codable {
    public var dimensionClass: DimensionClass
    /// Why the page is an outlier (empty for canonical pages).
    public var kinds: [DimensionOutlierKind]
    /// Signed relative difference between the page width and the book's median width.
    public var widthDeviation: Double
    /// Signed relative difference between the page height and the book's median height.
    public var heightDeviation: Double
    /// Signed relative difference between the body line pitch and the book's median pitch (`nil` when unmeasured).
    public var linePitchDeviation: Double?
    /// The page was photographed at a different scale than the book (line pitch differs). Flag only.
    public var scaleMismatch: Bool
    /// The page size the outlier should get on its own canvas (`nil` for canonical pages).
    public var proposedCanvasSize: Size2I?
    /// Index into `DimensionConsensusSummary.outlierGroups` for outliers that share a size (`nil` otherwise).
    public var groupIndex: Int?

    public init(
        dimensionClass: DimensionClass = .canonical,
        kinds: [DimensionOutlierKind] = [],
        widthDeviation: Double = 0,
        heightDeviation: Double = 0,
        linePitchDeviation: Double? = nil,
        scaleMismatch: Bool = false,
        proposedCanvasSize: Size2I? = nil,
        groupIndex: Int? = nil
    ) {
        self.dimensionClass = dimensionClass
        self.kinds = kinds
        self.widthDeviation = widthDeviation
        self.heightDeviation = heightDeviation
        self.linePitchDeviation = linePitchDeviation
        self.scaleMismatch = scaleMismatch
        self.proposedCanvasSize = proposedCanvasSize
        self.groupIndex = groupIndex
    }
}

/// Book-level summary of the consensus-dimension clustering.
public struct DimensionConsensusSummary: Sendable, Equatable, Codable {
    /// `false` when classification was off, or the book had too few pages for statistics.
    public var applied: Bool
    /// `true` when so many pages differed that size alone was not trusted (only content overflow and overrides count).
    public var ambiguous: Bool
    /// Why classification did not run or was limited (`nil` otherwise).
    public var note: String?
    public var medianPageSize: Size2I
    public var canonicalPageCount: Int
    public var outlierPageCount: Int
    /// Output page indices of the outliers.
    public var outlierPages: [Int]
    /// Outliers of similar size, listed by output page index (record only).
    public var outlierGroups: [[Int]]
    /// Source page indices that were not split because they are landscape in a portrait book.
    public var splitVetoedSourcePages: [Int]
    /// The relative tolerance used.
    public var toleranceFraction: Double

    public init(
        applied: Bool,
        ambiguous: Bool = false,
        note: String? = nil,
        medianPageSize: Size2I = Size2I(width: 0, height: 0),
        canonicalPageCount: Int = 0,
        outlierPageCount: Int = 0,
        outlierPages: [Int] = [],
        outlierGroups: [[Int]] = [],
        splitVetoedSourcePages: [Int] = [],
        toleranceFraction: Double = 0.08
    ) {
        self.applied = applied
        self.ambiguous = ambiguous
        self.note = note
        self.medianPageSize = medianPageSize
        self.canonicalPageCount = canonicalPageCount
        self.outlierPageCount = outlierPageCount
        self.outlierPages = outlierPages
        self.outlierGroups = outlierGroups
        self.splitVetoedSourcePages = splitVetoedSourcePages
        self.toleranceFraction = toleranceFraction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applied = try c.decodeIfPresent(Bool.self, forKey: .applied) ?? false
        ambiguous = try c.decodeIfPresent(Bool.self, forKey: .ambiguous) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
        medianPageSize = try c.decodeIfPresent(Size2I.self, forKey: .medianPageSize) ?? Size2I(width: 0, height: 0)
        canonicalPageCount = try c.decodeIfPresent(Int.self, forKey: .canonicalPageCount) ?? 0
        outlierPageCount = try c.decodeIfPresent(Int.self, forKey: .outlierPageCount) ?? 0
        outlierPages = try c.decodeIfPresent([Int].self, forKey: .outlierPages) ?? []
        outlierGroups = try c.decodeIfPresent([[Int]].self, forKey: .outlierGroups) ?? []
        splitVetoedSourcePages = try c.decodeIfPresent([Int].self, forKey: .splitVetoedSourcePages) ?? []
        toleranceFraction = try c.decodeIfPresent(Double.self, forKey: .toleranceFraction) ?? 0.08
    }
}

/// Groups the processed pages of a book into canonical body pages and dimensional outliers.
///
/// A page is an outlier when its width or height differs from the book's median by more than the larger of
/// two margins: the spread of the book's page sizes (`iqrMultiplier` times the interquartile range) and a
/// fixed fraction of the median (`toleranceFraction`, 8% by default, above the 5% of ordinary cropping
/// variation). Landscape pages in a portrait book, and pages whose text block is larger than the book's, are
/// outliers too. The pass is pure statistics: it reads sizes and boxes, never pixels.
public struct DimensionConsensus: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Master switch (`--dimension-consensus auto|off`).
        public var enabled: Bool
        /// Fixed relative tolerance on the page width and height (default `0.08`).
        public var toleranceFraction: Double
        /// Multiplier on the interquartile range of the page sizes (default `1.5`).
        public var iqrMultiplier: Double
        /// Fewest pages for which any classification happens (default `5`).
        public var minimumPageCount: Int
        /// When more than this fraction of pages differ by size, or the sizes spread wider than this fraction of
        /// the median, the sizes are not trusted (default `0.25`).
        public var maxOutlierFraction: Double
        /// Relative line-pitch difference that flags a scale mismatch (default `0.20`).
        public var scaleMismatchTolerance: Double
        /// A text block this fraction beyond the book's 85th-percentile text block overflows (default `0.15`).
        public var contentOverflowFraction: Double
        /// Fraction of portrait scans needed before a landscape scan is kept whole instead of split (default `0.75`).
        public var portraitBookFraction: Double

        public init(
            enabled: Bool = true,
            toleranceFraction: Double = 0.08,
            iqrMultiplier: Double = 1.5,
            minimumPageCount: Int = 5,
            maxOutlierFraction: Double = 0.25,
            scaleMismatchTolerance: Double = 0.20,
            contentOverflowFraction: Double = 0.15,
            portraitBookFraction: Double = 0.75
        ) {
            self.enabled = enabled
            self.toleranceFraction = min(max(0.02, toleranceFraction), 0.50)
            self.iqrMultiplier = min(max(0.5, iqrMultiplier), 5.0)
            self.minimumPageCount = max(3, minimumPageCount)
            self.maxOutlierFraction = min(max(0.05, maxOutlierFraction), 0.90)
            self.scaleMismatchTolerance = min(max(0.05, scaleMismatchTolerance), 1.0)
            self.contentOverflowFraction = min(max(0.02, contentOverflowFraction), 1.0)
            self.portraitBookFraction = min(max(0.5, portraitBookFraction), 1.0)
        }
    }

    /// What the classifier knows about one processed page.
    public struct PageInput: Sendable, Equatable {
        public var pageIndex: Int
        public var pageSize: Size2I
        public var contentBox: Rect2I?
        /// Body line pitch from the running-header analysis, when measured.
        public var bodyLinePitch: Double?
        /// Manual override of the class (`nil` is automatic).
        public var forcedClass: DimensionClass?

        public init(pageIndex: Int, pageSize: Size2I, contentBox: Rect2I? = nil, bodyLinePitch: Double? = nil, forcedClass: DimensionClass? = nil) {
            self.pageIndex = pageIndex
            self.pageSize = pageSize
            self.contentBox = contentBox
            self.bodyLinePitch = bodyLinePitch
            self.forcedClass = forcedClass
        }
    }

    public struct Result: Sendable, Equatable {
        /// One record per input page, in input order.
        public var records: [PageDimensionRecord]
        public var summary: DimensionConsensusSummary

        /// Page indices (`PageInput.pageIndex`) classified as outliers.
        public var outlierPageIndices: Set<Int> {
            Set(summary.outlierPages)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Source scans that must not be split: landscape scans in a book whose scans are mostly portrait.
    ///
    /// - Returns: Indices into `sizes` (empty unless the book is portrait and large enough).
    public func splitVetoes(sourceSizes sizes: [Size2I]) -> [Int] {
        guard configuration.enabled, sizes.count >= configuration.minimumPageCount else { return [] }
        let portrait = sizes.filter { $0.height >= $0.width }.count
        guard Double(portrait) >= configuration.portraitBookFraction * Double(sizes.count) else { return [] }
        return sizes.indices.filter { sizes[$0].width > sizes[$0].height }
    }

    /// Classifies every page.
    public func classify(pages: [PageInput]) -> Result {
        let neutral = pages.map { _ in PageDimensionRecord() }
        func unapplied(_ note: String) -> Result {
            Result(
                records: neutral,
                summary: DimensionConsensusSummary(
                    applied: false,
                    note: note,
                    medianPageSize: Self.medianSize(pages),
                    canonicalPageCount: pages.count,
                    toleranceFraction: configuration.toleranceFraction
                )
            )
        }
        guard configuration.enabled else { return unapplied("disabled") }
        guard pages.count >= configuration.minimumPageCount else { return unapplied("tooFewPages") }

        let widths = pages.map { Double($0.pageSize.width) }
        let heights = pages.map { Double($0.pageSize.height) }
        let medW = Self.percentile(widths, 0.5)
        let medH = Self.percentile(heights, 0.5)
        guard medW > 0, medH > 0 else { return unapplied("emptyPages") }
        let thresholdW = max(configuration.iqrMultiplier * Self.iqr(widths) / medW, configuration.toleranceFraction)
        let thresholdH = max(configuration.iqrMultiplier * Self.iqr(heights) / medH, configuration.toleranceFraction)
        let medianPortrait = medH >= medW

        // Size-based kinds, per page.
        var kinds: [[DimensionOutlierKind]] = pages.map { page in
            var found: [DimensionOutlierKind] = []
            let dw = (Double(page.pageSize.width) - medW) / medW
            let dh = (Double(page.pageSize.height) - medH) / medH
            if abs(dw) > thresholdW || abs(dh) > thresholdH {
                if dw > thresholdW || dh > thresholdH { found.append(.oversize) }
                if dw < -thresholdW || dh < -thresholdH { found.append(.undersize) }
            }
            let portrait = page.pageSize.height >= page.pageSize.width
            if portrait != medianPortrait { found.append(.orientation) }
            return found
        }

        // A book where many pages differ by size has no trustworthy consensus.
        let sizeOutliers = kinds.filter { !$0.isEmpty }.count
        var ambiguous = false
        // Either many pages differ, or the sizes are so spread out (a large second size group) that the
        // interquartile range itself is wider than `maxOutlierFraction` of the median.
        let sizesSpread = thresholdW > configuration.maxOutlierFraction || thresholdH > configuration.maxOutlierFraction
        if sizesSpread || Double(sizeOutliers) > configuration.maxOutlierFraction * Double(pages.count) {
            ambiguous = true
            kinds = kinds.map { _ in [] }
        }

        // Content overflow: a text block much larger than the book's, on a page of normal size.
        let referenceBoxes = pages.indices.compactMap { i -> Rect2I? in
            guard kinds[i].isEmpty, let box = pages[i].contentBox, !box.isEmpty,
                  Double(box.width) >= 0.35 * medW else { return nil }
            return box
        }
        if referenceBoxes.count >= 3 {
            let refW = Self.percentile(referenceBoxes.map { Double($0.width) }, 0.85)
            let refH = Self.percentile(referenceBoxes.map { Double($0.height) }, 0.85)
            let limit = 1.0 + configuration.contentOverflowFraction
            for i in pages.indices where kinds[i].isEmpty {
                if let box = pages[i].contentBox, Double(box.width) > refW * limit || Double(box.height) > refH * limit {
                    kinds[i].append(.contentOverflow)
                }
            }
        }

        // Scale mismatch from the body line pitch (flag only).
        let pitches = pages.compactMap(\.bodyLinePitch).filter { $0 > 0 }
        let medPitch: Double? = pitches.count >= 3 ? Self.percentile(pitches, 0.5) : nil

        var records: [PageDimensionRecord] = []
        records.reserveCapacity(pages.count)
        for (i, page) in pages.enumerated() {
            var pageKinds = kinds[i]
            if let forced = page.forcedClass {
                pageKinds = forced == .outlier ? (pageKinds.isEmpty ? [.manual] : pageKinds) : []
            }
            let isOutlier = !pageKinds.isEmpty
            let pitchDeviation: Double? = {
                guard let pitch = page.bodyLinePitch, pitch > 0, let medPitch else { return nil }
                return (pitch - medPitch) / medPitch
            }()
            var proposed: Size2I?
            if isOutlier {
                var w = page.pageSize.width
                var h = page.pageSize.height
                if let box = page.contentBox { w = max(w, box.width); h = max(h, box.height) }
                proposed = Size2I(width: w, height: h)
            }
            records.append(PageDimensionRecord(
                dimensionClass: isOutlier ? .outlier : .canonical,
                kinds: pageKinds,
                widthDeviation: (Double(page.pageSize.width) - medW) / medW,
                heightDeviation: (Double(page.pageSize.height) - medH) / medH,
                linePitchDeviation: pitchDeviation,
                scaleMismatch: pitchDeviation.map { abs($0) > configuration.scaleMismatchTolerance } ?? false,
                proposedCanvasSize: proposed
            ))
        }

        // Group outliers of similar size (record only).
        var groups: [[Int]] = []
        var groupSizes: [Size2I] = []
        for (i, record) in records.enumerated() where record.dimensionClass == .outlier {
            guard let size = record.proposedCanvasSize else { continue }
            if let g = groupSizes.firstIndex(where: { Self.similar($0, size) }) {
                groups[g].append(pages[i].pageIndex)
            } else {
                groups.append([pages[i].pageIndex])
                groupSizes.append(size)
            }
        }
        let sharedGroups = groups.filter { $0.count >= 2 }
        for (gi, group) in sharedGroups.enumerated() {
            for index in group {
                if let i = pages.firstIndex(where: { $0.pageIndex == index }) { records[i].groupIndex = gi }
            }
        }

        let outlierPages = pages.indices.filter { records[$0].dimensionClass == .outlier }.map { pages[$0].pageIndex }
        let summary = DimensionConsensusSummary(
            applied: true,
            ambiguous: ambiguous,
            note: ambiguous ? "manySizeOutliers" : nil,
            medianPageSize: Size2I(width: Int(medW.rounded()), height: Int(medH.rounded())),
            canonicalPageCount: pages.count - outlierPages.count,
            outlierPageCount: outlierPages.count,
            outlierPages: outlierPages,
            outlierGroups: sharedGroups,
            toleranceFraction: configuration.toleranceFraction
        )
        return Result(records: records, summary: summary)
    }

    // MARK: - Helpers

    private static func similar(_ a: Size2I, _ b: Size2I) -> Bool {
        func close(_ x: Int, _ y: Int) -> Bool { abs(Double(x - y)) <= 0.05 * Double(max(x, y, 1)) }
        return close(a.width, b.width) && close(a.height, b.height)
    }

    private static func medianSize(_ pages: [PageInput]) -> Size2I {
        guard !pages.isEmpty else { return Size2I(width: 0, height: 0) }
        return Size2I(
            width: Int(percentile(pages.map { Double($0.pageSize.width) }, 0.5).rounded()),
            height: Int(percentile(pages.map { Double($0.pageSize.height) }, 0.5).rounded())
        )
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let pos = min(max(0, p), 1) * Double(sorted.count - 1)
        let lo = Int(pos.rounded(.down)), hi = Int(pos.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
    }

    private static func iqr(_ values: [Double]) -> Double {
        percentile(values, 0.75) - percentile(values, 0.25)
    }
}
