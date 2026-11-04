import Foundation
import ScanTailorCLI
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import ScanTailorPortableBackend
import Testing

@Suite("FontScaleAnalyzer & Automatic Camera-Wrapper Scale Calibration Tests")
struct FontScaleAnalyzerTests {

    @Test("Bimodal 1D Gaussian KDE separates x-height and cap-height without upward drift under heavy capitalization")
    func testBimodalKDESeparationAndCapitalizationInvariance() throws {
        // 300 DPI calibrated page: 10.0 pt body em = 41.67 px -> xHeight = 20 px, capHeight = 30 px, stroke = 4 px.
        let width = 1200
        let height = 1600
        let analyzer = FontScaleAnalyzer()

        // Page A: Standard English/Latin prose (~22% capitals/ascenders, ~78% lowercase)
        let proseBitmap = makeSyntheticTypesetBitmap(
            width: width,
            height: height,
            xHeight: 20,
            capHeight: 30,
            strokeWidth: 4,
            lineSpacing: 50,
            uppercaseEveryN: 5
        )

        // Page B: Capital-heavy dictionary / German noun page (~60% capitals/ascenders, ~40% lowercase)
        // A naive median would jump +50% from 20 px to 30 px; bimodal KDE must keep xHeight ≈ 20, capHeight ≈ 30!
        let heavyCapBitmap = makeSyntheticTypesetBitmap(
            width: width,
            height: height,
            xHeight: 20,
            capHeight: 30,
            strokeWidth: 4,
            lineSpacing: 50,
            uppercaseEveryN: 2,
            invertCasePattern: true // 3 out of 5 (~60%) capitals
        )

        let proseMetrics = try #require(analyzer.analyzePage(in: proseBitmap, declaredDPI: 300))
        let heavyCapMetrics = try #require(analyzer.analyzePage(in: heavyCapBitmap, declaredDPI: 300))

        #expect(proseMetrics.isBimodal)
        #expect(heavyCapMetrics.isBimodal)

        #expect(abs(proseMetrics.xHeightPixels - 20.0) <= 0.8)
        #expect(abs(proseMetrics.capHeightPixels - 30.0) <= 0.8)
        #expect(abs(heavyCapMetrics.xHeightPixels - 20.0) <= 0.8)
        #expect(abs(heavyCapMetrics.capHeightPixels - 30.0) <= 0.8)

        // Both must deduce ~10.0 pt body text at ~300 DPI with < 2% discrepancy between prose and heavy-caps!
        #expect(abs(proseMetrics.declaredBodyPointSize - 10.0) <= 0.4)
        #expect(abs(heavyCapMetrics.declaredBodyPointSize - 10.0) <= 0.4)
        let relativeDrift = abs(heavyCapMetrics.inferredEmHeightPixels - proseMetrics.inferredEmHeightPixels)
            / proseMetrics.inferredEmHeightPixels
        #expect(relativeDrift < 0.02)
    }

    @Test("Accurately measures vertical stem strokeWidthPixels and two-column baselineSpacingPixels with staggered columns")
    func testStrokeWidthAndTwoColumnBaselineSpacing() throws {
        // 600 DPI two-column dictionary layout where left and right columns have staggered vertical baselines:
        // Left column baselines: y = 220, 320, 420, ... (spacing = 100 px)
        // Right column baselines: y = 265, 365, 465, ... (spacing = 100 px, offset by +45 px!)
        // Global Y sorting without horizontal-overlap pairing would falsely measure ~45-55 px instead of 100 px.
        let width = 2400
        let height = 3200
        var bitmap = BinaryBitmap(width: width, height: height, initialBlack: false)

        let xHeight = 40
        let capHeight = 59
        let strokeWidth = 7
        let trueLeading = 100

        // Column 1: x = 220..1080
        for row in 0..<22 {
            let baseY = 240 + row * trueLeading
            drawGlyphLine(
                &bitmap,
                baselineY: baseY,
                startX: 220,
                endX: 1080,
                xHeight: xHeight,
                capHeight: capHeight,
                strokeWidth: strokeWidth,
                uppercaseEveryN: 4
            )
        }

        // Column 2: x = 1320..2180 (staggered by +45 px vertically)
        for row in 0..<22 {
            let baseY = 285 + row * trueLeading
            drawGlyphLine(
                &bitmap,
                baselineY: baseY,
                startX: 1320,
                endX: 2180,
                xHeight: xHeight,
                capHeight: capHeight,
                strokeWidth: strokeWidth,
                uppercaseEveryN: 3
            )
        }

        let analyzer = FontScaleAnalyzer()
        let metrics = try #require(analyzer.analyzePage(in: bitmap, declaredDPI: 600))

        #expect(abs(metrics.strokeWidthPixels - Double(strokeWidth)) <= 0.75)
        let measuredLeading = try #require(metrics.baselineSpacingPixels)
        #expect(abs(measuredLeading - Double(trueLeading)) <= 1.5)
    }

    @Test("Remains immune to massive dark outer desk blocks and hundreds of background dust specks")
    func testImmunityToOuterDeskBlocksAndDustSpecks() throws {
        let width = 1400
        let height = 1900
        var bitmap = makeSyntheticTypesetBitmap(
            width: width,
            height: height,
            xHeight: 24,
            capHeight: 36,
            strokeWidth: 4,
            lineSpacing: 58,
            uppercaseEveryN: 4,
            leftMargin: 280,
            rightMargin: 220
        )

        // 1. Massive solid dark wooden desk surface along the left 16% of the frame (exceeds 14% cleaner strip)
        for y in 0..<height {
            for x in 0..<224 {
                bitmap[x, y] = true
            }
        }
        // Top dark shadow block
        for y in 0..<70 {
            for x in 0..<width {
                bitmap[x, y] = true
            }
        }

        // 2. Inject 800 isolated 4x4 pepper/dust specks across the page interior (outnumbering real glyphs)
        var rngState: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<800 {
            rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
            let sx = 240 + Int((rngState >> 16) % UInt64(width - 320))
            rngState = rngState &* 6364136223846793005 &+ 1442695040888963407
            let sy = 100 + Int((rngState >> 16) % UInt64(height - 200))

            // Keep specks isolated (skip if touching existing ink)
            var clear = true
            for cy in (sy - 2)...(sy + 5) {
                for cx in (sx - 2)...(sx + 5) {
                    if bitmap.isBlack(x: cx, y: cy) == true {
                        clear = false
                        break
                    }
                }
                if !clear { break }
            }
            if clear {
                for py in sy..<(sy + 4) {
                    for px in sx..<(sx + 4) {
                        bitmap.setPixel(x: px, y: py, isBlack: true)
                    }
                }
            }
        }

        let analyzer = FontScaleAnalyzer()
        let metrics = try #require(analyzer.analyzePage(in: bitmap, declaredDPI: 300))

        #expect(abs(metrics.xHeightPixels - 24.0) <= 1.0)
        #expect(abs(metrics.capHeightPixels - 36.0) <= 1.0)
        #expect(abs(metrics.strokeWidthPixels - 4.0) <= 0.8)
    }

    @Test("OCR observation fusion disambiguates ALL-CAPS unimodal pages and guards against tilted-line box height inflation")
    func testOCRObservationFusionAllCapsAndTiltedLineGuard() throws {
        let width = 1200
        let height = 1600
        let analyzer = FontScaleAnalyzer()

        // 1. ALL-CAPS page (100% capitals of height 30 px at 300 DPI -> true 10 pt body where capHeight = 0.71 * 41.67 ≈ 29.6 px)
        var allCapsBitmap = BinaryBitmap(width: width, height: height, initialBlack: false)
        for row in 0..<8 {
            let baseY = 300 + row * 64
            drawGlyphLine(
                &allCapsBitmap,
                baselineY: baseY,
                startX: 180,
                endX: 1020,
                xHeight: 30,
                capHeight: 30,
                strokeWidth: 4,
                uppercaseEveryN: 1 // 100% capHeight
            )
        }

        // Without OCR, unimodal 30 px glyphs look like 30 px lowercase x-height (~15 pt).
        let unassistedMetrics = try #require(analyzer.analyzePage(in: allCapsBitmap, declaredDPI: 300))
        #expect(unassistedMetrics.declaredBodyPointSize > 14.0)

        // With ALL-CAPS OCR observations, Case 2a recognizes p* = 30 px as capHeight (7.1 pt -> ~10.1 pt em)!
        let allCapsOCR: [RecognizedTextObservation] = (0..<8).map { row in
            let topNorm = Double(300 + row * 64 - 30) / Double(height)
            let hNorm = 30.0 / Double(height)
            return RecognizedTextObservation(
                text: "CAPITULUM PRIMUM DE LEGIBUS",
                confidence: 0.96,
                boundingBox: Rect2D(x: 0.15, y: topNorm, width: 0.70, height: hNorm)
            )
        }
        let fusedAllCapsMetrics = try #require(
            analyzer.analyzePage(in: allCapsBitmap, declaredDPI: 300, ocrObservations: allCapsOCR)
        )
        #expect(!fusedAllCapsMetrics.isBimodal)
        #expect(abs(fusedAllCapsMetrics.capHeightPixels - 30.0) <= 1.0)
        #expect(abs(fusedAllCapsMetrics.xHeightPixels - 30.0 * (0.48 / 0.71)) <= 1.0)
        #expect(abs(fusedAllCapsMetrics.declaredBodyPointSize - 10.14) <= 0.5)

        // 2. Tilted-line OCR box height guard:
        // Suppose a bimodal page (xHeight = 20 px, capHeight = 30 px, em ≈ 41.8 px) has OCR line boxes
        // inflated to 110 px tall due to line skew (W * sin(theta)) or page curl.
        // The tilted-line guard must reject those inflated OCR heights without corrupting inferredEmHeightPixels.
        let bimodalBitmap = makeSyntheticTypesetBitmap(
            width: width,
            height: height,
            xHeight: 20,
            capHeight: 30,
            strokeWidth: 4,
            lineSpacing: 54,
            uppercaseEveryN: 4
        )
        let inflatedTiltedOCR: [RecognizedTextObservation] = (0..<10).map { row in
            RecognizedTextObservation(
                text: "Tilted dictionary line with inflated axis-aligned box",
                confidence: 0.95,
                boundingBox: Rect2D(
                    x: 0.12,
                    y: Double(200 + row * 54) / Double(height),
                    width: 0.76,
                    height: 110.0 / Double(height) // 2.6x inflated by tilt!
                )
            )
        }
        let guardedMetrics = try #require(
            analyzer.analyzePage(in: bimodalBitmap, declaredDPI: 300, ocrObservations: inflatedTiltedOCR)
        )
        #expect(abs(guardedMetrics.inferredEmHeightPixels - 41.8) <= 1.5)
        #expect(abs(guardedMetrics.declaredBodyPointSize - 10.0) <= 0.4)
    }

    @Test("areDeclaredPagesOversized, nominalProbeDPI, and estimatePreRasterScale gate calibrated vs camera-wrapper pages")
    func testOversizedPageGateAndPreRasterScaleDecision() {
        let analyzer = FontScaleAnalyzer()

        // Nominal probe DPI check (e.g. Simpson 2004 x 2268 slice -> 252 DPI)
        #expect(FontScaleAnalyzer.nominalProbeDPI(forPixelSize: Size2I(width: 2004, height: 2268), isLikelySpread: false) == 252)
        #expect(FontScaleAnalyzer.nominalProbeDPI(forPixelSize: Size2I(width: 400, height: 500), isLikelySpread: false) == 150)
        #expect(FontScaleAnalyzer.nominalProbeDPI(forPixelSize: Size2I(width: 5000, height: 7000), isLikelySpread: false) == 600)

        // Calibrated sizes (US Letter 8.5x11, Octavo 6x9, 2x3 test fixture, 17x11 ledger spread) -> NOT oversized
        #expect(!analyzer.areDeclaredPagesOversized([Size2D(width: 8.5, height: 11.0)]))
        #expect(!analyzer.areDeclaredPagesOversized([Size2D(width: 6.0, height: 9.0)]))
        #expect(!analyzer.areDeclaredPagesOversized([Size2D(width: 2.0, height: 3.0)]))
        #expect(!analyzer.areDeclaredPagesOversized([Size2D(width: 17.0, height: 11.0)]))

        // 72-DPI camera wrappers (56.0" x 31.5" spread, 25.0" x 37.5" portrait) -> oversized
        let cameraSpreadSizes = [Size2D(width: 56.0, height: 31.5), Size2D(width: 56.0, height: 31.5)]
        #expect(analyzer.areDeclaredPagesOversized(cameraSpreadSizes))
        #expect(analyzer.areDeclaredPagesOversized([Size2D(width: 25.0, height: 37.5)]))

        // Calibrated page with large 24 pt title text MUST NOT trigger rescaling because physical size (6x9") is calibrated
        let largeTitleMetric = FontScaleAnalyzer.PageGlyphMetrics(
            xHeightPixels: 96.0,
            capHeightPixels: 142.0,
            inferredEmHeightPixels: 200.0,
            strokeWidthPixels: 17.0,
            baselineSpacingPixels: 240.0,
            declaredDPI: 600,
            declaredBodyPointSize: 24.0,
            inferredOpticalDPI: 1440.0,
            sampledGlyphCount: 40,
            chainedLineCount: 4,
            isBimodal: true,
            ocrLineCount: 0,
            confidence: 0.90
        )
        let calibratedDecision = analyzer.estimatePreRasterScale(
            from: [largeTitleMetric],
            declaredPageSizesInches: [Size2D(width: 6.0, height: 9.0)]
        )
        #expect(!calibratedDecision.shouldRescale)
        #expect(calibratedDecision.scaleCorrectionFactor == 1.0)
        #expect(calibratedDecision.effectiveRenderDPI(forProcessingDPI: 600) == 600)

        // 300-DPI camera photo wrapped at 72 DPI (declaredBodyPointSize = 41.67 pt on 56" x 31.5" spread)
        let cameraProbeMetric = FontScaleAnalyzer.PageGlyphMetrics(
            xHeightPixels: 20.0,
            capHeightPixels: 29.6,
            inferredEmHeightPixels: 41.6667,
            strokeWidthPixels: 3.7,
            baselineSpacingPixels: 50.0,
            declaredDPI: 72,
            declaredBodyPointSize: 41.6667,
            inferredOpticalDPI: 300.0,
            sampledGlyphCount: 250,
            chainedLineCount: 30,
            isBimodal: true,
            ocrLineCount: 0,
            confidence: 0.95
        )
        let cameraDecision = analyzer.estimatePreRasterScale(
            from: [cameraProbeMetric],
            declaredPageSizesInches: cameraSpreadSizes
        )
        #expect(cameraDecision.shouldRescale)
        #expect(abs(cameraDecision.scaleCorrectionFactor - 0.24) <= 0.005)
        #expect(abs((cameraDecision.inferredSourceOpticalDPI ?? 0) - 300.0) <= 3.0)
        #expect(cameraDecision.effectiveRenderDPI(forProcessingDPI: 600) == 144)
    }

    @Test("BookPipelineCoordinator.processGrayscalePages rescales oversized GrayscaleBuffer inputs invariantly across DPI tags")
    func testDirectOversizedGrayscaleBufferRescalingAndInvariance() async throws {
        // Synthesize an authentic 6.0" x 9.0" page captured at 300 optical DPI -> 1800 x 2700 sensor pixels,
        // where 10 pt body text has xHeight = 20 px, capHeight = 30 px, strokeWidth = 4 px.
        let sensorW = 1800
        let sensorH = 2700
        let rawPixels = makeSyntheticGrayscalePixels(
            width: sensorW,
            height: sensorH,
            xHeight: 20,
            capHeight: 30,
            strokeWidth: 4,
            lineSpacing: 52
        )

        // Input Variant 1: Tagged as 72 DPI (25.0" x 37.5" billboard!)
        let bufferAt72DPI = GrayscaleBuffer(width: sensorW, height: sensorH, dpi: 72, pixels: rawPixels)
        // Input Variant 2: Tagged as 150 DPI (12.0" x 18.0" oversized!)
        let bufferAt150DPI = GrayscaleBuffer(width: sensorW, height: sensorH, dpi: 150, pixels: rawPixels)

        // Use processingDPI = 150, outputDPI = 75 so resampling ratio is 0.50 (< 0.75, exercising Gaussian anti-alias blur + affineWarp!)
        let config = BookPipelineCoordinator.Configuration(
            processingDPI: 150,
            outputDPI: 75,
            splitMode: .singlePage,
            enableDewarp: false
        )
        let coordinator = BookPipelineCoordinator(configuration: config)
        let accelerator = PortableComputeAccelerator()

        let out72 = try await coordinator.processGrayscalePages(
            [bufferAt72DPI],
            writer: NullPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )
        let out150 = try await coordinator.processGrayscalePages(
            [bufferAt150DPI],
            writer: NullPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )

        let est72 = try #require(out72.manifest.fontScaleEstimate)
        let est150 = try #require(out150.manifest.fontScaleEstimate)

        #expect(est72.wasAutoRescaled)
        #expect(est150.wasAutoRescaled)
        #expect(abs(est72.appliedScaleCorrectionFactor - 0.24) <= 0.02)
        #expect(abs(est150.appliedScaleCorrectionFactor - 0.50) <= 0.04)
        #expect(abs(est72.inferredSourceOpticalDPI - 300.0) <= 20.0)
        #expect(abs(est150.inferredSourceOpticalDPI - 300.0) <= 20.0)

        // Both must converge to the identical page: the ~4.5" x 7.9" text block of the 6" x 9" page plus margins.
        #expect(est72.estimatedSinglePageSizeInches.width >= 5.2 && est72.estimatedSinglePageSizeInches.width <= 5.8)
        #expect(est72.estimatedSinglePageSizeInches.height >= 8.1 && est72.estimatedSinglePageSizeInches.height <= 8.7)
        #expect(abs(est72.estimatedSinglePageSizeInches.width - est150.estimatedSinglePageSizeInches.width) <= 0.15)
        #expect(abs(est72.estimatedSinglePageSizeInches.height - est150.estimatedSinglePageSizeInches.height) <= 0.15)

        // Verify CLI summary formatting includes Typography & Scale telemetry
        let summaryText = ScanTailorCLI.formatManifestSummary(out72.manifest)
        #expect(summaryText.contains("Typography & Scale: auto-rescaled"))
    }

    // MARK: - Synthetic Typography Helpers

    private func makeSyntheticTypesetBitmap(
        width: Int,
        height: Int,
        xHeight: Int,
        capHeight: Int,
        strokeWidth: Int,
        lineSpacing: Int,
        uppercaseEveryN: Int,
        invertCasePattern: Bool = false,
        leftMargin: Int = 140,
        rightMargin: Int = 140
    ) -> BinaryBitmap {
        var bitmap = BinaryBitmap(width: width, height: height, initialBlack: false)
        var baseY = 180
        while baseY < height - 160 {
            drawGlyphLine(
                &bitmap,
                baselineY: baseY,
                startX: leftMargin,
                endX: width - rightMargin,
                xHeight: xHeight,
                capHeight: capHeight,
                strokeWidth: strokeWidth,
                uppercaseEveryN: uppercaseEveryN,
                invertCasePattern: invertCasePattern
            )
            baseY += lineSpacing
        }
        return bitmap
    }

    private func makeSyntheticGrayscalePixels(
        width: Int,
        height: Int,
        xHeight: Int,
        capHeight: Int,
        strokeWidth: Int,
        lineSpacing: Int
    ) -> ContiguousArray<UInt8> {
        let bitmap = makeSyntheticTypesetBitmap(
            width: width,
            height: height,
            xHeight: xHeight,
            capHeight: capHeight,
            strokeWidth: strokeWidth,
            lineSpacing: lineSpacing,
            uppercaseEveryN: 4,
            leftMargin: 220,
            rightMargin: 220
        )
        var pixels = ContiguousArray<UInt8>(repeating: 242, count: width * height)
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where bitmap[x, y] {
                pixels[row + x] = 28
            }
        }
        return pixels
    }

    private func drawGlyphLine(
        _ bitmap: inout BinaryBitmap,
        baselineY: Int,
        startX: Int,
        endX: Int,
        xHeight: Int,
        capHeight: Int,
        strokeWidth: Int,
        uppercaseEveryN: Int,
        invertCasePattern: Bool = false
    ) {
        let glyphW = max(strokeWidth * 3 + 2, Int((Double(xHeight) * 0.72).rounded()))
        let advance = glyphW + max(3, strokeWidth + 2)
        let wordSpace = max(6, Int((Double(xHeight) * 0.55).rounded()))

        var x = startX
        var charIndex = 0
        while x + glyphW < endX {
            let modHit = (charIndex % max(1, uppercaseEveryN)) == 0
            let isCap = (uppercaseEveryN == 1) ? true : (invertCasePattern ? !modHit : modHit)

            if isCap {
                drawStrokedCapital(
                    &bitmap,
                    baselineY: baselineY,
                    leftX: x,
                    width: glyphW,
                    capHeight: capHeight,
                    strokeWidth: strokeWidth,
                    style: charIndex
                )
            } else {
                drawStrokedLowercase(
                    &bitmap,
                    baselineY: baselineY,
                    leftX: x,
                    width: glyphW,
                    xHeight: xHeight,
                    strokeWidth: strokeWidth,
                    style: charIndex
                )
            }

            charIndex += 1
            if charIndex % 6 == 0 {
                x += advance + wordSpace
            } else {
                x += advance
            }
        }
    }

    private func drawStrokedLowercase(
        _ bitmap: inout BinaryBitmap,
        baselineY: Int,
        leftX: Int,
        width: Int,
        xHeight: Int,
        strokeWidth: Int,
        style: Int
    ) {
        let topY = baselineY - xHeight
        let rightStemX = leftX + width - strokeWidth

        // Left & right vertical stems ('n', 'u', 'o')
        fillRect(&bitmap, x0: leftX, y0: topY, x1: leftX + strokeWidth, y1: baselineY)
        fillRect(&bitmap, x0: rightStemX, y0: topY, x1: leftX + width, y1: baselineY)

        switch style % 3 {
        case 0: // 'n': top arch
            fillRect(&bitmap, x0: leftX, y0: topY, x1: leftX + width, y1: topY + strokeWidth)
        case 1: // 'u': bottom arch
            fillRect(&bitmap, x0: leftX, y0: baselineY - strokeWidth, x1: leftX + width, y1: baselineY)
        default: // 'o': top & bottom arches
            fillRect(&bitmap, x0: leftX, y0: topY, x1: leftX + width, y1: topY + strokeWidth)
            fillRect(&bitmap, x0: leftX, y0: baselineY - strokeWidth, x1: leftX + width, y1: baselineY)
        }
    }

    private func drawStrokedCapital(
        _ bitmap: inout BinaryBitmap,
        baselineY: Int,
        leftX: Int,
        width: Int,
        capHeight: Int,
        strokeWidth: Int,
        style: Int
    ) {
        let topY = baselineY - capHeight
        let rightStemX = leftX + width - strokeWidth

        switch style % 3 {
        case 0: // 'L': left vertical stem + bottom bar
            fillRect(&bitmap, x0: leftX, y0: topY, x1: leftX + strokeWidth, y1: baselineY)
            fillRect(&bitmap, x0: leftX, y0: baselineY - strokeWidth, x1: leftX + width, y1: baselineY)
        case 1: // 'T': central vertical stem + top bar
            let midX = leftX + (width - strokeWidth) / 2
            fillRect(&bitmap, x0: midX, y0: topY, x1: midX + strokeWidth, y1: baselineY)
            fillRect(&bitmap, x0: leftX, y0: topY, x1: leftX + width, y1: topY + strokeWidth)
        default: // 'H': dual vertical stems + middle crossbar (tests crossbar filtering!)
            let midY = topY + (capHeight - strokeWidth) / 2
            fillRect(&bitmap, x0: leftX, y0: topY, x1: leftX + strokeWidth, y1: baselineY)
            fillRect(&bitmap, x0: rightStemX, y0: topY, x1: leftX + width, y1: baselineY)
            fillRect(&bitmap, x0: leftX, y0: midY, x1: leftX + width, y1: midY + strokeWidth)
        }
    }

    private func fillRect(_ bitmap: inout BinaryBitmap, x0: Int, y0: Int, x1: Int, y1: Int) {
        let minX = max(0, x0)
        let maxX = min(bitmap.width, x1)
        let minY = max(0, y0)
        let maxY = min(bitmap.height, y1)
        guard minX < maxX, minY < maxY else { return }
        for y in minY..<maxY {
            for x in minX..<maxX {
                bitmap[x, y] = true
            }
        }
    }
}

private struct NullPDFWriter: PDFDocumentWriter, ~Copyable {
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap,
        dpi: Int,
        pageBoxPoints: Rect2D,
        ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {}

    consuming func finalize() throws(PDFWriteError) {}
}
