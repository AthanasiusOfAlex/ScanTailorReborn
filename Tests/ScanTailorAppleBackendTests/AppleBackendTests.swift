import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import ScanTailorAppleBackend
import ScanTailorContracts
import ScanTailorCore
import Testing

@Suite("Apple PDF I/O, 1-Bit CCITT & Vision OCR Backend Tests")
struct AppleBackendTests {

    // MARK: - 1. BinaryBitmap <-> CGImage & CCITT Group 4 TIFF Bridge

    @Test("1-bit and 8-bit CGImage bridge and CCITT Group 4 TIFF compression")
    func testCGImageBridgeAndCCITTGroup4() throws {
        let width = 300
        let height = 200
        var bitmap = BinaryBitmap(width: width, height: height, initialBlack: false)

        // Draw a black frame and diagonal pattern
        for x in 20..<280 {
            bitmap[x, 20] = true
            bitmap[x, 179] = true
        }
        for y in 20..<180 {
            bitmap[20, y] = true
            bitmap[279, y] = true
        }
        for i in 0..<100 {
            bitmap[50 + i, 50 + i] = true
        }

        let cg1Bit = try #require(BinaryBitmapCGImageBridge.make1BitCGImage(from: bitmap))
        #expect(cg1Bit.width == width)
        #expect(cg1Bit.height == height)
        #expect(cg1Bit.bitsPerComponent == 1)
        #expect(cg1Bit.bitsPerPixel == 1)

        let cg8Bit = try #require(BinaryBitmapCGImageBridge.make8BitCGImage(from: bitmap))
        #expect(cg8Bit.width == width)
        #expect(cg8Bit.height == height)
        #expect(cg8Bit.bitsPerComponent == 8)
        #expect(cg8Bit.bitsPerPixel == 8)

        let tiffData = try BinaryBitmapCGImageBridge.encodeCCITTGroup4TIFF(from: bitmap, dpi: 300)
        #expect(!tiffData.isEmpty)
        // CCITT Group 4 compressed size should be much smaller than uncompressed 8-bit (60,000 bytes)
        #expect(tiffData.count < 4_000)

        // Verify ImageIO can decode the CCITT Group 4 TIFF back with exact dimensions and compression code 4
        let source = try #require(CGImageSourceCreateWithData(tiffData as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let tiffDict = try #require(props[kCGImagePropertyTIFFDictionary] as? [CFString: Any])
        let compression = tiffDict[kCGImagePropertyTIFFCompression] as? Int
        #expect(compression == 4)
    }

    // MARK: - 2. ApplePDFSourceReader Error Handling & Multi-Page Rasterization

    @Test("ApplePDFSourceReader error handling for missing and invalid files")
    func testPDFReaderErrors() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).pdf")

        #expect(throws: PDFReadError.fileNotFound(url: missingURL)) {
            _ = try ApplePDFSourceReader(url: missingURL)
        }

        let corruptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).pdf")
        try Data("not a valid pdf".utf8).write(to: corruptURL)
        defer { try? FileManager.default.removeItem(at: corruptURL) }

        #expect(throws: PDFReadError.self) {
            _ = try ApplePDFSourceReader(url: corruptURL)
        }
    }

    @Test("ApplePDFSourceReader rasterizes synthetic book PDF at 600 DPI with concurrent access")
    func testPDFSourceReaderRasterizationAndConcurrency() async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sample-book-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Create a 2-page PDF (4.0 x 6.0 inches = 288 x 432 points)
        let pageBox = CGRect(x: 0, y: 0, width: 288, height: 432)
        try Self.generateSyntheticPDF(
            at: tempURL,
            pageBox: pageBox,
            pageStrings: [
                "CHAPTER I\nThe Beginning of ScanTailor Reborn",
                "Page Two: Crisp Monochrome Typography"
            ]
        )

        let reader = try ApplePDFSourceReader(url: tempURL)
        #expect(reader.pageCount == 2)

        let box0 = try reader.pageBoxPoints(at: 0)
        #expect(abs(box0.width - 288.0) < 1e-6)
        #expect(abs(box0.height - 432.0) < 1e-6)

        // Verify out-of-bounds error
        await #expect(throws: PDFReadError.pageOutOfBounds(index: 5, total: 2)) {
            _ = try await reader.rasterizePage(at: 5, targetDPI: 300)
        }

        // Rasterize both pages concurrently at 600 DPI
        // 4x6 inches at 600 DPI = 2400 x 3600 pixels
        async let page0Task = reader.rasterizePage(at: 0, targetDPI: 600)
        async let page1Task = reader.rasterizePage(at: 1, targetDPI: 600)

        let (gray0, gray1) = try await (page0Task, page1Task)
        #expect(gray0.width == 2400)
        #expect(gray0.height == 3600)
        #expect(gray0.dpi == 600)

        #expect(gray1.width == 2400)
        #expect(gray1.height == 3600)
        #expect(gray1.dpi == 600)

        // Verify corners are pure white paper (255) and interior contains dark text pixels (< 64)
        #expect(gray0[0, 0] == 255)
        #expect(gray0[gray0.width - 1, gray0.height - 1] == 255)

        let darkPixelCount0 = gray0.pixels.reduce(into: 0) { count, px in
            if px < 100 { count += 1 }
        }
        #expect(darkPixelCount0 > 1_000)
    }

    // MARK: - 3. End-to-End Pipeline: Read 600 DPI -> Binarize -> Downsample 300 DPI -> Vision OCR -> Write 1-Bit Searchable PDF

    @Test("End-to-end: Read PDF at 600 DPI, binarize, downsample to 300 DPI, run Vision OCR, and write 1-bit searchable PDF")
    func testEndToEndReadBinarizeOCRAndWriteSearchablePDF() async throws {
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("input-book-\(UUID().uuidString).pdf")
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("output-searchable-\(UUID().uuidString).pdf")
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }

        // 1. Generate a synthetic input PDF page (5 x 4 inches = 360 x 288 points)
        let pageBox = CGRect(x: 0, y: 0, width: 360, height: 288)
        let expectedPhrase = "SCANTAILOR MONOCHROME\nARCHIVE 1924"
        try Self.generateSyntheticPDF(
            at: inputURL,
            pageBox: pageBox,
            pageStrings: [expectedPhrase]
        )

        // 2. Rasterize at 600 DPI via ApplePDFSourceReader
        let reader = try ApplePDFSourceReader(url: inputURL)
        #expect(reader.pageCount == 1)
        let pageBoxPoints = try reader.pageBoxPoints(at: 0)
        let gray600 = try await reader.rasterizePage(at: 0, targetDPI: 600)
        #expect(gray600.width == 3000)
        #expect(gray600.height == 2400)

        // 3. Threshold 600 DPI grayscale to 1-bit BinaryBitmap
        var binary600 = BinaryBitmap(width: gray600.width, height: gray600.height, initialBlack: false)
        for y in 0..<gray600.height {
            let rowStart = y * gray600.width
            for x in 0..<gray600.width {
                if gray600.pixels[rowStart + x] < 160 {
                    binary600[x, y] = true
                }
            }
        }
        #expect(binary600.countBlackPixels() > 5_000)

        // 4. Area-thresholded 2x downsample from 600 DPI to 300 DPI
        let accelerator = MetalComputeAccelerator()
        let binary300 = accelerator.downsampleBinaryTo300DPI(binary600)
        #expect(binary300.width == 1500)
        #expect(binary300.height == 1200)

        // 5. Run AppleVisionOCREngine on the 300 DPI 1-bit bitmap
        let ocrEngine = AppleVisionOCREngine()
        let observations = try await ocrEngine.recognizeText(
            in: binary300,
            dpi: 300,
            languages: ["en-US"]
        )
        #expect(!observations.isEmpty)

        let combinedRecognizedText = observations.map(\.text).joined(separator: " ").uppercased()
        #expect(combinedRecognizedText.contains("SCANTAILOR"))
        #expect(combinedRecognizedText.contains("MONOCHROME"))
        #expect(combinedRecognizedText.contains("1924"))

        for obs in observations {
            #expect(obs.confidence > 0.3)
            #expect(obs.boundingBox.minX >= 0.0 && obs.boundingBox.maxX <= 1.0)
            #expect(obs.boundingBox.minY >= 0.0 && obs.boundingBox.maxY <= 1.0)
        }

        // 6. Write 300 DPI 1-bit PDF with invisible searchable OCR text layer
        var writer = try ApplePDFDocumentWriter(
            destinationURL: outputURL,
            title: "ScanTailor Test Output",
            author: "ScanTailorReborn"
        )
        try writer.appendPage(
            bitmap: binary300,
            dpi: 300,
            pageBoxPoints: pageBoxPoints,
            ocrLayer: observations
        )
        try writer.finalize()

        // 7. Verify output PDF file size is compact (< 50 KB for a 1500x1200 1-bit page + OCR layer)
        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = try #require(attrs[.size] as? Int)
        #expect(fileSize > 500)
        #expect(fileSize < 50_000)

        // 8. Verify PDFKit can open the output PDF and extract/search the invisible OCR text layer
        let outputPDF = try #require(PDFDocument(url: outputURL))
        #expect(outputPDF.pageCount == 1)

        let pdfPage = try #require(outputPDF.page(at: 0))
        let extractedPageText = (pdfPage.string ?? "").uppercased()
        #expect(extractedPageText.contains("SCANTAILOR"))
        #expect(extractedPageText.contains("MONOCHROME"))
        #expect(extractedPageText.contains("1924"))

        let matches = outputPDF.findString("MONOCHROME", withOptions: .caseInsensitive)
        #expect(!matches.isEmpty)
    }

    // MARK: - Test Helper

    private static func generateSyntheticPDF(
        at url: URL,
        pageBox: CGRect,
        pageStrings: [String]
    ) throws {
        var mediaBox = pageBox
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            Issue.record("Failed to create synthetic PDF context")
            return
        }

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 22.0, nil)

        for pageText in pageStrings {
            context.beginPDFPage(nil)
            context.setFillColor(gray: 1.0, alpha: 1.0)
            context.fill(pageBox)

            let lines = pageText.split(separator: "\n", omittingEmptySubsequences: false)
            var currentY = pageBox.height * 0.65

            for lineText in lines {
                let attrs: [CFString: Any] = [
                    kCTFontAttributeName: font,
                    kCTForegroundColorFromContextAttributeName: true
                ]
                if let attrStr = CFAttributedStringCreate(
                    kCFAllocatorDefault,
                    String(lineText) as CFString,
                    attrs as CFDictionary
                ) {
                    let ctLine = CTLineCreateWithAttributedString(attrStr)
                    context.setFillColor(gray: 0.0, alpha: 1.0)
                    context.textMatrix = CGAffineTransform(translationX: 28.0, y: currentY)
                    CTLineDraw(ctLine, context)
                }
                currentY -= 36.0
            }

            context.endPDFPage()
        }

        context.closePDF()
    }
}
