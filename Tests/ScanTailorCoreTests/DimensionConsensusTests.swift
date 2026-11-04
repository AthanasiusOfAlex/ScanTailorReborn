import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

@Suite("Substep 6.2.1 — Consensus Dimension Clustering Tests")
struct DimensionConsensusTests {
    static let normal = Size2I(width: 4000, height: 5600)

    static func input(_ i: Int, _ size: Size2I = normal, box: Rect2I? = nil, pitch: Double? = 100, forced: DimensionClass? = nil) -> DimensionConsensus.PageInput {
        DimensionConsensus.PageInput(
            pageIndex: i, pageSize: size,
            contentBox: box ?? Rect2I(x: 400, y: 500, width: 3000, height: 4500),
            bodyLinePitch: pitch, forcedClass: forced
        )
    }

    /// `count` ordinary pages whose sizes vary by about 1%, as real crops do.
    static func book(_ count: Int = 12) -> [DimensionConsensus.PageInput] {
        (0..<count).map { i in
            input(i, Size2I(width: 4000 + (i % 3) * 20, height: 5600 + (i % 4) * 15))
        }
    }

    // MARK: - Statistics (no pixels)

    @Test("A uniform book has no outliers; ordinary 1% crop variation is not one")
    func uniformBook() {
        let result = DimensionConsensus().classify(pages: Self.book())
        #expect(result.summary.applied && result.summary.outlierPageCount == 0)
        #expect(result.records.allSatisfy { $0.dimensionClass == .canonical && $0.proposedCanvasSize == nil })
        #expect(result.summary.canonicalPageCount == 12)
    }

    @Test("An oversize cover and a thumbnail cover are outliers, each with its own proposed canvas")
    func covers() {
        var pages = Self.book()
        pages[0] = Self.input(0, Size2I(width: 5200, height: 6100))   // Flannery-like: +30% W, +9% H
        pages[1] = Self.input(1, Size2I(width: 1700, height: 2700))   // Pilsner-like thumbnail
        let result = DimensionConsensus().classify(pages: pages)
        #expect(result.summary.outlierPages == [0, 1])
        #expect(result.records[0].kinds == [.oversize])
        #expect(result.records[1].kinds == [.undersize])
        #expect(result.records[0].proposedCanvasSize == Size2I(width: 5200, height: 6100))
        #expect(result.records[0].widthDeviation > 0.25 && result.records[1].widthDeviation < -0.5)
        #expect(result.records[2...].allSatisfy { $0.dimensionClass == .canonical })
    }

    @Test("The 8% tolerance sits between ordinary variation and cover differences")
    func tolerance() {
        var pages = Self.book()
        pages[3] = Self.input(3, Size2I(width: 4000, height: 5600 * 105 / 100))   // +5%: stays
        pages[4] = Self.input(4, Size2I(width: 4000, height: 5600 * 112 / 100))   // +12%: outlier
        let result = DimensionConsensus().classify(pages: pages)
        #expect(result.records[3].dimensionClass == .canonical)
        #expect(result.records[4].dimensionClass == .outlier)
        let loose = DimensionConsensus(configuration: .init(toleranceFraction: 0.20)).classify(pages: pages)
        #expect(loose.summary.outlierPageCount == 0)
    }

    @Test("A landscape page in a portrait book is an orientation outlier")
    func landscape() {
        var pages = Self.book()
        pages[5] = Self.input(5, Size2I(width: 5800, height: 4100))
        let result = DimensionConsensus().classify(pages: pages)
        #expect(result.records[5].kinds.contains(.orientation))
        #expect(result.summary.outlierPages == [5])
    }

    @Test("Too few pages: nothing is classified")
    func tooFewPages() {
        var pages = Array(Self.book().prefix(4))
        pages[0] = Self.input(0, Size2I(width: 5200, height: 6100))
        let result = DimensionConsensus().classify(pages: pages)
        #expect(!result.summary.applied && result.summary.note == "tooFewPages")
        #expect(result.records.allSatisfy { $0.dimensionClass == .canonical })
    }

    @Test("When many pages differ, sizes are not trusted; a disabled pass changes nothing")
    func ambiguousAndDisabled() {
        var pages = Self.book(10)
        for i in 0..<4 { pages[i] = Self.input(i, Size2I(width: 5200, height: 6100)) }
        let result = DimensionConsensus().classify(pages: pages)
        #expect(result.summary.ambiguous && result.summary.outlierPageCount == 0)
        let off = DimensionConsensus(configuration: .init(enabled: false)).classify(pages: Self.book() + [Self.input(12, Size2I(width: 9000, height: 9000))])
        #expect(!off.summary.applied && off.summary.outlierPageCount == 0)
    }

    @Test("Text that is too big for the book's text block is an outlier even on a normal-size page")
    func contentOverflow() {
        var pages = Self.book()
        pages[6] = Self.input(6, box: Rect2I(x: 100, y: 100, width: 3800, height: 5400))
        let result = DimensionConsensus().classify(pages: pages)
        #expect(result.records[6].kinds == [.contentOverflow])
        #expect(result.records[6].proposedCanvasSize == Self.normal)
    }

    @Test("A different line pitch flags a scale mismatch without making the page an outlier")
    func scaleMismatch() {
        var pages = Self.book()
        pages[7] = Self.input(7, pitch: 135)
        let result = DimensionConsensus().classify(pages: pages)
        #expect(result.records[7].scaleMismatch && result.records[7].dimensionClass == .canonical)
        #expect(result.records[8].scaleMismatch == false)
    }

    @Test("Manual overrides win in both directions; outliers of one size share a group")
    func overridesAndGroups() {
        var pages = Self.book()
        pages[0] = Self.input(0, Size2I(width: 5200, height: 6100), forced: .canonical)
        pages[1] = Self.input(1, forced: .outlier)
        pages[9] = Self.input(9, Size2I(width: 1700, height: 2700))
        pages[10] = Self.input(10, Size2I(width: 1720, height: 2690))
        let result = DimensionConsensus().classify(pages: pages)
        #expect(result.records[0].dimensionClass == .canonical)
        #expect(result.records[1].kinds == [.manual])
        #expect(result.summary.outlierGroups == [[9, 10]])
        #expect(result.records[9].groupIndex == 0 && result.records[10].groupIndex == 0 && result.records[1].groupIndex == nil)
    }

    @Test("Landscape scans in a portrait book are kept whole; a book of spreads is left alone")
    func splitVeto() {
        let portrait = Size2I(width: 2400, height: 3300)
        let landscape = Size2I(width: 3300, height: 2400)
        let consensus = DimensionConsensus()
        #expect(consensus.splitVetoes(sourceSizes: Array(repeating: portrait, count: 9) + [landscape]) == [9])
        #expect(consensus.splitVetoes(sourceSizes: Array(repeating: landscape, count: 8) + [portrait, portrait]).isEmpty, "a book of spreads is not portrait")
        #expect(consensus.splitVetoes(sourceSizes: [portrait, landscape]).isEmpty, "too few pages")
    }

    // MARK: - Harmonizer

    static func detection(_ box: Rect2I) -> ContentBoxDetector.DetectionResult {
        ContentBoxDetector.DetectionResult(
            contentBox: box, mainBodyBox: box,
            retainedClusters: [.init(exactBounds: box, foregroundPixels: 100_000)],
            rejectedBoxes: [], confidence: 0.99
        )
    }

    @Test("An outlier is left out of the canonical canvas and frame, is Tier 3, and keeps its whole text block")
    func harmonizerIgnoresOutlier() {
        let body = Rect2I(x: 500, y: 600, width: 3000, height: 4400)
        func pages(withCover: Bool) -> [MarginHarmonizer.PageInput] {
            var list = (1...8).map { i in
                MarginHarmonizer.PageInput(pageIndex: i, side: i % 2 == 0 ? .verso : .recto, pageSize: Size2I(width: 4000, height: 5600), dpi: 600, detection: Self.detection(body))
            }
            if withCover {
                list.insert(MarginHarmonizer.PageInput(
                    pageIndex: 0, side: .recto, pageSize: Size2I(width: 5200, height: 6100), dpi: 600,
                    detection: Self.detection(Rect2I(x: 100, y: 100, width: 4470, height: 5922))
                ), at: 0)
            }
            return list
        }
        let harmonizer = MarginHarmonizer()
        let without = harmonizer.harmonizeBook(pages: pages(withCover: false))
        let with = harmonizer.harmonizeBook(pages: pages(withCover: true), dimensionOutliers: [0])
        #expect(with.canvasSize == without.canvasSize)
        #expect(with.versoCanonicalFrame == without.versoCanonicalFrame && with.rectoCanonicalFrame == without.rectoCanonicalFrame)

        let cover = with.pagePlans[0]
        #expect(cover.tier == .standaloneFloating && cover.isDimensionOutlier)
        #expect(cover.proposedCanvasSize == Size2I(width: 5200, height: 6100))
        #expect(cover.sourceContentBox == Rect2I(x: 100, y: 100, width: 4470, height: 5922), "pass 2 does not trim an outlier to the canonical width")
        #expect(with.pagePlans.dropFirst().allSatisfy { $0.tier == .fullBody && !$0.isDimensionOutlier })

        // Without the outlier set the cover widens the median-based canvas decisions and is not marked.
        let naive = harmonizer.harmonizeBook(pages: pages(withCover: true))
        #expect(!naive.pagePlans[0].isDimensionOutlier)

        // Fewer than three canonical pages: the set is ignored.
        let tiny = harmonizer.harmonizeBook(pages: Array(pages(withCover: true).prefix(3)), dimensionOutliers: [0, 1])
        #expect(tiny.pagePlans.allSatisfy { !$0.isDimensionOutlier })
    }

    @Test("Registration keeps an outlier where it is and tags it")
    func registrationTagsOutlier() {
        let plan = MarginHarmonizer.PageLayoutPlan(
            pageIndex: 0, side: .recto, tier: .standaloneFloating, wasOutlierTrimmed: false,
            sourceContentBox: Rect2I(x: 0, y: 0, width: 10, height: 10), retainedClusterBoxes: [], rejectedClusterBoxes: [],
            destinationOrigin: Point2I(x: 0, y: 0), canvasSize: Size2I(width: 100, height: 100),
            proposedCanvasSize: Size2I(width: 120, height: 130)
        )
        #expect(plan.isDimensionOutlier)
        let data = try? JSONEncoder().encode(plan)
        #expect(data.flatMap { try? JSONDecoder().decode(MarginHarmonizer.PageLayoutPlan.self, from: $0) } == plan)
    }

    // MARK: - Pipeline (tiny pages)

    static func page(width: Int, height: Int, side: MarginHarmonizer.PageSide = .recto) -> GrayscaleBuffer {
        var gray = GrayscaleBuffer(width: width, height: height, dpi: 300, initialValue: 235)
        var rects: [Rect2I] = []
        for i in 0..<((height - 220) / 20) {
            rects += RunningHeaderDetectionTests.lineRects(baseline: 110 + i * 20, x0: 100, x1: width - 100, core: 10)
        }
        for r in rects {
            for y in max(0, r.minY)..<min(gray.height, r.maxY) {
                for x in max(0, r.minX)..<min(gray.width, r.maxX) { gray.pixels[y * gray.width + x] = 30 }
            }
        }
        return gray
    }

    static func pipeline(consensus: Bool) -> BookPipelineCoordinator {
        BookPipelineCoordinator(configuration: .init(
            processingDPI: 300, outputDPI: 150, splitMode: .automatic,
            enableDewarp: false, enableAutomaticFontScaleCalibration: false,
            enablePerspectiveRectification: false, enableDeskMasking: false,
            dimensionConsensusConfiguration: .init(enabled: consensus)
        ))
    }

    @Test("Pipeline: an oversize cover and a landscape table are outliers; the table is not split; --off restores the old result")
    func pipelineOutliers() async throws {
        var pages = (0..<8).map { _ in Self.page(width: 600, height: 750) }
        pages.insert(Self.page(width: 800, height: 830), at: 0)    // cover
        pages.insert(Self.page(width: 820, height: 560), at: 4)    // landscape table
        let accelerator = PortableComputeAccelerator()

        let output = try await Self.pipeline(consensus: true).processGrayscalePages(pages, writer: NullWriter(), accelerator: accelerator)
        let manifest = output.manifest
        let summary = try #require(manifest.dimensionConsensus)
        #expect(manifest.pages.count == 10, "the landscape table stays one page")
        #expect(manifest.sourcePageSplits[4].layoutType == .singlePage)
        #expect(summary.splitVetoedSourcePages == [4])
        #expect(summary.outlierPages == [0, 4], "\(summary)")
        #expect(manifest.pages[0].layoutPlan.tier == .standaloneFloating)
        #expect(manifest.pages[0].layoutPlan.proposedCanvasSize != nil)
        #expect(manifest.pages[0].registration?.flags.contains("registration:dimensionalOutlier") == true)
        #expect(manifest.pages[1].dimension?.dimensionClass == .canonical)
        #expect(manifest.canonicalCanvasSizeAtProcessingDPI.width < 800, "the cover does not set the canvas: \(manifest.canonicalCanvasSizeAtProcessingDPI)")

        let text = ScanTailorCLI.formatManifestSummary(manifest)
        #expect(text.contains("Dimension Consensus: 8 canonical · 2 outlier"), "\(text)")

        // JSON round trip, and a manifest from before 6.2.1.
        let data = try JSONEncoder().encode(manifest)
        #expect(try JSONDecoder().decode(BookProcessingManifest.self, from: data) == manifest)
        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "dimensionConsensus")
        if var records = old["pages"] as? [[String: Any]] {
            for i in records.indices {
                records[i].removeValue(forKey: "dimension")
                if var plan = records[i]["layoutPlan"] as? [String: Any] {
                    plan.removeValue(forKey: "proposedCanvasSize")
                    records[i]["layoutPlan"] = plan
                }
            }
            old["pages"] = records
        }
        let decoded = try JSONDecoder().decode(BookProcessingManifest.self, from: try JSONSerialization.data(withJSONObject: old))
        #expect(decoded.dimensionConsensus == nil && decoded.pages.allSatisfy { $0.dimension == nil })

        // Switched off: no classification, nothing vetoed.
        let off = try await Self.pipeline(consensus: false).processGrayscalePages(pages, writer: NullWriter(), accelerator: accelerator)
        #expect(off.manifest.dimensionConsensus?.applied == false)
        #expect(off.manifest.pages.allSatisfy { !$0.layoutPlan.isDimensionOutlier })

        // A manual `canonical` class on the cover re-run puts it back with the book.
        var edited = manifest
        edited.pages[0].manualOverride = PageManualOverride(dimensionClass: .canonical)
        let rerun = try await Self.pipeline(consensus: true).processGrayscalePages(
            pages, writer: NullWriter(), accelerator: accelerator, existingManifest: edited
        )
        #expect(rerun.manifest.pages[0].dimension?.dimensionClass == .canonical)
        #expect(rerun.manifest.dimensionConsensus?.outlierPages == [4])
    }

    @Test("CLI: --dimension-consensus and --outlier-tolerance parse")
    func cliFlags() throws {
        let base = ["in.pdf", "-o", "out.pdf"]
        let defaults = try ScanTailorCLI.parseProcessOptions(base)
        #expect(defaults.enableDimensionConsensus && defaults.outlierTolerance == 0.08)
        #expect(try ScanTailorCLI.parseProcessOptions(base + ["--dimension-consensus", "off"]).enableDimensionConsensus == false)
        #expect(try ScanTailorCLI.parseProcessOptions(base + ["--dimension-consensus", "auto"]).enableDimensionConsensus)
        #expect(try ScanTailorCLI.parseProcessOptions(base + ["--outlier-tolerance", "0.12"]).outlierTolerance == 0.12)
        #expect(throws: (any Error).self) { try ScanTailorCLI.parseProcessOptions(base + ["--dimension-consensus", "maybe"]) }
        #expect(throws: (any Error).self) { try ScanTailorCLI.parseProcessOptions(base + ["--outlier-tolerance", "0.9"]) }
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
