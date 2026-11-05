import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

private struct NullWriter: PDFDocumentWriter, ~Copyable {
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap, dpi: Int, pageBoxPoints: Rect2D, ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {}
    consuming func finalize() throws(PDFWriteError) {}
}

/// Reads a page with a thin bar of ink as a JSTOR cover sheet, any other inked page as one word, a blank as nothing.
private struct CoverOCR: OCREngine {
    func recognizeText(in bitmap: borrowing BinaryBitmap, dpi: Int, languages: [String]) async throws(OCRError) -> [RecognizedTextObservation] {
        let ink = bitmap.countBlackPixels()
        let box = Rect2D(x: 0.1, y: 0.1, width: 0.5, height: 0.05)
        // A little ink (a page of text carries tens of thousands of pixels) reads as the cover sheet.
        if ink > 50 && ink < 3000 {
            return [RecognizedTextObservation(text: "Stable URL: http://www.jstor.org/stable/23579290 Your use of the JSTOR archive indicates your acceptance", confidence: 0.9, boundingBox: box)]
        }
        guard ink > 50 else { return [] }
        return [RecognizedTextObservation(text: "word", confidence: 0.9, boundingBox: box)]
    }
    var cacheIdentity: String { "CoverOCR" }
}

@Suite("Substep 7.1.1d — Cover Handling and Blank Pages at the Ends")
struct CoverHandlingTests {
    // MARK: - Cover sheet text

    @Test("The cover sheets of JSTOR, Project MUSE, Google Books and the Internet Archive are recognized")
    func recognizesRepositories() {
        let jstor = "GBPress- Gregorian Biblical Press What is Included in a Means to an End? Author(s): Kevin Flannery Source: Gregorianum Published by: GBPress Stable URL: http://www.jstor.org/stable/23579290 Accessed: 22-10-2015 19:43 UTC REFERENCES Linked references are available on JSTOR for this article"
        let jstorTerms = "Your use of the JSTOR archive indicates your acceptance of the Terms & Conditions of Use"
        let muse = "Praeter Intentionem in Aquinas Joseph M. Boyle Jr. The Thomist Published by The Catholic University of America Press For additional information about this article https://muse.jhu.edu/article/639338/summary [77.43.5.124] Project MUSE (2025-01-25 16:32 GMT)"
        let google = "This is a digital copy of a book that was preserved for generations on library shelves before it was carefully scanned by Google"
        let archive = "Digitized by the Internet Archive in 2011 with funding from University of Toronto"
        #expect(CoverSheetDetector.repository(in: jstor) == "JSTOR")
        #expect(CoverSheetDetector.repository(in: jstorTerms) == "JSTOR")
        #expect(CoverSheetDetector.repository(in: muse) == "Project MUSE")
        #expect(CoverSheetDetector.repository(in: google) == "Google Books")
        #expect(CoverSheetDetector.repository(in: archive) == "Internet Archive")
        #expect(CoverSheetDetector.repository(in: "  YOUR USE of the\n JSTOR   archive ") == "JSTOR")
    }

    @Test("A page that only mentions a repository is not a cover sheet")
    func ordinaryPagesAreNotCovers() {
        // Project MUSE stamps its name on every page of an article.
        #expect(CoverSheetDetector.repository(in: "THE MULTIFARIOUS MORAL OBJECT [77.43.5.124] Project MUSE (2025-04-26 05:44 GMT) Pontificio A Regina") == nil)
        #expect(CoverSheetDetector.repository(in: "As Finnis notes in his JSTOR article, the stable view of the matter") == nil)
        #expect(CoverSheetDetector.repository(in: "Google it. The Internet Archive holds many books.") == nil)
        // Google Books prints its watermark on every page (lugo.1893).
        #expect(CoverSheetDetector.repository(in: "DISPUTATIO I. 3 sectio prima. Digitized by Google") == nil)
        #expect(CoverSheetDetector.repository(in: "") == nil)
    }

    // MARK: - Planning

    @Test("A whole scan among split scans of its size is split too; others are left alone")
    func consensusSplit() {
        let spread = Size2I(width: 6000, height: 4800)
        let sizes = [spread, spread, spread, spread, spread, Size2I(width: 3000, height: 4800), Size2I(width: 6100, height: 4900)]
        // Scans 1–4 split; scan 0 is not (a candidate); scan 5 is portrait; scan 6 is within 5 % but may not be split.
        let counts = [1, 2, 2, 2, 2, 1, 1]
        let eligible = [true, true, true, true, true, true, false]
        #expect(BookEnds.consensusSplitScans(sizes: sizes, sliceCounts: counts, eligible: eligible) == [0])

        // Two split neighbours are not enough, nor is a book that is mostly whole scans.
        #expect(BookEnds.consensusSplitScans(sizes: [spread, spread, spread], sliceCounts: [1, 2, 2], eligible: [true, true, true]).isEmpty)
        #expect(BookEnds.consensusSplitScans(sizes: Array(repeating: spread, count: 8), sliceCounts: [1, 1, 1, 1, 1, 2, 2, 2], eligible: Array(repeating: true, count: 8)).isEmpty)
    }

    @Test("Covers are looked for in the first two and the last scan; a printed cover is an odd-sized end scan")
    func candidates() {
        #expect(BookEnds.coverSheetCandidates(scanCount: 10) == [0, 1, 9])
        #expect(BookEnds.coverSheetCandidates(scanCount: 2) == [0, 1])
        #expect(BookEnds.coverSheetCandidates(scanCount: 1) == [0])
        #expect(BookEnds.coverSheetCandidates(scanCount: 0).isEmpty)

        let page = Size2I(width: 600, height: 750)
        let small = Size2I(width: 400, height: 500)
        #expect(BookEnds.printedCoverScans(sizes: [small, page, page, page, page, small]) == [0, 5])
        #expect(BookEnds.printedCoverScans(sizes: [page, small, page, page, page, page]).isEmpty, "only the ends")
        #expect(BookEnds.printedCoverScans(sizes: [small, page, page]).isEmpty, "too few scans to know the usual size")
    }

    @Test("Only blanks before the first or after the last page with content are dropped")
    func verdicts() {
        let t = true, f = false
        let none: BookEnds.Verdict? = nil
        // blank, content, blank, content, blank
        #expect(BookEnds.verdicts(isBlank: [t, f, t, f, t], isCover: [none, none, none, none, none])
                == [.leadingBlank, nil, nil, nil, .trailingBlank])
        // A cover is dropped, and the blank behind it becomes a leading blank.
        #expect(BookEnds.verdicts(isBlank: [f, t, f, f], isCover: [.coverSheet, none, none, none])
                == [.coverSheet, .leadingBlank, nil, nil])
        // A book of blanks.
        #expect(BookEnds.verdicts(isBlank: [t, t], isCover: [none, none]) == [.leadingBlank, .leadingBlank])
    }

    // MARK: - Pipeline

    static func pipeline(_ handling: CoverHandling, prune: Bool = true) -> BookPipelineCoordinator {
        BookPipelineCoordinator(configuration: .init(
            processingDPI: 300, outputDPI: 150, splitMode: .automatic,
            autoPruneBlankPages: prune, coverHandling: handling,
            enableDewarp: false, enableAutomaticFontScaleCalibration: false,
            enablePerspectiveRectification: false, enableDeskMasking: false,
            stopAfter: .layout
        ))
    }

    static func blank() -> GrayscaleBuffer { GrayscaleBuffer(width: 600, height: 750, dpi: 300, initialValue: 235) }

    static func text() -> GrayscaleBuffer { DimensionConsensusTests.page(width: 600, height: 750) }

    /// A page with a tall bar: the fake OCR reads it as a JSTOR cover sheet.
    static func coverSheet() -> GrayscaleBuffer {
        var page = blank()
        for y in 200..<420 { for x in 296..<304 { page.pixels[y * page.width + x] = 20 } }
        return page
    }

    static func run(_ handling: CoverHandling, pages: [GrayscaleBuffer], prune: Bool = true) async throws -> BookProcessingManifest {
        try await pipeline(handling, prune: prune)
            .processGrayscalePages(pages, writer: NullWriter(), accelerator: PortableComputeAccelerator(), ocrEngine: CoverOCR())
            .manifest
    }

    /// blank, JSTOR sheet, text, blank, text, text, blank
    static func book() -> [GrayscaleBuffer] {
        [blank(), coverSheet(), text(), blank(), text(), text(), blank()]
    }

    @Test("auto drops the library sheet and the blanks at the ends; the blank between pages stays")
    func autoMode() async throws {
        let manifest = try await Self.run(.auto, pages: Self.book())
        #expect(manifest.pages.map(\.sourcePageIndex) == [2, 3, 4, 5])
        #expect(manifest.prunedPages.map(\.sourcePageIndex) == [0, 1, 6])
        #expect(manifest.prunedPages.map(\.kind) == ["leadingBlank", "coverSheet", "trailingBlank"])
        #expect(manifest.prunedPages[1].reason.contains("JSTOR"))
    }

    @Test("keep leaves the library sheet in the book; the blanks at the ends still go")
    func keepMode() async throws {
        let manifest = try await Self.run(.keep, pages: Self.book())
        #expect(manifest.pages.map(\.sourcePageIndex) == [1, 2, 3, 4, 5])
        #expect(manifest.prunedPages.map(\.kind) == ["leadingBlank", "trailingBlank"])
    }

    @Test("Without blank pruning every blank page stays, the library sheet still goes")
    func noPruning() async throws {
        let manifest = try await Self.run(.auto, pages: Self.book(), prune: false)
        #expect(manifest.pages.map(\.sourcePageIndex) == [0, 2, 3, 4, 5, 6])
        #expect(manifest.prunedPages.map(\.kind) == ["coverSheet"])
    }

    @Test("strip also drops an odd-sized printed cover; auto keeps it")
    func stripMode() async throws {
        var pages = (0..<6).map { _ in Self.text() }
        pages[0] = DimensionConsensusTests.page(width: 800, height: 900)
        let auto = try await Self.run(.auto, pages: pages)
        #expect(auto.pages.count == 6)
        let strip = try await Self.run(.strip, pages: pages)
        #expect(strip.pages.map(\.sourcePageIndex) == [1, 2, 3, 4, 5])
        #expect(strip.prunedPages.map(\.kind) == ["cover"])
    }

    @Test("A page with an edit is never dropped as a cover or a blank")
    func editedPagesStay() async throws {
        let adjustments = try PageAdjustments.parse(Data(#"{"version":1,"pages":{"s1":{"keep":true},"s2":{"keep":true}}}"#.utf8))
        let pipeline = BookPipelineCoordinator(configuration: .init(
            processingDPI: 300, outputDPI: 150, splitMode: .automatic, coverHandling: .auto,
            enableDewarp: false, enableAutomaticFontScaleCalibration: false,
            enablePerspectiveRectification: false, enableDeskMasking: false,
            adjustments: adjustments, stopAfter: .layout
        ))
        let manifest = try await pipeline
            .processGrayscalePages(Self.book(), writer: NullWriter(), accelerator: PortableComputeAccelerator(), ocrEngine: CoverOCR())
            .manifest
        #expect(manifest.pages.map(\.sourcePageIndex) == [0, 1, 2, 3, 4, 5])
    }

    @Test("--cover-handling is parsed, and rejects an unknown mode")
    func cliOption() throws {
        #expect(try ScanTailorCLI.parseProcessOptions(["book.pdf", "-o", "out.pdf"]).coverHandling == .auto)
        #expect(try ScanTailorCLI.parseProcessOptions(["book.pdf", "-o", "out.pdf", "--cover-handling", "strip"]).coverHandling == .strip)
        #expect(throws: ScanTailorCLI.CLIError.self) { try ScanTailorCLI.parseProcessOptions(["book.pdf", "-o", "out.pdf", "--cover-handling", "burn"]) }
    }

    @Test("Older manifests without a pruned page's kind still decode")
    func legacyPrunedRecord() throws {
        let json = #"{"sourcePageIndex":0,"splitSide":"single","inkDensity":0,"reason":"old"}"#
        let record = try JSONDecoder().decode(PrunedPageRecord.self, from: Data(json.utf8))
        #expect(record.kind == nil && record.reason == "old")
    }
}
