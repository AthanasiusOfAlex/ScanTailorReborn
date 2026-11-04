import Foundation
import ScanTailorAppleBackend
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import Testing

/// Opt-in checks on short excerpts of real books (Substep 6.1.2).
///
/// The scans stay outside the repository. Set `SCANTAILOR_CORPUS_DIR` to the folder that holds the book
/// folders (for example `…/PDFs-in-the-making`) to run them; without the variable every test is skipped.
/// Each sample reads only a few source pages, but these are full 600 DPI runs: about 20 seconds in total
/// in a release build, but roughly half an hour in a debug build, so run them with `-c release`:
///
/// ```
/// SCANTAILOR_CORPUS_DIR="$HOME/Library/CloudStorage/OneDrive-MRC/PDFs-in-the-making" \
///   swift test -c release --filter RealCorpusTests
/// ```
private let corpusDirectory: String? = {
    guard let value = ProcessInfo.processInfo.environment["SCANTAILOR_CORPUS_DIR"], !value.isEmpty else { return nil }
    return value
}()

@Suite("Real-corpus vertical registration (opt-in: SCANTAILOR_CORPUS_DIR)", .enabled(if: corpusDirectory != nil))
struct RealCorpusTests {
    struct Sample {
        var name: String
        var relativePath: String
        var pages: ClosedRange<Int>
    }

    static let flannery = Sample(name: "flannery.1993", relativePath: "flannery.1993/00-pdf-orig/flannery.1993.pdf", pages: 1...8)
    static let gury = Sample(name: "gury.1866", relativePath: "gury.1866/00-pdf-orig/gury.1866.pdf", pages: 300...307)
    static let vermeersch = Sample(name: "vermeersch.1934", relativePath: "vermeersch.1934/00-pdf-orig/vermeersch.1934.pdf", pages: 1...6)
    /// Spreads 57–59 are folios 110–115: curved headers, fore-edge page stacks, and noise beside the folios.
    static let long = Sample(name: "long.2015 (folios 110-115)", relativePath: "long.2015/00-pdf-orig/orig.pdf", pages: 57...59)

    /// Scans 2-8 around the landscape table on scan 5 (the fourth scan of the sample).
    static let sle = Sample(name: "SLE.2 (landscape table)", relativePath: "SLE.2/00-pdf-orig/SLE.2.pdf", pages: 2...8)
    /// A thumbnail-sized cover followed by ordinary pages.
    static let pilsner = Sample(name: "pilsner.2006 (cover)", relativePath: "pilsner.2006/00-pdf-orig/Pilsner 2006 - The specification of human actions.pdf", pages: 1...6)

    struct Run {
        var output: BookPipelineCoordinator.PipelineOutput
        var manifest: BookProcessingManifest { output.manifest }
        var summary: VerticalRegistrationSummary?
    }

    static func run(_ sample: Sample) async throws -> Run {
        let root = try #require(corpusDirectory)
        let url = URL(fileURLWithPath: root).appendingPathComponent(sample.relativePath)
        try #require(FileManager.default.fileExists(atPath: url.path), "missing corpus file \(url.path)")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ScanTailorCorpus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reader = try ApplePDFSourceReader(url: url)
        let writer = try ApplePDFDocumentWriter(destinationURL: tempDir.appendingPathComponent("out.pdf"))
        let coordinator = BookPipelineCoordinator(configuration: .init(pageRange: sample.pages))
        let output = try await coordinator.processBook(
            reader: reader, writer: writer, accelerator: MetalComputeAccelerator(), ocrEngine: nil
        )
        return Run(output: output, summary: output.manifest.verticalRegistration)
    }

    /// Baseline of the topmost line on each rendered page, re-measured from the output bitmaps.
    static func renderedTopBaselines(_ run: Run) -> [Int] {
        let detector = RunningHeaderDetector()
        return run.output.outputBitmapsAtOutputDPI.enumerated().compactMap { i, bitmap in
            let profile = detector.profilePage(bitmap, region: bitmap.contentBoundingBox(), pageIndex: i, side: .single)
            return profile.lines.first?.baselineY
        }
    }

    /// The registration summary, required.
    static func registration(_ run: Run) throws -> VerticalRegistrationSummary {
        try #require(run.summary, "no registration summary")
    }

    static func headerPageCount(_ run: Run, side: MarginHarmonizer.PageSide) -> Int {
        run.manifest.runningHeaderModel?.sides.first { $0.side == side }?.headerPageCount ?? 0
    }

    // MARK: - Tests

    @Test("Flannery 1993 (pp. 1-8): a clean scan; headers on both sides line up exactly")
    func flannery() async throws {
        let run = try await Self.run(Self.flannery)
        let summary = try Self.registration(run)
        #expect(Self.headerPageCount(run, side: .verso) >= 3 && Self.headerPageCount(run, side: .recto) >= 3)
        #expect(summary.headerPageCount >= 5, "\(summary)")
        #expect(summary.headerSpreadAfterPixels == 0)
        #expect(summary.maxShiftPixels < 3 * 100, "shifts stay under three line pitches")
        #expect(run.manifest.pages.dropFirst().allSatisfy { $0.layoutPlan.tier == .fullBody })

        // The JSTOR cover (page 1) is bigger than the book: it is an outlier and does not set the canvas.
        let consensus = try #require(run.manifest.dimensionConsensus)
        #expect(consensus.outlierPages == [0], "\(consensus)")
        #expect(run.manifest.pages[0].dimension?.kinds.contains(.oversize) == true)
        #expect(run.manifest.pages[0].layoutPlan.tier == .standaloneFloating)
        #expect(run.manifest.pages[0].layoutPlan.proposedCanvasSize != nil)
        #expect(run.manifest.canonicalCanvasSizeAtProcessingDPI.width < 4200, "\(run.manifest.canonicalCanvasSizeAtProcessingDPI)")
    }

    @Test("Gury 1866 (pp. 300-307): a header only 1.15 pitches above the body is found and aligned")
    func gury() async throws {
        let run = try await Self.run(Self.gury)
        let summary = try Self.registration(run)
        #expect(summary.headerPageCount >= 4, "\(summary)")
        #expect(summary.headerSpreadAfterPixels == 0)
        #expect(try #require(summary.headerSpreadBeforePixels) > 0, "the scan had jitter to remove")
        #expect(run.manifest.pages.allSatisfy { $0.layoutPlan.tier == .fullBody })
        // No page is pushed by a header's height because its header was missed.
        #expect(summary.maxShiftPixels < 100, "\(summary)")
    }

    @Test("Vermeersch 1934 (pp. 1-6): dust above small headers does not hide them; odd pages stay put")
    func vermeersch() async throws {
        let run = try await Self.run(Self.vermeersch)
        let summary = try Self.registration(run)
        #expect(Self.headerPageCount(run, side: .verso) >= 3, "\(String(describing: run.manifest.runningHeaderModel))")
        // Several pages of this short excerpt fall to Tier 3 for upstream reasons (a handful of pages
        // cannot establish a canonical frame), and Tier 3 pages are preserved, so only two register.
        #expect(summary.headerPageCount >= 2, "\(summary)")
        #expect(summary.headerSpreadAfterPixels == 0)
        // Registration never throws a page by more than three line pitches (about 320 px here).
        #expect(summary.maxShiftPixels < 330, "\(summary)")
    }

    @Test("Long 2015 (folios 110-115): fore-edge texture is ignored, every page is a full-body page, headers line up")
    func long() async throws {
        let run = try await Self.run(Self.long)
        let summary = try Self.registration(run)
        let pages = run.manifest.pages
        #expect(pages.count == 6)
        #expect(pages.allSatisfy { $0.layoutPlan.tier == .fullBody }, "\(pages.map(\.layoutPlan.tier))")
        #expect(Self.headerPageCount(run, side: .verso) == 3 && Self.headerPageCount(run, side: .recto) == 3)
        #expect(summary.headerPageCount == 6)
        #expect(summary.headerSpreadAfterPixels == 0)
        #expect((summary.bodySpreadAfterPixels ?? 99) <= 12, "\(summary)")
        // The canonical text width is the text, not the text plus the page-edge texture (about 2,800 px).
        #expect(run.manifest.versoCanonicalFrame.width < 3000, "\(run.manifest.versoCanonicalFrame)")

        // Re-measure the rendered pages at output DPI: the headers share one baseline within a pixel.
        let baselines = Self.renderedTopBaselines(run)
        #expect(baselines.count == 6)
        #expect((baselines.max() ?? 0) - (baselines.min() ?? 0) <= 1, "rendered header baselines: \(baselines)")
    }

    @Test("SLE.2 (scans 2-8): a landscape table in a portrait book is kept whole and marked as an outlier")
    func sleLandscapeTable() async throws {
        let run = try await Self.run(Self.sle)
        let consensus = try #require(run.manifest.dimensionConsensus)
        #expect(consensus.splitVetoedSourcePages == [3], "\(consensus)")
        #expect(run.manifest.sourcePageSplits[3].layoutType == .singlePage)
        #expect(run.manifest.pages.filter { $0.sourcePageIndex == 3 }.count == 1, "the table is one page")
        let table = try #require(run.manifest.pages.first { $0.sourcePageIndex == 3 })
        #expect(table.dimension?.kinds.contains(.orientation) == true, "\(consensus)")
        #expect(table.layoutPlan.isDimensionOutlier)
        #expect(run.manifest.pages.filter { $0.layoutPlan.isDimensionOutlier }.count == 1, "\(consensus)")
    }

    @Test("Pilsner 2006 (pp. 1-6): the thumbnail cover is an undersize outlier and the body pages are unaffected")
    func pilsnerCover() async throws {
        let run = try await Self.run(Self.pilsner)
        let consensus = try #require(run.manifest.dimensionConsensus)
        #expect(consensus.outlierPages.contains(0), "\(consensus)")
        #expect(run.manifest.pages[0].dimension?.kinds.contains(.undersize) == true)
        #expect(run.manifest.pages[0].layoutPlan.proposedCanvasSize != nil)
        #expect(run.manifest.pages.dropFirst().allSatisfy { !$0.layoutPlan.isDimensionOutlier }, "\(consensus)")
    }
}
