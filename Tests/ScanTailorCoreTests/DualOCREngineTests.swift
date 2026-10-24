import Foundation
import ScanTailorCLI
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import Testing

@Suite("DualOCREngine & Multi-Engine CLI Dispatch Tests")
struct DualOCREngineTests {

    // MARK: - Mock Engine for Unit Testing

    struct MockOCREngine: OCREngine, Sendable {
        let resultsToReturn: [RecognizedTextObservation]
        let errorToThrow: OCRError?

        init(results: [RecognizedTextObservation] = [], error: OCRError? = nil) {
            self.resultsToReturn = results
            self.errorToThrow = error
        }

        func recognizeText(
            in bitmap: borrowing BinaryBitmap,
            dpi: Int,
            languages: [String]
        ) async throws(OCRError) -> [RecognizedTextObservation] {
            if let errorToThrow {
                throw errorToThrow
            }
            return resultsToReturn
        }
    }

    // MARK: - Synthesis & Merging Tests

    @Test("DualOCREngine prioritizes classical Greek script over Latin misrecognition")
    func testDualOCREngineGreekScriptPriority() async throws {
        // Line 1: Primary misreads Greek as ASCII "‘avdpwv" with 0.88 confidence
        // Secondary correctly outputs Greek "ἄνδρα μοι ἔννεπε" with 0.82 confidence
        let primaryObs = [
            RecognizedTextObservation(
                text: "‘avdpwv",
                confidence: 0.88,
                boundingBox: Rect2D(x: 0.10, y: 0.20, width: 0.50, height: 0.04)
            )
        ]
        let secondaryObs = [
            RecognizedTextObservation(
                text: "ἄνδρα μοι ἔννεπε",
                confidence: 0.82,
                boundingBox: Rect2D(x: 0.10, y: 0.20, width: 0.52, height: 0.04)
            )
        ]

        let engine = DualOCREngine(
            primary: MockOCREngine(results: primaryObs),
            secondary: MockOCREngine(results: secondaryObs),
            strategy: .mergeAndDeduplicate
        )

        let dummyBitmap = BinaryBitmap(width: 100, height: 100, initialBlack: true)
        let merged = try await engine.recognizeText(in: dummyBitmap, dpi: 300, languages: ["grc", "en-US"])

        #expect(merged.count == 1)
        #expect(merged[0].text == "ἄνδρα μοι ἔννεπε")
    }

    @Test("DualOCREngine selects candidate with significantly higher confidence when neither has classical script")
    func testDualOCREngineConfidencePriority() async throws {
        // Line 1: Primary has 0.95 confidence, secondary has 0.65 confidence
        let primaryObs = [
            RecognizedTextObservation(
                text: "Introduction and Historical Context",
                confidence: 0.95,
                boundingBox: Rect2D(x: 0.15, y: 0.10, width: 0.70, height: 0.03)
            )
        ]
        let secondaryObs = [
            RecognizedTextObservation(
                text: "Introdvction and Hlstorlcal Context",
                confidence: 0.65,
                boundingBox: Rect2D(x: 0.15, y: 0.10, width: 0.71, height: 0.03)
            )
        ]

        let engine = DualOCREngine(
            primary: MockOCREngine(results: primaryObs),
            secondary: MockOCREngine(results: secondaryObs)
        )

        let dummyBitmap = BinaryBitmap(width: 100, height: 100, initialBlack: true)
        let merged = try await engine.recognizeText(in: dummyBitmap, dpi: 300, languages: ["en-US"])

        #expect(merged.count == 1)
        #expect(merged[0].text == "Introduction and Historical Context")
        #expect(merged[0].confidence == 0.95)
    }

    @Test("DualOCREngine retains non-overlapping text lines detected by either engine")
    func testDualOCREngineNonOverlappingRetention() async throws {
        // Primary detects header at top (y=0.05)
        let primaryObs = [
            RecognizedTextObservation(
                text: "CHAPTER III: THE ONTOLOGICAL PROOF",
                confidence: 0.96,
                boundingBox: Rect2D(x: 0.20, y: 0.05, width: 0.60, height: 0.03)
            )
        ]
        // Secondary detects marginal gloss at bottom right (y=0.85)
        let secondaryObs = [
            RecognizedTextObservation(
                text: "cf. Thomas Aquinas, ST I, q. 2, a. 3",
                confidence: 0.89,
                boundingBox: Rect2D(x: 0.15, y: 0.85, width: 0.50, height: 0.03)
            )
        ]

        let engine = DualOCREngine(
            primary: MockOCREngine(results: primaryObs),
            secondary: MockOCREngine(results: secondaryObs)
        )

        let dummyBitmap = BinaryBitmap(width: 100, height: 100, initialBlack: true)
        let merged = try await engine.recognizeText(in: dummyBitmap, dpi: 300, languages: ["lat", "en-US"])

        #expect(merged.count == 2)
        // Verified sorted in reading order: header first, marginal gloss second
        #expect(merged[0].text == "CHAPTER III: THE ONTOLOGICAL PROOF")
        #expect(merged[1].text == "cf. Thomas Aquinas, ST I, q. 2, a. 3")
    }

    @Test("DualOCREngine correctly sorts multi-column observations in standard reading order")
    func testDualOCREngineReadingOrderSorting() {
        let obs = [
            RecognizedTextObservation(text: "Bottom line", confidence: 0.9, boundingBox: Rect2D(x: 0.1, y: 0.80, width: 0.8, height: 0.04)),
            RecognizedTextObservation(text: "Line 1 Right", confidence: 0.9, boundingBox: Rect2D(x: 0.55, y: 0.10, width: 0.35, height: 0.04)),
            RecognizedTextObservation(text: "Line 1 Left", confidence: 0.9, boundingBox: Rect2D(x: 0.10, y: 0.10, width: 0.35, height: 0.04)),
            RecognizedTextObservation(text: "Middle line", confidence: 0.9, boundingBox: Rect2D(x: 0.10, y: 0.40, width: 0.8, height: 0.04)),
        ]

        let sorted = DualOCREngine.sortReadingOrder(obs)
        #expect(sorted.map(\.text) == [
            "Line 1 Left",
            "Line 1 Right",
            "Middle line",
            "Bottom line"
        ])
    }

    @Test("DualOCREngine gracefully falls back when one engine fails")
    func testDualOCREngineErrorResilience() async throws {
        let goodObs = [
            RecognizedTextObservation(text: "Surviving text", confidence: 0.90, boundingBox: Rect2D(x: 0.1, y: 0.1, width: 0.5, height: 0.05))
        ]

        // 1. Primary throws, secondary succeeds
        let primaryFailsEngine = DualOCREngine(
            primary: MockOCREngine(error: .recognitionFailed(reason: "Vision unsupported language")),
            secondary: MockOCREngine(results: goodObs)
        )
        let dummy = BinaryBitmap(width: 50, height: 50, initialBlack: true)
        let res1 = try await primaryFailsEngine.recognizeText(in: dummy, dpi: 300, languages: ["grc"])
        #expect(res1.count == 1)
        #expect(res1[0].text == "Surviving text")

        // 2. Secondary throws, primary succeeds
        let secondaryFailsEngine = DualOCREngine(
            primary: MockOCREngine(results: goodObs),
            secondary: MockOCREngine(error: .engineUnavailable(reason: "Language nonexistent not found"))
        )
        let res2 = try await secondaryFailsEngine.recognizeText(in: dummy, dpi: 300, languages: ["en-US"])
        #expect(res2.count == 1)
        #expect(res2[0].text == "Surviving text")

        // 3. Both throw -> rethrows
        let bothFailEngine = DualOCREngine(
            primary: MockOCREngine(error: .cancelled),
            secondary: MockOCREngine(error: .cancelled)
        )
        await #expect(throws: OCRError.self) {
            _ = try await bothFailEngine.recognizeText(in: dummy, dpi: 300, languages: ["en-US"])
        }
    }

    @Test("Language filtering and classical script detection logic")
    func testLanguageFilteringAndScriptDetection() {
        // filterAppleVisionLanguages: strips classical codes, retains standard BCP-47
        let inputLangs = ["en-US", "grc", "deu_frak", "fr-FR", "lat", "frk"]
        let filtered = DualOCREngine.filterAppleVisionLanguages(inputLangs)
        #expect(filtered == ["en-US", "fr-FR"])

        // All classical codes -> empty array (which lets Vision run default system language)
        #expect(DualOCREngine.filterAppleVisionLanguages(["grc", "lat"]).isEmpty)

        // containsClassicalScript:
        // Polytonic Greek
        #expect(DualOCREngine.containsClassicalScript("Ἀριστοτέλης"))
        #expect(DualOCREngine.containsClassicalScript("λόγος"))
        // Fraktur long s
        #expect(DualOCREngine.containsClassicalScript("Waſſer"))
        // Plain Latin English
        #expect(!DualOCREngine.containsClassicalScript("ScanTailor Reborn Pure Swift 6"))
    }

    // MARK: - CLI Options & Engine Dispatch Tests

    @Test("CLI option parser handles OCR engine selection, languages, and tessdata directory")
    func testCLIParsingOCROptions() throws {
        // 1. Explicit Tesseract with grc+lat
        let args1 = [
            "process", "in.pdf", "-o", "out.pdf",
            "--ocr-engine", "tesseract",
            "--ocr-languages", "grc+lat",
            "--tessdata-dir", "/opt/homebrew/share/tessdata"
        ]
        let opts1 = try ScanTailorCLI.parseProcessOptions(Array(args1.dropFirst()))
        #expect(opts1.ocrEngineType == .tesseract)
        #expect(opts1.ocrLanguages == ["grc", "lat"])
        #expect(opts1.tessdataDir == "/opt/homebrew/share/tessdata")

        // 2. Dual engine with comma-separated languages
        let args2 = [
            "process", "in.pdf", "-o", "out.pdf",
            "--engine", "dual",
            "--languages", "en-US,de-DE"
        ]
        let opts2 = try ScanTailorCLI.parseProcessOptions(Array(args2.dropFirst()))
        #expect(opts2.ocrEngineType == .dual)
        #expect(opts2.ocrLanguages == ["en-US", "de-DE"])

        // 3. Apple engine alias
        let args3 = [
            "process", "in.pdf", "-o", "out.pdf",
            "--ocr-engine", "apple"
        ]
        let opts3 = try ScanTailorCLI.parseProcessOptions(Array(args3.dropFirst()))
        #expect(opts3.ocrEngineType == .apple)

        // 4. Invalid OCR engine throws error
        #expect(throws: ScanTailorCLI.CLIError.self) {
            _ = try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf", "--ocr-engine", "unknownEngine"])
        }
    }

    @Test("Automatic OCR engine resolution selects Dual for classical languages and Tesseract for portable backend")
    func testAutoOCREngineResolution() {
        var opts = ScanTailorCLI.ProcessOptions(inputPDFPath: "in.pdf", outputPDFPath: "out.pdf")

        // 1. Default (en-US, no explicit engine) -> .apple
        opts.ocrLanguages = ["en-US"]
        #expect(ScanTailorCLI.resolveOCREngineType(options: opts) == .apple)

        // 2. Classical Greek -> auto-resolves to .dual
        opts.ocrLanguages = ["grc", "en-US"]
        #expect(ScanTailorCLI.resolveOCREngineType(options: opts) == .dual)

        // 3. German Fraktur -> auto-resolves to .dual
        opts.ocrLanguages = ["deu_frak"]
        #expect(ScanTailorCLI.resolveOCREngineType(options: opts) == .dual)

        // 4. Portable backend requested -> auto-resolves to .tesseract
        opts.usePortableBackend = true
        opts.ocrLanguages = ["en-US"]
        #expect(ScanTailorCLI.resolveOCREngineType(options: opts) == .tesseract)

        // 5. Explicit override takes precedence over heuristics
        opts.ocrEngineType = .apple
        #expect(ScanTailorCLI.resolveOCREngineType(options: opts) == .apple)
    }

    @Test("makeOCREngine factory respects --no-ocr and returns correct engine instance")
    func testMakeOCREngineFactory() {
        var opts = ScanTailorCLI.ProcessOptions(inputPDFPath: "in.pdf", outputPDFPath: "out.pdf")

        // Disabled OCR returns nil
        opts.enableOCR = false
        #expect(ScanTailorCLI.makeOCREngine(options: opts) == nil)

        // Enabled OCR returns an engine
        opts.enableOCR = true
        opts.ocrEngineType = .tesseract
        let engine = ScanTailorCLI.makeOCREngine(options: opts)
        #expect(engine != nil)
    }
}
