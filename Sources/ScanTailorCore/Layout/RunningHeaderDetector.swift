import ScanTailorContracts

/// Per-page policy for running-header detection, stored in the manifest's manual overrides.
public enum RunningHeaderPolicy: String, Sendable, Equatable, Codable, CaseIterable {
    /// Use the book-wide clustering decision.
    case automatic
    /// Treat the page's top text line as a running header, even outside the book-wide cluster.
    case present
    /// Treat the page as headerless and anchor it on its first body baseline.
    case absent
}

/// The vertical registration anchor detected for one page.
///
/// All coordinates are in the page's pass-1 coordinate frame at the processing DPI (after
/// splitting, deskew, and dewarping, before canonical framing). The anchor is the running
/// header's baseline when the page carries a recurring header, otherwise the baseline of the
/// first body text line (WHITE_PAPER release criterion 4).
public struct PageTopAnchor: Sendable, Equatable, Codable {
    /// What the anchor line is.
    public enum Kind: String, Sendable, Equatable, Codable {
        /// A running header confirmed by book-wide clustering (or a `present` override).
        case runningHeader
        /// The first body text line (no running header on this page).
        case bodyBaseline
        /// No text lines were found (blank or graphics-only page).
        case none
    }

    /// What the anchor line is.
    public var kind: Kind
    /// Y coordinate of the anchor baseline (`nil` for `.none`).
    public var anchorY: Int?
    /// Bounds of the running header line, including any rule beneath it.
    public var headerBox: Rect2I?
    /// Baseline of the running header line.
    public var headerBaselineY: Int?
    /// Bounds of a page number (folio) found in the header line.
    public var folioBox: Rect2I?
    /// Bounds of a page number (folio) found alone at the foot of the page.
    public var footerFolioBox: Rect2I?
    /// Top edge of the first body text line.
    public var firstBodyLineTopY: Int?
    /// Baseline of the first body text line.
    public var firstBodyBaselineY: Int?
    /// Confidence in `[0, 1]`.
    public var confidence: Double
    /// Diagnostic flags (for example `header:outOfCluster`, `titleLike`, `sinkage`, `book:tooFewPages`).
    public var flags: [String]

    public init(
        kind: Kind,
        anchorY: Int? = nil,
        headerBox: Rect2I? = nil,
        headerBaselineY: Int? = nil,
        folioBox: Rect2I? = nil,
        footerFolioBox: Rect2I? = nil,
        firstBodyLineTopY: Int? = nil,
        firstBodyBaselineY: Int? = nil,
        confidence: Double,
        flags: [String] = []
    ) {
        self.kind = kind
        self.anchorY = anchorY
        self.headerBox = headerBox
        self.headerBaselineY = headerBaselineY
        self.folioBox = folioBox
        self.footerFolioBox = footerFolioBox
        self.firstBodyLineTopY = firstBodyLineTopY
        self.firstBodyBaselineY = firstBodyBaselineY
        self.confidence = min(max(0.0, confidence), 1.0)
        self.flags = flags
    }
}

/// Book-wide running-header statistics, one summary per logical page side.
public struct RunningHeaderModel: Sendable, Equatable, Codable {
    /// Statistics for one logical page side (`verso`, `recto`, or `single`).
    public struct SideSummary: Sendable, Equatable, Codable {
        /// Logical page side.
        public var side: MarginHarmonizer.PageSide
        /// Pages on this side with at least one text line.
        public var pageCount: Int
        /// Pages on this side anchored on a running header.
        public var headerPageCount: Int
        /// Pages on this side with a folio alone at the foot.
        public var footerFolioCount: Int
        /// Median baseline-to-baseline pitch of body lines, in pixels.
        public var bodyLinePitchPixels: Double?
        /// Median core (x-height-like) height of body lines, in pixels.
        public var bodyCoreHeightPixels: Double?
        /// Cluster center: header-baseline to first-body-baseline distance, in body line pitches.
        public var headerOffsetPitches: Double?
        /// Cluster center: header core height divided by body core height.
        public var headerHeightRatio: Double?
        /// Whether a recurring running header was confirmed on this side.
        public var hasRunningHeaders: Bool
        /// Diagnostic flags (for example `book:tooFewPages`).
        public var flags: [String]

        public init(
            side: MarginHarmonizer.PageSide,
            pageCount: Int,
            headerPageCount: Int,
            footerFolioCount: Int,
            bodyLinePitchPixels: Double?,
            bodyCoreHeightPixels: Double?,
            headerOffsetPitches: Double?,
            headerHeightRatio: Double?,
            hasRunningHeaders: Bool,
            flags: [String] = []
        ) {
            self.side = side
            self.pageCount = pageCount
            self.headerPageCount = headerPageCount
            self.footerFolioCount = footerFolioCount
            self.bodyLinePitchPixels = bodyLinePitchPixels
            self.bodyCoreHeightPixels = bodyCoreHeightPixels
            self.headerOffsetPitches = headerOffsetPitches
            self.headerHeightRatio = headerHeightRatio
            self.hasRunningHeaders = hasRunningHeaders
            self.flags = flags
        }
    }

    /// Per-side summaries in `verso`, `recto`, `single` order (sides with no pages are omitted).
    public var sides: [SideSummary]

    public init(sides: [SideSummary]) {
        self.sides = sides
    }
}

/// Detects running headers, folios, and the first body baseline on every page of a book.
///
/// Works in two stages:
/// 1. ``profilePage(_:region:pageIndex:side:)`` splits a page's content box into text lines with
///    a row ink profile and measures each line's baseline and core height.
/// 2. ``analyzeBook(_:policies:)`` groups pages by logical side and clusters the top lines that
///    stand apart from the body. A top line is a running header when its distance to the body
///    (in body line pitches) and its height (relative to body text) recur across the book.
///
/// Geometry only: no OCR is needed, so results are deterministic. Detection never changes pixels.
public struct RunningHeaderDetector: Sendable {
    /// Tuning parameters. All ratios are scale-free, so no DPI is needed.
    public struct Configuration: Sendable, Equatable, Codable {
        /// Minimum black pixels for a row to count as inked.
        public var minRowInkPixels: Int
        /// Minimum header-to-body baseline distance, in body line pitches, for a top line to be a header candidate.
        public var minHeaderSeparationPitches: Double
        /// Maximum header core height relative to body core height; taller top lines are titles.
        public var maxHeaderHeightRatio: Double
        /// Minimum header core height relative to body core height.
        public var minHeaderHeightRatio: Double
        /// Cluster tolerance on the header offset, in body line pitches.
        public var offsetTolerancePitches: Double
        /// Cluster tolerance on the header height ratio.
        public var heightRatioTolerance: Double
        /// Minimum pages in a cluster for it to confirm running headers.
        public var minClusterPages: Int
        /// Minimum fraction of a side's text pages in a cluster for it to confirm running headers.
        public var minClusterFraction: Double
        /// Maximum folio width, in multiples of the folio's own core height.
        public var maxFolioWidthCoreHeights: Double
        /// Minimum horizontal gap separating a folio from header text, in multiples of the header's core height.
        public var minFolioGapCoreHeights: Double
        /// Minimum distance above a footer folio, in body line pitches.
        public var minFooterSeparationPitches: Double
        /// A page whose text starts this fraction of the page height below its side's median start is flagged `sinkage`.
        public var sinkageFraction: Double

        public init(
            minRowInkPixels: Int = 1,
            minHeaderSeparationPitches: Double = 1.5,
            maxHeaderHeightRatio: Double = 1.75,
            minHeaderHeightRatio: Double = 0.35,
            offsetTolerancePitches: Double = 0.35,
            heightRatioTolerance: Double = 0.20,
            minClusterPages: Int = 3,
            minClusterFraction: Double = 0.30,
            maxFolioWidthCoreHeights: Double = 4.5,
            minFolioGapCoreHeights: Double = 2.5,
            minFooterSeparationPitches: Double = 1.5,
            sinkageFraction: Double = 0.15
        ) {
            self.minRowInkPixels = max(1, minRowInkPixels)
            self.minHeaderSeparationPitches = min(max(1.05, minHeaderSeparationPitches), 6.0)
            self.maxHeaderHeightRatio = min(max(1.0, maxHeaderHeightRatio), 4.0)
            self.minHeaderHeightRatio = min(max(0.05, minHeaderHeightRatio), 1.0)
            self.offsetTolerancePitches = min(max(0.05, offsetTolerancePitches), 3.0)
            self.heightRatioTolerance = min(max(0.02, heightRatioTolerance), 1.0)
            self.minClusterPages = max(2, minClusterPages)
            self.minClusterFraction = min(max(0.0, minClusterFraction), 1.0)
            self.maxFolioWidthCoreHeights = min(max(1.0, maxFolioWidthCoreHeights), 20.0)
            self.minFolioGapCoreHeights = min(max(0.5, minFolioGapCoreHeights), 20.0)
            self.minFooterSeparationPitches = min(max(1.05, minFooterSeparationPitches), 6.0)
            self.sinkageFraction = min(max(0.01, sinkageFraction), 1.0)
        }
    }

    /// One horizontal text line found by the row ink profile.
    public struct TextLine: Sendable, Equatable, Codable {
        /// Exact bounds of the line's ink (including a merged rule, if any).
        public var bounds: Rect2I
        /// Baseline: the first row below the line's dense core.
        public var baselineY: Int
        /// Height of the dense core (x-height for lowercase text, cap height for capitals or digits).
        public var coreHeight: Int
        /// Black pixels in the line.
        public var inkPixels: Int
        /// Whether a thin horizontal rule was merged into this line.
        public var hasRule: Bool

        public init(bounds: Rect2I, baselineY: Int, coreHeight: Int, inkPixels: Int, hasRule: Bool = false) {
            self.bounds = bounds
            self.baselineY = baselineY
            self.coreHeight = coreHeight
            self.inkPixels = inkPixels
            self.hasRule = hasRule
        }
    }

    /// Text lines and body metrics measured on one page.
    public struct PageLineProfile: Sendable, Equatable {
        /// Output page index.
        public var pageIndex: Int
        /// Logical page side.
        public var side: MarginHarmonizer.PageSide
        /// Page size in pixels.
        public var pageSize: Size2I
        /// Text lines, top to bottom.
        public var lines: [TextLine]
        /// Ink segments of the top line, split at wide gaps (used for folio detection).
        public var firstLineSegments: [Rect2I]
        /// Ink segments of the bottom line, split at wide gaps (used for folio detection).
        public var lastLineSegments: [Rect2I]
        /// Median baseline pitch of the lines below the top line (`nil` with fewer than three lines).
        public var bodyLinePitch: Double?
        /// Median core height of the lines below the top line (`nil` with fewer than two lines).
        public var bodyCoreHeight: Double?

        public init(
            pageIndex: Int,
            side: MarginHarmonizer.PageSide,
            pageSize: Size2I,
            lines: [TextLine],
            firstLineSegments: [Rect2I] = [],
            lastLineSegments: [Rect2I] = [],
            bodyLinePitch: Double? = nil,
            bodyCoreHeight: Double? = nil
        ) {
            self.pageIndex = pageIndex
            self.side = side
            self.pageSize = pageSize
            self.lines = lines
            self.firstLineSegments = firstLineSegments
            self.lastLineSegments = lastLineSegments
            self.bodyLinePitch = bodyLinePitch
            self.bodyCoreHeight = bodyCoreHeight
        }
    }

    /// Result of book-wide analysis.
    public struct BookAnalysis: Sendable, Equatable {
        /// One anchor per input profile, in input order.
        public var anchors: [PageTopAnchor]
        /// Book-wide statistics.
        public var model: RunningHeaderModel

        public init(anchors: [PageTopAnchor], model: RunningHeaderModel) {
            self.anchors = anchors
            self.model = model
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Stage 1: Per-Page Line Profile

    /// Splits the page's content region into text lines and measures them.
    ///
    /// - Parameters:
    ///   - bitmap: Cleaned 1-bit page.
    ///   - region: Content box to profile (`nil` or empty yields a profile with no lines).
    ///   - pageIndex: Output page index, carried into the profile.
    ///   - side: Logical page side, carried into the profile.
    /// - Returns: The page's line profile.
    public func profilePage(
        _ bitmap: borrowing BinaryBitmap,
        region: Rect2I?,
        pageIndex: Int,
        side: MarginHarmonizer.PageSide
    ) -> PageLineProfile {
        let pageSize = Size2I(width: bitmap.width, height: bitmap.height)
        let empty = PageLineProfile(pageIndex: pageIndex, side: side, pageSize: pageSize, lines: [])
        guard let region, let area = region.clamped(to: Rect2I(size: pageSize)), area.width > 0, area.height > 0 else {
            return empty
        }

        let wordsPerRow = bitmap.wordsPerRow
        let rowInk = bitmap.withUnsafeWords { words in
            (area.minY..<area.maxY).map { y in
                Self.rowInk(words, wordsPerRow: wordsPerRow, y: y, minX: area.minX, maxX: area.maxX)
            }
        }

        // Raw bands: maximal runs of inked rows.
        var spans: [Range<Int>] = []
        var start: Int? = nil
        for (offset, ink) in rowInk.enumerated() {
            let y = area.minY + offset
            if ink >= configuration.minRowInkPixels {
                if start == nil { start = y }
            } else if let s = start {
                spans.append(s..<y)
                start = nil
            }
        }
        if let s = start { spans.append(s..<area.maxY) }
        guard !spans.isEmpty else { return empty }

        let ink: (Int) -> Int = { rowInk[$0 - area.minY] }
        spans = Self.splitMergedLines(spans, ink: ink)

        // Measure, then fold accents and rules into their neighbouring lines.
        let lines = bitmap.withUnsafeWords { words in
            let bands = spans.compactMap {
                Self.measureBand($0, ink: ink, words: words, wordsPerRow: wordsPerRow, area: area)
            }
            return Self.foldSmallBands(bands, ink: ink, words: words, wordsPerRow: wordsPerRow, area: area)
        }
        guard !lines.isEmpty else { return empty }

        let below = lines.dropFirst()
        let pitches = zip(below, below.dropFirst()).map { Double($1.baselineY - $0.baselineY) }
        let bodyPitch = Self.median(pitches)
        let bodyCore = Self.median(below.map { Double($0.coreHeight) })

        let first = lines[0]
        let firstSegments = Self.segments(of: first, in: bitmap, gapCoreHeights: configuration.minFolioGapCoreHeights)
        let lastSegments = lines.count > 1
            ? Self.segments(of: lines[lines.count - 1], in: bitmap, gapCoreHeights: configuration.minFolioGapCoreHeights)
            : firstSegments

        return PageLineProfile(
            pageIndex: pageIndex,
            side: side,
            pageSize: pageSize,
            lines: lines,
            firstLineSegments: firstSegments,
            lastLineSegments: lastSegments,
            bodyLinePitch: bodyPitch,
            bodyCoreHeight: bodyCore
        )
    }

    // MARK: - Stage 2: Book-Wide Clustering

    /// Clusters top lines across the book and assigns each page its top anchor.
    ///
    /// - Parameters:
    ///   - profiles: Per-page profiles from ``profilePage(_:region:pageIndex:side:)``.
    ///   - policies: Per-page overrides keyed by `PageLineProfile.pageIndex`.
    /// - Returns: One anchor per profile (input order) and the book-wide model.
    public func analyzeBook(
        _ profiles: [PageLineProfile],
        policies: [Int: RunningHeaderPolicy] = [:]
    ) -> BookAnalysis {
        var anchors = [PageTopAnchor](repeating: PageTopAnchor(kind: .none, confidence: 1.0, flags: ["noText"]), count: profiles.count)
        var summaries: [RunningHeaderModel.SideSummary] = []

        for side in [MarginHarmonizer.PageSide.verso, .recto, .single] {
            let indices = profiles.indices.filter { profiles[$0].side == side }
            guard !indices.isEmpty else { continue }
            let textIndices = indices.filter { !profiles[$0].lines.isEmpty }

            let pitchG = Self.median(textIndices.compactMap { profiles[$0].bodyLinePitch })
            let coreG = Self.median(textIndices.compactMap { profiles[$0].bodyCoreHeight })
                ?? Self.median(textIndices.flatMap { profiles[$0].lines.map { Double($0.coreHeight) } })

            // Measure each page's top line against its body.
            var measures: [Int: Measure] = [:]
            for i in textIndices {
                measures[i] = measure(profiles[i], groupPitch: pitchG, groupCore: coreG)
            }

            let candidates = textIndices.filter { measures[$0]?.isCandidate == true }
            let tooFewPages = textIndices.count < configuration.minClusterPages
            var members: Set<Int> = []
            var center: (offset: Double, ratio: Double)? = nil
            if tooFewPages {
                members = Set(candidates)
                if !candidates.isEmpty {
                    center = (
                        Self.median(candidates.compactMap { measures[$0]?.offset }) ?? 0,
                        Self.median(candidates.compactMap { measures[$0]?.ratio }) ?? 0
                    )
                }
            } else if let cluster = cluster(candidates.compactMap { i in measures[i].map { (i, $0) } }) {
                let supported = cluster.members.count >= configuration.minClusterPages
                    && Double(cluster.members.count) >= configuration.minClusterFraction * Double(textIndices.count)
                if supported {
                    members = cluster.members
                    center = cluster.center
                }
            }
            let support = textIndices.isEmpty ? 0 : Double(members.count) / Double(textIndices.count)

            let startFractions = textIndices.map { Double(profiles[$0].lines[0].bounds.minY) / Double(max(1, profiles[$0].pageSize.height)) }
            let medianStart = Self.median(startFractions) ?? 0

            var headerCount = 0
            var footerCount = 0
            for i in textIndices {
                let profile = profiles[i]
                guard let m = measures[i] else { continue }
                var flags: [String] = []
                if tooFewPages { flags.append("book:tooFewPages") }
                if m.isTitleLike { flags.append("titleLike") }
                if Double(profile.lines[0].bounds.minY) / Double(max(1, profile.pageSize.height)) > medianStart + configuration.sinkageFraction {
                    flags.append("sinkage")
                }

                let policy = policies[profile.pageIndex] ?? .automatic
                let isHeader: Bool
                let confidence: Double
                switch policy {
                case .present:
                    isHeader = true
                    confidence = 1.0
                    flags.append("override:present")
                case .absent:
                    isHeader = false
                    confidence = 1.0
                    flags.append("override:absent")
                case .automatic:
                    if members.contains(i), let center {
                        isHeader = true
                        let distance = max(
                            abs(m.offset - center.offset) / configuration.offsetTolerancePitches,
                            abs(m.ratio - center.ratio) / configuration.heightRatioTolerance
                        )
                        let base = tooFewPages ? 0.45 : 0.6 + 0.4 * support
                        confidence = base * (1.0 - 0.5 * min(1.0, distance))
                    } else {
                        isHeader = false
                        if m.isCandidate && center != nil {
                            flags.append("header:outOfCluster")
                            confidence = 0.6
                        } else if m.isUndersized {
                            flags.append("header:sizeMismatch")
                            confidence = 0.6
                        } else if m.isTitleLike {
                            confidence = 0.6
                        } else {
                            confidence = center == nil ? 0.85 : 0.8
                        }
                    }
                }

                let lines = profile.lines
                let footer = footerFolio(profile, pitch: m.pitch, excludingHeader: isHeader)
                if footer != nil { footerCount += 1 }
                let bodyIndex = isHeader ? 1 : 0
                let lastBodyIndex = footer == nil ? lines.count - 1 : lines.count - 2
                let body = bodyIndex <= lastBodyIndex ? lines[bodyIndex] : nil

                if isHeader {
                    headerCount += 1
                    let header = lines[0]
                    anchors[i] = PageTopAnchor(
                        kind: .runningHeader,
                        anchorY: header.baselineY,
                        headerBox: header.bounds,
                        headerBaselineY: header.baselineY,
                        folioBox: headerFolio(profile),
                        footerFolioBox: footer,
                        firstBodyLineTopY: body?.bounds.minY,
                        firstBodyBaselineY: body?.baselineY,
                        confidence: confidence,
                        flags: flags
                    )
                } else if let body {
                    anchors[i] = PageTopAnchor(
                        kind: .bodyBaseline,
                        anchorY: body.baselineY,
                        footerFolioBox: footer,
                        firstBodyLineTopY: body.bounds.minY,
                        firstBodyBaselineY: body.baselineY,
                        confidence: confidence,
                        flags: flags
                    )
                } else {
                    anchors[i] = PageTopAnchor(kind: .none, footerFolioBox: footer, confidence: 0.7, flags: flags + ["folioOnly"])
                }
            }

            summaries.append(
                RunningHeaderModel.SideSummary(
                    side: side,
                    pageCount: textIndices.count,
                    headerPageCount: headerCount,
                    footerFolioCount: footerCount,
                    bodyLinePitchPixels: pitchG,
                    bodyCoreHeightPixels: coreG,
                    headerOffsetPitches: center?.offset,
                    headerHeightRatio: center?.ratio,
                    hasRunningHeaders: !members.isEmpty,
                    flags: tooFewPages ? ["book:tooFewPages"] : []
                )
            )
        }

        return BookAnalysis(anchors: anchors, model: RunningHeaderModel(sides: summaries))
    }

    // MARK: - Book Analysis Helpers

    /// How a page's top line relates to its body text.
    private struct Measure {
        /// Header-baseline to next-baseline distance, in body pitches.
        var offset: Double
        /// Top line core height over body core height.
        var ratio: Double
        /// Body pitch used for this page, in pixels.
        var pitch: Double?
        var isCandidate: Bool
        var isTitleLike: Bool
        var isUndersized: Bool
    }

    private func measure(_ profile: PageLineProfile, groupPitch: Double?, groupCore: Double?) -> Measure {
        let lines = profile.lines
        let pitch = profile.bodyLinePitch ?? groupPitch
        let core = profile.bodyCoreHeight ?? groupCore
        guard lines.count >= 2, let pitch, pitch > 0, let core, core > 0 else {
            let ratio = core.map { Double(lines[0].coreHeight) / max(1, $0) } ?? 1.0
            return Measure(offset: 0, ratio: ratio, pitch: pitch, isCandidate: false,
                           isTitleLike: ratio > configuration.maxHeaderHeightRatio, isUndersized: false)
        }
        let offset = Double(lines[1].baselineY - lines[0].baselineY) / pitch
        let ratio = Double(lines[0].coreHeight) / core
        let separated = offset >= configuration.minHeaderSeparationPitches
        let titleLike = ratio > configuration.maxHeaderHeightRatio
        let undersized = ratio < configuration.minHeaderHeightRatio
        return Measure(
            offset: offset,
            ratio: ratio,
            pitch: pitch,
            isCandidate: separated && !titleLike && !undersized,
            isTitleLike: titleLike,
            isUndersized: separated && undersized
        )
    }

    /// Mode-seeking cluster: seed at the candidate with the most neighbours, then gather around the members' median.
    private func cluster(_ points: [(index: Int, measure: Measure)]) -> (members: Set<Int>, center: (offset: Double, ratio: Double))? {
        guard !points.isEmpty else { return nil }
        func distance(_ a: (Double, Double), _ b: (Double, Double)) -> Double {
            max(abs(a.0 - b.0) / configuration.offsetTolerancePitches, abs(a.1 - b.1) / configuration.heightRatioTolerance)
        }
        let coords = points.map { ($0.measure.offset, $0.measure.ratio) }
        var bestSeed = 0
        var bestCount = -1
        for (s, seed) in coords.enumerated() {
            let count = coords.filter { distance($0, seed) <= 1.0 }.count
            if count > bestCount {
                bestCount = count
                bestSeed = s
            }
        }
        let neighbours = coords.filter { distance($0, coords[bestSeed]) <= 1.0 }
        let center = (Self.median(neighbours.map(\.0)) ?? coords[bestSeed].0, Self.median(neighbours.map(\.1)) ?? coords[bestSeed].1)
        let members = Set(points.indices.filter { distance(coords[$0], center) <= 1.0 }.map { points[$0].index })
        return (members, center)
    }

    /// A folio at the outer end of the header line, or a header line that is only a folio.
    private func headerFolio(_ profile: PageLineProfile) -> Rect2I? {
        let header = profile.lines[0]
        let maxWidth = configuration.maxFolioWidthCoreHeights * Double(max(1, header.coreHeight))
        let segments = profile.firstLineSegments
        if segments.count <= 1 {
            return Double(header.bounds.width) <= maxWidth ? header.bounds : nil
        }
        let fits: (Rect2I) -> Bool = { Double($0.width) <= maxWidth }
        switch profile.side {
        case .verso:
            return fits(segments[0]) ? segments[0] : nil
        case .recto:
            return fits(segments[segments.count - 1]) ? segments[segments.count - 1] : nil
        case .single:
            let ends = [segments[0], segments[segments.count - 1]].filter(fits)
            return ends.min { $0.width < $1.width }
        }
    }

    /// A narrow line alone at the foot of the page, well below the body.
    private func footerFolio(_ profile: PageLineProfile, pitch: Double?, excludingHeader: Bool) -> Rect2I? {
        let lines = profile.lines
        let minCount = excludingHeader ? 3 : 2
        guard lines.count >= minCount, let pitch, pitch > 0 else { return nil }
        let last = lines[lines.count - 1]
        let previous = lines[lines.count - 2]
        guard Double(last.baselineY - previous.baselineY) >= configuration.minFooterSeparationPitches * pitch else { return nil }
        let maxWidth = configuration.maxFolioWidthCoreHeights * Double(max(1, last.coreHeight))
        guard Double(last.bounds.width) <= maxWidth, profile.lastLineSegments.count <= 1 else { return nil }
        return last.bounds
    }

    // MARK: - Line Profile Helpers

    /// A raw band with its measured line metrics (a rule-like band keeps `isRule`).
    private struct Band {
        var line: TextLine
        var isRule: Bool
    }

    /// Black pixels in row `y` between `minX` (inclusive) and `maxX` (exclusive).
    static func rowInk(_ words: UnsafeBufferPointer<UInt64>, wordsPerRow: Int, y: Int, minX: Int, maxX: Int) -> Int {
        guard maxX > minX else { return 0 }
        var total = 0
        let rowBase = y * wordsPerRow
        for w in (minX / 64)...((maxX - 1) / 64) {
            total += (words[rowBase + w] & Self.mask(word: w, minX: minX, maxX: maxX)).nonzeroBitCount
        }
        return total
    }

    /// Bit mask selecting columns `[minX, maxX)` inside word `w` (bit 63 is the word's leftmost pixel).
    private static func mask(word w: Int, minX: Int, maxX: Int) -> UInt64 {
        let lo = max(minX, w * 64) - w * 64
        let hi = min(maxX, w * 64 + 64) - w * 64
        return (UInt64.max >> lo) & ~(UInt64.max >> hi)
    }

    /// First and last black column in row `y` within `[minX, maxX)`.
    private static func rowExtent(_ words: UnsafeBufferPointer<UInt64>, wordsPerRow: Int, y: Int, minX: Int, maxX: Int) -> (Int, Int)? {
        guard maxX > minX else { return nil }
        let rowBase = y * wordsPerRow
        let firstWord = minX / 64
        let lastWord = (maxX - 1) / 64
        var left: Int? = nil
        for w in firstWord...lastWord {
            let v = words[rowBase + w] & mask(word: w, minX: minX, maxX: maxX)
            if v != 0 {
                left = w * 64 + v.leadingZeroBitCount
                break
            }
        }
        guard let left else { return nil }
        for w in stride(from: lastWord, through: firstWord, by: -1) {
            let v = words[rowBase + w] & mask(word: w, minX: minX, maxX: maxX)
            if v != 0 {
                return (left, w * 64 + 63 - v.trailingZeroBitCount)
            }
        }
        return nil
    }

    /// Splits bands that are much taller than typical where a near-empty row separates two touching lines.
    private static func splitMergedLines(_ spans: [Range<Int>], ink: (Int) -> Int) -> [Range<Int>] {
        guard let typical = median(spans.map { Double($0.count) }), typical >= 4 else { return spans }
        var result: [Range<Int>] = []
        var queue = spans[...]
        while let span = queue.popFirst() {
            guard Double(span.count) > 1.7 * typical else {
                result.append(span)
                continue
            }
            let peak = span.map(ink).max() ?? 0
            let inner = (span.lowerBound + span.count / 5)..<(span.upperBound - span.count / 5)
            guard let cut = inner.min(by: { ink($0) < ink($1) }), Double(ink(cut)) <= 0.2 * Double(peak) else {
                result.append(span)
                continue
            }
            // Re-examine both halves; put the lower half back first so order is preserved.
            queue = [span.lowerBound..<cut, (cut + 1)..<span.upperBound][...] + queue
        }
        return result.filter { !$0.isEmpty }
    }

    /// Measures one band: ink, exact horizontal extent, dense core, and baseline.
    private static func measureBand(
        _ span: Range<Int>,
        ink: (Int) -> Int,
        words: UnsafeBufferPointer<UInt64>,
        wordsPerRow: Int,
        area: Rect2I
    ) -> Band? {
        var total = 0
        var peak = 0
        var minX = Int.max
        var maxX = Int.min
        for y in span {
            let rowInk = ink(y)
            total += rowInk
            peak = max(peak, rowInk)
            if rowInk > 0, let (l, r) = rowExtent(words, wordsPerRow: wordsPerRow, y: y, minX: area.minX, maxX: area.maxX) {
                minX = min(minX, l)
                maxX = max(maxX, r)
            }
        }
        guard total > 0, minX <= maxX else { return nil }
        let threshold = max(1, peak / 2)
        let coreTop = span.first { ink($0) >= threshold } ?? span.lowerBound
        let coreBottom = span.last { ink($0) >= threshold } ?? (span.upperBound - 1)
        let bounds = Rect2I(minX: minX, minY: span.lowerBound, maxX: maxX + 1, maxY: span.upperBound)
        let fill = Double(total) / Double(max(1, bounds.area))
        let isThin = span.count <= 6 || coreBottom - coreTop + 1 <= max(2, span.count / 2)
        return Band(
            line: TextLine(bounds: bounds, baselineY: coreBottom + 1, coreHeight: coreBottom - coreTop + 1, inkPixels: total),
            isRule: isThin && fill >= 0.5 && bounds.width >= area.width / 2
        )
    }

    /// Folds accent-sized bands into adjacent lines and rules into the line above (or below at the top).
    private static func foldSmallBands(
        _ bands: [Band],
        ink: (Int) -> Int,
        words: UnsafeBufferPointer<UInt64>,
        wordsPerRow: Int,
        area: Rect2I
    ) -> [TextLine] {
        var items = bands
        guard items.count > 1 else { return items.map(\.line) }
        let typical = median(items.filter { !$0.isRule }.map { Double($0.line.bounds.height) }) ?? 1

        func remeasure(_ a: Band, _ b: Band) -> Band? {
            let span = min(a.line.bounds.minY, b.line.bounds.minY)..<max(a.line.bounds.maxY, b.line.bounds.maxY)
            return measureBand(span, ink: ink, words: words, wordsPerRow: wordsPerRow, area: area)
        }
        func gap(_ upper: Band, _ lower: Band) -> Double {
            Double(lower.line.bounds.minY - upper.line.bounds.maxY)
        }

        // Rules: keep the text line's own metrics, widen its bounds, and mark it.
        var i = 0
        while i < items.count {
            guard items[i].isRule else { i += 1; continue }
            let rule = items.remove(at: i)
            let target: Int? = (i > 0 && gap(items[i - 1], rule) <= 1.5 * typical) ? i - 1
                : (i < items.count && gap(rule, items[i]) <= 1.5 * typical) ? i : nil
            if let t = target, !items[t].isRule {
                items[t].line.bounds = items[t].line.bounds.union(rule.line.bounds)
                items[t].line.hasRule = true
            }
        }

        // Accents and dots: small bands close to a neighbour join it.
        i = 0
        while i < items.count {
            let band = items[i]
            guard Double(band.line.bounds.height) < 0.45 * typical, items.count > 1 else { i += 1; continue }
            let nearBelow = i + 1 < items.count && gap(band, items[i + 1]) <= 0.6 * typical
            let nearAbove = i > 0 && gap(items[i - 1], band) <= 0.6 * typical
            if nearBelow, var merged = remeasure(band, items[i + 1]) {
                merged.line.hasRule = items[i + 1].line.hasRule
                merged.line.bounds = merged.line.bounds.union(items[i + 1].line.bounds)
                items[i + 1] = merged
                items.remove(at: i)
            } else if nearAbove, var merged = remeasure(items[i - 1], band) {
                merged.line.hasRule = items[i - 1].line.hasRule
                merged.line.bounds = merged.line.bounds.union(items[i - 1].line.bounds)
                items[i - 1] = merged
                items.remove(at: i)
            } else {
                i += 1
            }
        }
        return items.map(\.line)
    }

    /// Splits a line's ink into horizontal segments separated by gaps wider than `gapCoreHeights` core heights.
    private static func segments(of line: TextLine, in bitmap: borrowing BinaryBitmap, gapCoreHeights: Double) -> [Rect2I] {
        let box = line.bounds
        guard box.width > 0, box.height > 0 else { return [] }
        var columns = [Int](repeating: 0, count: box.width)
        for y in box.minY..<box.maxY {
            for x in box.minX..<box.maxX where bitmap[x, y] {
                columns[x - box.minX] += 1
            }
        }
        let minGap = max(2, Int((gapCoreHeights * Double(max(1, line.coreHeight))).rounded()))
        var ranges: [Range<Int>] = []
        var start: Int? = nil
        var lastInk = -1
        for (x, count) in columns.enumerated() where count > 0 {
            if let s = start, x - lastInk - 1 >= minGap {
                ranges.append(s..<(lastInk + 1))
                start = x
            } else if start == nil {
                start = x
            }
            lastInk = x
        }
        if let s = start { ranges.append(s..<(lastInk + 1)) }

        return ranges.map { r in
            var top = box.maxY
            var bottom = box.minY
            for y in box.minY..<box.maxY {
                for x in (box.minX + r.lowerBound)..<(box.minX + r.upperBound) where bitmap[x, y] {
                    top = min(top, y)
                    bottom = max(bottom, y + 1)
                    break
                }
            }
            return Rect2I(minX: box.minX + r.lowerBound, minY: top, maxX: box.minX + r.upperBound, maxY: max(top + 1, bottom))
        }
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
