import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

@Suite("Substep 6.1.1 — Running Header & Top Baseline Detection Tests")
struct RunningHeaderDetectionTests {
    static let width = 1000
    static let height = 1400
    static let bodyCore = 20
    static let pitch = 40
    static let headerOffset = 100 // 2.5 pitches

    // MARK: - Synthetic typography

    /// Glyph rectangles for one text line: a dense core, with ascenders on every 3rd glyph and
    /// descenders on every 4th. `capitals` draws full-height glyphs only (digits, folios).
    static func lineRects(baseline: Int, x0: Int, x1: Int, core: Int, capitals: Bool = false) -> [Rect2I] {
        let glyph = max(4, core / 2)
        let advance = glyph + max(2, core / 5)
        let ascender = core * 2 / 5
        let descender = core * 7 / 20
        var rects: [Rect2I] = []
        var x = x0
        var n = 0
        while x + glyph <= x1 {
            let top = (!capitals && n % 3 == 0) ? baseline - core - ascender : baseline - core
            let bottom = (!capitals && n % 4 == 1) ? baseline + descender : baseline
            rects.append(Rect2I(minX: x, minY: top, maxX: x + glyph, maxY: bottom))
            n += 1
            x += advance
            if n % 6 == 0 { x += advance } // word space
        }
        return rects
    }

    struct PageSpec {
        var dy = 0
        var header = true
        var folio = true
        var rule = false
        var title = false
        var footerFolio = false
        var heading: (core: Int, offset: Int)? = nil
        var bodyLines = 24
        /// Extra space between the header and the first body line (a sunk first paragraph).
        var bodyGap = 0
    }

    /// Ink rectangles for one page. Returns the rects plus the expected anchors.
    static func pageRects(_ spec: PageSpec, side: MarginHarmonizer.PageSide) -> (rects: [Rect2I], headerBaseline: Int?, firstBodyBaseline: Int) {
        var rects: [Rect2I] = []
        let headerBaseline = 120 + spec.dy
        var bodyStart = headerBaseline + headerOffset
        var expectedHeader: Int? = nil
        if spec.title {
            rects += lineRects(baseline: 450 + spec.dy, x0: 300, x1: 700, core: 60)
            bodyStart = 450 + spec.dy + 3 * pitch
        } else if let heading = spec.heading {
            rects += lineRects(baseline: headerBaseline, x0: 100, x1: 500, core: heading.core)
            bodyStart = headerBaseline + heading.offset
        } else if spec.header {
            expectedHeader = headerBaseline
            rects += lineRects(baseline: headerBaseline, x0: 300, x1: 700, core: 18)
            if spec.folio {
                let folioX = side == .verso ? 100 : 846
                rects += lineRects(baseline: headerBaseline, x0: folioX, x1: folioX + 56, core: 28, capitals: true)
            }
            if spec.rule {
                rects.append(Rect2I(minX: 100, minY: headerBaseline + 12, maxX: 900, maxY: headerBaseline + 15))
            }
        } else {
            bodyStart = headerBaseline + 20
        }
        bodyStart += spec.bodyGap
        for i in 0..<spec.bodyLines {
            rects += lineRects(baseline: bodyStart + i * pitch, x0: 100, x1: 900, core: bodyCore)
        }
        if spec.footerFolio {
            rects += lineRects(baseline: bodyStart + (spec.bodyLines - 1) * pitch + 3 * pitch, x0: 470, x1: 530, core: 28, capitals: true)
        }
        return (rects, expectedHeader, bodyStart)
    }

    static func bitmap(_ rects: [Rect2I]) -> BinaryBitmap {
        var bmp = BinaryBitmap(width: width, height: height)
        for r in rects {
            for y in max(0, r.minY)..<min(height, r.maxY) {
                for x in max(0, r.minX)..<min(width, r.maxX) { bmp[x, y] = true }
            }
        }
        return bmp
    }

    static func profile(_ spec: PageSpec, index: Int, side: MarginHarmonizer.PageSide, detector: RunningHeaderDetector = RunningHeaderDetector()) -> RunningHeaderDetector.PageLineProfile {
        let bmp = bitmap(pageRects(spec, side: side).rects)
        return detector.profilePage(bmp, region: bmp.contentBoundingBox(), pageIndex: index, side: side)
    }

    static func side(_ i: Int) -> MarginHarmonizer.PageSide { i % 2 == 0 ? .recto : .verso }

    /// Ten alternating pages: 3 is a chapter opener, 6 is headerless, 8 has a footer folio.
    static func bookSpecs() -> [PageSpec] {
        let jitter = [-40, -20, 0, 20, 40, 30, -30, 10, -10, 0]
        return (0..<10).map { i in
            var spec = PageSpec(dy: jitter[i])
            if i == 3 { spec.title = true; spec.bodyLines = 18 }
            if i == 6 { spec.header = false }
            if i == 8 { spec.footerFolio = true; spec.bodyLines = 22 }
            return spec
        }
    }

    // MARK: - Line profile

    @Test("Line profile: splits lines, measures baselines, core height, and body pitch")
    func lineProfile() throws {
        let spec = PageSpec(dy: 0)
        let expected = Self.pageRects(spec, side: .recto)
        let p = Self.profile(spec, index: 0, side: .recto)
        #expect(p.lines.count == 1 + spec.bodyLines)
        let header = try #require(p.lines.first)
        #expect(abs(header.baselineY - (expected.headerBaseline ?? 0)) <= 2)
        #expect(abs(header.coreHeight - 18) <= 2)
        #expect(abs(p.lines[1].baselineY - expected.firstBodyBaseline) <= 2)
        #expect(abs((p.bodyLinePitch ?? 0) - Double(Self.pitch)) <= 1)
        #expect(abs((p.bodyCoreHeight ?? 0) - Double(Self.bodyCore)) <= 2)
        // Header text and the right-hand folio are separate segments.
        #expect(p.firstLineSegments.count == 2)

        // Blank and missing regions yield no lines.
        let blank = BinaryBitmap(width: 200, height: 200)
        #expect(RunningHeaderDetector().profilePage(blank, region: nil, pageIndex: 0, side: .single).lines.isEmpty)
        #expect(RunningHeaderDetector().profilePage(blank, region: Rect2I(x: 0, y: 0, width: 200, height: 200), pageIndex: 0, side: .single).lines.isEmpty)
    }

    @Test("Line profile: a rule under the header merges into the header line; touching lines are split")
    func ruleAndTouchingLines() throws {
        let spec = PageSpec(rule: true)
        let p = Self.profile(spec, index: 0, side: .recto)
        #expect(p.lines.count == 1 + spec.bodyLines, "the rule is not a separate line")
        #expect(p.lines[0].hasRule)
        #expect(p.lines[0].bounds.maxY >= 120 + 15)
        #expect(abs(p.lines[0].baselineY - 120) <= 2, "the rule does not move the header baseline")

        // Two lines joined by a thin bridge (a touching descender and ascender).
        var rects = Self.lineRects(baseline: 200, x0: 100, x1: 900, core: 20)
        rects += Self.lineRects(baseline: 236, x0: 100, x1: 900, core: 20)
        rects.append(Rect2I(minX: 500, minY: 200, maxX: 504, maxY: 210))
        rects += (0..<8).flatMap { i in Self.lineRects(baseline: 320 + i * 40, x0: 100, x1: 900, core: 20) }
        let bmp = Self.bitmap(rects)
        let touching = RunningHeaderDetector().profilePage(bmp, region: bmp.contentBoundingBox(), pageIndex: 0, side: .single)
        #expect(touching.lines.count == 10, "lines: \(touching.lines.map(\.bounds))")
    }

    // MARK: - Book clustering

    @Test("Book: recurring headers are confirmed despite position jitter; folios are found on the outer side")
    func bookHeaders() throws {
        let specs = Self.bookSpecs()
        let profiles = specs.indices.map { Self.profile(specs[$0], index: $0, side: Self.side($0)) }
        let analysis = RunningHeaderDetector().analyzeBook(profiles)
        #expect(analysis.anchors.count == 10)

        for i in [0, 1, 2, 4, 5, 7, 8, 9] {
            let expected = Self.pageRects(specs[i], side: Self.side(i))
            let anchor = analysis.anchors[i]
            #expect(anchor.kind == .runningHeader, "page \(i): \(anchor.flags)")
            #expect(abs((anchor.anchorY ?? 0) - (expected.headerBaseline ?? 0)) <= 2, "page \(i)")
            #expect(abs((anchor.firstBodyBaselineY ?? 0) - expected.firstBodyBaseline) <= 2, "page \(i)")
            #expect(anchor.confidence >= 0.7, "page \(i)")
            let folio = try #require(anchor.folioBox, "page \(i)")
            if Self.side(i) == .verso { #expect(folio.minX < 200) } else { #expect(folio.minX > 800) }
        }

        let recto = try #require(analysis.model.sides.first { $0.side == .recto })
        let verso = try #require(analysis.model.sides.first { $0.side == .verso })
        #expect(recto.hasRunningHeaders && verso.hasRunningHeaders)
        #expect(recto.headerPageCount == 4 && recto.pageCount == 5)
        #expect(verso.headerPageCount == 4 && verso.pageCount == 5)
        #expect(abs((recto.headerOffsetPitches ?? 0) - 2.5) < 0.1)
        #expect(abs((recto.bodyLinePitchPixels ?? 0) - Double(Self.pitch)) <= 1)
        #expect(recto.footerFolioCount == 1)
    }

    @Test("Book: a header whose first body line is sunk lower than usual is still a header (second chance)")
    func sunkBodyHeaders() throws {
        var specs = (0..<10).map { _ in PageSpec() }
        for i in [2, 6] { specs[i].bodyGap = 2 * Self.pitch }   // two of five recto pages: body two pitches lower
        let profiles = specs.indices.map { Self.profile(specs[$0], index: $0, side: Self.side($0)) }
        let analysis = RunningHeaderDetector().analyzeBook(profiles)
        for i in specs.indices {
            let anchor = analysis.anchors[i]
            #expect(anchor.kind == .runningHeader, "page \(i): \(anchor.flags)")
            #expect(anchor.confidence >= 0.5, "page \(i): confidence \(anchor.confidence)")
            #expect(anchor.flags.contains("header:lenient") == [2, 6].contains(i), "page \(i): \(anchor.flags)")
        }
        let recto = try #require(analysis.model.sides.first { $0.side == .recto })
        #expect(recto.headerPageCount == 5)
    }

    @Test("Book: chapter openers are title-like, headerless pages anchor on the first body baseline, footer folios are not body")
    func bookExceptions() throws {
        let specs = Self.bookSpecs()
        let profiles = specs.indices.map { Self.profile(specs[$0], index: $0, side: Self.side($0)) }
        let analysis = RunningHeaderDetector().analyzeBook(profiles)

        let opener = analysis.anchors[3]
        #expect(opener.kind == .bodyBaseline)
        #expect(opener.flags.contains("titleLike") && opener.flags.contains("sinkage"), "\(opener.flags)")
        #expect(abs((opener.anchorY ?? 0) - (450 + specs[3].dy)) <= 2, "anchored on the title line")

        let headerless = analysis.anchors[6]
        let expected = Self.pageRects(specs[6], side: .recto)
        #expect(headerless.kind == .bodyBaseline)
        #expect(abs((headerless.anchorY ?? 0) - expected.firstBodyBaseline) <= 2)
        #expect(headerless.headerBox == nil)
        #expect(!headerless.flags.contains("header:outOfCluster"))

        let footer = try #require(analysis.anchors[8].footerFolioBox)
        #expect(footer.minX >= 460 && footer.maxX <= 540)
        #expect(analysis.anchors.enumerated().allSatisfy { $0.offset == 8 || $0.element.footerFolioBox == nil })
    }

    @Test("Book: scattered section headings in a headerless book form no cluster")
    func noRecurringHeaders() {
        let headings: [Int: (Int, Int)] = [0: (26, 64), 2: (20, 96), 4: (16, 128)] // offsets 1.6, 2.4, 3.2 pitches
        let profiles = (0..<6).map { i in
            Self.profile(PageSpec(header: false, heading: headings[i]), index: i, side: .single)
        }
        let analysis = RunningHeaderDetector().analyzeBook(profiles)
        #expect(analysis.anchors.allSatisfy { $0.kind == .bodyBaseline }, "\(analysis.anchors.map(\.kind))")
        #expect(analysis.model.sides.count == 1)
        #expect(analysis.model.sides[0].hasRunningHeaders == false)
        #expect(analysis.model.sides[0].headerPageCount == 0)
        #expect(analysis.anchors[1].confidence >= 0.8)
    }

    @Test("Overrides and small books: present/absent policies, tooFewPages, and blank pages")
    func overridesAndSmallBooks() throws {
        let specs = Self.bookSpecs()
        let profiles = specs.indices.map { Self.profile(specs[$0], index: $0, side: Self.side($0)) }
        let analysis = RunningHeaderDetector().analyzeBook(profiles, policies: [6: .present, 0: .absent, 1: .automatic])

        let forcedHeader = analysis.anchors[6]
        #expect(forcedHeader.kind == .runningHeader)
        #expect(forcedHeader.flags.contains("override:present"))
        #expect(forcedHeader.headerBaselineY == profiles[6].lines[0].baselineY)

        let forcedBody = analysis.anchors[0]
        #expect(forcedBody.kind == .bodyBaseline)
        #expect(forcedBody.flags.contains("override:absent"))
        #expect(forcedBody.anchorY == profiles[0].lines[0].baselineY, "the top line is treated as body")
        #expect(analysis.anchors[1].kind == .runningHeader)

        // Two pages: no cluster is possible, so candidates are accepted with low confidence.
        let small = RunningHeaderDetector().analyzeBook([
            Self.profile(PageSpec(), index: 0, side: .single),
            Self.profile(PageSpec(header: false), index: 1, side: .single),
        ])
        #expect(small.anchors[0].kind == .runningHeader)
        #expect(small.anchors[0].flags.contains("book:tooFewPages"))
        #expect(small.anchors[0].confidence < 0.5)
        #expect(small.anchors[1].kind == .bodyBaseline)
        #expect(small.model.sides[0].flags == ["book:tooFewPages"])

        // Slanted columns on a camera photo run the lines together into page-tall "lines": no anchor (7.1.1b-i).
        let merged = RunningHeaderDetector.PageLineProfile(
            pageIndex: 0, side: .single, pageSize: Size2I(width: 1000, height: 1400),
            lines: [
                .init(bounds: Rect2I(x: 100, y: 100, width: 800, height: 500), baselineY: 590, coreHeight: 450, inkPixels: 90_000),
                .init(bounds: Rect2I(x: 100, y: 620, width: 800, height: 600), baselineY: 1210, coreHeight: 550, inkPixels: 99_000),
            ]
        )
        let mergedAnchor = RunningHeaderDetector().analyzeBook([merged]).anchors[0]
        #expect(mergedAnchor.kind == .none)
        #expect(mergedAnchor.flags.contains("body:linesUnresolved"))

        // Blank page.
        let blank = RunningHeaderDetector().profilePage(BinaryBitmap(width: 100, height: 100), region: nil, pageIndex: 0, side: .recto)
        let blankAnalysis = RunningHeaderDetector().analyzeBook([blank])
        #expect(blankAnalysis.anchors[0].kind == .none)
        #expect(blankAnalysis.anchors[0].anchorY == nil)
        #expect(blankAnalysis.model.sides[0].pageCount == 0)

        // Configuration clamps and decodes.
        let config = RunningHeaderDetector.Configuration(minHeaderSeparationPitches: 0.2, minClusterPages: 0)
        #expect(config.minHeaderSeparationPitches == 1.05 && config.minClusterPages == 2)
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(RunningHeaderDetector.Configuration.self, from: data) == config)
    }

    // MARK: - Pipeline

    static func grayPage() -> GrayscaleBuffer {
        var gray = GrayscaleBuffer(width: 1200, height: 1500, dpi: 300, initialValue: 235)
        let (rects, _, _) = pageRects(PageSpec(dy: 80, folio: true), side: .recto)
        for r in rects {
            for y in max(0, r.minY)..<min(gray.height, r.maxY) {
                for x in max(0, r.minX + 100)..<min(gray.width, r.maxX + 100) { gray.pixels[y * gray.width + x] = 30 }
            }
        }
        return gray
    }

    static func pipeline(headers: Bool = true) -> BookPipelineCoordinator {
        BookPipelineCoordinator(configuration: .init(
            processingDPI: 300,
            outputDPI: 150,
            splitMode: .singlePage,
            enableDewarp: false,
            enableAutomaticFontScaleCalibration: false,
            enablePerspectiveRectification: false,
            enableDeskMasking: false,
            enableRunningHeaderDetection: headers
        ))
    }

    @Test("Pipeline: anchors are recorded, overrides apply, output pixels are unchanged, manifests round-trip")
    func pipelineIntegration() async throws {
        let image = Self.grayPage()
        let accelerator = PortableComputeAccelerator()
        let first = try await Self.pipeline().processGrayscalePages([image], writer: NullWriter(), accelerator: accelerator)
        let anchor = try #require(first.manifest.pages[0].topAnchor)
        #expect(anchor.kind == .runningHeader, "\(anchor.flags)")
        #expect(anchor.flags.contains("book:tooFewPages"))
        #expect(abs((anchor.anchorY ?? 0) - 200) <= 3, "header baseline at 120 + 80")
        let model = try #require(first.manifest.runningHeaderModel)
        #expect(model.sides.map(\.side) == [.recto])
        #expect(ScanTailorCLI.formatManifestSummary(first.manifest).contains("Running Headers: recto 1/1 | 0 body-anchored | 0 none"))

        var manifest = first.manifest
        manifest.pages[0].manualOverride = PageManualOverride(runningHeader: .absent)
        let absent = try await Self.pipeline().processGrayscalePages(
            [image], writer: NullWriter(), accelerator: accelerator, existingManifest: manifest
        )
        #expect(absent.manifest.pages[0].topAnchor?.kind == .bodyBaseline)
        #expect(absent.manifest.pages[0].topAnchor?.flags.contains("override:absent") == true)

        let off = try await Self.pipeline(headers: false).processGrayscalePages([image], writer: NullWriter(), accelerator: accelerator)
        #expect(off.manifest.pages[0].topAnchor == nil)
        #expect(off.manifest.runningHeaderModel == nil)
        #expect(!ScanTailorCLI.formatManifestSummary(off.manifest).contains("Running Headers"))
        #expect(off.outputBitmapsAtOutputDPI == first.outputBitmapsAtOutputDPI, "detection changes no pixels")

        // JSON round trip, and manifests from before 6.1.1 decode with no anchors.
        let data = try JSONEncoder().encode(absent.manifest)
        #expect(try JSONDecoder().decode(BookProcessingManifest.self, from: data) == absent.manifest)
        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "runningHeaderModel")
        if var pages = legacy["pages"] as? [[String: Any]] {
            for i in pages.indices {
                pages[i].removeValue(forKey: "topAnchor")
                if var override = pages[i]["manualOverride"] as? [String: Any] {
                    override.removeValue(forKey: "runningHeader")
                    pages[i]["manualOverride"] = override
                }
            }
            legacy["pages"] = pages
        }
        let decoded = try JSONDecoder().decode(
            BookProcessingManifest.self, from: try JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.pages[0].topAnchor == nil)
        #expect(decoded.runningHeaderModel == nil)
        #expect(decoded.pages[0].manualOverride?.runningHeader == nil)
    }
}

private struct NullWriter: PDFDocumentWriter, ~Copyable {
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap,
        dpi: Int,
        pageBoxPoints: Rect2D,
        ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {}

    consuming func finalize() throws(PDFWriteError) {}
}
