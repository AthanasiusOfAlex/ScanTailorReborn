import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore

/// Synthetic reproductions of the failures the real corpus exposed in Substep 6.1.1 (Gury, Vermeersch, Long):
/// vertical streaks and page-edge textures fusing text lines, dust above a header, a header that sits close
/// to its body, and stacked noise on a folio.
@Suite("Substep 6.1.2 — Running Header Calibration Tests")
struct RunningHeaderCalibrationTests {
    typealias Spec = RunningHeaderDetectionTests.PageSpec
    static func lineRects(baseline: Int, x0: Int, x1: Int, core: Int, capitals: Bool = false) -> [Rect2I] {
        RunningHeaderDetectionTests.lineRects(baseline: baseline, x0: x0, x1: x1, core: core, capitals: capitals)
    }
    static func bitmap(_ rects: [Rect2I]) -> BinaryBitmap { RunningHeaderDetectionTests.bitmap(rects) }
    static let width = RunningHeaderDetectionTests.width
    static let height = RunningHeaderDetectionTests.height

    /// A plain page: a header (with a right/left folio) and 24 body lines at pitch 40.
    /// Body lines start at slightly different x so glyph columns do not line up from line to line
    /// (aligned columns would look like vertical streaks, which real text never does).
    static func plainPage(dy: Int = 0, side: MarginHarmonizer.PageSide = .recto) -> [Rect2I] {
        let headerBaseline = 120 + dy
        var rects = lineRects(baseline: headerBaseline, x0: 300, x1: 700, core: 18)
        let folioX = side == .verso ? 100 : 846
        rects += lineRects(baseline: headerBaseline, x0: folioX, x1: folioX + 56, core: 28, capitals: true)
        for i in 0..<24 {
            rects += lineRects(baseline: headerBaseline + 100 + i * 40, x0: 100 + (i * 5) % 14, x1: 900, core: 20)
        }
        return rects
    }

    static func profile(_ rects: [Rect2I], side: MarginHarmonizer.PageSide = .recto, detector: RunningHeaderDetector = RunningHeaderDetector()) -> RunningHeaderDetector.PageLineProfile {
        let bmp = bitmap(rects)
        return detector.profilePage(bmp, region: bmp.contentBoundingBox(), pageIndex: 0, side: side)
    }

    /// Dots (3 x 3 every 6 px) filling `rect`: a dithered texture such as a page-edge stack. With
    /// `everyRow`, a second lattice offset by half a period puts ink in every pixel row.
    static func texture(_ rect: Rect2I, everyRow: Bool = false) -> [Rect2I] {
        var dots: [Rect2I] = []
        let offsets = everyRow ? [0, 3] : [0]
        for offset in offsets {
            for y in stride(from: rect.minY + offset, to: rect.maxY - 3, by: 6) {
                for x in stride(from: rect.minX + offset, to: rect.maxX - 3, by: 6) {
                    dots.append(Rect2I(minX: x, minY: y, maxX: x + 3, maxY: y + 3))
                }
            }
        }
        return dots
    }

    // MARK: - Column analysis

    @Test("A full-height vertical streak inside the text block is ignored instead of fusing every line")
    func verticalStreakInsideText() throws {
        let clean = Self.profile(Self.plainPage())
        var rects = Self.plainPage()
        rects.append(Rect2I(minX: 520, minY: 60, maxX: 526, maxY: 1330)) // streak through the text
        let streaked = Self.profile(rects)

        #expect(streaked.lines.count == clean.lines.count, "lines: \(streaked.lines.count) vs \(clean.lines.count)")
        #expect(streaked.suppressedColumns > 0)
        #expect(clean.suppressedColumns == 0)
        #expect(abs(streaked.lines[0].baselineY - clean.lines[0].baselineY) <= 1)
        #expect(abs((streaked.bodyLinePitch ?? 0) - Double(RunningHeaderDetectionTests.pitch)) <= 1)

        // With suppression off the streak merges everything into one band.
        let off = RunningHeaderDetector(configuration: .init(streakColumnFraction: 0, minColumnIsolationGapFraction: 0))
        #expect(Self.profile(rects, detector: off).lines.count < clean.lines.count / 2)
    }

    @Test("A dithered page-edge texture behind an empty gap is trimmed; the text lines are unchanged")
    func edgeTextureBehindGap() throws {
        let clean = Self.profile(Self.plainPage())
        var rects = Self.plainPage()
        rects += Self.texture(Rect2I(minX: 10, minY: 40, maxX: 60, maxY: 1340), everyRow: true)
        let textured = Self.profile(rects)

        #expect(textured.lines.count == clean.lines.count)
        #expect(textured.suppressedColumns >= 40)
        #expect(textured.lines[0].bounds.minX >= 90, "the header line does not reach into the texture")
        #expect(abs(textured.lines[1].baselineY - clean.lines[1].baselineY) <= 1)

        let off = RunningHeaderDetector(configuration: .init(streakColumnFraction: 0, minColumnIsolationGapFraction: 0))
        #expect(Self.profile(rects, detector: off).lines.count < clean.lines.count / 2, "without trimming the texture fuses the lines")
    }

    @Test("Two text columns are both kept: a column gap is not edge noise when both carry text")
    func twoColumns() throws {
        var rects: [Rect2I] = []
        for i in 0..<20 {
            rects += Self.lineRects(baseline: 200 + i * 40, x0: 100 + (i * 5) % 14, x1: 460, core: 20)
            rects += Self.lineRects(baseline: 200 + i * 40, x0: 540 + (i * 5) % 14, x1: 900, core: 20)
        }
        let p = Self.profile(rects)
        #expect(p.suppressedColumns == 0)
        #expect(p.lines.count == 20)
        #expect(p.lines[0].bounds.minX <= 101 && p.lines[0].bounds.maxX >= 895)
    }

    // MARK: - Specks and stacked fragments

    @Test("Dust above the header is dropped, so the header is still the top line")
    func dustAboveHeader() throws {
        var rects = Self.plainPage()
        rects.append(Rect2I(minX: 410, minY: 40, maxX: 416, maxY: 46))
        let p = Self.profile(rects)
        #expect(p.lines.count == 25)
        #expect(abs(p.lines[0].baselineY - 120) <= 2)
        let kept = RunningHeaderDetector(configuration: .init(speckFraction: 0))
        #expect(Self.profile(rects, detector: kept).lines.count > 25, "specks are lines when the filter is off")
    }

    @Test("A short dash between the header and the body is a speck, so the header still stands apart")
    func dashBelowHeader() throws {
        var rects = Self.plainPage()
        // A pen dash or scratch: wider than the core height, but far thinner than any line of type.
        rects.append(Rect2I(minX: 120, minY: 160, maxX: 150, maxY: 164))
        let p = Self.profile(rects)
        #expect(p.lines.count == 25)
        #expect(abs(p.lines[0].baselineY - 120) <= 2)
        #expect(abs(p.lines[1].baselineY - 220) <= 2)
    }

    @Test("A narrow blob stacked on the header belongs to the header line")
    func stackedBlob() throws {
        var rects = Self.plainPage()
        // The header's folio is on the right; stack a speckle patch on the header's left end.
        rects.append(Rect2I(minX: 300, minY: 85, maxX: 318, maxY: 102))
        let p = Self.profile(rects)
        #expect(p.lines.count == 25, "lines: \(p.lines.map(\.bounds))")
        #expect(abs(p.lines[0].baselineY - 120) <= 2)
        #expect(p.lines[0].bounds.width >= 400)
    }

    // MARK: - Supported separation and small sides

    /// A page whose header sits only 1.15 body pitches above the first body line.
    static func closeHeaderPage(dy: Int, folio: Bool = false, side: MarginHarmonizer.PageSide) -> [Rect2I] {
        let headerBaseline = 120 + dy
        var rects = lineRects(baseline: headerBaseline, x0: 300, x1: 700, core: 14)
        if folio {
            let x = side == .verso ? 100 : 846
            rects += lineRects(baseline: headerBaseline, x0: x, x1: x + 56, core: 28, capitals: true)
        }
        for i in 0..<24 {
            rects += lineRects(baseline: headerBaseline + 46 + i * 40, x0: 100, x1: 900, core: 20)
        }
        return rects
    }

    static func analyze(_ pages: [[Rect2I]], detector: RunningHeaderDetector = RunningHeaderDetector()) -> RunningHeaderDetector.BookAnalysis {
        let profiles = pages.enumerated().map { i, rects in
            detector.profilePage(bitmap(rects), region: bitmap(rects).contentBoundingBox(), pageIndex: i,
                                 side: RunningHeaderDetectionTests.side(i))
        }
        return detector.analyzeBook(profiles)
    }

    @Test("A header only 1.15 pitches above the body counts when a wide gap sets it apart")
    func closeHeaderWithWideGap() throws {
        let jitter = [0, 12, -10, 6, -6, 14, -12, 4]
        let pages = jitter.enumerated().map { i, dy in
            Self.closeHeaderPage(dy: dy, side: RunningHeaderDetectionTests.side(i))
        }
        let analysis = Self.analyze(pages)
        #expect(analysis.model.sides.allSatisfy { $0.hasRunningHeaders }, "\(analysis.model.sides)")
        #expect(analysis.anchors.allSatisfy { $0.kind == .runningHeader }, "\(analysis.anchors.map(\.flags))")
        let offset = try #require(analysis.model.sides.first?.headerOffsetPitches)
        #expect(abs(offset - 1.15) <= 0.1)

        // Without the supporting-evidence rule the 1.5 pitch minimum rejects them.
        let strict = RunningHeaderDetector(configuration: .init(minSupportedSeparationPitches: 6.0))
        #expect(Self.analyze(pages, detector: strict).model.sides.allSatisfy { !$0.hasRunningHeaders })
    }

    @Test("Two matching pages confirm headers on a small side; one does not")
    func smallSides() throws {
        // Eight pages: recto pages 0, 2 have headers; recto pages 4, 6 are headerless.
        let headerless: Set<Int> = [4, 6]
        let pages: [[Rect2I]] = (0..<8).map { i in
            headerless.contains(i)
                ? RunningHeaderDetectionTests.pageRects(Spec(header: false), side: .recto).rects
                : Self.closeHeaderPage(dy: 0, side: RunningHeaderDetectionTests.side(i))
        }
        let analysis = Self.analyze(pages)
        let recto = try #require(analysis.model.sides.first { $0.side == .recto })
        #expect(recto.pageCount == 4 && recto.headerPageCount == 2 && recto.hasRunningHeaders)

        // Only one matching page on that side: no cluster.
        var single = pages
        single[2] = RunningHeaderDetectionTests.pageRects(Spec(header: false), side: .recto).rects
        let one = try #require(Self.analyze(single).model.sides.first { $0.side == .recto })
        #expect(!one.hasRunningHeaders)
    }

    // MARK: - Content box

    @Test("ContentBoxDetector rejects a dense page-edge texture behind a gap, so the box covers only the text")
    func contentBoxEdgeTexture() throws {
        var bitmap = BinaryBitmap(width: 1400, height: 1800, initialBlack: false)
        func fill(_ r: Rect2I) {
            for y in r.minY..<r.maxY { for x in r.minX..<r.maxX { bitmap[x, y] = true } }
        }
        for i in 0..<36 {
            for r in Self.lineRects(baseline: 260 + i * 42, x0: 480 + (i * 5) % 14, x1: 1280, core: 24) { fill(r) }
        }
        // A dense dithered strip that survives the cluster filters on its own.
        for r in Self.texture(Rect2I(minX: 120, minY: 80, maxX: 240, maxY: 1700)) { fill(r) }

        let config = ContentBoxDetector.Configuration(cleanBordersFirst: false, outerEdgeMarginFraction: 0.02, edgeNoiseIsolationGapFraction: 0.01)
        let trimmed = try #require(ContentBoxDetector(configuration: config).detect(in: bitmap, dpi: 600).contentBox)
        #expect(trimmed.minX >= 470 && trimmed.maxX <= 1290, "box: \(trimmed)")

        var off = config
        off.edgeNoiseIsolationGapFraction = 0
        let untrimmed = try #require(ContentBoxDetector(configuration: off).detect(in: bitmap, dpi: 600).contentBox)
        #expect(untrimmed.minX < 400, "without the check the texture widens the box: \(untrimmed)")
    }

    @Test("ContentBoxDetector keeps the section and page number columns of a table of contents")
    func contentBoxKeepsNumberColumns() throws {
        var bitmap = BinaryBitmap(width: 1400, height: 1800, initialBlack: false)
        func fill(_ r: Rect2I) {
            for y in r.minY..<r.maxY { for x in r.minX..<r.maxX { bitmap[x, y] = true } }
        }
        for i in 0..<36 {
            for r in Self.lineRects(baseline: 260 + i * 42, x0: 480 + (i * 5) % 14, x1: 1200, core: 24) { fill(r) }
        }
        // Section numbers 0.17 in left of the text and page numbers 0.17 in right of it, one per entry of six lines.
        for entry in 0..<6 {
            let top = 236 + entry * 252
            fill(Rect2I(minX: 340, minY: top, maxX: 380, maxY: top + 30))
            fill(Rect2I(minX: 1300, minY: top + 210, maxX: 1350, maxY: top + 240))
        }

        let config = ContentBoxDetector.Configuration(cleanBordersFirst: false, outerEdgeMarginFraction: 0.02, edgeNoiseIsolationGapFraction: 0.01)
        let box = try #require(ContentBoxDetector(configuration: config).detect(in: bitmap, dpi: 600).contentBox)
        #expect(box.minX <= 340 && box.maxX >= 1350, "both number columns are content: \(box)")
    }

    /// A tightly cut contents page (Anscombe 1963, p. ix): the section numbers lie in the outer edge strip, where
    /// border noise is set aside, and must still be kept as a column of numbers. Specks beside them are not kept.
    @Test("Content box keeps a number column that lies in the outer edge strip")
    func contentBoxKeepsNumberColumnInEdgeStrip() throws {
        var bitmap = BinaryBitmap(width: 1400, height: 1800, initialBlack: false)
        func fill(_ r: Rect2I) {
            for y in r.minY..<r.maxY { for x in r.minX..<r.maxX { bitmap[x, y] = true } }
        }
        for i in 0..<36 {
            for r in Self.lineRects(baseline: 260 + i * 42, x0: 200 + (i * 5) % 14, x1: 1200, core: 24) { fill(r) }
        }
        for entry in 0..<6 {
            let top = 236 + entry * 252
            fill(Rect2I(minX: 20, minY: top, maxX: 60, maxY: top + 30))
            fill(Rect2I(minX: 30, minY: top + 150, maxX: 36, maxY: top + 156))
        }

        let config = ContentBoxDetector.Configuration(cleanBordersFirst: false, outerEdgeMarginFraction: 0.05, edgeNoiseIsolationGapFraction: 0.01)
        let box = try #require(ContentBoxDetector(configuration: config).detect(in: bitmap, dpi: 600).contentBox)
        #expect(box.minX <= 20, "the section numbers are content: \(box)")
        #expect(box.maxY <= 1760, "the specks below the last number are not: \(box)")
    }
}
