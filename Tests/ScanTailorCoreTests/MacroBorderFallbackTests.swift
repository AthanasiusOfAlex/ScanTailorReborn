import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

@Suite("Substep 5.2.2 — Macro-Cluster Border Cleaning Fallback Tests")
struct MacroBorderFallbackTests {
    static let width = 800
    static let height = 1000
    static let allSides: Set<DocumentQuadDetection.Side> = [.top, .right, .bottom, .left]

    static func fill(_ bitmap: inout BinaryBitmap, x0: Int, y0: Int, x1: Int, y1: Int, density: Double = 1.0) {
        var state: UInt64 = 0x9E3779B97F4A7C15
        for y in max(0, y0)..<min(bitmap.height, y1) {
            for x in max(0, x0)..<min(bitmap.width, x1) {
                if density >= 1.0 {
                    bitmap[x, y] = true
                } else {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    if Double(state >> 33) / Double(1 << 31) < density { bitmap[x, y] = true }
                }
            }
        }
    }

    /// A page of text-like glyph rows (cell density well below the solid-dark threshold).
    static func textPage() -> BinaryBitmap {
        var page = BinaryBitmap(width: width, height: height)
        for lineTop in stride(from: 150, to: 850, by: 24) {
            for x in stride(from: 300, to: 720, by: 8) {
                fill(&page, x0: x, y0: lineTop, x1: x + 5, y1: lineTop + 8)
            }
        }
        return page
    }

    static func context(_ sides: Set<DocumentQuadDetection.Side> = allSides) -> MacroBorderContext {
        MacroBorderContext(eligibleSides: sides, triggers: ["quad:marginal"])
    }

    static func blackCount(_ b: BinaryBitmap, x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
        var n = 0
        for y in y0..<y1 { for x in x0..<x1 where b[x, y] { n += 1 } }
        return n
    }

    // MARK: - Algorithm

    @Test("A deep solid edge block beyond the 14% strip limit survives the standard cleaner but is excised by the fallback")
    func deepBlockExcised() {
        var page = Self.textPage()
        let textBefore = Self.blackCount(page, x0: 280, y0: 100, x1: 760, y1: 900)
        Self.fill(&page, x0: 0, y0: 250, x1: 264, y1: 650) // 33% deep, 40% span

        let cleaner = BorderAndSpeckleCleaner()
        let plain = cleaner.clean(page)
        #expect(plain[100, 450], "the standard rules must leave a 33%-deep block (that is the gap)")

        let (cleaned, result) = cleaner.clean(page, fallback: Self.context())
        #expect(result?.didExcise == true)
        #expect((result?.excisedDepthBySide.left ?? 0) > 0.30)
        #expect(Self.blackCount(cleaned, x0: 0, y0: 240, x1: 280, y1: 660) == 0)
        #expect(Self.blackCount(cleaned, x0: 280, y0: 100, x1: 760, y1: 900) == textBefore, "text must survive untouched")
    }

    @Test("A desk remnant detached from the edge by a white band (e.g. a capped mask) is excised")
    func detachedRemnantExcised() {
        var page = Self.textPage()
        Self.fill(&page, x0: 64, y0: 300, x1: 260, y1: 700)
        let cleaner = BorderAndSpeckleCleaner()
        #expect(cleaner.clean(page)[150, 500], "detached from the edge: the standard cleaner never sees it")

        let (cleaned, result) = cleaner.clean(page, fallback: Self.context())
        #expect(result?.didExcise == true, "rejected: \(result?.rejectedCandidates ?? [])")
        #expect(Self.blackCount(cleaned, x0: 0, y0: 280, x1: 280, y1: 720) == 0)
    }

    @Test("A wood-grain block with holes (density ≈ 0.7) is excised")
    func woodGrainBlockExcised() {
        var page = Self.textPage()
        Self.fill(&page, x0: 0, y0: 250, x1: 250, y1: 650, density: 0.7)
        let (cleaned, result) = BorderAndSpeckleCleaner().clean(page, fallback: Self.context())
        #expect(result?.didExcise == true)
        let leftover = Self.blackCount(cleaned, x0: 0, y0: 240, x1: 280, y1: 660)
        #expect(leftover < 250 * 400 / 100, "only a trace of the grain may remain, got \(leftover)")
    }

    @Test("Legitimate content survives even on a marginal page: near-edge text, hatching, short blocks, too-deep figures, gutter side")
    func legitimateContentSurvives() {
        var page = Self.textPage()
        // Dense-ish text hugging the left edge (2% in).
        for x in stride(from: 16, to: 200, by: 8) { Self.fill(&page, x0: x, y0: 400, x1: x + 5, y1: 408) }
        // A dense narrow text column 5% from the edge: line gaps make it text-like, not desk.
        for lineTop in stride(from: 150, to: 850, by: 24) {
            for x in stride(from: 40, to: 240, by: 8) { Self.fill(&page, x0: x, y0: lineTop, x1: x + 5, y1: lineTop + 8) }
        }
        let cleaner = BorderAndSpeckleCleaner(configuration: .init(despeckle: false))
        let (cleaned, result) = cleaner.clean(page, fallback: Self.context())
        #expect(result?.didExcise == false)
        #expect(cleaned == cleaner.clean(page), "nothing but the standard cleanup may change")

        // Short span: deep block narrower than 15% of the edge is refused.
        var shortPage = Self.textPage()
        Self.fill(&shortPage, x0: 0, y0: 400, x1: 250, y1: 480)
        let (shortOut, shortResult) = cleaner.clean(shortPage, fallback: Self.context())
        #expect(shortResult?.rejectedCandidates.contains("left:shortSpan") == true)
        #expect(shortResult?.didExcise == false)
        #expect(shortOut == cleaner.clean(shortPage))

        // Full-bleed dark figure 45% deep is refused as probable content.
        var bleedPage = Self.textPage()
        Self.fill(&bleedPage, x0: 0, y0: 250, x1: 360, y1: 650)
        let (bleedOut, bleedResult) = cleaner.clean(bleedPage, fallback: Self.context())
        #expect(bleedResult?.rejectedCandidates.contains("left:tooDeep") == true)
        #expect(bleedResult?.didExcise == false)
        #expect(bleedOut == cleaner.clean(bleedPage))

        // A block on the gutter side of a left-verso slice is not eligible.
        var gutterPage = Self.textPage()
        Self.fill(&gutterPage, x0: 536, y0: 250, x1: 800, y1: 650)
        let versoSides: Set<DocumentQuadDetection.Side> = [.top, .bottom, .left]
        let (gutterOut, gutterResult) = cleaner.clean(gutterPage, fallback: Self.context(versoSides))
        #expect(gutterResult?.didExcise == false)
        #expect(gutterResult?.rejectedCandidates.contains(where: { $0.hasPrefix("right:") }) == false, "the gutter side is never examined")
        #expect(gutterOut == cleaner.clean(gutterPage))
    }

    @Test("No context means identical output and no telemetry; a disabled configuration also passes through")
    func passthrough() {
        var page = Self.textPage()
        Self.fill(&page, x0: 0, y0: 250, x1: 264, y1: 650)
        let cleaner = BorderAndSpeckleCleaner()
        let (same, none) = cleaner.clean(page, fallback: nil)
        #expect(same == cleaner.clean(page))
        #expect(none == nil)

        var config = BorderAndSpeckleCleaner.Configuration()
        config.macroBorder.enabled = false
        let (off, offResult) = BorderAndSpeckleCleaner(configuration: config).clean(page, fallback: Self.context())
        #expect(off == cleaner.clean(page))
        #expect(offResult == nil)

        // Legacy configuration JSON (before 5.2.2) decodes with defaults.
        let data = try? JSONEncoder().encode(BorderAndSpeckleCleaner.Configuration())
        var object = (try? JSONSerialization.jsonObject(with: data ?? Data())) as? [String: Any] ?? [:]
        object.removeValue(forKey: "macroBorder")
        let legacy = try? JSONDecoder().decode(
            BorderAndSpeckleCleaner.Configuration.self,
            from: (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        )
        #expect(legacy == BorderAndSpeckleCleaner.Configuration())
    }

    // MARK: - Engagement context

    @Test("Context builder: confident pages pass through; marginal, capped, or rejected pages engage; overrides apply")
    func contextBuilder() {
        let quad = DocumentQuad.fullFrame(width: 100, height: 100)
        func record(
            _ detection: DocumentQuadDetection?,
            mask: DeskMaskResult? = nil
        ) -> SourcePageGeometryRecord {
            SourcePageGeometryRecord(
                sourcePageIndex: 0, rasterSize: Size2I(width: 100, height: 100),
                detection: detection, rectified: false, plan: nil, deskMask: mask
            )
        }
        func ctx(_ r: SourcePageGeometryRecord, side: PageSide = .single, policy: BorderFallbackPolicy? = nil) -> MacroBorderContext? {
            r.borderFallbackContext(splitSide: side, policy: policy, marginalConfidence: 0.70)
        }
        let confident = DocumentQuadDetection(outcome: .detected, quad: quad, confidence: 0.9)
        let cleanMask = DeskMaskResult(mode: .residual, maskedFraction: 0.02)
        #expect(ctx(record(confident, mask: cleanMask)) == nil)
        #expect(ctx(record(DocumentQuadDetection(outcome: .fullFrame, quad: quad, confidence: 1), mask: .skipped(reason: "fullFrame"))) == nil)
        #expect(ctx(record(nil)) == nil)

        #expect(ctx(record(DocumentQuadDetection(outcome: .detected, quad: quad, confidence: 0.6)))?.triggers == ["quad:marginal"])
        let occluded = DocumentQuadDetection(outcome: .detected, quad: quad, confidence: 0.9, flags: ["occluded:left", "bentSide:top"])
        #expect(ctx(record(occluded))?.triggers == ["quad:occluded:left"])

        let rejected = DocumentQuadDetection(outcome: .rejected, quad: quad, confidence: 0.2)
        #expect(ctx(record(rejected))?.triggers == ["quad:rejected"])
        #expect(ctx(record(rejected, mask: DeskMaskResult(mode: .full, maskedFraction: 0.4))) == nil, "a clean full-mode mask handled it")

        let capped = DeskMaskResult(mode: .residual, maskedFraction: 0.1, flags: ["capped:depth"])
        #expect(ctx(record(confident, mask: capped))?.triggers == ["mask:capped:depth"])
        #expect(ctx(record(confident, mask: .skipped(reason: "noSharpBoundary")))?.triggers == ["mask:skipped:noSharpBoundary"])

        let marginal = record(DocumentQuadDetection(outcome: .detected, quad: quad, confidence: 0.6))
        #expect(ctx(marginal, side: .leftVerso)?.eligibleSides == [.top, .bottom, .left])
        #expect(ctx(marginal, side: .rightRecto)?.eligibleSides == [.top, .bottom, .right])
        #expect(ctx(marginal, policy: .disabled) == nil)
        #expect(ctx(record(nil), policy: .forced)?.triggers == ["forced"])
        #expect(ctx(record(confident, mask: cleanMask), policy: .forced)?.eligibleSides == Self.allSides)
    }

    // MARK: - Pipeline

    static func blockPage() -> GrayscaleBuffer {
        var gray = GrayscaleBuffer(width: 1200, height: 1500, dpi: 300, initialValue: 235)
        // A large dark block on the left edge: 33% deep, 40% of the height.
        // Textured like wood: dark grain bands plus per-pixel noise.
        var state: UInt64 = 12345
        for y in 375..<975 {
            for x in 0..<400 {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                let noise = Int(state >> 59) - 16 // -16...15
                let grain = ((y / 6) % 3) * 12 // horizontal grain bands
                gray.pixels[y * gray.width + x] = UInt8(max(0, min(255, 40 + grain + noise)))
            }
        }
        // Body text to the right.
        for lineTop in stride(from: 250, to: 1250, by: 36) {
            for x in stride(from: 500, to: 1050, by: 12) {
                for y in lineTop..<(lineTop + 14) { for dx in 0..<8 { gray.pixels[y * gray.width + x + dx] = 30 } }
            }
        }
        return gray
    }

    static func pipeline(fallback: Bool = true) -> BookPipelineCoordinator {
        BookPipelineCoordinator(configuration: .init(
            processingDPI: 300,
            outputDPI: 150,
            splitMode: .singlePage,
            enableDewarp: false,
            enableAutomaticFontScaleCalibration: false,
            enablePerspectiveRectification: false,
            enableDeskMasking: false,
            enableBorderFallback: fallback
        ))
    }

    @Test("Pipeline: confident page is untouched; forced override engages and records telemetry; disabled override and flag suppress it")
    func pipelineIntegration() async throws {
        let image = Self.blockPage()
        let accelerator = PortableComputeAccelerator()
        let first = try await Self.pipeline().processGrayscalePages([image], writer: NullWriter(), accelerator: accelerator)
        #expect(first.manifest.pages[0].borderFallback == nil, "no marginal telemetry, no fallback")
        #expect(!ScanTailorCLI.formatManifestSummary(first.manifest).contains("Border Fallback"))

        var manifest = first.manifest
        manifest.pages[0].manualOverride = PageManualOverride(borderFallback: .forced)
        let forced = try await Self.pipeline().processGrayscalePages(
            [image], writer: NullWriter(), accelerator: accelerator, existingManifest: manifest
        )
        let telemetry = try #require(forced.manifest.pages[0].borderFallback)
        #expect(telemetry.triggers == ["forced"])
        #expect(telemetry.didExcise, "rejected: \(telemetry.rejectedCandidates)")
        #expect(ScanTailorCLI.formatManifestSummary(forced.manifest).contains("Border Fallback: 1 excised"))
        #expect(forced.manifest.pages[0].manualOverride?.borderFallback == .forced)

        manifest.pages[0].manualOverride = PageManualOverride(borderFallback: .disabled)
        let disabled = try await Self.pipeline().processGrayscalePages(
            [image], writer: NullWriter(), accelerator: accelerator, existingManifest: manifest
        )
        #expect(disabled.manifest.pages[0].borderFallback == nil)

        manifest.pages[0].manualOverride = PageManualOverride(borderFallback: .forced)
        let switchedOff = try await Self.pipeline(fallback: false).processGrayscalePages(
            [image], writer: NullWriter(), accelerator: accelerator, existingManifest: manifest
        )
        #expect(switchedOff.manifest.pages[0].borderFallback == nil)

        // JSON round trip, and manifests from before 5.2.2 decode with no telemetry.
        let data = try JSONEncoder().encode(forced.manifest)
        #expect(try JSONDecoder().decode(BookProcessingManifest.self, from: data) == forced.manifest)
        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if var pages = legacy["pages"] as? [[String: Any]] {
            for i in pages.indices { pages[i].removeValue(forKey: "borderFallback") }
            legacy["pages"] = pages
        }
        let decoded = try JSONDecoder().decode(
            BookProcessingManifest.self, from: try JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(decoded.pages[0].borderFallback == nil)

        // CLI flag.
        #expect(try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf"]).enableBorderFallback)
        #expect(try !ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf", "--no-border-fallback"]).enableBorderFallback)
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
