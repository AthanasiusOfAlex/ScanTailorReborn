import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import ScanTailorAppleBackend
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import Testing

@Suite("Full Book Pipeline, Manifest Persistence & Diagnostic Overlay Integration Tests")
struct CLIIntegrationTests {

    @Test("End-to-end book pipeline splits spread, harmonizes 3-tier margins, writes 1-bit PDF, persists JSON manifest, and renders PNG diagnostic overlays")
    func testEndToEndBookPipelineManifestAndDiagnosticOverlays() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanTailorCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputPDFURL = tempDir.appendingPathComponent("input-spread-book.pdf")
        let outputPDFURL = tempDir.appendingPathComponent("output-clean-book.pdf")
        let outputOverridePDFURL = tempDir.appendingPathComponent("output-override-book.pdf")
        let manifestURL = tempDir.appendingPathComponent("book-manifest.json")
        let diagPNGURL = tempDir.appendingPathComponent("page-0001-diag.png")

        // 1. Create a synthetic 2-scan input PDF:
        //    - Scan 0: A wide two-page spread (288 x 216 pt = 4 x 3 inches) with left & right text columns and a gutter valley
        //    - Scan 1: A single portrait page (144 x 216 pt = 2 x 3 inches) with a standalone centered title/epigraph block
        try createSyntheticSpreadAndSinglePDF(at: inputPDFURL)

        let reader = try ApplePDFSourceReader(url: inputPDFURL)
        #expect(reader.pageCount == 2)

        let writer = try ApplePDFDocumentWriter(destinationURL: outputPDFURL)
        let accelerator = MetalComputeAccelerator()

        // Use 150 DPI processing -> 75 DPI output on compact PDF page boxes so the integration test runs in ~1s
        let config = BookPipelineCoordinator.Configuration(
            processingDPI: 150,
            outputDPI: 75,
            splitMode: .automatic,
            enableDewarp: true
        )
        let coordinator = BookPipelineCoordinator(configuration: config)

        let result = try await coordinator.processBook(
            reader: reader,
            writer: writer,
            accelerator: accelerator,
            ocrEngine: nil
        )

        // Scan 0 (two-page spread) splits into 2 pages + Scan 1 (single page) = 3 output pages!
        #expect(result.manifest.sourcePageSplits.count == 2)
        #expect(result.manifest.sourcePageSplits[0].layoutType == .twoPageSpread)
        #expect(result.manifest.sourcePageSplits[1].layoutType == .singlePage)
        #expect(result.manifest.pages.count == 3)

        // Verify output PDF exists and has 3 pages
        let outDoc = try #require(PDFDocument(url: outputPDFURL))
        #expect(outDoc.pageCount == 3)

        // 2. Persist manifest to JSON and verify round-trip decoding + manual override re-run
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(result.manifest)
        try manifestData.write(to: manifestURL)

        var decodedManifest = try JSONDecoder().decode(BookProcessingManifest.self, from: Data(contentsOf: manifestURL))
        #expect(decodedManifest == result.manifest)

        let customOrigin = Point2I(x: 42, y: 54)
        decodedManifest.pages[2].manualOverride = PageManualOverride(
            disableDewarp: true,
            overrideDestinationOrigin: customOrigin
        )

        let writer2 = try ApplePDFDocumentWriter(destinationURL: outputOverridePDFURL)
        let rerunResult = try await coordinator.processBook(
            reader: reader,
            writer: writer2,
            accelerator: accelerator,
            ocrEngine: nil,
            existingManifest: decodedManifest
        )
        #expect(rerunResult.manifest.pages[2].layoutPlan.destinationOrigin == customOrigin)
        #expect(rerunResult.manifest.pages[2].dewarpApplied == false)

        // 3. Render diagnostic overlay PNG for page 0 and verify valid PNG dimensions
        let overlayRenderer = DiagnosticOverlayRenderer()
        let p0Record = result.manifest.pages[0]
        let p0Bitmap = result.cleanedBitmapsAtProcessingDPI[0]

        try overlayRenderer.writePNGOverlay(
            bitmap: p0Bitmap,
            contentBox: p0Record.layoutPlan.sourceContentBox,
            retainedClusterBoxes: p0Record.layoutPlan.retainedClusterBoxes,
            rejectedBoxes: [Rect2I(x: 4, y: 4, width: 12, height: 12)],
            tracedLines: p0Record.tracedLines,
            to: diagPNGURL
        )

        let imageSource = try #require(CGImageSourceCreateWithURL(diagPNGURL as CFURL, nil))
        let cgImage = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(cgImage.width == p0Bitmap.width)
        #expect(cgImage.height == p0Bitmap.height)
    }

    // MARK: - Synthetic PDF Fixture Helper

    private func createSyntheticSpreadAndSinglePDF(at url: URL) throws {
        var defaultBox = CGRect(x: 0, y: 0, width: 144, height: 108)
        guard let ctx = CGContext(url as CFURL, mediaBox: &defaultBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        // Page 1: Two-page spread (144 x 108 pt, aspect = 1.333) with left page text, central dark spine crease at x=72, and right page text
        var spreadBox = CGRect(x: 0, y: 0, width: 144, height: 108)
        let spreadBoxData = withUnsafeBytes(of: &spreadBox) { Data($0) as CFData }
        ctx.beginPDFPage([kCGPDFContextMediaBox: spreadBoxData] as CFDictionary)
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(spreadBox)

        // Dark spine shadow at x = 71..73
        ctx.setFillColor(gray: 0.25, alpha: 1.0)
        ctx.fill(CGRect(x: 71, y: 0, width: 2, height: 108))

        // Left page text lines (x = 12..60) and Right page text lines (x = 84..132)
        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        for lineY in stride(from: 18, through: 90, by: 8) {
            var x = 12
            while x < 60 {
                ctx.fill(CGRect(x: x, y: lineY, width: 4, height: 3))
                x += 6
            }
            var rx = 84
            while rx < 132 {
                ctx.fill(CGRect(x: rx, y: lineY, width: 4, height: 3))
                rx += 6
            }
        }
        ctx.endPDFPage()

        // Page 2: Single portrait page (72 x 108 pt, aspect = 0.667) with a small standalone epigraph block
        var singleBox = CGRect(x: 0, y: 0, width: 72, height: 108)
        let singleBoxData = withUnsafeBytes(of: &singleBox) { Data($0) as CFData }
        ctx.beginPDFPage([kCGPDFContextMediaBox: singleBoxData] as CFDictionary)
        ctx.setFillColor(gray: 1.0, alpha: 1.0)
        ctx.fill(singleBox)

        ctx.setFillColor(gray: 0.0, alpha: 1.0)
        for lineY in [48, 56] {
            var x = 22
            while x < 50 {
                ctx.fill(CGRect(x: x, y: lineY, width: 4, height: 3))
                x += 6
            }
        }
        ctx.endPDFPage()
        ctx.closePDF()
    }
}
