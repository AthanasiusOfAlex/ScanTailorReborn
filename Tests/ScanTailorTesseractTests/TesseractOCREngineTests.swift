import CoreGraphics
import CoreText
import Foundation
import PDFKit
import ScanTailorAppleBackend
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import ScanTailorTesseractBackend
import Testing

@Suite("TesseractOCREngine & LeptonicaPix Tests")
struct TesseractOCREngineTests {

    // MARK: - Helper: Render Synthetic Text Page

    /// Renders multi-line Unicode text into both an 8-bit `GrayscaleImage` and a 1-bit `BinaryBitmap`
    /// at the specified DPI using CoreGraphics / CoreText.
    private static func renderSyntheticTextPage(
        lines: [String],
        width: Int = 1400,
        height: Int = 500,
        dpi: Int = 300,
        fontName: String = "TimesNewRomanPSMT",
        fontSize: CGFloat = 56.0
    ) throws -> (grayscale: GrayscaleImage, binary: BinaryBitmap) {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = ContiguousArray<UInt8>(repeating: 255, count: width * height)

        try pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else {
                throw OCRError.recognitionFailed(reason: "Failed to create 8-bit CGContext.")
            }

            // Fill background with white (255).
            context.setFillColor(gray: 1.0, alpha: 1.0)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let font = CTFontCreateWithName(fontName as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ]

            context.setFillColor(gray: 0.0, alpha: 1.0)
            context.textMatrix = .identity

            let lineSpacing = fontSize * 1.6
            for (index, lineText) in lines.enumerated() {
                let attributed = NSAttributedString(string: lineText, attributes: attributes)
                let ctLine = CTLineCreateWithAttributedString(attributed)
                // CoreGraphics has bottom-left origin; place line 0 near top of page.
                let yPos = CGFloat(height) - CGFloat(index + 1) * lineSpacing - 40.0
                context.textPosition = CGPoint(x: 80.0, y: max(40.0, yPos))
                CTLineDraw(ctLine, context)
            }
        }

        let grayscale = GrayscaleImage(width: width, height: height, dpi: dpi, pixels: pixels)
        var binary = BinaryBitmap(width: width, height: height)
        for y in 0..<height {
            let rowOffset = y * width
            for x in 0..<width {
                if pixels[rowOffset + x] < 128 {
                    binary.setPixel(x: x, y: y, isBlack: true)
                }
            }
        }
        return (grayscale, binary)
    }

    // MARK: - 1. Library Linkage & Environment Discovery

    @Test("Tesseract and Leptonica C libraries report valid runtime versions and tessdata")
    func runtimeVersionsAndTessdata() throws {
        let tessVersion = TesseractOCREngine.tesseractVersion
        let leptVersion = TesseractOCREngine.leptonicaVersion

        #expect(!tessVersion.isEmpty)
        #expect(tessVersion != "unknown")
        #expect(leptVersion.lowercased().contains("leptonica"))

        let tessdataPath = try #require(TesseractOCREngine.resolveTessdataPath())
        let engine = TesseractOCREngine(
            configuration: .init(tessdataPath: tessdataPath)
        )
        let available = Set(engine.availableLanguages())

        // Verify scholarly languages required by the White Paper are installed.
        #expect(available.contains("eng"))
        #expect(available.contains("lat"))
        #expect(available.contains("grc"))
        #expect(available.contains("deu_frak"))
    }

    // MARK: - 2. LeptonicaPix Raster Bridging

    @Test("LeptonicaPix accurately bridges 1-bit BinaryBitmap across 64-bit to 32-bit word boundaries")
    func leptonicaPixFromBinaryBitmap() throws {
        // Choose dimensions (137 x 53) that are not multiples of 32 or 64.
        let width = 137
        let height = 53
        var bitmap = BinaryBitmap(width: width, height: height)

        for y in 0..<height {
            for x in 0..<width {
                let isForeground = ((x * 7 + y * 13) % 5 == 0) || (x == 0) || (x == 63) || (x == 64) || (x == width - 1)
                bitmap.setPixel(x: x, y: y, isBlack: isForeground)
            }
        }

        let pix = try LeptonicaPix(bitmap: bitmap, dpi: 300)
        #expect(pix.width == width)
        #expect(pix.height == height)
        #expect(pix.depth == 1)
        #expect(pix.wordsPerLine == (width + 31) / 32)

        for y in 0..<height {
            for x in 0..<width {
                let expected: UInt32 = bitmap[x, y] ? 1 : 0
                let actual = pix.pixelValue(x: x, y: y)
                #expect(actual == expected, "Mismatch at (\(x), \(y))")
            }
        }
    }

    @Test("LeptonicaPix accurately bridges 8-bit GrayscaleImage across 4-byte word boundaries")
    func leptonicaPixFromGrayscaleImage() throws {
        // Choose dimensions (67 x 29) not divisible by 4.
        let width = 67
        let height = 29
        var pixels = ContiguousArray<UInt8>(repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = UInt8((x * 11 + y * 17 + 23) & 0xFF)
            }
        }

        let image = GrayscaleImage(width: width, height: height, dpi: 400, pixels: pixels)
        let pix = try LeptonicaPix(grayscale: image, dpi: 400)
        #expect(pix.width == width)
        #expect(pix.height == height)
        #expect(pix.depth == 8)
        #expect(pix.wordsPerLine == (width + 3) / 4)

        for y in 0..<height {
            for x in 0..<width {
                let expected = UInt32(image[x, y])
                let actual = pix.pixelValue(x: x, y: y)
                #expect(actual == expected, "Grayscale mismatch at (\(x), \(y))")
            }
        }
    }

    // MARK: - 3. Language Normalization & Coordinate Transformations

    @Test("Language code normalization maps BCP-47 tags and scholarly codes to Tesseract identifiers")
    func languageNormalization() {
        #expect(TesseractOCREngine.normalizeLanguageCode("grc") == "grc")
        #expect(TesseractOCREngine.normalizeLanguageCode("deu_frak") == "deu_frak")
        #expect(TesseractOCREngine.normalizeLanguageCode("de-Latf") == "deu_frak")
        #expect(TesseractOCREngine.normalizeLanguageCode("lat") == "lat")
        #expect(TesseractOCREngine.normalizeLanguageCode("la") == "lat")
        #expect(TesseractOCREngine.normalizeLanguageCode("en-US") == "eng")
        #expect(TesseractOCREngine.normalizeLanguageCode("de-DE") == "deu")

        let combined = TesseractOCREngine.buildLanguageString(
            from: ["grc", "la", "en-US", "grc", "deu_frak"],
            fallback: ["eng"]
        )
        #expect(combined == "grc+lat+eng+deu_frak")
    }

    @Test("Coordinate space conversions handle bottom-left inversion, normalized top-left, and 72 DPI PDF points")
    func coordinateTransformations() {
        // 1. Bottom-left to top-left inversion
        let bottomLeftBox = Rect2D(x: 100.0, y: 50.0, width: 200.0, height: 30.0)
        let topLeftBox = TesseractOCREngine.invertBottomLeftToTopLeft(
            box: bottomLeftBox,
            imageHeight: 1000.0
        )
        #expect(abs(topLeftBox.x - 100.0) < 1e-9)
        #expect(abs(topLeftBox.y - 920.0) < 1e-9)
        #expect(abs(topLeftBox.width - 200.0) < 1e-9)
        #expect(abs(topLeftBox.height - 30.0) < 1e-9)

        // 2. 300 DPI pixel box to 72 DPI PDF points (scale = 72 / 300 = 0.24)
        let pdfBox = TesseractOCREngine.pixelBoxToPDFPoints(
            left: 300,
            top: 600,
            right: 900,
            bottom: 750,
            dpi: 300
        )
        #expect(abs(pdfBox.x - 72.0) < 1e-9)
        #expect(abs(pdfBox.y - 144.0) < 1e-9)
        #expect(abs(pdfBox.width - 144.0) < 1e-9)
        #expect(abs(pdfBox.height - 36.0) < 1e-9)

        // 3. Normalized top-left [0, 1] x [0, 1]
        let normBox = TesseractOCREngine.convertPixelBox(
            left: 250,
            top: 100,
            right: 750,
            bottom: 300,
            imageWidth: 1000,
            imageHeight: 400,
            dpi: 300,
            coordinateSpace: .normalizedTopLeft
        )
        #expect(abs(normBox.x - 0.25) < 1e-9)
        #expect(abs(normBox.y - 0.25) < 1e-9)
        #expect(abs(normBox.width - 0.50) < 1e-9)
        #expect(abs(normBox.height - 0.50) < 1e-9)
    }

    @Test("Requesting a nonexistent language throws OCRError.engineUnavailable")
    func missingLanguageThrowsEngineUnavailable() async {
        let bitmap = BinaryBitmap(width: 200, height: 100)
        let engine = TesseractOCREngine()

        do {
            _ = try await engine.recognizeText(
                in: bitmap,
                dpi: 300,
                languages: ["nonexistent_xyz_lang"]
            )
            Issue.record("Expected OCRError.engineUnavailable to be thrown")
        } catch {
            if case .engineUnavailable = error {
                // Expected
            } else {
                Issue.record("Unexpected OCRError case: \(error)")
            }
        }
    }

    // MARK: - 4. Live OCR Recognition (Latin/English, Polytonic Greek, German Fraktur)

    @Test("TesseractOCREngine recognizes Latin and English text on both 1-bit BinaryBitmap and 8-bit GrayscaleImage")
    func recognizeLatinAndEnglish() async throws {
        let lines = [
            "GALLIA EST OMNIS DIVISA IN PARTES TRES",
            "PHILOLOGIA CLASSICA ET HISTORIA ANTIQUA",
        ]
        let (grayscale, binary) = try Self.renderSyntheticTextPage(lines: lines)
        let engine = TesseractOCREngine()

        // 1-bit BinaryBitmap
        let binaryObs = try await engine.recognizeText(
            in: binary,
            dpi: 300,
            languages: ["lat", "eng"]
        )
        #expect(!binaryObs.isEmpty)

        let combinedBinaryText = binaryObs.map(\.text).joined(separator: " ").uppercased()
        #expect(combinedBinaryText.contains("GALLIA"))
        #expect(combinedBinaryText.contains("DIVISA"))
        #expect(combinedBinaryText.contains("PHILOLOGIA"))

        for obs in binaryObs {
            #expect(obs.confidence > 0.5 && obs.confidence <= 1.0)
            #expect(obs.boundingBox.x >= 0.0 && obs.boundingBox.x <= 1.0)
            #expect(obs.boundingBox.y >= 0.0 && obs.boundingBox.y <= 1.0)
            #expect(obs.boundingBox.width > 0.0 && obs.boundingBox.width <= 1.0)
            #expect(obs.boundingBox.height > 0.0 && obs.boundingBox.height <= 1.0)
        }

        // 8-bit GrayscaleImage
        let grayObs = try await engine.recognizeText(
            in: grayscale,
            dpi: 300,
            languages: ["lat", "eng"]
        )
        #expect(!grayObs.isEmpty)
        let combinedGrayText = grayObs.map(\.text).joined(separator: " ").uppercased()
        #expect(combinedGrayText.contains("GALLIA"))
        #expect(combinedGrayText.contains("HISTORIA"))
    }

    @Test("TesseractOCREngine recognizes Ancient Greek (grc) text")
    func recognizeAncientGreek() async throws {
        let lines = [
            "ΜΗΝΙΝ ΑΕΙΔΕ ΘΕΑ ΠΗΛΗΙΑΔΕΩ ΑΧΙΛΗΟΣ",
            "ΑΛΗΘΕΙΑ ΚΑΙ ΣΟΦΙΑ ΤΩΝ ΕΛΛΗΝΩΝ",
        ]
        let (_, binary) = try Self.renderSyntheticTextPage(
            lines: lines,
            fontName: "TimesNewRomanPSMT",
            fontSize: 58.0
        )

        let engine = TesseractOCREngine()
        let observations = try await engine.recognizeText(
            in: binary,
            dpi: 300,
            languages: ["grc"]
        )

        #expect(!observations.isEmpty)
        let fullText = observations.map(\.text).joined(separator: " ")
        // Strip diacritics and normalize case to verify core Greek lexical recognition
        let folded = fullText
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "el"))
        #expect(folded.contains("μηνιν") || folded.contains("θεα") || folded.contains("αληθεια") || folded.contains("σοφια"))
    }

    @Test("TesseractOCREngine recognizes German with deu_frak dictionary")
    func recognizeGermanFrakturDictionary() async throws {
        let lines = [
            "Wissenschaft und Philosophie der Geschichte",
            "Kritik der reinen Vernunft",
        ]
        let (grayscale, _) = try Self.renderSyntheticTextPage(
            lines: lines,
            fontName: "Georgia",
            fontSize: 56.0
        )

        let engine = TesseractOCREngine()
        let observations = try await engine.recognizeText(
            in: grayscale,
            dpi: 300,
            languages: ["deu_frak", "eng"]
        )

        #expect(!observations.isEmpty)
        let combined = observations.map(\.text).joined(separator: " ").lowercased()
        #expect(combined.contains("wissenschaft") || combined.contains("philosophie") || combined.contains("kritik") || combined.contains("vernunft"))
    }

    // MARK: - 5. End-to-End PDF Searchable Layer Integration

    @Test("TesseractOCREngine observations integrate seamlessly with ApplePDFDocumentWriter searchable PDF layer")
    func tesseractToSearchablePDFIntegration() async throws {
        let lines = [
            "SCANTAILOR TESSERACT ARCHIVAL PIPELINE",
            "MONOCHROME CCITT GROUP FOUR DOCUMENT",
        ]
        let (_, binary) = try Self.renderSyntheticTextPage(lines: lines)

        let engine = TesseractOCREngine()
        let observations = try await engine.recognizeText(
            in: binary,
            dpi: 300,
            languages: ["eng"]
        )
        #expect(!observations.isEmpty)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tesseract-pdf-test-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var writer = try ApplePDFDocumentWriter(destinationURL: tempURL)
        let pageBox = Rect2D(
            x: 0.0,
            y: 0.0,
            width: Double(binary.width) * 72.0 / 300.0,
            height: Double(binary.height) * 72.0 / 300.0
        )
        try writer.appendPage(
            bitmap: binary,
            dpi: 300,
            pageBoxPoints: pageBox,
            ocrLayer: observations
        )
        try writer.finalize()

        let pdfDoc = try #require(PDFDocument(url: tempURL))
        #expect(pdfDoc.pageCount == 1)

        let matches = pdfDoc.findString("TESSERACT", withOptions: [.caseInsensitive])
        #expect(!matches.isEmpty)
    }

    // MARK: - 6. Swift 6 Strict Concurrency Parallel Recognition

    @Test("TesseractOCREngine safely executes parallel OCR requests across concurrent tasks")
    func concurrentRecognitionSafety() async throws {
        let pages: [[String]] = [
            ["FIRST CONCURRENT PAGE FOR TESSERACT"],
            ["SECOND CONCURRENT PAGE WITH LATIN TEXT"],
            ["THIRD CONCURRENT PAGE IN PARALLEL"],
            ["FOURTH CONCURRENT PAGE VERIFICATION"],
        ]

        let bitmaps = try pages.map { lines in
            try Self.renderSyntheticTextPage(lines: lines, width: 1200, height: 300).binary
        }

        let engine = TesseractOCREngine()

        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, bitmap) in bitmaps.enumerated() {
                group.addTask {
                    let obs = try await engine.recognizeText(
                        in: bitmap,
                        dpi: 300,
                        languages: ["eng"]
                    )
                    let joined = obs.map(\.text).joined(separator: " ").uppercased()
                    return (index, joined)
                }
            }

            var collected: [Int: String] = [:]
            for try await (idx, text) in group {
                collected[idx] = text
            }
            return collected
        }

        #expect(results.count == 4)
        #expect(results[0]?.contains("FIRST") == true)
        #expect(results[1]?.contains("SECOND") == true)
        #expect(results[2]?.contains("THIRD") == true)
        #expect(results[3]?.contains("FOURTH") == true)
    }

    // MARK: - 7. DualOCREngine Synthesis & Searchable PDF Layer

    @Test("DualOCREngine coordinates AppleVision and Tesseract to generate searchable PDF with mixed text")
    func dualEngineSearchablePDFIntegration() async throws {
        let (grayscale, binary) = try Self.renderSyntheticTextPage(
            lines: ["SCANTAYLOR SCHOLARLY DIGITIZATION", "IN PRINCIPIO ERAT VERBUM ET VERBUM"],
            width: 1400,
            height: 400,
            dpi: 300
        )
        _ = grayscale

        let visionEngine = AppleVisionOCREngine()
        let tesseractEngine = TesseractOCREngine()
        let dualEngine = DualOCREngine(
            primary: visionEngine,
            secondary: tesseractEngine,
            strategy: .mergeAndDeduplicate
        )

        let observations = try await dualEngine.recognizeText(
            in: binary,
            dpi: 300,
            languages: ["lat", "en-US"]
        )

        #expect(!observations.isEmpty)
        let allText = observations.map(\.text).joined(separator: " ").uppercased()
        #expect(allText.contains("SCANTAYLOR"))
        #expect(allText.contains("PRINCIPIO") || allText.contains("VERBUM"))

        // Write to PDF using ApplePDFDocumentWriter
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DualOCRTest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        var writer = try ApplePDFDocumentWriter(destinationURL: tempURL)
        let pageBox = Rect2D(x: 0, y: 0, width: Double(binary.width) * 72.0 / 300.0, height: Double(binary.height) * 72.0 / 300.0)
        try writer.appendPage(bitmap: binary, dpi: 300, pageBoxPoints: pageBox, ocrLayer: observations)
        try writer.finalize()

        // Validate resulting PDF is searchable
        let pdfDoc = try #require(PDFDocument(url: tempURL))
        #expect(pdfDoc.pageCount == 1)
        let matches = pdfDoc.findString("SCANTAYLOR", withOptions: [.caseInsensitive])
        #expect(!matches.isEmpty)
    }
}
