import Foundation
import ScanTailorContracts
@testable import ScanTailorCore
import ScanTailorPipeline
import ScanTailorPortableBackend
import Testing

@Suite("Substep 4.2.1 — Dynamic Glyph-Scale Kernel Radius & Sigma Derivation Tests")
struct GlyphAdaptiveNormalizationTests {

    // MARK: - Synthetic Glyph & Illumination Fixture Helpers

    private static func fillRect(_ bitmap: inout BinaryBitmap, _ rect: Rect2I, isBlack: Bool = true) {
        let minX = max(0, rect.minX)
        let maxX = min(bitmap.width, rect.maxX)
        let minY = max(0, rect.minY)
        let maxY = min(bitmap.height, rect.maxY)
        guard minX < maxX && minY < maxY else { return }
        for y in minY..<maxY {
            for x in minX..<maxX {
                bitmap[x, y] = isBlack
            }
        }
    }

    /// Draws realistic multi-stem lowercase and capital glyphs (`n`, `u`, `h`, `m`, `H`, `E`, `M`)
    /// along horizontal baselines so both `FontScaleAnalyzer` and stroke-interior recall metrics
    /// exercise authentic vertical stems, horizontal crossbars, and dense multi-stem junctions.
    private static func drawMultiStemTypesetPage(
        width: Int,
        height: Int,
        xHeight: Int,
        capHeight: Int,
        strokeWidth: Int,
        lineSpacing: Int,
        leftMargin: Int,
        rightMargin: Int,
        topBaselineY: Int,
        lineCount: Int
    ) -> (groundTruth: BinaryBitmap, coreInterior: BinaryBitmap) {
        var gt = BinaryBitmap(width: width, height: height, initialBlack: false)
        var core = BinaryBitmap(width: width, height: height, initialBlack: false)
        let coreInset = max(1, strokeWidth / 3)

        func addBar(_ rect: Rect2I) {
            fillRect(&gt, rect, isBlack: true)
            let inner = Rect2I(
                x: rect.minX + coreInset,
                y: rect.minY + coreInset,
                width: rect.width - 2 * coreInset,
                height: rect.height - 2 * coreInset
            )
            if inner.width >= 1 && inner.height >= 1 {
                fillRect(&core, inner, isBlack: true)
            }
        }

        let counterGap = max(strokeWidth + 2, Int((Double(xHeight) * 0.34).rounded()))
        let glyphAdvance = max(3 * strokeWidth + 2 * counterGap, Int((Double(xHeight) * 1.15).rounded()))
        let wordSpace = max(glyphAdvance, Int((Double(xHeight) * 0.90).rounded()))

        for row in 0..<lineCount {
            let baseY = topBaselineY + row * lineSpacing
            guard baseY + 4 < height - 20 else { break }

            var cursorX = leftMargin
            var glyphIndex = 0

            while cursorX + glyphAdvance < width - rightMargin {
                let isCap = (glyphIndex % 5 == 0)
                let h = isCap ? capHeight : xHeight
                let yTop = baseY - h
                guard yTop > 16 else { break }

                let pattern = glyphIndex % 4
                switch pattern {
                case 0:
                    // 'H' or 'h': left stem, right stem, middle crossbar
                    let gW = 2 * strokeWidth + counterGap
                    addBar(Rect2I(x: cursorX, y: yTop, width: strokeWidth, height: h))
                    let rightTop = isCap ? yTop : (baseY - xHeight)
                    let rightH = isCap ? h : xHeight
                    addBar(Rect2I(x: cursorX + strokeWidth + counterGap, y: rightTop, width: strokeWidth, height: rightH))
                    let midY = baseY - xHeight / 2 - strokeWidth / 2
                    addBar(Rect2I(x: cursorX, y: midY, width: gW, height: strokeWidth))
                    cursorX += gW + max(4, strokeWidth)

                case 1:
                    // 'm' or 'M': three vertical stems + top arch bar (wide dense ink footprint)
                    let gW = 3 * strokeWidth + 2 * counterGap
                    if cursorX + gW < width - rightMargin {
                        addBar(Rect2I(x: cursorX, y: yTop, width: strokeWidth, height: h))
                        addBar(Rect2I(x: cursorX + strokeWidth + counterGap, y: yTop, width: strokeWidth, height: h))
                        addBar(Rect2I(x: cursorX + 2 * (strokeWidth + counterGap), y: yTop, width: strokeWidth, height: h))
                        addBar(Rect2I(x: cursorX, y: yTop, width: gW, height: strokeWidth))
                        cursorX += gW + max(4, strokeWidth)
                    } else {
                        cursorX = width - rightMargin
                    }

                case 2:
                    // 'u': two stems + bottom baseline bar
                    let gW = 2 * strokeWidth + counterGap
                    addBar(Rect2I(x: cursorX, y: yTop, width: strokeWidth, height: h))
                    addBar(Rect2I(x: cursorX + strokeWidth + counterGap, y: yTop, width: strokeWidth, height: h))
                    addBar(Rect2I(x: cursorX, y: baseY - strokeWidth, width: gW, height: strokeWidth))
                    cursorX += gW + max(4, strokeWidth)

                default:
                    // 'E' or 'n': two/three horizontal bars or arch
                    let gW = 2 * strokeWidth + counterGap
                    addBar(Rect2I(x: cursorX, y: yTop, width: strokeWidth, height: h))
                    addBar(Rect2I(x: cursorX, y: yTop, width: gW, height: strokeWidth))
                    if isCap {
                        addBar(Rect2I(x: cursorX, y: yTop + (h - strokeWidth) / 2, width: gW - strokeWidth / 2, height: strokeWidth))
                        addBar(Rect2I(x: cursorX, y: baseY - strokeWidth, width: gW, height: strokeWidth))
                    } else {
                        addBar(Rect2I(x: cursorX + strokeWidth + counterGap, y: yTop, width: strokeWidth, height: h))
                    }
                    cursorX += gW + max(4, strokeWidth)
                }

                glyphIndex += 1
                if glyphIndex % 4 == 0 {
                    cursorX += wordSpace
                }
            }
        }

        return (gt, core)
    }

    private static func renderShadedGrayscale(
        from groundTruth: borrowing BinaryBitmap,
        dpi: Int,
        inkReflectanceRatio: Double = 0.28
    ) -> GrayscaleBuffer {
        let w = groundTruth.width
        let h = groundTruth.height
        let wordsPerRow = groundTruth.wordsPerRow
        var pixels = ContiguousArray<UInt8>(repeating: 235, count: w * h)

        groundTruth.words.withUnsafeBufferPointer { wordPtr in
            pixels.withUnsafeMutableBufferPointer { dstPtr in
                for y in 0..<h {
                    let vy = Double(y) / Double(max(1, h - 1))
                    // Top-to-bottom illumination falloff + left spine shadow ramp
                    let vertFactor = 1.0 - 0.24 * vy
                    let wordRow = y * wordsPerRow
                    let pixRow = y * w

                    for x in 0..<w {
                        let vx = Double(x) / Double(max(1, w - 1))
                        let horizFactor = 0.56 + 0.44 * vx
                        let paperLum = 236.0 * vertFactor * horizFactor
                        let word = wordPtr[wordRow + (x >> 6)]
                        let isInk = ((word >> (63 - (x & 63))) & 1) != 0
                        let lum = isInk ? (paperLum * inkReflectanceRatio) : paperLum
                        dstPtr[pixRow + x] = UInt8(clamping: Int(lum.rounded()))
                    }
                }
            }
        }

        return GrayscaleBuffer(width: w, height: h, dpi: dpi, pixels: pixels)
    }

    private static func naiveDilate2D(_ buffer: borrowing GrayscaleBuffer, radius: Int) -> GrayscaleBuffer {
        guard radius > 0 else {
            return GrayscaleBuffer(width: buffer.width, height: buffer.height, dpi: buffer.dpi, pixels: buffer.pixels)
        }
        let w = buffer.width
        let h = buffer.height
        var out = ContiguousArray<UInt8>(repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - radius)
            let y1 = min(h - 1, y + radius)
            for x in 0..<w {
                let x0 = max(0, x - radius)
                let x1 = min(w - 1, x + radius)
                var m: UInt8 = 0
                for sy in y0...y1 {
                    for sx in x0...x1 {
                        let v = buffer[sx, sy]
                        if v > m { m = v }
                    }
                }
                out[y * w + x] = m
            }
        }
        return GrayscaleBuffer(width: w, height: h, dpi: buffer.dpi, pixels: out)
    }

    private static func naiveErode2D(_ buffer: borrowing GrayscaleBuffer, radius: Int) -> GrayscaleBuffer {
        guard radius > 0 else {
            return GrayscaleBuffer(width: buffer.width, height: buffer.height, dpi: buffer.dpi, pixels: buffer.pixels)
        }
        let w = buffer.width
        let h = buffer.height
        var out = ContiguousArray<UInt8>(repeating: 255, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - radius)
            let y1 = min(h - 1, y + radius)
            for x in 0..<w {
                let x0 = max(0, x - radius)
                let x1 = min(w - 1, x + radius)
                var m: UInt8 = 255
                for sy in y0...y1 {
                    for sx in x0...x1 {
                        let v = buffer[sx, sy]
                        if v < m { m = v }
                    }
                }
                out[y * w + x] = m
            }
        }
        return GrayscaleBuffer(width: w, height: h, dpi: buffer.dpi, pixels: out)
    }

    // MARK: - Unit & Pipeline Verification Tests

    @Test("deriveKernelParameters scales closing radius, Gaussian sigma, and downsample factor across calibrated, bold, and Simpson-scale camera typography")
    func testDeriveKernelParametersMathematicalInvariantsAndCodable() throws {
        let normalizer = BackgroundNormalizer()

        // 1. Calibrated 300 DPI 10-pt prose (H_x = 20 px, H_cap = 29.6 px, W_stroke = 3.7 px)
        let scale300 = BackgroundNormalizer.GlyphScale(
            xHeightPixels: 20.0,
            strokeWidthPixels: 3.7,
            capHeightPixels: 29.6,
            confidence: 0.90
        )
        let params300 = normalizer.deriveKernelParameters(
            imageWidth: 1650,
            imageHeight: 2550,
            dpi: 300,
            glyphScale: scale300
        )
        #expect(params300.usedGlyphScale == true)
        #expect(params300.fullResolutionClosingRadius == 25)
        #expect(abs(params300.fullResolutionBlurSigma - 12.5) < 1e-6)
        #expect(params300.effectiveDownsampleFactor == 4)
        #expect(abs(params300.downsampledBlurSigma - 3.125) < 1e-6)

        // 2. Calibrated 600 DPI 10-pt prose (H_x = 40 px, H_cap = 59.2 px, W_stroke = 7.3 px)
        let scale600 = BackgroundNormalizer.GlyphScale(
            xHeightPixels: 40.0,
            strokeWidthPixels: 7.3,
            capHeightPixels: 59.2,
            confidence: 0.92
        )
        let params600 = normalizer.deriveKernelParameters(
            imageWidth: 3300,
            imageHeight: 5100,
            dpi: 600,
            glyphScale: scale600
        )
        #expect(params600.usedGlyphScale == true)
        #expect(params600.fullResolutionClosingRadius == 50)
        #expect(abs(params600.fullResolutionBlurSigma - 25.0) < 1e-6)
        #expect(params600.effectiveDownsampleFactor == 4)
        #expect(abs(params600.downsampledBlurSigma - 6.25) < 1e-6)

        // 3. Simpson 1968 oversized 72-DPI camera canvas (H_x = 140 px, H_cap = 208 px, W_stroke = 25 px)
        // Must bridge 208-px tall characters (2 * R_closing > 208 px) regardless of bogus 72-DPI wrapper metadata!
        let simpsonScale = BackgroundNormalizer.GlyphScale(
            xHeightPixels: 140.0,
            strokeWidthPixels: 25.0,
            capHeightPixels: 208.0,
            confidence: 0.88
        )
        let paramsSimpson = normalizer.deriveKernelParameters(
            imageWidth: 16800,
            imageHeight: 18900,
            dpi: 72,
            glyphScale: simpsonScale
        )
        #expect(paramsSimpson.usedGlyphScale == true)
        #expect(paramsSimpson.fullResolutionClosingRadius == 177)
        #expect(2 * paramsSimpson.fullResolutionClosingRadius > 208)
        #expect(abs(paramsSimpson.fullResolutionBlurSigma - 88.5) < 1e-6)
        #expect(paramsSimpson.effectiveDownsampleFactor == 14)
        #expect(paramsSimpson.downsampledBlurSigma > 5.0 && paramsSimpson.downsampledBlurSigma <= 20.0)

        // 4. Stroke-width dominance on heavy bold / blackletter stems at identical x-height (H_x = 32 px)
        let regularWeight = BackgroundNormalizer.GlyphScale(xHeightPixels: 32.0, strokeWidthPixels: 4.0, confidence: 0.85)
        let boldWeight = BackgroundNormalizer.GlyphScale(xHeightPixels: 32.0, strokeWidthPixels: 12.0, confidence: 0.85)
        let paramsRegular = normalizer.deriveKernelParameters(imageWidth: 2000, imageHeight: 2800, dpi: 300, glyphScale: regularWeight)
        let paramsBold = normalizer.deriveKernelParameters(imageWidth: 2000, imageHeight: 2800, dpi: 300, glyphScale: boldWeight)
        #expect(paramsRegular.fullResolutionClosingRadius == 40)
        #expect(paramsBold.fullResolutionClosingRadius == 75)
        #expect(paramsBold.fullResolutionBlurSigma > paramsRegular.fullResolutionBlurSigma * 1.8)

        // 5. Low-confidence rejection falls back safely to DPI scaling
        let lowConf = BackgroundNormalizer.GlyphScale(xHeightPixels: 120.0, strokeWidthPixels: 22.0, confidence: 0.20)
        let fallbackParams = normalizer.deriveKernelParameters(imageWidth: 1650, imageHeight: 2550, dpi: 300, glyphScale: lowConf)
        #expect(fallbackParams.usedGlyphScale == false)
        #expect(fallbackParams.resolvedGlyphScale == nil)
        #expect(fallbackParams.fullResolutionClosingRadius == 24)
        #expect(abs(fallbackParams.fullResolutionBlurSigma - 12.0) < 1e-6)

        // 6. Codable round-trip & backward-compatible legacy JSON decoding
        let customConfig = BackgroundNormalizer.Configuration(
            downsampleFactor: 4,
            referenceClosingRadiusAt300DPI: 30,
            downsampledBlurSigma: 2.5,
            minimumBackgroundDivisor: 40,
            strength: 0.9,
            enableGlyphScaleAdaptation: true,
            closingRadiusXHeightMultiplier: 1.35,
            closingRadiusStrokeWidthMultiplier: 6.5,
            minimumGlyphConfidence: 0.40
        )
        let encodedConfig = try JSONEncoder().encode(customConfig)
        let decodedConfig = try JSONDecoder().decode(BackgroundNormalizer.Configuration.self, from: encodedConfig)
        #expect(decodedConfig == customConfig)

        let legacyJSON = Data(#"{"downsampleFactor":4,"referenceClosingRadiusAt300DPI":24,"downsampledBlurSigma":3.0,"minimumBackgroundDivisor":32,"strength":1.0}"#.utf8)
        let legacyDecoded = try JSONDecoder().decode(BackgroundNormalizer.Configuration.self, from: legacyJSON)
        #expect(legacyDecoded.enableGlyphScaleAdaptation == true)
        #expect(legacyDecoded.closingRadiusXHeightMultiplier == 1.25)
        #expect(legacyDecoded.closingRadiusStrokeWidthMultiplier == 6.25)
        #expect(legacyDecoded.minimumGlyphConfidence == 0.35)
    }

    @Test("Dynamic glyph-scale normalization prevents character interior erosion on uncalibrated 72-DPI camera captures")
    func testGlyphScaleNormalizationPreventsCharacterErosionOn72DPICameraCapture() throws {
        // Synthetic high-resolution camera slice wrapped at 72 DPI:
        // Glyphs have xHeight = 68 px, capHeight = 102 px, thick vertical/horizontal stems = 22 px
        // (matching Simpson 1968 stroke scale where 22-px stems exceed the 72-DPI 6-px closing footprint).
        let width = 1360
        let height = 1600
        let (groundTruth, coreInterior) = Self.drawMultiStemTypesetPage(
            width: width,
            height: height,
            xHeight: 68,
            capHeight: 102,
            strokeWidth: 22,
            lineSpacing: 158,
            leftMargin: 120,
            rightMargin: 120,
            topBaselineY: 230,
            lineCount: 8
        )
        let cameraGray72 = Self.renderShadedGrayscale(from: groundTruth, dpi: 72, inkReflectanceRatio: 0.30)
        let accelerator = PortableComputeAccelerator()

        // A. Legacy fixed-DPI normalization (`enableGlyphScaleAdaptation: false`) at declared 72 DPI:
        //    R_closing = round(24 * 72 / 300) = 6 px -> erodes straight into 22-px thick / 102-px tall characters!
        let fixedBgConfig = BackgroundNormalizer.Configuration(enableGlyphScaleAdaptation: false)
        let fixedNormResult = BackgroundNormalizer(configuration: fixedBgConfig).normalizeWithTelemetry(
            cameraGray72,
            accelerator: accelerator
        )
        #expect(fixedNormResult.parameters.usedGlyphScale == false)
        #expect(fixedNormResult.parameters.fullResolutionClosingRadius == 6)

        // B. Dynamic glyph-scale normalization (`enableGlyphScaleAdaptation: true`, automatic pre-probe):
        let adaptiveBgConfig = BackgroundNormalizer.Configuration(enableGlyphScaleAdaptation: true)
        let adaptiveNormResult = BackgroundNormalizer(configuration: adaptiveBgConfig).normalizeWithTelemetry(
            cameraGray72,
            accelerator: accelerator
        )
        #expect(adaptiveNormResult.parameters.usedGlyphScale == true)
        let resolvedScale = try #require(adaptiveNormResult.parameters.resolvedGlyphScale)
        #expect(abs(resolvedScale.xHeightPixels - 68.0) <= 8.0)
        #expect(abs(resolvedScale.strokeWidthPixels - 22.0) <= 4.0)
        #expect(adaptiveNormResult.parameters.fullResolutionClosingRadius >= 85)

        // Measure mean normalized luminance inside deep stroke interiors (`coreInterior`):
        // Legacy fixed-DPI washes out stroke interiors close to white (> 185); dynamic keeps them dark (< 100).
        var fixedCoreSum = 0
        var adaptiveCoreSum = 0
        var coreCount = 0
        for y in 0..<height {
            for x in 0..<width where coreInterior[x, y] {
                fixedCoreSum += Int(fixedNormResult.buffer[x, y])
                adaptiveCoreSum += Int(adaptiveNormResult.buffer[x, y])
                coreCount += 1
            }
        }
        #expect(coreCount > 5000)
        let fixedMeanCoreLum = Double(fixedCoreSum) / Double(coreCount)
        let adaptiveMeanCoreLum = Double(adaptiveCoreSum) / Double(coreCount)
        #expect(fixedMeanCoreLum > 185.0)
        #expect(adaptiveMeanCoreLum < 100.0)

        // Verify end-to-end AdaptiveBinarizer (both Wolf-Jolion and Sauvola) preserves solid stroke interiors
        // without hollowing out stems or hallucinating noise in shaded margins!
        let fixedBinarizer = AdaptiveBinarizer(
            configuration: .init(method: .wolfJolion, backgroundNormalization: fixedBgConfig)
        )
        let fixedBinary = fixedBinarizer.binarize(cameraGray72, accelerator: accelerator)
        var fixedCoreHits = 0
        for y in 0..<height {
            for x in 0..<width where coreInterior[x, y] && fixedBinary[x, y] {
                fixedCoreHits += 1
            }
        }
        let fixedCoreRecall = Double(fixedCoreHits) / Double(coreCount)

        for method in [AdaptiveBinarizer.Method.wolfJolion, AdaptiveBinarizer.Method.sauvola] {
            let adaptiveBinarizer = AdaptiveBinarizer(
                configuration: .init(method: method, backgroundNormalization: adaptiveBgConfig)
            )
            let adaptiveBinary = adaptiveBinarizer.binarize(cameraGray72, accelerator: accelerator)

            var adaptiveCoreHits = 0
            var totalGTHits = 0
            var totalGTCount = 0
            var marginFalsePositives = 0

            for y in 0..<height {
                for x in 0..<width {
                    if coreInterior[x, y] && adaptiveBinary[x, y] {
                        adaptiveCoreHits += 1
                    }
                    if groundTruth[x, y] {
                        totalGTCount += 1
                        if adaptiveBinary[x, y] {
                            totalGTHits += 1
                        }
                    } else if y < 60 || y >= height - 60 || x < 60 || x >= width - 60 {
                        if adaptiveBinary[x, y] {
                            marginFalsePositives += 1
                        }
                    }
                }
            }

            let adaptiveCoreRecall = Double(adaptiveCoreHits) / Double(coreCount)
            let totalRecall = Double(totalGTHits) / Double(max(1, totalGTCount))

            // Fixed-DPI starved interior recall badly, while dynamic glyph-scale achieves >= 96% solid core recall!
            #expect(fixedCoreRecall < 0.45)
            #expect(adaptiveCoreRecall >= 0.96)
            #expect(totalRecall >= 0.92)
            #expect(marginFalsePositives == 0)
        }
    }

    @Test("Thick bold display typography at calibrated 300 DPI expands kernel radius via stroke width to prevent stem washout")
    func testBoldDisplayStrokeWidthPreventsInteriorWashoutAt300DPI() throws {
        // Calibrated 300-DPI title/display page with bold 13-px stems and 42-px x-height:
        // Fixed 300-DPI radius (24 px) fails to bridge wide 3-stem 'M'/'m' glyphs (width = 3*13 + 2*16 = 71 px > 48 px)!
        let width = 1160
        let height = 1360
        let (groundTruth, coreInterior) = Self.drawMultiStemTypesetPage(
            width: width,
            height: height,
            xHeight: 42,
            capHeight: 63,
            strokeWidth: 13,
            lineSpacing: 110,
            leftMargin: 110,
            rightMargin: 110,
            topBaselineY: 200,
            lineCount: 9
        )
        let shaded300 = Self.renderShadedGrayscale(from: groundTruth, dpi: 300, inkReflectanceRatio: 0.28)
        let accelerator = PortableComputeAccelerator()

        let adaptiveNormalizer = BackgroundNormalizer()
        let result = adaptiveNormalizer.normalizeWithTelemetry(shaded300, accelerator: accelerator)

        #expect(result.parameters.usedGlyphScale == true)
        // Stroke-width term (~6.25 * 13 ≈ 81 px) dominates over 300-DPI fixed default (24 px) and x-height term (1.25 * 42 ≈ 52.5 px)
        #expect(result.parameters.fullResolutionClosingRadius >= 65)
        #expect(result.parameters.fullResolutionBlurSigma >= 32.5)

        let binary = AdaptiveBinarizer(
            configuration: .init(method: .wolfJolion, backgroundNormalization: .init())
        ).binarize(shaded300, accelerator: accelerator)

        var coreHits = 0
        var coreTotal = 0
        for y in 0..<height {
            for x in 0..<width where coreInterior[x, y] {
                coreTotal += 1
                if binary[x, y] { coreHits += 1 }
            }
        }
        #expect(coreTotal > 3000)
        #expect(Double(coreHits) / Double(coreTotal) >= 0.96)
    }

    @Test("Blank pages, non-text camera illustration plates, and van Herk O(1) separable morphology behave safely and bit-exactly")
    func testFallbacksOnNonTextPagesAndVanHerkBitExactEquivalence() {
        let accelerator = PortableComputeAccelerator()
        let normalizer = BackgroundNormalizer()

        // 1. Blank page fast-path fallback
        let blank = GrayscaleBuffer(width: 600, height: 800, dpi: 300, initialValue: 238)
        #expect(normalizer.estimateGlyphScale(in: blank, accelerator: accelerator) == nil)
        let blankNorm = normalizer.normalizeWithTelemetry(blank, accelerator: accelerator)
        #expect(blankNorm.parameters.usedGlyphScale == false)
        #expect(blankNorm.parameters.fullResolutionClosingRadius == 24)
        #expect(blankNorm.buffer[300, 400] >= 250)

        // 2. High-resolution 72-DPI camera photo of a geometric illustration plate (0 collinear text chains)
        var plateBitmap = BinaryBitmap(width: 1900, height: 2400, initialBlack: false)
        Self.fillRect(&plateBitmap, Rect2I(x: 250, y: 300, width: 1400, height: 18), isBlack: true)
        Self.fillRect(&plateBitmap, Rect2I(x: 250, y: 2082, width: 1400, height: 18), isBlack: true)
        Self.fillRect(&plateBitmap, Rect2I(x: 250, y: 300, width: 18, height: 1800), isBlack: true)
        Self.fillRect(&plateBitmap, Rect2I(x: 1632, y: 300, width: 18, height: 1800), isBlack: true)
        let plateGray72 = Self.renderShadedGrayscale(from: plateBitmap, dpi: 72)

        #expect(normalizer.estimateGlyphScale(in: plateGray72, accelerator: accelerator) == nil)
        let plateResult = normalizer.normalizeWithTelemetry(plateGray72, accelerator: accelerator)
        #expect(plateResult.parameters.usedGlyphScale == false)
        // High-res 72-DPI fallback elevates to nominalProbeDPI (~267 DPI -> R_closing >= 20 px instead of 6 px)
        #expect(plateResult.parameters.fullResolutionClosingRadius >= 20)

        // 3. Bit-for-bit verification of van Herk O(1) separable dilation & erosion vs brute-force 2D windows
        let testW = 53
        let testH = 41
        var pseudoRandomPixels = ContiguousArray<UInt8>(repeating: 0, count: testW * testH)
        var state: UInt64 = 0xD1B5_4A32_D192_ED03
        for idx in 0..<(testW * testH) {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            pseudoRandomPixels[idx] = UInt8((state >> 56) & 0xFF)
        }
        let sampleBuf = GrayscaleBuffer(width: testW, height: testH, dpi: 300, pixels: pseudoRandomPixels)

        for radius in [0, 1, 2, 7, 19, 80] {
            let fastDilated = BackgroundNormalizer.grayscaleDilateSeparable(sampleBuf, radius: radius)
            let refDilated = Self.naiveDilate2D(sampleBuf, radius: radius)
            #expect(fastDilated.pixels == refDilated.pixels)

            let fastEroded = BackgroundNormalizer.grayscaleErodeSeparable(sampleBuf, radius: radius)
            let refEroded = Self.naiveErode2D(sampleBuf, radius: radius)
            #expect(fastEroded.pixels == refEroded.pixels)
        }
    }

    @Test("BookPipelineCoordinator Pass 1 preserves oversized large-print and display characters under uneven lighting")
    func testPipelinePass1PreservesOversizedCharactersInBookPipeline() async throws {
        // 1200 x 1560 @ 300 DPI (4.0" x 5.2" calibrated trim size -> 1:1 Pass 1 pixel coordinates)
        // with large 18-px bold strokes and 56-px x-height that would erode under fixed 24-px 300-DPI closing.
        let width = 1200
        let height = 1560
        let (groundTruth, coreInterior) = Self.drawMultiStemTypesetPage(
            width: width,
            height: height,
            xHeight: 56,
            capHeight: 84,
            strokeWidth: 18,
            lineSpacing: 132,
            leftMargin: 120,
            rightMargin: 120,
            topBaselineY: 220,
            lineCount: 9
        )
        let rawPage = Self.renderShadedGrayscale(from: groundTruth, dpi: 300, inkReflectanceRatio: 0.28)

        struct NullPDFWriter: PDFDocumentWriter, ~Copyable {
            mutating func appendPage(
                bitmap: borrowing BinaryBitmap,
                dpi: Int,
                pageBoxPoints: Rect2D,
                ocrLayer: [RecognizedTextObservation]
            ) throws(PDFWriteError) {}
            consuming func finalize() throws(PDFWriteError) {}
        }

        let config = BookPipelineCoordinator.Configuration(
            processingDPI: 300,
            outputDPI: 150,
            splitMode: .singlePage,
            enableDewarp: false,
            enableAutomaticFontScaleCalibration: false
        )
        let coordinator = BookPipelineCoordinator(configuration: config)
        let output = try await coordinator.processGrayscalePages(
            [rawPage],
            writer: NullPDFWriter(),
            accelerator: PortableComputeAccelerator(),
            ocrEngine: nil
        )

        #expect(output.cleanedBitmapsAtProcessingDPI.count == 1)
        let cleaned = output.cleanedBitmapsAtProcessingDPI[0]
        #expect(cleaned.width == width && cleaned.height == height)

        var hits = 0
        var total = 0
        var coreHits = 0
        var coreTotal = 0
        for y in 0..<height {
            for x in 0..<width {
                if groundTruth[x, y] {
                    total += 1
                    if cleaned[x, y] { hits += 1 }
                }
                if coreInterior[x, y] {
                    coreTotal += 1
                    if cleaned[x, y] { coreHits += 1 }
                }
            }
        }
        let recall = Double(hits) / Double(max(1, total))
        let coreRecall = Double(coreHits) / Double(max(1, coreTotal))
        #expect(recall >= 0.92)
        #expect(coreRecall >= 0.96)
    }
}
