import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

/// Records the size of every page the pipeline writes.
private final class PageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(box: Rect2D, pixels: Size2I)] = []
    func add(_ box: Rect2D, _ pixels: Size2I) { lock.lock(); storage.append((box, pixels)); lock.unlock() }
    var pages: [(box: Rect2D, pixels: Size2I)] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct RecordingWriter: PDFDocumentWriter, ~Copyable {
    let log: PageLog
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap, dpi: Int, pageBoxPoints: Rect2D, ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {
        log.add(pageBoxPoints, Size2I(width: bitmap.width, height: bitmap.height))
    }
    consuming func finalize() throws(PDFWriteError) {}
}

@Suite("Substep 6.2.2 — Independent Outlier Trim Box Tests")
struct OutlierCanvasTests {
    static func pipeline(
        manual: Set<Int>? = nil, enabled: Bool = true, isolate: Bool = true, scaleCalibration: Bool = false
    ) -> BookPipelineCoordinator {
        BookPipelineCoordinator(configuration: .init(
            processingDPI: 300, outputDPI: 150, splitMode: .automatic,
            enableDewarp: false, enableAutomaticFontScaleCalibration: scaleCalibration,
            enablePerspectiveRectification: false, enableDeskMasking: false,
            dimensionConsensusConfiguration: .init(enabled: enabled, manualOutlierPages: manual),
            isolateOutlierCanvases: isolate
        ))
    }

    /// Eight ordinary pages with an oversize cover at 0 and a page of odd pixel size at 5.
    static func book() -> [GrayscaleBuffer] {
        var pages = (0..<8).map { _ in DimensionConsensusTests.page(width: 600, height: 750) }
        pages.insert(DimensionConsensusTests.page(width: 801, height: 831), at: 0)
        return pages
    }

    // MARK: - Manual list

    @Test("A manual list marks exactly those pages, works with detection off and in short books, and reports bad numbers")
    func manualList() async throws {
        let accelerator = PortableComputeAccelerator()
        let pages = Self.book()
        let manual = try await Self.pipeline(manual: [2, 4], enabled: false)
            .processGrayscalePages(pages, writer: RecordingWriter(log: PageLog()), accelerator: accelerator)
        let summary = try #require(manual.manifest.dimensionConsensus)
        #expect(summary.outlierPages == [2, 4], "\(summary)")
        #expect(summary.note == "manualList" && summary.applied)
        #expect(manual.manifest.pages[0].dimension?.dimensionClass == .canonical, "the cover is normal now")

        let none = try await Self.pipeline(manual: [])
            .processGrayscalePages(pages, writer: RecordingWriter(log: PageLog()), accelerator: accelerator)
        #expect(none.manifest.dimensionConsensus?.outlierPages == [])

        let short = try await Self.pipeline(manual: [1, 99])
            .processGrayscalePages(Array(pages.prefix(3)), writer: RecordingWriter(log: PageLog()), accelerator: accelerator)
        #expect(short.manifest.dimensionConsensus?.outlierPages == [1], "\(String(describing: short.manifest.dimensionConsensus))")
        #expect(short.manifest.dimensionConsensus?.ignoredManualPages == [100])
    }

    @Test("Without a list, a per-page manual outlier works even when detection is off")
    func perPageOverrideWhenOff() async throws {
        let accelerator = PortableComputeAccelerator()
        let pages = Self.book()
        let first = try await Self.pipeline(enabled: false)
            .processGrayscalePages(pages, writer: RecordingWriter(log: PageLog()), accelerator: accelerator)
        var edited = first.manifest
        edited.pages[3].manualOverride = PageManualOverride(dimensionClass: .outlier)
        let rerun = try await Self.pipeline(enabled: false).processGrayscalePages(
            pages, writer: RecordingWriter(log: PageLog()), accelerator: accelerator, existingManifest: edited
        )
        #expect(rerun.manifest.dimensionConsensus?.outlierPages == [3])
        #expect(rerun.manifest.dimensionConsensus?.applied == false, "detection itself stayed off")
    }

    // MARK: - Own canvas

    @Test("Isolated outliers get their own PDF page size; normal pages share one; shared mode restores the old result")
    func isolatedCanvas() async throws {
        let accelerator = PortableComputeAccelerator()
        let pages = Self.book()

        let log = PageLog()
        let output = try await Self.pipeline().processGrayscalePages(pages, writer: RecordingWriter(log: log), accelerator: accelerator)
        let written = log.pages
        #expect(written.count == 9)
        let summary = try #require(output.manifest.dimensionConsensus)
        #expect(summary.outlierPages == [0] && summary.isolatedCanvasPages == [0], "\(summary)")

        // Normal pages: one size. The cover: a different, larger size that holds its whole scan.
        #expect(Set(written.dropFirst().map { "\($0.pixels.width)x\($0.pixels.height)" }).count == 1)
        #expect(written[0].pixels.width > written[1].pixels.width && written[0].pixels.height > written[1].pixels.height)
        #expect(written[0].box.width == Double(written[0].pixels.width) * 72 / 150)
        let record = try #require(output.manifest.pages[0].dimension)
        #expect(record.pdfPageSizePoints == Size2D(width: written[0].box.width, height: written[0].box.height))
        #expect(output.manifest.pages[1].dimension?.pdfPageSizePoints == nil)
        // The cover's page is its own scan size at the output DPI (odd 801×831 halves with rounding up or down).
        #expect(abs(written[0].pixels.width - 401) <= 1 && abs(written[0].pixels.height - 416) <= 1, "\(written[0].pixels)")

        // The canvas of the book is the body's, not the cover's.
        #expect(output.manifest.canonicalCanvasSizeAtProcessingDPI.width < 801)

        // The cover's text block is kept whole.
        let plan = output.manifest.pages[0].layoutPlan
        let box = try #require(plan.sourceContentBox)
        #expect(plan.canvasSize == plan.proposedCanvasSize)
        #expect(plan.destinationOrigin.x + box.width <= plan.canvasSize.width)
        #expect(plan.destinationOrigin.y + box.height <= plan.canvasSize.height)

        // Shared mode: every page has the same size.
        let sharedLog = PageLog()
        let shared = try await Self.pipeline(isolate: false)
            .processGrayscalePages(pages, writer: RecordingWriter(log: sharedLog), accelerator: accelerator)
        #expect(Set(sharedLog.pages.map { "\($0.pixels.width)x\($0.pixels.height)" }).count == 1)
        #expect(shared.manifest.dimensionConsensus?.isolatedCanvasPages == [])
        #expect(shared.manifest.pages[0].dimension?.pdfPageSizePoints == nil)
    }

    @Test("The new fields survive a JSON round trip, and a manifest from before 6.2.2 still loads")
    func manifestCoding() async throws {
        let output = try await Self.pipeline().processGrayscalePages(
            Self.book(), writer: RecordingWriter(log: PageLog()), accelerator: PortableComputeAccelerator()
        )
        let data = try JSONEncoder().encode(output.manifest)
        #expect(try JSONDecoder().decode(BookProcessingManifest.self, from: data) == output.manifest)

        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var summary = try #require(old["dimensionConsensus"] as? [String: Any])
        summary.removeValue(forKey: "isolatedCanvasPages")
        summary.removeValue(forKey: "ignoredManualPages")
        old["dimensionConsensus"] = summary
        var records = try #require(old["pages"] as? [[String: Any]])
        var dimension = try #require(records[0]["dimension"] as? [String: Any])
        dimension.removeValue(forKey: "pdfPageSizePoints")
        records[0]["dimension"] = dimension
        old["pages"] = records
        let decoded = try JSONDecoder().decode(BookProcessingManifest.self, from: try JSONSerialization.data(withJSONObject: old))
        #expect(decoded.dimensionConsensus?.isolatedCanvasPages == [])
        #expect(decoded.pages[0].dimension?.pdfPageSizePoints == nil)
    }

    // MARK: - Classifier and CLI

    @Test("Classifier: a manual list beats detection, per-page classes and short books")
    func classifierManual() {
        let pages = DimensionConsensusTests.book(12)
        let result = DimensionConsensus(configuration: .init(manualOutlierPages: [1, 45])).classify(pages: pages)
        #expect(result.summary.outlierPages == [1])
        #expect(result.records[1].kinds == [.manual] && result.records[1].proposedCanvasSize != nil)

        var forced = pages
        forced[1].forcedClass = .canonical
        #expect(DimensionConsensus(configuration: .init(manualOutlierPages: [1])).classify(pages: forced).summary.outlierPages == [1])

        let short = DimensionConsensus(configuration: .init(manualOutlierPages: [0])).classify(pages: Array(pages.prefix(3)))
        #expect(short.summary.outlierPages == [0] && short.summary.applied)
        #expect(DimensionConsensus(configuration: .init(manualOutlierPages: [])).classify(pages: pages).summary.outlierPages.isEmpty)
    }

    @Test("Harmonizer: a manual list may leave a single canonical page")
    func harmonizerMinimum() {
        let detection = DimensionConsensusTests.detection(Rect2I(x: 100, y: 100, width: 400, height: 600))
        let pages = (0..<3).map {
            MarginHarmonizer.PageInput(pageIndex: $0, side: $0 % 2 == 0 ? .recto : .verso, pageSize: Size2I(width: 700, height: 900), dpi: 300, detection: detection)
        }
        let harmonizer = MarginHarmonizer()
        let strict = harmonizer.harmonizeBook(pages: pages, dimensionOutliers: [0, 1])
        #expect(strict.pagePlans.allSatisfy { !$0.isDimensionOutlier }, "two outliers leave one canonical page: ignored")
        let manual = harmonizer.harmonizeBook(pages: pages, dimensionOutliers: [0, 1], minimumCanonicalPages: 1)
        #expect(manual.pagePlans.filter(\.isDimensionOutlier).count == 2)
    }

    @Test("CLI: --outlier-pages and --outlier-canvas parse; bad lists are rejected")
    func cliFlags() throws {
        let base = ["in.pdf", "-o", "out.pdf"]
        #expect(try ScanTailorCLI.parseProcessOptions(base).outlierPages == nil)
        #expect(try ScanTailorCLI.parseProcessOptions(base).isolateOutlierCanvases)
        #expect(try ScanTailorCLI.parseProcessOptions(base + ["--outlier-pages", "1,45,89-91,120"]).outlierPages == [1, 45, 89, 90, 91, 120])
        #expect(try ScanTailorCLI.parseProcessOptions(base + ["--outlier-pages", "none"]).outlierPages == [])
        #expect(try ScanTailorCLI.parseProcessOptions(base + ["--outlier-canvas", "shared"]).isolateOutlierCanvases == false)
        for bad in ["0", "5-2", "a,b", "", "1,,2"] {
            #expect(throws: (any Error).self) { try ScanTailorCLI.parseProcessOptions(base + ["--outlier-pages", bad]) }
        }
        #expect(throws: (any Error).self) { try ScanTailorCLI.parseProcessOptions(base + ["--outlier-canvas", "tiny"]) }
    }
}
