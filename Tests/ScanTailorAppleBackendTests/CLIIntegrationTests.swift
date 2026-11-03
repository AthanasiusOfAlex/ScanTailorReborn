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

    @Test("Automatic font-scale pre-raster calibration rescues uncalibrated 72-DPI camera-wrapper spread PDF into true book-sized output pages")
    func testUncalibrated72DPICameraWrapperSpreadPDFAutoRescalesToBookDimensions() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanTailorFontScaleCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputPDFURL = tempDir.appendingPathComponent("uncalibrated-camera-spread.pdf")
        let outputPDFURL = tempDir.appendingPathComponent("calibrated-book-output.pdf")
        let rerunPDFURL = tempDir.appendingPathComponent("calibrated-book-rerun.pdf")

        // Simulate a 300-optical-DPI camera capture of an 11.0" x 8.0" two-page spread (3300 x 2400 px)
        // wrapped into a PDF with missing DPI metadata so PDFKit reports 3300 x 2400 pt (45.83" x 33.33").
        try createSyntheticUncalibrated72DPICameraSpreadPDF(at: inputPDFURL)

        let reader = try ApplePDFSourceReader(url: inputPDFURL)
        #expect(reader.pageCount == 1)
        let declaredPoints = try reader.pageBoxPoints(at: 0)
        #expect(declaredPoints.width == 3300)
        #expect(declaredPoints.height == 2400)

        let writer = try ApplePDFDocumentWriter(destinationURL: outputPDFURL)
        let accelerator = MetalComputeAccelerator()

        // Use 300 DPI internal processing -> 150 DPI output (2:1 downsample) so Debug (-Onone) test runs remain fast
        // while still exercising full-page typography (20 px x-height / 30 px cap-height) and physical inch sizing.
        let config = BookPipelineCoordinator.Configuration(
            processingDPI: 300,
            outputDPI: 150,
            splitMode: .automatic,
            enableDewarp: false
        )
        let coordinator = BookPipelineCoordinator(configuration: config)

        let result = try await coordinator.processBook(
            reader: reader,
            writer: writer,
            accelerator: accelerator,
            ocrEngine: nil
        )

        // 1. Spread splits cleanly into 2 book pages
        #expect(result.manifest.sourcePageSplits.count == 1)
        #expect(result.manifest.sourcePageSplits[0].layoutType == .twoPageSpread)
        #expect(result.manifest.pages.count == 2)

        // 2. Verify fontScaleEstimate telemetry recorded pre-raster rescue (~300 optical DPI, ~0.24x scale factor)
        #expect(result.manifest.physicalScaleAmbiguous == false)
        let scaleEstimate = try #require(result.manifest.fontScaleEstimate)
        #expect(scaleEstimate.wasAutoRescaled == true)
        #expect(scaleEstimate.wasAntiBillboardClamped == false)
        #expect(scaleEstimate.inferredSourceOpticalDPI >= 265.0 && scaleEstimate.inferredSourceOpticalDPI <= 335.0)
        #expect(scaleEstimate.appliedScaleCorrectionFactor >= 0.21 && scaleEstimate.appliedScaleCorrectionFactor <= 0.28)
        #expect(scaleEstimate.estimatedBodyPointSize >= 9.0 && scaleEstimate.estimatedBodyPointSize <= 11.2)
        #expect(scaleEstimate.declaredBodyPointSizeBeforeRescale >= 36.0 && scaleEstimate.declaredBodyPointSizeBeforeRescale <= 48.0)

        // 3. Verify output PDF pages have genuine book dimensions (~5.0"–6.5" x ~7.0"–8.5"), NOT 22" x 33" billboards
        let outDoc = try #require(PDFDocument(url: outputPDFURL))
        #expect(outDoc.pageCount == 2)
        for pageIdx in 0..<outDoc.pageCount {
            let pdfPage = try #require(outDoc.page(at: pageIdx))
            let mediaBounds = pdfPage.bounds(for: .mediaBox)
            let widthInches = Double(mediaBounds.width) / 72.0
            let heightInches = Double(mediaBounds.height) / 72.0
            #expect(widthInches >= 5.0 && widthInches <= 6.5)
            #expect(heightInches >= 7.0 && heightInches <= 8.5)
        }

        // 4. Verify JSON manifest round-trip and deterministic override re-run reuse appliedScaleCorrectionFactor
        let manifestData = try JSONEncoder().encode(result.manifest)
        let decodedManifest = try JSONDecoder().decode(BookProcessingManifest.self, from: manifestData)
        #expect(decodedManifest == result.manifest)

        let rerunWriter = try ApplePDFDocumentWriter(destinationURL: rerunPDFURL)
        let rerunResult = try await coordinator.processBook(
            reader: reader,
            writer: rerunWriter,
            accelerator: accelerator,
            ocrEngine: nil,
            existingManifest: decodedManifest
        )
        #expect(rerunResult.manifest.canonicalCanvasSizeAtProcessingDPI == result.manifest.canonicalCanvasSizeAtProcessingDPI)
        #expect(
            rerunResult.manifest.fontScaleEstimate?.appliedScaleCorrectionFactor
                == result.manifest.fontScaleEstimate?.appliedScaleCorrectionFactor
        )
    }

    @Test("Explicit --input-dpi, --page-size, and --content-box-size controls produce exact target PDF MediaBox dimensions on uncalibrated camera spreads")
    func testExplicitCLIDimensionAndInputDPIOverridesProduceExactPDFMediaBoxes() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanTailorDimensionCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputPDFURL = tempDir.appendingPathComponent("uncalibrated-spread.pdf")
        let a5PDFURL = tempDir.appendingPathComponent("a5-output.pdf")
        let contentBoxPDFURL = tempDir.appendingPathComponent("content-box-output.pdf")

        try createSyntheticUncalibrated72DPICameraSpreadPDF(at: inputPDFURL)
        let reader = try ApplePDFSourceReader(url: inputPDFURL)
        let accelerator = MetalComputeAccelerator()

        // 1. Explicit `inputDPI: 300` + `targetPageSize: .preset(.a5)` (148 x 210 mm = 419.53 x 595.28 pt)
        let a5Writer = try ApplePDFDocumentWriter(destinationURL: a5PDFURL)
        let a5Config = BookPipelineCoordinator.Configuration(
            processingDPI: 300,
            outputDPI: 150,
            inputDPI: 300,
            targetPageSize: .preset(.a5),
            splitMode: .automatic,
            enableDewarp: false
        )
        let a5Result = try await BookPipelineCoordinator(configuration: a5Config).processBook(
            reader: reader,
            writer: a5Writer,
            accelerator: accelerator,
            ocrEngine: nil
        )

        #expect(a5Result.manifest.inputDPI == 300)
        #expect(a5Result.manifest.pageSize == .preset(.a5))
        #expect(a5Result.manifest.fontScaleEstimate?.inferredSourceOpticalDPI == 300.0)
        #expect(abs((a5Result.manifest.fontScaleEstimate?.appliedScaleCorrectionFactor ?? 0.0) - 0.24) < 1e-6)

        let a5Doc = try #require(PDFDocument(url: a5PDFURL))
        #expect(a5Doc.pageCount == 2)
        let expectedA5Pts = PhysicalSizeSpec.preset(.a5).sizeInPoints
        for idx in 0..<a5Doc.pageCount {
            let bounds = try #require(a5Doc.page(at: idx)).bounds(for: .mediaBox)
            #expect(abs(Double(bounds.width) - expectedA5Pts.width) <= 1.0)
            #expect(abs(Double(bounds.height) - expectedA5Pts.height) <= 1.0)
        }

        // 2. Explicit `targetContentBoxSize: 4x5.8in` (without `inputDPI` or `targetPageSize`) + default margins (0.5" L/R, 0.25" T/B)
        //    -> Expected output page size = 5.0" x 6.3" (360.0 x 453.6 pt)!
        let boxSpec = try #require(PhysicalSizeSpec.parse("4x5.8in"))
        let boxWriter = try ApplePDFDocumentWriter(destinationURL: contentBoxPDFURL)
        let boxConfig = BookPipelineCoordinator.Configuration(
            processingDPI: 300,
            outputDPI: 150,
            targetContentBoxSize: boxSpec,
            splitMode: .automatic,
            enableDewarp: false
        )
        let boxResult = try await BookPipelineCoordinator(configuration: boxConfig).processBook(
            reader: reader,
            writer: boxWriter,
            accelerator: accelerator,
            ocrEngine: nil
        )

        #expect(boxResult.manifest.contentBoxSize == boxSpec)
        #expect(boxResult.manifest.versoCanonicalFrame.width == 1200) // 4.0" at 300 DPI
        #expect(boxResult.manifest.versoCanonicalFrame.height == 1740) // 5.8" at 300 DPI

        let boxDoc = try #require(PDFDocument(url: contentBoxPDFURL))
        #expect(boxDoc.pageCount == 2)
        for idx in 0..<boxDoc.pageCount {
            let bounds = try #require(boxDoc.page(at: idx)).bounds(for: .mediaBox)
            #expect(abs(Double(bounds.width) - 360.0) <= 1.5)
            #expect(abs(Double(bounds.height) - 453.6) <= 1.5)
        }
    }

    @Test("Illustration-only 72-DPI camera wrapper clamps billboard PDF MediaBox below 14 inches, flags physicalScaleAmbiguous, and honors explicit folio override")
    func testIllustrationOnlyCameraWrapperClampsBillboardMediaBoxAndEscalatesUntilPageSizeOverride() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScanTailorAntiBillboardCLITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inputPDFURL = tempDir.appendingPathComponent("illustration-billboard.pdf")
        let autoClampedPDFURL = tempDir.appendingPathComponent("auto-clamped.pdf")
        let folioPDFURL = tempDir.appendingPathComponent("folio-resolved.pdf")

        // 2400 x 3600 pt = 33.33" x 50.0" camera photo containing a full-page ornamental plate (0 prose lines)
        try createSyntheticIllustrationOnlyCameraWrapperPDF(at: inputPDFURL)
        let reader = try ApplePDFSourceReader(url: inputPDFURL)
        let accelerator = MetalComputeAccelerator()

        // 1. Automatic run without overrides: must clamp PDF MediaBox to ~7.33" x 11.0" (<= 14.0") and set `physicalScaleAmbiguous = true`
        let autoWriter = try ApplePDFDocumentWriter(destinationURL: autoClampedPDFURL)
        let autoConfig = BookPipelineCoordinator.Configuration(
            processingDPI: 200,
            outputDPI: 100,
            splitMode: .singlePage,
            enableDewarp: false
        )
        let autoResult = try await BookPipelineCoordinator(configuration: autoConfig).processBook(
            reader: reader,
            writer: autoWriter,
            accelerator: accelerator,
            ocrEngine: nil
        )

        #expect(autoResult.manifest.physicalScaleAmbiguous == true)
        let scaleEstimate = try #require(autoResult.manifest.fontScaleEstimate)
        #expect(scaleEstimate.wasAntiBillboardClamped == true)

        let autoDoc = try #require(PDFDocument(url: autoClampedPDFURL))
        #expect(autoDoc.pageCount == 1)
        let autoBounds = try #require(autoDoc.page(at: 0)).bounds(for: .mediaBox)
        let autoWInches = Double(autoBounds.width) / 72.0
        let autoHInches = Double(autoBounds.height) / 72.0
        #expect(autoWInches >= 7.0 && autoWInches <= 8.6)
        #expect(autoHInches >= 10.5 && autoHInches <= 11.6)

        // 2. Explicit `--page-size folio` (12.0" x 15.0" = 864 x 1080 pt) honors > 14" user request and clears `physicalScaleAmbiguous`
        let folioWriter = try ApplePDFDocumentWriter(destinationURL: folioPDFURL)
        let folioConfig = BookPipelineCoordinator.Configuration(
            processingDPI: 200,
            outputDPI: 100,
            targetPageSize: .preset(.folio),
            splitMode: .singlePage,
            enableDewarp: false
        )
        let folioResult = try await BookPipelineCoordinator(configuration: folioConfig).processBook(
            reader: reader,
            writer: folioWriter,
            accelerator: accelerator,
            ocrEngine: nil
        )

        #expect(folioResult.manifest.physicalScaleAmbiguous == false)
        let folioDoc = try #require(PDFDocument(url: folioPDFURL))
        #expect(folioDoc.pageCount == 1)
        let folioBounds = try #require(folioDoc.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(Double(folioBounds.width) - 864.0) <= 2.0)
        #expect(abs(Double(folioBounds.height) - 1080.0) <= 2.0)
    }

    // MARK: - Synthetic PDF Fixture Helpers

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

    private func createSyntheticUncalibrated72DPICameraSpreadPDF(at url: URL) throws {
        // 3300 x 2400 pt represents an 11.0" x 8.0" two-page hardcover spread captured at 300 optical DPI
        // and wrapped into a PDF at 72 pt/in (1 pt = 1 camera pixel -> 45.83" x 33.33" declared box).
        var spreadBox = CGRect(x: 0, y: 0, width: 3300, height: 2400)
        guard let ctx = CGContext(url as CFURL, mediaBox: &spreadBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let spreadBoxData = withUnsafeBytes(of: &spreadBox) { Data($0) as CFData }
        ctx.beginPDFPage([kCGPDFContextMediaBox: spreadBoxData] as CFDictionary)

        // Warm off-white paper background
        ctx.setFillColor(gray: 0.96, alpha: 1.0)
        ctx.fill(spreadBox)

        // Central dark spine crease around x = 1650
        ctx.setFillColor(gray: 0.28, alpha: 1.0)
        ctx.fill(CGRect(x: 1646, y: 0, width: 8, height: 2400))

        // 10 pt Roman body typography at 300 optical DPI:
        // em = 41.67 px -> xHeight = 20 pt, capHeight = 30 pt, strokeWidth = 4 pt, leading = 52 pt.
        // Verso text block: x = 240..<1440 (4.0" wide at 300 DPI)
        // Recto text block: x = 1860..<3060 (4.0" wide at 300 DPI)
        // Vertical span: y = 310...2026 (~5.8" tall at 300 DPI)
        ctx.setFillColor(gray: 0.05, alpha: 1.0)

        func drawStrokedTextBlock(startX: Int, endX: Int) {
            var lineIdx = 0
            for baselineY in stride(from: 310, through: 2026, by: 52) {
                var cursorX = startX
                var glyphIdx = 0
                while cursorX + 18 <= endX {
                    // ~18% uppercase / ascender glyphs (capHeight = 30), ~82% lowercase x-height glyphs (xHeight = 20)
                    let isCap = (glyphIdx == 0) || ((glyphIdx + lineIdx) % 6 == 0)
                    if isCap {
                        // Stroked 'H' / 'U' (width 18, height 30, stroke 4)
                        ctx.fill(CGRect(x: cursorX, y: baselineY, width: 4, height: 30))
                        ctx.fill(CGRect(x: cursorX + 14, y: baselineY, width: 4, height: 30))
                        let barY = (glyphIdx % 2 == 0) ? (baselineY + 13) : baselineY
                        ctx.fill(CGRect(x: cursorX, y: barY, width: 18, height: 4))
                        cursorX += 25
                    } else {
                        // Stroked 'n' / 'u' (width 15, height 20, stroke 4)
                        ctx.fill(CGRect(x: cursorX, y: baselineY, width: 4, height: 20))
                        ctx.fill(CGRect(x: cursorX + 11, y: baselineY, width: 4, height: 20))
                        let archY = (glyphIdx % 2 == 0) ? (baselineY + 16) : baselineY
                        ctx.fill(CGRect(x: cursorX, y: archY, width: 15, height: 4))
                        cursorX += 22
                    }
                    // Word gap every 5 glyphs
                    if glyphIdx % 5 == 4 {
                        cursorX += 12
                    }
                    glyphIdx += 1
                }
                lineIdx += 1
            }
        }

        drawStrokedTextBlock(startX: 240, endX: 1440)
        drawStrokedTextBlock(startX: 1860, endX: 3060)

        ctx.endPDFPage()
        ctx.closePDF()
    }

    private func createSyntheticIllustrationOnlyCameraWrapperPDF(at url: URL) throws {
        // 2400 x 3600 pt = 33.33" x 50.0" camera wrapper containing a framed architectural/botanical plate with 0 prose lines.
        var pageBox = CGRect(x: 0, y: 0, width: 2400, height: 3600)
        guard let ctx = CGContext(url as CFURL, mediaBox: &pageBox, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let boxData = withUnsafeBytes(of: &pageBox) { Data($0) as CFData }
        ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
        ctx.setFillColor(gray: 0.96, alpha: 1.0)
        ctx.fill(pageBox)

        // Outer ornamental plate frame + interior geometric engraving (connected artwork, 0 horizontal text chains)
        ctx.setStrokeColor(gray: 0.08, alpha: 1.0)
        ctx.setLineWidth(24.0)
        ctx.stroke(CGRect(x: 360, y: 480, width: 1680, height: 2640))
        ctx.strokeEllipse(in: CGRect(x: 560, y: 960, width: 1280, height: 1680))
        ctx.move(to: CGPoint(x: 360, y: 480))
        ctx.addLine(to: CGPoint(x: 2040, y: 3120))
        ctx.move(to: CGPoint(x: 2040, y: 480))
        ctx.addLine(to: CGPoint(x: 360, y: 3120))
        ctx.strokePath()

        ctx.endPDFPage()
        ctx.closePDF()
    }
}
