import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

private final class SizeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Rect2D] = []
    func add(_ box: Rect2D) { lock.lock(); storage.append(box); lock.unlock() }
    var boxes: [Rect2D] { lock.lock(); defer { lock.unlock() }; return storage }
}

private struct LoggingWriter: PDFDocumentWriter, ~Copyable {
    let log: SizeLog
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap, dpi: Int, pageBoxPoints: Rect2D, ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) { log.add(pageBoxPoints) }
    consuming func finalize() throws(PDFWriteError) {}
}

@Suite("Substep 6.3.1 — Manifest-Driven Per-Page Adjustments")
struct AdjustmentsTests {
    // MARK: - Helpers

    static func pipeline(
        adjustments: PageAdjustments = .empty,
        outlierRefs: [PageReference] = [],
        manual: Set<Int>? = nil,
        stopAfter: PipelineStop? = nil
    ) -> BookPipelineCoordinator {
        BookPipelineCoordinator(configuration: .init(
            processingDPI: 300, outputDPI: 150, splitMode: .automatic,
            enableDewarp: false, enableAutomaticFontScaleCalibration: false,
            enablePerspectiveRectification: false, enableDeskMasking: false,
            dimensionConsensusConfiguration: .init(manualOutlierPages: manual),
            adjustments: adjustments,
            manualOutlierReferences: outlierRefs,
            stopAfter: stopAfter
        ))
    }

    /// Eight identical ordinary pages (scans 1–8).
    static func book(count: Int = 8) -> [GrayscaleBuffer] {
        (0..<count).map { _ in DimensionConsensusTests.page(width: 600, height: 750) }
    }

    static func adjustments(_ json: String) throws -> PageAdjustments {
        try PageAdjustments.parse(Data(json.utf8))
    }

    fileprivate static func run(_ pipeline: BookPipelineCoordinator, pages: [GrayscaleBuffer] = book(), log: SizeLog = SizeLog(), existing: BookProcessingManifest? = nil) async throws -> BookPipelineCoordinator.PipelineOutput {
        try await pipeline.processGrayscalePages(pages, writer: LoggingWriter(log: log), accelerator: PortableComputeAccelerator(), existingManifest: existing)
    }

    // MARK: - Parsing

    @Test("References and lengths parse; a unit is always required")
    func referencesAndLengths() {
        #expect(PageReference("45") == .outputPage(45))
        #expect(PageReference("s12") == .scan(12, .whole))
        #expect(PageReference("S12l") == .scan(12, .left))
        #expect(PageReference("s7R") == .scan(7, .right))
        for bad in ["", "0", "s", "s0", "s12x", "12a", "-3", "s1.5"] { #expect(PageReference(bad) == nil, "\(bad)") }
        #expect(PageReference.scan(3, .left).description == "s3L")
        #expect([PageReference.scan(2, .right), .outputPage(9), .scan(2, .left)].sorted() == [.outputPage(9), .scan(2, .left), .scan(2, .right)])

        #expect(AdjustmentLength.parse("-2mm") == AdjustmentLength(value: -2, unit: .millimeters))
        #expect(AdjustmentLength.parse("+0.1in")?.pixels(atDPI: 600) == 60)
        #expect(AdjustmentLength.parse("25.4mm")?.pixels(atDPI: 300) == 300)
        #expect(AdjustmentLength.parse("72pt")?.pixels(atDPI: 600) == 600)
        #expect(AdjustmentLength.parse("120px")?.pixels(atDPI: 300) == 60)
        #expect(AdjustmentLength.parse("52%", allowPercent: true)?.pixels(atDPI: 600, extent: 1000) == 520)
        #expect(AdjustmentLength.parse("52%") == nil)
        #expect(AdjustmentLength.parse("2") == nil)
        #expect(AdjustmentLength.parse("two inches") == nil)
    }

    @Test("A complete file parses into typed adjustments and equivalent command-line options")
    func parsesCompleteFile() throws {
        let parsed = try Self.adjustments("""
        {
          "version": 1, "note": "ignored",
          "book": { "page-size": "octavo", "margins": "0.75in", "outlier-pages": "1,s45L", "no-dewarp": true, "no-ocr": false, "outlier-tolerance": 0.1 },
          "scans": { "s12": { "split": "single" }, "s30": { "splitX": "52%", "disableRectification": true, "_why": "gutter shadow" } },
          "pages": {
            "s45L": { "skew": -0.4, "contentBox": { "nudge": { "top": "-2mm", "bottom": "+0.1in" } } },
            "77":   { "tier": "floating", "keep": true, "outlier": false },
            "s88":  { "contentBox": { "rect": ["1.0in", "1.2in", "4.1in", "6.6in"] }, "offset": { "y": "+1mm" }, "pageSize": "6x9in", "runningHeader": "absent" }
          }
        }
        """)
        #expect(parsed.bookArguments == ["--margins", "0.75in", "--no-dewarp", "--outlier-pages", "1,s45L", "--outlier-tolerance", "0.1", "--page-size", "octavo"])
        #expect(parsed.scans[.scan(12, .whole)]?.split == .singlePage)
        #expect(parsed.scans[.scan(30, .whole)]?.splitX == AdjustmentLength(value: 52, unit: .percent))
        #expect(parsed.scans[.scan(30, .whole)]?.disableRectification == true)
        let p = try #require(parsed.pages[.scan(45, .left)])
        #expect(p.skewDegrees == -0.4)
        #expect(p.contentBoxNudge?.top == AdjustmentLength(value: -2, unit: .millimeters))
        #expect(p.contentBoxNudge?.bottom == AdjustmentLength(value: 0.1, unit: .inches))
        #expect(p.contentBoxNudge?.left == nil)
        let q = try #require(parsed.pages[.outputPage(77)])
        #expect(q.tier == .standaloneFloating && q.keep == true && q.outlier == false)
        let r = try #require(parsed.pages[.scan(88, .whole)])
        #expect(r.contentBoxRect?.right == AdjustmentLength(value: 4.1, unit: .inches))
        #expect(r.offsetY == AdjustmentLength(value: 1, unit: .millimeters) && r.offsetX == nil)
        #expect(r.pageSize == PhysicalSizeSpec.parse("6x9in") && r.runningHeader == .absent)
        #expect(parsed.pages[.scan(45, .left)]?.fieldNames == ["skew", "contentBox.nudge"])
    }

    @Test("Every mistake is reported at once, with a suggestion where there is a likely typo")
    func reportsAllProblems() throws {
        let error = try #require(throws: AdjustmentsError.self) {
            try Self.adjustments("""
            {
              "book": { "output": "x.pdf", "margins": {"a": 1} },
              "scans": { "12": { "split": "single" }, "s5": { "split": "sideways", "splitX": "2%" } },
              "pages": {
                "s45L": { "skeww": 1, "offset": { "x": 3 } },
                "s9":   { "keep": true, "drop": true, "tier": "huge", "contentBox": { "rect": ["1in", "1in", "0.5in", "2in"] }, "disableDewarp": 1 },
                "page7": {},
                "8": { "contentBox": { "nudge": { "topp": "1mm" } }, "skew": 45 }
              }
            }
            """)
        }
        let text = error.problems.joined(separator: "\n")
        #expect(error.problems.count >= 12, "\(text)")
        #expect(text.contains("book.output: not allowed here"))
        #expect(text.contains("book.margins: must be a string"))
        #expect(text.contains("scans.12:") && text.contains("named like \"s12\""))
        #expect(text.contains("scans.s5.split:") && text.contains("scans.s5.splitX:"))
        #expect(text.contains("pages.s45L.skeww: unknown key — did you mean \"skew\"?"))
        #expect(text.contains("pages.s45L.offset.x: needs a unit"))
        #expect(text.contains("pages.s9: keep and drop contradict"))
        #expect(text.contains("pages.s9.tier:"))
        #expect(text.contains("pages.s9.contentBox.rect: right must be greater than left"))
        #expect(text.contains("pages.s9.disableDewarp: must be true or false"))
        #expect(text.contains("pages.page7:"))
        #expect(text.contains("pages.8.contentBox.nudge.topp: unknown key — did you mean \"top\"?"))
        #expect(text.contains("pages.8.skew: 45.0 degrees is too large"))

        #expect(throws: AdjustmentsError.self) { try PageAdjustments.parse(Data("[1,2]".utf8)) }
        #expect(throws: AdjustmentsError.self) { try PageAdjustments.parse(Data("{ nope".utf8)) }
        #expect(throws: AdjustmentsError.self) { try Self.adjustments("{\"version\": 2}") }
    }

    // MARK: - Pipeline

    @Test("A content-box nudge moves the box edges; the stored override is the resolved box, so a re-run does not nudge twice")
    func nudgeIsIdempotent() async throws {
        let baseline = try await Self.run(Self.pipeline())
        let before = try #require(baseline.manifest.pages[2].layoutPlan.sourceContentBox)

        let adjustments = try Self.adjustments("""
        { "pages": { "s3": { "contentBox": { "nudge": { "top": "-0.1in", "right": "-0.2in" } } } } }
        """)
        let adjusted = try await Self.run(Self.pipeline(adjustments: adjustments))
        let after = try #require(adjusted.manifest.pages[2].layoutPlan.sourceContentBox)
        #expect(after.minY == before.minY - 30 && after.maxX == before.maxX - 60, "\(before) → \(after)")
        #expect(after.minX == before.minX && after.maxY == before.maxY)
        let stored = try #require(adjusted.manifest.pages[2].manualOverride)
        #expect(stored.contentBoxNudge == nil && stored.overrideContentBox == after)
        #expect(adjusted.manifest.pages[1].layoutPlan.sourceContentBox == baseline.manifest.pages[1].layoutPlan.sourceContentBox)

        // Feeding the manifest back (the older --manifest path) reproduces the page exactly.
        let again = try await Self.run(Self.pipeline(), existing: adjusted.manifest)
        #expect(again.manifest.pages[2].layoutPlan.sourceContentBox == after)
    }

    @Test("Offset moves the content after placement; a forced tier changes the placement rule; scan names find pages")
    func offsetAndTier() async throws {
        let baseline = try await Self.run(Self.pipeline())
        #expect(baseline.manifest.pages.allSatisfy { $0.layoutPlan.tier == .fullBody })

        let adjustments = try Self.adjustments("""
        { "pages": { "s2": { "offset": { "x": "0.1in", "y": "-0.05in" } }, "4": { "tier": "standaloneFloating" } } }
        """)
        let adjusted = try await Self.run(Self.pipeline(adjustments: adjustments))
        let was = baseline.manifest.pages[1].layoutPlan.destinationOrigin
        let now = adjusted.manifest.pages[1].layoutPlan.destinationOrigin
        #expect(now.x == was.x + 30 && now.y == was.y - 15, "\(was) → \(now)")
        #expect(adjusted.manifest.pages[3].layoutPlan.tier == .standaloneFloating)
        #expect(adjusted.manifest.pages[3].manualOverride?.forcedTier == .standaloneFloating)
        #expect(adjusted.manifest.pages[0].layoutPlan.tier == .fullBody)
        let report = try #require(adjusted.manifest.adjustments)
        #expect(report.applied.map(\.reference) == ["4", "s2"].sorted(by: { PageReference($0)! < PageReference($1)! }), "\(report)")
        #expect(report.ignored.isEmpty, "\(report)")
    }

    @Test("A dropped page leaves the book; entries that find nothing are reported with the reason")
    func dropAndIgnored() async throws {
        let adjustments = try Self.adjustments("""
        { "pages": { "s5": { "drop": true }, "s99": { "skew": 1 }, "s2L": { "skew": 1 }, "99": { "skew": 1 } },
          "scans": { "s77": { "split": "single" } } }
        """)
        let output = try await Self.run(Self.pipeline(adjustments: adjustments))
        #expect(output.manifest.pages.count == 7)
        #expect(output.manifest.pages.map(\.sourcePageIndex) == [0, 1, 2, 3, 5, 6, 7])
        #expect(output.manifest.prunedPages.map(\.sourcePageIndex) == [4])
        #expect(output.manifest.prunedPages.first?.reason.contains("Dropped") == true)

        let report = try #require(output.manifest.adjustments)
        #expect(report.applied.map(\.reference) == ["s5"])
        let reasons = Dictionary(uniqueKeysWithValues: report.ignored.map { ($0.reference, $0.reason) })
        #expect(reasons["s99"]?.contains("was not processed") == true, "\(reasons)")
        #expect(reasons["s2L"]?.contains("was not split") == true, "\(reasons)")
        #expect(reasons["99"]?.contains("no output page 99") == true, "\(reasons)")
        #expect(reasons["s77"]?.contains("was not processed") == true, "\(reasons)")
        // The summary line for people and agents mentions them.
        let text = ScanTailorCLI.formatAdjustmentReport(report)
        #expect(text.contains("1 applied, 4 ignored") && text.contains("IGNORED  s2L"), "\(text)")
    }

    @Test("A scan-level split forces a spread at an exact position, and the halves can be named s2L / s2R")
    func scanSplit() async throws {
        let adjustments = try Self.adjustments("""
        { "scans": { "s2": { "split": "spread", "splitX": "50%" } },
          "pages": { "s2L": { "skew": 0.5 }, "s2R": { "tier": "standaloneFloating" } } }
        """)
        let output = try await Self.run(Self.pipeline(adjustments: adjustments))
        #expect(output.manifest.pages.count == 9)
        #expect(output.manifest.sourcePageSplits[1].layoutType == .twoPageSpread)
        let line = try #require(output.manifest.sourcePageSplits[1].splitLine)
        #expect(line.centerX == 300 && line.normalizedCenterX == 0.5)
        let halves = output.manifest.pages.filter { $0.sourcePageIndex == 1 }
        #expect(halves.map(\.splitSide) == [.leftVerso, .rightRecto])
        #expect(halves[0].manualOverride?.overrideSkewDegrees == 0.5 && halves[1].manualOverride?.forcedTier == .standaloneFloating)
        #expect(halves[1].layoutPlan.tier == .standaloneFloating)
        #expect(output.manifest.scanReference(of: halves[0]) == "s2L" && output.manifest.scanReference(of: halves[1]) == "s2R")
        #expect(output.manifest.adjustments?.ignored.isEmpty == true, "\(String(describing: output.manifest.adjustments))")

        // Forcing a single page keeps a scan whole.
        let single = try Self.adjustments("{ \"scans\": { \"s3\": { \"split\": \"single\" } } }")
        let kept = try await Self.run(Self.pipeline(adjustments: single))
        #expect(kept.manifest.sourcePageSplits[2].layoutType == .singlePage && kept.manifest.pages.count == 8)
    }

    @Test("Scan names work in the outlier list; unknown names are reported; the list still replaces detection")
    func outlierScanReferences() async throws {
        var pages = Self.book()
        pages[0] = DimensionConsensusTests.page(width: 801, height: 831)
        let output = try await Self.run(Self.pipeline(outlierRefs: [.scan(3, .whole), .scan(99, .whole), .scan(4, .left)]), pages: pages)
        let summary = try #require(output.manifest.dimensionConsensus)
        #expect(summary.outlierPages == [2], "the oversize cover is normal now: \(summary)")
        #expect(summary.note == "manualList" && summary.applied)
        #expect(summary.ignoredManualReferences == ["s99", "s4L"], "\(summary)")
        #expect(output.manifest.pages[2].layoutPlan.isDimensionOutlier)
        #expect(ScanTailorCLI.formatManifestSummary(output.manifest).contains("ignored (no such page): s99,s4L"))

        // Mixed with plain numbers.
        let mixed = try await Self.run(Self.pipeline(outlierRefs: [.scan(3, .whole)], manual: [0]), pages: pages)
        #expect(mixed.manifest.dimensionConsensus?.outlierPages == [0, 2])
    }

    @Test("An outlier's page size can be set when the aspect matches, and is refused with a reason when it does not")
    func outlierPageSize() async throws {
        var pages = Self.book()
        pages[0] = DimensionConsensusTests.page(width: 801, height: 831)
        let log = SizeLog()
        let ok = try Self.adjustments("{ \"pages\": { \"s1\": { \"pageSize\": \"3.2x3.32in\" } } }")
        let output = try await Self.run(Self.pipeline(adjustments: ok), pages: pages, log: log)
        let box = try #require(log.boxes.first)
        #expect(abs(box.width - 3.2 * 72) < 1e-6 && abs(box.height - 3.32 * 72) < 1e-6, "\(box)")
        #expect(output.manifest.pages[0].dimension?.pdfPageSizePoints == Size2D(width: box.width, height: box.height))
        #expect(output.manifest.adjustments?.ignored.isEmpty == true)

        let wrong = try Self.adjustments("{ \"pages\": { \"s1\": { \"pageSize\": \"6x9in\" }, \"s4\": { \"pageSize\": \"6x9in\" } } }")
        let refused = try await Self.run(Self.pipeline(adjustments: wrong), pages: pages)
        let notes = refused.manifest.adjustments?.ignored.map(\.reason) ?? []
        #expect(notes.count == 2 && notes.contains { $0.contains("differs from the page's") } && notes.contains { $0.contains("own canvas") }, "\(notes)")
    }

    @Test("--stop-after layout renders and writes nothing, yet plans exactly the pages a full run produces")
    func stopAfterLayout() async throws {
        var pages = Self.book()
        pages[0] = DimensionConsensusTests.page(width: 801, height: 831)
        let fullLog = SizeLog()
        let full = try await Self.run(Self.pipeline(), pages: pages, log: fullLog)
        let stoppedLog = SizeLog()
        let stopped = try await Self.run(Self.pipeline(stopAfter: .layout), pages: pages, log: stoppedLog)

        #expect(stoppedLog.boxes.isEmpty && stopped.outputBitmapsAtOutputDPI.isEmpty)
        #expect(stopped.stoppedAfter == .layout && full.stoppedAfter == nil)
        #expect(stopped.cleanedBitmapsAtProcessingDPI.count == 8)
        #expect(stopped.manifest.pages.map(\.layoutPlan) == full.manifest.pages.map(\.layoutPlan))
        #expect(stopped.manifest.pages.map { $0.dimension?.pdfPageSizePoints } == full.manifest.pages.map { $0.dimension?.pdfPageSizePoints })
        #expect(stopped.manifest.canonicalCanvasSizeAtProcessingDPI == full.manifest.canonicalCanvasSizeAtProcessingDPI)
        #expect(fullLog.boxes.count == 8)
    }

    @Test("The manifest keeps the report and scan numbers through JSON; manifests from before 6.3.1 still load")
    func manifestCoding() async throws {
        let adjustments = try Self.adjustments("{ \"pages\": { \"s2\": { \"skew\": 0.2 }, \"s50\": { \"skew\": 1 } } }")
        let output = try await Self.run(Self.pipeline(adjustments: adjustments))
        let data = try JSONEncoder().encode(output.manifest)
        let decoded = try JSONDecoder().decode(BookProcessingManifest.self, from: data)
        #expect(decoded == output.manifest)
        #expect(decoded.sourceScanNumbers == Array(1...8))
        #expect(decoded.adjustments?.applied.map(\.reference) == ["s2"] && decoded.adjustments?.ignored.map(\.reference) == ["s50"])

        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "adjustments")
        old.removeValue(forKey: "sourceScanNumbers")
        var summary = try #require(old["dimensionConsensus"] as? [String: Any])
        summary.removeValue(forKey: "ignoredManualReferences")
        old["dimensionConsensus"] = summary
        let legacy = try JSONDecoder().decode(BookProcessingManifest.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(legacy.adjustments == nil && legacy.sourceScanNumbers.isEmpty)
        #expect(legacy.scanNumber(of: legacy.pages[3]) == 4, "old manifests fall back to the scan's position")
        #expect(legacy.dimensionConsensus?.ignoredManualReferences == [])
    }

    // MARK: - CLI

    @Test("CLI: the new flags parse, stopping needs somewhere to keep its results, and scan names are accepted in --outlier-pages")
    func cliFlags() throws {
        let base = ["in.pdf", "-o", "out.pdf"]
        let o = try ScanTailorCLI.parseProcessOptions(base + ["--apply-manifest", "a.json", "--outlier-pages", "1,s45L,s9", "--manifest", "m.json", "--stop-after", "layout"])
        #expect(o.applyManifestPath == "a.json" && o.stopAfter == .layout)
        #expect(o.outlierPages == [1] && o.outlierScanRefs == [.scan(45, .left), .scan(9, .whole)])
        #expect(try ScanTailorCLI.parseProcessOptions(base + ["--outlier-pages", "s45L"]).outlierPages == nil)
        #expect(try ScanTailorCLI.parseProcessOptions(base + ["--outlier-pages", "none"]).outlierPages == [])

        #expect(throws: (any Error).self) { try ScanTailorCLI.parseProcessOptions(base + ["--stop-after", "layout"]) }
        #expect(throws: (any Error).self) { try ScanTailorCLI.parseProcessOptions(base + ["--stop-after", "nonsense", "--manifest", "m.json"]) }
        #expect(throws: (any Error).self) { try ScanTailorCLI.parseProcessOptions(base + ["--layout-sheets"]) }
        #expect(throws: (any Error).self) { try ScanTailorCLI.parseProcessOptions(base + ["--outlier-pages", "s0"]) }
        #expect(throws: (any Error).self) { try ScanTailorCLI.parseProcessOptions(base + ["--outlier-pages", "s45x"]) }

        // No output path is needed when stopping.
        let stopped = try ScanTailorCLI.parseProcessOptions(["book.pdf", "--stop-after", "layout", "--diagnostics-dir", "d"])
        #expect(stopped.outputPDFPath == "book-layout.pdf" && stopped.layoutSheets)
    }

    @Test("CLI: the file's book section becomes options, the command line wins, and a complete manifest is accepted too")
    func cliLoadsAdjustments() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adjust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("a.json")
        try Data("""
        { "book": { "margins": "0.5in", "page-size": "octavo", "outlier-pages": "2,s9L" },
          "pages": { "s3": { "skew": 0.1 } } }
        """.utf8).write(to: file)

        let args = ["in.pdf", "-o", "out.pdf", "--apply-manifest", file.path, "--margins", "0.9in"]
        let loaded = try ScanTailorCLI.loadAdjustments(into: try ScanTailorCLI.parseProcessOptions(args), arguments: args)
        #expect(loaded.margins == PublicationMargins.parse("0.9in"), "the command line wins")
        #expect(loaded.pageSize == PhysicalSizeSpec.parse("octavo"))
        #expect(loaded.outlierPages == [2] && loaded.outlierScanRefs == [.scan(9, .left)])
        #expect(loaded.adjustments.pages[.scan(3, .whole)]?.skewDegrees == 0.1)
        #expect(loaded.inputPDFPath == "in.pdf" && loaded.outputPDFPath == "out.pdf")

        // Errors are reported with the file name and every problem.
        let bad = dir.appendingPathComponent("bad.json")
        try Data("{ \"pages\": { \"s1\": { \"skeww\": 1 } }, \"scans\": { \"nine\": {} } }".utf8).write(to: bad)
        let badArgs = ["in.pdf", "-o", "out.pdf", "--apply-manifest", bad.path]
        #expect(throws: (any Error).self) { try ScanTailorCLI.loadAdjustments(into: try ScanTailorCLI.parseProcessOptions(badArgs), arguments: badArgs) }
        let missing = ["in.pdf", "-o", "out.pdf", "--apply-manifest", dir.appendingPathComponent("nope.json").path]
        #expect(throws: (any Error).self) { try ScanTailorCLI.loadAdjustments(into: try ScanTailorCLI.parseProcessOptions(missing), arguments: missing) }
    }

    @Test("CLI: a complete earlier manifest given to --apply-manifest is recognized and applied as before")
    func cliAcceptsFullManifest() async throws {
        let output = try await Self.run(Self.pipeline())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adjust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("full.json")
        try JSONEncoder().encode(output.manifest).write(to: file)
        let args = ["in.pdf", "-o", "out.pdf", "--apply-manifest", file.path]
        let loaded = try ScanTailorCLI.loadAdjustments(into: try ScanTailorCLI.parseProcessOptions(args), arguments: args)
        #expect(loaded.priorManifestPath == file.path && loaded.adjustments.isEmpty)
    }

    @Test("inspect --pages: one row per page with sizes and margins in inches, and the margin spread of full-body pages")
    func inspectPages() async throws {
        var pages = Self.book()
        pages[0] = DimensionConsensusTests.page(width: 801, height: 831)
        let output = try await Self.run(Self.pipeline(), pages: pages)
        let rows = ScanTailorCLI.pageRows(output.manifest)
        #expect(rows.count == 8)
        #expect(rows[0].ownCanvas && rows[0].scan == "s1" && rows[0].pdfPageInches != nil)
        #expect(rows[3].scan == "s4" && !rows[3].ownCanvas && rows[3].tier == "fullBody" && rows[3].page == 4)
        let margins = try #require(rows[3].marginsInches)
        let box = try #require(output.manifest.pages[3].layoutPlan.sourceContentBox)
        let canvas = output.manifest.pages[3].layoutPlan.canvasSize
        #expect(abs(margins.left + Double(box.width) / 300 + margins.right - Double(canvas.width) / 300) < 0.002)
        #expect(abs(margins.top + Double(box.height) / 300 + margins.bottom - Double(canvas.height) / 300) < 0.002)

        let table = ScanTailorCLI.formatPageTable(output.manifest)
        #expect(table.contains("s4") && table.contains("own canvas") && table.contains("Pages on their own canvas (outliers): 1"), "\(table)")
        #expect(table.contains("Full-body recto pages") || table.contains("Full-body verso pages"), "\(table)")
        #expect(table.split(separator: "\n").count >= 10)

        let json = try JSONEncoder().encode(rows)
        #expect(try JSONDecoder().decode([ScanTailorCLI.PageRow].self, from: json) == rows)
    }
}
