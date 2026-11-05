import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

/// Records every page a run writes, with its text layer.
fileprivate final class PageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(box: Rect2D, text: [RecognizedTextObservation])] = []
    func add(_ box: Rect2D, _ text: [RecognizedTextObservation]) { lock.lock(); storage.append((box, text)); lock.unlock() }
    var boxes: [Rect2D] { lock.lock(); defer { lock.unlock() }; return storage.map(\.box) }
    var texts: [[RecognizedTextObservation]] { lock.lock(); defer { lock.unlock() }; return storage.map(\.text) }
}

private struct CapturingWriter: PDFDocumentWriter, ~Copyable {
    let log: PageLog
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap, dpi: Int, pageBoxPoints: Rect2D, ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) { log.add(pageBoxPoints, ocrLayer) }
    consuming func finalize() throws(PDFWriteError) {}
}

/// A deterministic OCR engine that counts its calls: one "word" per page, named after the page's ink.
private struct CountingOCR: OCREngine {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    let counter = Counter()

    func recognizeText(in bitmap: borrowing BinaryBitmap, dpi: Int, languages: [String]) async throws(OCRError) -> [RecognizedTextObservation] {
        counter.increment()
        let ink = bitmap.countBlackPixels()
        guard ink > 50 else { return [] }
        return [RecognizedTextObservation(text: "word\(ink)", confidence: 0.9, boundingBox: Rect2D(x: 0.1, y: 0.1, width: 0.5, height: 0.05))]
    }

    var cacheIdentity: String { "CountingOCR" }
}

@Suite("Substep 6.3.2 — Cached and Parallel Re-Runs")
struct PipelineCacheTests {
    // MARK: - Helpers

    /// Eight pages, each with a mark of its own so no two scans are alike, and a blank fifth scan.
    static func book() -> [GrayscaleBuffer] {
        (0..<8).map { i in
            if i == 4 { return GrayscaleBuffer(width: 600, height: 750, dpi: 300, initialValue: 235) }
            var page = DimensionConsensusTests.page(width: 600, height: 750)
            for y in 60..<(80 + 4 * i) {
                for x in (100 + 30 * i)..<(130 + 30 * i) { page.pixels[y * page.width + x] = 20 }
            }
            return page
        }
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("scantailor-cache-test-\(UUID().uuidString)", isDirectory: true)
    }

    static func pipeline(
        jobs: Int = 1,
        cache: URL? = nil,
        codeVersion: String = "test-1",
        adjustments: PageAdjustments = .empty,
        stopAfter: PipelineStop? = nil,
        enableDewarp: Bool = false
    ) -> BookPipelineCoordinator {
        BookPipelineCoordinator(configuration: .init(
            processingDPI: 300, outputDPI: 150, splitMode: .automatic,
            enableDewarp: enableDewarp, enableAutomaticFontScaleCalibration: false,
            enablePerspectiveRectification: false, enableDeskMasking: false,
            adjustments: adjustments,
            stopAfter: stopAfter,
            jobs: jobs,
            cache: cache.map { PipelineCacheOptions(directory: $0, codeVersion: codeVersion) }
        ))
    }

    fileprivate struct Run {
        var output: BookPipelineCoordinator.PipelineOutput
        var log: PageLog
        var ocrCalls: Int
        /// The manifest without the run report, which changes from run to run.
        var manifest: BookProcessingManifest {
            var m = output.manifest
            m.run = nil
            return m
        }
        var cache: PipelineRunReport.CacheReport? { output.manifest.run?.cache }
    }

    fileprivate static func run(_ pipeline: BookPipelineCoordinator, pages: [GrayscaleBuffer] = book()) async throws -> Run {
        let log = PageLog()
        let ocr = CountingOCR()
        let output = try await pipeline.processGrayscalePages(
            pages, writer: CapturingWriter(log: log), accelerator: PortableComputeAccelerator(), ocrEngine: ocr
        )
        return Run(output: output, log: log, ocrCalls: ocr.counter.count)
    }

    fileprivate static func expectSame(_ a: Run, _ b: Run, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(a.manifest == b.manifest, sourceLocation: sourceLocation)
        #expect(a.output.outputBitmapsAtOutputDPI == b.output.outputBitmapsAtOutputDPI, sourceLocation: sourceLocation)
        #expect(a.output.cleanedBitmapsAtProcessingDPI == b.output.cleanedBitmapsAtProcessingDPI, sourceLocation: sourceLocation)
        #expect(a.log.boxes == b.log.boxes, sourceLocation: sourceLocation)
        #expect(a.log.texts == b.log.texts, sourceLocation: sourceLocation)
    }

    static func adjustments(_ json: String) throws -> PageAdjustments {
        try PageAdjustments.parse(Data(json.utf8))
    }

    // MARK: - Identity

    @Test("A warm cache gives exactly the cold result, reusing every scan and every page's text")
    func warmEqualsCold() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let reference = try await Self.run(Self.pipeline())
        #expect(reference.output.manifest.prunedPages.isEmpty, "the blank fifth scan lies between pages: it keeps the book's order")
        #expect(reference.output.manifest.pages.count == 8)
        #expect(reference.cache == nil)

        let cold = try await Self.run(Self.pipeline(jobs: 3, cache: dir))
        Self.expectSame(reference, cold)
        #expect(cold.cache?.scansReused == 0)
        #expect(cold.cache?.ocrReused == 0)

        let warm = try await Self.run(Self.pipeline(jobs: 3, cache: dir))
        Self.expectSame(reference, warm)
        #expect(warm.cache?.scansReused == 8)
        #expect(warm.cache?.scans == 8)
        #expect(warm.cache?.ocrReused == 8)
        #expect(warm.cache?.ocrPages == 8)
        #expect(warm.ocrCalls == 0, "no OCR at all: pruning checks are cached with the scan, page text by its pixels")

        let report = try #require(warm.output.manifest.run)
        #expect(report.jobs == 3)
        #expect(report.timings.contains { $0.stage == "pass1" && $0.isElapsed })
    }

    @Test("Parallel runs equal one scan at a time, with drops, splits and edits by page number")
    func parallelEqualsSerial() async throws {
        let adj = try Self.adjustments("""
        { "scans": { "s4": { "splitX": "50%" } },
          "pages": { "2": { "skew": 1.0, "offset": { "x": "1mm" } }, "s4R": { "drop": true }, "s7": { "disableDewarp": true }, "7": { "tier": "standaloneFloating" } } }
        """)
        let serial = try await Self.run(Self.pipeline(jobs: 1, adjustments: adj))
        let parallel = try await Self.run(Self.pipeline(jobs: 4, adjustments: adj))
        Self.expectSame(serial, parallel)
        let pages = serial.output.manifest.pages
        #expect(pages[1].skewAngleDegrees == 1.0, "an edit by page number reaches pass 1")
        #expect(serial.output.manifest.adjustments?.ignored.isEmpty == true, "\(serial.output.manifest.adjustments?.ignored ?? [])")
        #expect(serial.output.manifest.prunedPages.contains { $0.reason.contains("drop") })
    }

    // MARK: - Invalidation

    @Test("A pixel-changing edit re-processes only its scan; layout edits re-process nothing")
    func selectiveInvalidation() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await Self.run(Self.pipeline(jobs: 4, cache: dir))

        let skew = try Self.adjustments(#"{ "pages": { "s3": { "skew": 0.8 } } }"#)
        let skewed = try await Self.run(Self.pipeline(jobs: 4, cache: dir, adjustments: skew))
        #expect(skewed.cache?.scansReused == 7)
        Self.expectSame(skewed, try await Self.run(Self.pipeline(adjustments: skew)))

        let layoutOnly = try Self.adjustments(#"{ "pages": { "s2": { "offset": { "y": "2mm" }, "tier": "standaloneFloating" }, "6": { "outlier": true } } }"#)
        let moved = try await Self.run(Self.pipeline(jobs: 4, cache: dir, adjustments: layoutOnly))
        #expect(moved.cache?.scansReused == 8)
        Self.expectSame(moved, try await Self.run(Self.pipeline(adjustments: layoutOnly)))

        // An edit by page number is matched after numbering; the corrected page is cached for next time.
        let byNumber = try Self.adjustments(#"{ "pages": { "3": { "skew": -0.6 } } }"#)
        let first = try await Self.run(Self.pipeline(jobs: 4, cache: dir, adjustments: byNumber))
        #expect(first.cache?.scansReused == 7)
        #expect(first.output.manifest.pages[2].skewAngleDegrees == -0.6)
        let second = try await Self.run(Self.pipeline(jobs: 4, cache: dir, adjustments: byNumber))
        #expect(second.cache?.scansReused == 8)
        Self.expectSame(first, second)
    }

    @Test("A new code version or a changed pass-1 option reuses nothing")
    func versionAndOptionsInvalidate() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await Self.run(Self.pipeline(jobs: 2, cache: dir))

        let rebuilt = try await Self.run(Self.pipeline(jobs: 2, cache: dir, codeVersion: "test-2"))
        #expect(rebuilt.cache?.scansReused == 0)
        #expect(rebuilt.cache?.ocrReused == 0)

        let dewarp = try await Self.run(Self.pipeline(jobs: 2, cache: dir, enableDewarp: true))
        #expect(dewarp.cache?.scansReused == 0)
    }

    @Test("Unreadable or missing cache entries are recomputed")
    func corruptEntries() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let reference = try await Self.run(Self.pipeline(jobs: 2, cache: dir))

        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "bin" } ?? []
        #expect(!files.isEmpty)
        for (i, file) in files.enumerated() {
            if i.isMultiple(of: 2) {
                try Data("not a cache entry".utf8).write(to: file)
            } else {
                try FileManager.default.removeItem(at: file)
            }
        }
        let recovered = try await Self.run(Self.pipeline(jobs: 2, cache: dir))
        Self.expectSame(reference, recovered)
        #expect(recovered.cache?.scansReused == 0)

        try FileManager.default.removeItem(at: dir)
        Self.expectSame(reference, try await Self.run(Self.pipeline(jobs: 2, cache: dir)))
    }

    @Test("A stopped run fills the cache that a complete run then uses")
    func stoppedRunFillsCache() async throws {
        let dir = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let layout = try await Self.run(Self.pipeline(jobs: 4, cache: dir, stopAfter: .layout))
        #expect(layout.log.boxes.isEmpty)
        #expect(layout.cache?.ocrPages == 0)
        let full = try await Self.run(Self.pipeline(jobs: 4, cache: dir))
        #expect(full.cache?.scansReused == 8)
        Self.expectSame(full, try await Self.run(Self.pipeline()))
    }

    // MARK: - Building blocks

    @Test("Bounded parallel map keeps input order, respects the limit, and reports progress")
    func boundedParallel() async throws {
        final class Gauge: @unchecked Sendable {
            let lock = NSLock()
            var current = 0
            var peak = 0
            func enter() { lock.lock(); current += 1; peak = max(peak, current); lock.unlock() }
            func leave() { lock.lock(); current -= 1; lock.unlock() }
        }
        let gauge = Gauge()
        var reported: [Int] = []
        let results = try await BoundedParallel.map(count: 20, jobs: 3, progress: { reported.append($0) }) { (i: Int) async throws(CancellationError) -> Int in
            gauge.enter()
            defer { gauge.leave() }
            try? await Task.sleep(for: .milliseconds(Int.random(in: 1...5)))
            return i * i
        }
        #expect(results == (0..<20).map { $0 * $0 })
        #expect(gauge.peak <= 3)
        #expect(reported == Array(1...20))

        struct Boom: Error, Equatable {}
        await #expect(throws: Boom.self) {
            _ = try await BoundedParallel.map(count: 10, jobs: 2) { (i: Int) async throws(Boom) -> Int in
                if i == 4 { throw Boom() }
                return i
            }
        }
    }

    @Test("Cached bitmaps round-trip; a stored size that does not match its words is rejected")
    func cachedBitmap() {
        var bitmap = BinaryBitmap(width: 130, height: 7)
        bitmap[3, 2] = true
        bitmap[129, 6] = true
        #expect(CachedBitmap(bitmap).bitmap == bitmap)
        var broken = CachedBitmap(bitmap)
        broken.height = 8
        #expect(broken.bitmap == nil)
    }

    @Test("CLI: --jobs, --cache-dir, --no-cache and --timings; the cache line and timing table")
    func cliFlags() throws {
        let defaults = try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf"])
        #expect(defaults.jobs == ScanTailorCLI.defaultJobs)
        #expect(defaults.useCache)
        #expect(defaults.cacheDirPath == nil)
        #expect(!defaults.showTimings)

        let opts = try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf", "-j", "6", "--cache-dir", "/tmp/c", "--timings"])
        #expect(opts.jobs == 6)
        #expect(opts.cacheDirPath == "/tmp/c")
        #expect(opts.showTimings)
        #expect(try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "o.pdf", "--no-cache"]).useCache == false)
        #expect(throws: ScanTailorCLI.CLIError.self) { try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "o.pdf", "--jobs", "0"]) }

        let report = PipelineRunReport(
            jobs: 4,
            cache: .init(scansReused: 15, scans: 16, ocrReused: 14, ocrPages: 16, directory: "/c"),
            timings: [.init(stage: "total", seconds: 1.5, isElapsed: true), .init(stage: "pass1.binarize", seconds: 0.25, isElapsed: false)]
        )
        #expect(ScanTailorCLI.formatCacheLine(report) == "Cache: 15/16 scans reused, OCR of 14/16 pages reused (/c; --no-cache to recompute)")
        let table = ScanTailorCLI.formatTimings(report)
        #expect(table.contains("Timings (elapsed, 4 jobs): total 1.50 s"))
        #expect(table.contains("pass1.binarize  0.25 s"))
        #expect(!ScanTailorCLI.buildIdentity().isEmpty)
    }
}
