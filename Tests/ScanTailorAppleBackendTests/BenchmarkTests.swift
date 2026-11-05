import Foundation
import ScanTailorAppleBackend
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import Testing

/// Opt-in multi-document benchmark of the v1.0 release criteria (Substep 7.1.1).
///
/// It runs three whole documents through the layout stages (`--stop-after layout`, four jobs, a throw-away
/// cache) and scores the manifest against the publication layout rules: one hugging canvas per book, every
/// page centered left to right, header pages aligned at the top, sensible physical size. A second, warm run
/// times the edit loop. Checks that a book is known to fail sit in ``Book/knownFailing``; they run under
/// `withKnownIssue`, so fixing one makes the test report it until the entry is removed.
///
/// ```
/// SCANTAILOR_CORPUS_DIR="$HOME/Library/CloudStorage/OneDrive-MRC/PDFs-in-the-making" \
///   SCANTAILOR_BENCHMARK=1 swift test -c release --filter BenchmarkTests
/// ```
///
/// `SCANTAILOR_BENCHMARK_OUT` names the folder that receives the JSON scorecards (default: the temp folder).
/// Measuring ink outside the paper and stroke widths needs rendered pages; that belongs to Substep 7.1.2.
private let benchmarkEnabled: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["SCANTAILOR_BENCHMARK"] == "1" && !(env["SCANTAILOR_CORPUS_DIR"] ?? "").isEmpty
}()

@Suite("v1.0 benchmark (opt-in: SCANTAILOR_BENCHMARK=1 and SCANTAILOR_CORPUS_DIR)", .enabled(if: benchmarkEnabled), .serialized)
struct BenchmarkTests {
    struct Book {
        var name: String
        var relativePath: String
        /// Names of checks that fail today (see ``Scorecard/Check/id``), with the substep expected to fix them.
        var knownFailing: [String: String]
        /// A small adjustments file (JSON, as for `--apply-manifest`) for the pages automatic detection cannot settle.
        /// When present the book is scored twice: automatically, and again with these adjustments, which must pass
        /// every check (``Book/knownFailing`` applies to the automatic run only).
        var adjustments: String? = nil
    }

    static let flannery = Book(name: "flannery.1993", relativePath: "flannery.1993/00-pdf-orig/flannery.1993.pdf", knownFailing: [:])
    // Vermeersch (7.1.1c): specks are ignored and recto headers recognized automatically. Scan 2 has halftone gutter
    // shadow fused into its text on both halves; no rule separates it safely, so those two boxes are set by hand
    // (rects from the diagnostic images: text extent in inches from the page's top-left corner). The title page
    // (scan 1, blank left half) is a cover matter for 7.1.1d and is left out of `boxes-sane`.
    static let vermeersch = Book(
        name: "vermeersch.1934", relativePath: "vermeersch.1934/00-pdf-orig/vermeersch.1934.pdf",
        knownFailing: ["boxes-sane": "manual boxes for s2L and s2R (adjustments file)"],
        adjustments: """
        { "version": 1,
          "pages": {
            "s2L": { "contentBox": { "rect": ["1.23in", "0.65in", "4.82in", "7.45in"] }, "_why": "halftone gutter shadow fused with the text at the right edge" },
            "s2R": { "contentBox": { "rect": ["0.27in", "1.08in", "3.88in", "7.53in"] }, "_why": "halftone shadow along the left edge and top-left" }
          } }
        """
    )
    // Camera photo, cropped to the paper, split at the fold, and each page scaled to the book's text block (7.1.1b).
    static let simpson = Book(name: "simpson.1968 (pp. 280-281)", relativePath: "simpson.1968/simpson.1968.280-281.pdf", knownFailing: [:])

    /// Scored results for one book; written as JSON.
    struct Scorecard: Codable {
        struct Check: Codable {
            var id: String
            var passed: Bool
            var detail: String
        }
        /// `automatic`, or `adjusted` (scored again with the book's adjustments file).
        var variant: String
        var book: String
        var pages: Int
        var canonicalPages: Int
        var canvasInches: [String]
        var coldSeconds: Double
        var warmSeconds: Double
        var checks: [Check]
    }

    static let marginTolerance = 0.1   // inches
    static let sideMargin = 0.5
    static let topMargin = 0.25

    static func run(_ book: Book, cache: PipelineCacheOptions, adjusted: Bool = false) async throws -> (BookProcessingManifest, Double) {
        let root = try #require(ProcessInfo.processInfo.environment["SCANTAILOR_CORPUS_DIR"])
        let url = URL(fileURLWithPath: root).appendingPathComponent(book.relativePath)
        try #require(FileManager.default.fileExists(atPath: url.path), "missing corpus file \(url.path)")
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("ScanTailorBench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let reader = try ApplePDFSourceReader(url: url)
        let writer = try ApplePDFDocumentWriter(destinationURL: tempDir.appendingPathComponent("out.pdf"))
        var configuration = BookPipelineCoordinator.Configuration()
        configuration.stopAfter = .layout
        configuration.jobs = 4
        configuration.cache = cache
        if adjusted, let json = book.adjustments {
            configuration.adjustments = try PageAdjustments.parse(Data(json.utf8))
        }
        let start = ContinuousClock.now
        let output = try await BookPipelineCoordinator(configuration: configuration).processBook(
            reader: reader, writer: writer, accelerator: MetalComputeAccelerator(), ocrEngine: nil
        )
        let c = (ContinuousClock.now - start).components
        return (output.manifest, Double(c.seconds) + Double(c.attoseconds) * 1e-18)
    }

    /// Scores a manifest against the layout rules (distances in inches).
    static func score(_ book: Book, manifest m: BookProcessingManifest, cold: Double, warm: Double, variant: String = "automatic") -> Scorecard {
        let dpi = Double(m.processingDPI)
        let isolated = Set(m.dimensionConsensus?.isolatedCanvasPages ?? [])
        let body = m.pages.filter { !isolated.contains($0.outputPageIndex) && $0.layoutPlan.sourceContentBox != nil }

        func margins(_ p: PageProcessingRecord) -> (l: Double, r: Double, t: Double, b: Double)? {
            let plan = p.layoutPlan
            guard let box = plan.sourceContentBox else { return nil }
            return (
                Double(plan.destinationOrigin.x) / dpi,
                Double(plan.canvasSize.width - plan.destinationOrigin.x - box.width) / dpi,
                Double(plan.destinationOrigin.y) / dpi,
                Double(plan.canvasSize.height - plan.destinationOrigin.y - box.height) / dpi
            )
        }
        func f(_ v: Double) -> String { String(format: "%.2f", v) }

        var checks: [Scorecard.Check] = []

        // 1. Criterion 6: one canvas for every non-isolated page.
        let sizes = Set(body.map { "\($0.layoutPlan.canvasSize.width)x\($0.layoutPlan.canvasSize.height)" })
        checks.append(.init(id: "canvas-uniform", passed: sizes.count <= 1, detail: "\(sizes.count) distinct canvas sizes"))

        // 2. Criterion 3: the canvas hugs the text block (the widest body page touches 1/2 in left and right, the
        //    tallest 1/4 in top and bottom, within tolerance).
        let all = body.compactMap { margins($0) }
        let minL = all.map(\.l).min() ?? 0, minR = all.map(\.r).min() ?? 0
        let minT = all.map(\.t).min() ?? 0, minB = all.map(\.b).min() ?? 0
        let hugs = abs(minL - sideMargin) <= marginTolerance && abs(minR - sideMargin) <= marginTolerance
            && abs(minT - topMargin) <= marginTolerance && abs(minB - topMargin) <= marginTolerance
        checks.append(.init(id: "canvas-hugs-text", passed: hugs,
            detail: "smallest margins L \(f(minL)) R \(f(minR)) T \(f(minT)) B \(f(minB)) in; want 0.50/0.50/0.25/0.25"))

        // 3. Every page centered left to right, except floating pages off to one side (those are not counted).
        let candidates = body.filter { $0.layoutPlan.tier != .standaloneFloating }
        let off = candidates.filter { p in margins(p).map { abs($0.l - $0.r) > marginTolerance } ?? false }
        checks.append(.init(id: "pages-centered", passed: off.isEmpty,
            detail: "\(off.count) of \(candidates.count) pages are off-center by more than \(f(marginTolerance)) in"))

        // 4. Header pages sit at the same height, and at the top margin.
        let headerPages = body.filter { $0.registration?.method == .header }
        let tops = headerPages.compactMap { margins($0)?.t }
        let topSpread = (tops.max() ?? 0) - (tops.min() ?? 0)
        let topOK = tops.isEmpty || (topSpread <= marginTolerance / 1.5 && abs((tops.min() ?? 0) - topMargin) <= marginTolerance)
        checks.append(.init(id: "header-pages-top-aligned", passed: topOK,
            detail: "\(headerPages.count) header pages, top margin \(f(tops.min() ?? 0))–\(f(tops.max() ?? 0)) in"))

        // 5. Criterion 4: header baselines line up after registration.
        let v = m.verticalRegistration
        let hasHeaders = (m.runningHeaderModel?.sides.contains { $0.headerPageCount > 0 }) ?? false
        let aligned = !hasHeaders || ((v?.headerPageCount ?? 0) >= max(1, body.count / 4) && (v?.headerSpreadAfterPixels ?? 1) == 0
            && (v?.preservedPageCount ?? 0) <= max(1, body.count / 4))
        checks.append(.init(id: "header-registration", passed: aligned,
            detail: "header pages \(v?.headerPageCount ?? 0), spread \(v?.headerSpreadAfterPixels.map(String.init) ?? "-") px, preserved \(v?.preservedPageCount ?? 0)"))

        // 6. Criterion 7: believable physical page size (3–10 in wide, 4–13 in tall), not flagged ambiguous.
        let canvasPlan = body.first?.layoutPlan.canvasSize
        let w = Double(canvasPlan?.width ?? 0) / dpi, h = Double(canvasPlan?.height ?? 0) / dpi
        let sizeOK = (3...10).contains(w) && (4...13).contains(h) && !m.physicalScaleAmbiguous
        checks.append(.init(id: "physical-size", passed: sizeOK, detail: "canvas \(f(w))×\(f(h)) in; ambiguous: \(m.physicalScaleAmbiguous)"))

        // 7. No page's text block is far bigger than the book's typical one or touches the top of its scan: those are
        //    gutter shadow and scan-edge ink taken for text (the pages `inspect --pages` lists under "Pages to check").
        //    The first output page, a title page beside a blank half, belongs to the cover rules (7.1.1d).
        let sized = m.pages.compactMap { p -> (PageProcessingRecord, Rect2I)? in p.layoutPlan.sourceContentBox.map { (p, $0) } }
        func medianOf(_ values: [Int]) -> Double { values.isEmpty ? 0 : Double(values.sorted()[values.count / 2]) }
        let typicalW = medianOf(body.compactMap { $0.layoutPlan.sourceContentBox?.width })
        let typicalH = medianOf(body.compactMap { $0.layoutPlan.sourceContentBox?.height })
        let oversized = sized.filter { page, box in
            page.outputPageIndex > 0 && (Double(box.width) > 1.08 * typicalW || Double(box.height) > 1.08 * typicalH
                || Double(box.minY) / dpi < 0.05)
        }.map { "\($0.0.outputPageIndex + 1)" }
        checks.append(.init(id: "boxes-sane", passed: oversized.isEmpty,
            detail: oversized.isEmpty ? "no oversized boxes" : "oversized boxes on pages \(oversized.joined(separator: ", "))"))

        // 8. Criterion 10: the warm edit loop is fast (under a fifth of the cold run, or under 5 s).
        checks.append(.init(id: "warm-run-fast", passed: warm < max(5, cold / 5), detail: "cold \(f(cold)) s, warm \(f(warm)) s"))

        return Scorecard(
            variant: variant, book: book.name, pages: m.pages.count, canonicalPages: body.count,
            canvasInches: sizes.sorted(), coldSeconds: cold, warmSeconds: warm, checks: checks
        )
    }

    static func benchmark(_ book: Book) async throws {
        let root = try #require(ProcessInfo.processInfo.environment["SCANTAILOR_CORPUS_DIR"])
        let url = URL(fileURLWithPath: root).appendingPathComponent(book.relativePath)
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("ScanTailorBenchCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let cache = PipelineCacheOptions(directory: cacheDir, codeVersion: "benchmark", sourceFingerprint: PipelineCacheOptions.fingerprint(ofFileAt: url))

        let (_, coldSeconds) = try await run(book, cache: cache)
        let (manifest, warmSeconds) = try await run(book, cache: cache)
        let card = score(book, manifest: manifest, cold: coldSeconds, warm: warmSeconds)

        var adjustedCard: Scorecard? = nil
        if book.adjustments != nil {
            let (adjustedManifest, adjustedSeconds) = try await run(book, cache: cache, adjusted: true)
            adjustedCard = score(book, manifest: adjustedManifest, cold: coldSeconds, warm: adjustedSeconds, variant: "adjusted")
        }

        let outDir = ProcessInfo.processInfo.environment["SCANTAILOR_BENCHMARK_OUT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let slug = book.name.split(separator: " ").first.map(String.init) ?? book.name
        try encoder.encode(card).write(to: outDir.appendingPathComponent("benchmark-\(slug).json"))
        if let adjustedCard {
            try encoder.encode(adjustedCard).write(to: outDir.appendingPathComponent("benchmark-\(slug)-adjusted.json"))
        }

        for check in card.checks {
            if let fixedBy = book.knownFailing[check.id] {
                withKnownIssue("\(check.id) fails automatically until \(fixedBy): \(check.detail)") {
                    #expect(check.passed, "\(check.detail)")
                }
            } else {
                #expect(check.passed, "\(check.id): \(check.detail)")
            }
        }
        // With the adjustments file every check must pass: the manual route closes the gap.
        for check in adjustedCard?.checks ?? [] {
            #expect(check.passed, "adjusted \(check.id): \(check.detail)")
        }
    }

    @Test("Flannery 1993 (whole book)") func flanneryBook() async throws { try await Self.benchmark(Self.flannery) }
    @Test("Vermeersch 1934 (whole book)") func vermeerschBook() async throws { try await Self.benchmark(Self.vermeersch) }
    @Test("Simpson 1968 (pp. 280-281, camera photos)") func simpsonBook() async throws { try await Self.benchmark(Self.simpson) }
}
