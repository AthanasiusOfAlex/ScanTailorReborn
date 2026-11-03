import Foundation
import ScanTailorContracts
@testable import ScanTailorCore
import ScanTailorPipeline
import ScanTailorPortableBackend
import Testing

@Suite("Substep 4.2.2 — Dual-Pass Illumination Flattening & Anti-Starvation Tests")
struct DualPassIlluminationTests {

    // MARK: - Synthetic Camera Optics, Typesetting & Stroke-Width Helpers

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

    /// Generates symmetric upper-half and lower-half typeset lines with vertical stems (`H`, `n`, `m`, `u`)
    /// and thin horizontal crossbars/serifs so upper-vs-lower stroke thickness and recall can be compared
    /// at identical layout geometry.
    private static func drawSymmetricUpperLowerTypesetPage(
        width: Int,
        height: Int,
        xHeight: Int,
        capHeight: Int,
        stemWidth: Int,
        crossbarHeight: Int,
        leftMargin: Int,
        rightMargin: Int,
        linesPerHalf: Int,
        lineSpacing: Int
    ) -> (groundTruth: BinaryBitmap, stemMidpointsY: (upper: [Int], lower: [Int])) {
        var gt = BinaryBitmap(width: width, height: height, initialBlack: false)
        var upperMidY: [Int] = []
        var lowerMidY: [Int] = []

        let counterGap = max(stemWidth + 2, Int((Double(xHeight) * 0.36).rounded()))
        let glyphAdvance = 2 * stemWidth + counterGap + max(4, stemWidth)
        let wordSpace = max(glyphAdvance, Int((Double(xHeight) * 0.85).rounded()))

        let upperStartBaseline = max(capHeight + 50, height / 9 + capHeight)
        let lowerStartBaseline = height / 2 + max(capHeight + 36, height / 14)

        for half in 0..<2 {
            let baseStart = (half == 0) ? upperStartBaseline : lowerStartBaseline
            for row in 0..<linesPerHalf {
                let baseY = baseStart + row * lineSpacing
                guard baseY + 12 < height - 40 else { break }

                let midY = baseY - xHeight / 2
                if half == 0 {
                    upperMidY.append(midY)
                } else {
                    lowerMidY.append(midY)
                }

                var cursorX = leftMargin
                var idx = 0
                while cursorX + 3 * stemWidth + 2 * counterGap < width - rightMargin {
                    let isCap = (idx % 5 == 0)
                    let h = isCap ? capHeight : xHeight
                    let yTop = baseY - h

                    switch idx % 4 {
                    case 0:
                        // 'H' / 'h' with thin horizontal crossbar
                        let gW = 2 * stemWidth + counterGap
                        fillRect(&gt, Rect2I(x: cursorX, y: yTop, width: stemWidth, height: h))
                        let rTop = isCap ? yTop : (baseY - xHeight)
                        let rH = isCap ? h : xHeight
                        fillRect(&gt, Rect2I(x: cursorX + stemWidth + counterGap, y: rTop, width: stemWidth, height: rH))
                        fillRect(&gt, Rect2I(x: cursorX, y: baseY - xHeight / 2 - crossbarHeight / 2, width: gW, height: crossbarHeight))
                        cursorX += gW + max(4, stemWidth)

                    case 1:
                        // 'm' / 'M': three stems + thin top arch
                        let gW = 3 * stemWidth + 2 * counterGap
                        fillRect(&gt, Rect2I(x: cursorX, y: yTop, width: stemWidth, height: h))
                        fillRect(&gt, Rect2I(x: cursorX + stemWidth + counterGap, y: yTop, width: stemWidth, height: h))
                        fillRect(&gt, Rect2I(x: cursorX + 2 * (stemWidth + counterGap), y: yTop, width: stemWidth, height: h))
                        fillRect(&gt, Rect2I(x: cursorX, y: yTop, width: gW, height: crossbarHeight))
                        cursorX += gW + max(4, stemWidth)

                    case 2:
                        // 'u': two stems + thin baseline bar
                        let gW = 2 * stemWidth + counterGap
                        fillRect(&gt, Rect2I(x: cursorX, y: yTop, width: stemWidth, height: h))
                        fillRect(&gt, Rect2I(x: cursorX + stemWidth + counterGap, y: yTop, width: stemWidth, height: h))
                        fillRect(&gt, Rect2I(x: cursorX, y: baseY - crossbarHeight, width: gW, height: crossbarHeight))
                        cursorX += gW + max(4, stemWidth)

                    default:
                        // 'n' / 'E'
                        let gW = 2 * stemWidth + counterGap
                        fillRect(&gt, Rect2I(x: cursorX, y: yTop, width: stemWidth, height: h))
                        fillRect(&gt, Rect2I(x: cursorX, y: yTop, width: gW, height: crossbarHeight))
                        if isCap {
                            fillRect(&gt, Rect2I(x: cursorX, y: yTop + (h - crossbarHeight) / 2, width: gW - stemWidth / 2, height: crossbarHeight))
                            fillRect(&gt, Rect2I(x: cursorX, y: baseY - crossbarHeight, width: gW, height: crossbarHeight))
                        } else {
                            fillRect(&gt, Rect2I(x: cursorX + stemWidth + counterGap, y: yTop, width: stemWidth, height: h))
                        }
                        cursorX += gW + max(4, stemWidth)
                    }

                    idx += 1
                    if idx % 4 == 0 {
                        cursorX += wordSpace
                    }
                }
            }
        }

        return (gt, (upperMidY, lowerMidY))
    }

    /// Measures average horizontal run length across vertical stems along the given scanline `y` coordinates
    /// inside `[minX..<maxX]`, directly quantifying rendered stroke weight in pixels.
    private static func measureMeanStemRunWidth(
        in bitmap: borrowing BinaryBitmap,
        scanlinesY: [Int],
        minX: Int,
        maxX: Int,
        expectedMaxStemRun: Int
    ) -> Double {
        let clampedMinX = max(0, minX)
        let clampedMaxX = min(bitmap.width, maxX)
        guard clampedMinX < clampedMaxX else { return 0.0 }

        var runSum = 0
        var runCount = 0

        for y in scanlinesY where y >= 0 && y < bitmap.height {
            var x = clampedMinX
            while x < clampedMaxX {
                if bitmap[x, y] {
                    let start = x
                    while x < clampedMaxX && bitmap[x, y] {
                        x += 1
                    }
                    let len = x - start
                    if len >= 1 && len <= expectedMaxStemRun {
                        runSum += len
                        runCount += 1
                    }
                } else {
                    x += 1
                }
            }
        }

        return runCount > 0 ? (Double(runSum) / Double(runCount)) : 0.0
    }

    // MARK: - Verification Tests

    @Test("Simpson Page 2 illumination & veiling-glare ramp achieves uniform stroke weight and eliminates threshold starvation")
    func testSimpsonPage2GradientAndGlareAchievesUniformStrokeWeightWithoutStarvation() {
        let width = 1040
        let height = 1360
        let stemWidth = 7
        let crossbarHeight = 3

        let (groundTruth, midpoints) = Self.drawSymmetricUpperLowerTypesetPage(
            width: width,
            height: height,
            xHeight: 28,
            capHeight: 42,
            stemWidth: stemWidth,
            crossbarHeight: crossbarHeight,
            leftMargin: 110,
            rightMargin: 90,
            linesPerHalf: 6,
            lineSpacing: 74
        )

        // Build soft optical camera ink coverage map (3x3 tent PSF simulating handheld lens softness
        // where thin crossbars and stroke edges sit at partial contrast and starve first!).
        var coverage = ContiguousArray<Float>(repeating: 0.0, count: width * height)
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                var sum: Float = 0.0
                for dy in -1...1 {
                    for dx in -1...1 {
                        if groundTruth[x + dx, y + dy] {
                            let w: Float = (dx == 0 && dy == 0) ? 4.0 : ((dx == 0 || dy == 0) ? 2.0 : 1.0)
                            sum += w
                        }
                    }
                }
                coverage[y * width + x] = sum / 16.0
            }
        }

        // Synthesize handheld camera capture with:
        // - Upper half: specular lamp glare + elevated ink pedestal (paper ~220, ink core ~154, contrast = 66)
        // - Lower half: shadowed diffuse illumination with crisp contrast (paper ~178, ink core ~64, contrast = 114)
        // - Horizontal spine-to-edge lighting ramp across width
        // - Dark wooden desk border strip on the far left (`x = 0..<22`, luminance ~14) that would poison
        //   naive global Wolf-Jolion `(M, R_max)` anchors!
        var rawPixels = ContiguousArray<UInt8>(repeating: 210, count: width * height)
        for y in 0..<height {
            // Smooth vertical S-curve transition between glared upper half and shadowed crisp lower half
            let normY = Double(y) / Double(height - 1)
            let s = 1.0 / (1.0 + exp((normY - 0.50) * 10.0)) // ~1.0 in upper half, ~0.0 in lower half

            let basePaperY = 178.0 + 42.0 * s     // 220 at top -> 178 at bottom
            let baseInkY = 64.0 + 90.0 * s        // 154 at top (glare-veiled!) -> 64 at bottom (crisp)

            for x in 0..<width {
                if x < 22 {
                    // Peripheral dark desk strip along outer left edge
                    rawPixels[y * width + x] = UInt8(12 + ((x + y) % 5))
                    continue
                }
                let normX = Double(x) / Double(width - 1)
                let hMod = 0.84 + 0.16 * normX
                let paper = basePaperY * hMod
                let ink = baseInkY * hMod
                let cov = Double(coverage[y * width + x])
                let lum = paper * (1.0 - cov) + ink * cov
                rawPixels[y * width + x] = UInt8(clamping: Int(lum.rounded()))
            }
        }
        let cameraSource = GrayscaleBuffer(width: width, height: height, dpi: 300, pixels: rawPixels)
        let accelerator = PortableComputeAccelerator()

        // 1. Compare single-pass without contrast leveling vs Substep 4.2.2 Dual-Pass + Anti-Starvation
        let singlePassConfig = BackgroundNormalizer.Configuration(
            enableDualPassFlattening: false,
            enableAntiStarvationContrastLeveling: false
        )
        let singleNorm = BackgroundNormalizer(configuration: singlePassConfig).normalizeWithTelemetry(
            cameraSource,
            accelerator: accelerator
        )
        #expect(singleNorm.parameters.dualPassApplied == false)
        #expect(singleNorm.parameters.contrastLevelingApplied == false)

        let dualPassConfig = BackgroundNormalizer.Configuration()
        let dualNorm = BackgroundNormalizer(configuration: dualPassConfig).normalizeWithTelemetry(
            cameraSource,
            accelerator: accelerator
        )
        #expect(dualNorm.parameters.dualPassApplied == true)
        #expect(dualNorm.parameters.contrastLevelingApplied == true)
        #expect(dualNorm.parameters.peakContrastGain > 1.35)

        // Verify normalized paper is flat (~255) in both halves AND normalized ink core darkness is harmonized!
        #expect(dualNorm.buffer[520, 45] >= 250)
        #expect(dualNorm.buffer[520, height - 45] >= 250)

        var singleUpperInkSum = 0, singleLowerInkSum = 0
        var dualUpperInkSum = 0, dualLowerInkSum = 0
        var upperCoreCount = 0, lowerCoreCount = 0
        for y in 0..<height {
            for x in 110..<(width - 90) where coverage[y * width + x] >= 0.95 {
                if y < height / 2 {
                    singleUpperInkSum += Int(singleNorm.buffer[x, y])
                    dualUpperInkSum += Int(dualNorm.buffer[x, y])
                    upperCoreCount += 1
                } else {
                    singleLowerInkSum += Int(singleNorm.buffer[x, y])
                    dualLowerInkSum += Int(dualNorm.buffer[x, y])
                    lowerCoreCount += 1
                }
            }
        }
        #expect(upperCoreCount > 1000 && lowerCoreCount > 1000)
        let singleUpperInkMean = Double(singleUpperInkSum) / Double(upperCoreCount)
        let singleLowerInkMean = Double(singleLowerInkSum) / Double(lowerCoreCount)
        let dualUpperInkMean = Double(dualUpperInkSum) / Double(upperCoreCount)
        let dualLowerInkMean = Double(dualLowerInkSum) / Double(lowerCoreCount)

        // Single-pass left upper ink elevated (> 160) vs lower ink (~100), > 58 levels apart;
        // Dual-pass harmonizes upper ink right down to crisp black (< 112), narrowing disparity by > 5x!
        #expect(abs(singleUpperInkMean - singleLowerInkMean) > 58.0)
        #expect(dualUpperInkMean < 112.0)
        #expect(abs(dualUpperInkMean - dualLowerInkMean) <= 14.0)

        // 2. End-to-end AdaptiveBinarizer stroke-weight uniformity & anti-starvation check (Wolf-Jolion & Sauvola)
        let singleSauvola = AdaptiveBinarizer(
            configuration: .init(method: .sauvola, k: 0.30, backgroundNormalization: singlePassConfig)
        ).binarize(cameraSource, accelerator: accelerator)

        var singleUpperHits = 0, upperGT = 0
        for y in 0..<(height / 2) {
            for x in 110..<(width - 90) where groundTruth[x, y] {
                upperGT += 1
                if singleSauvola[x, y] { singleUpperHits += 1 }
            }
        }
        let singleUpperRecall = Double(singleUpperHits) / Double(max(1, upperGT))

        for method in [AdaptiveBinarizer.Method.wolfJolion, AdaptiveBinarizer.Method.sauvola] {
            let dualBinary = AdaptiveBinarizer(
                configuration: .init(method: method, k: 0.30, backgroundNormalization: dualPassConfig)
            ).binarize(cameraSource, accelerator: accelerator)

            var upperHits = 0, uTotal = 0
            var lowerHits = 0, lTotal = 0
            var marginFalsePositives = 0

            for y in 0..<height {
                for x in 90..<(width - 40) {
                    if groundTruth[x, y] {
                        if y < height / 2 {
                            uTotal += 1
                            if dualBinary[x, y] { upperHits += 1 }
                        } else {
                            lTotal += 1
                            if dualBinary[x, y] { lowerHits += 1 }
                        }
                    } else if y < 48 || y >= height - 48 || x >= width - 60 {
                        if dualBinary[x, y] {
                            marginFalsePositives += 1
                        }
                    }
                }
            }

            let upperRecall = Double(upperHits) / Double(max(1, uTotal))
            let lowerRecall = Double(lowerHits) / Double(max(1, lTotal))

            let upperStemWidth = Self.measureMeanStemRunWidth(
                in: dualBinary,
                scanlinesY: midpoints.upper,
                minX: 105,
                maxX: width - 85,
                expectedMaxStemRun: stemWidth + 4
            )
            let lowerStemWidth = Self.measureMeanStemRunWidth(
                in: dualBinary,
                scanlinesY: midpoints.lower,
                minX: 105,
                maxX: width - 85,
                expectedMaxStemRun: stemWidth + 4
            )

            // Single-pass starved the glared upper half badly, while Substep 4.2.2 achieves >= 92% recall
            // and near-identical stem stroke weight across upper and lower halves!
            #expect(singleUpperRecall < 0.72)
            #expect(upperRecall >= 0.92)
            #expect(lowerRecall >= 0.92)
            #expect(abs(upperRecall - lowerRecall) <= 0.05)
            #expect(abs(upperStemWidth - lowerStemWidth) <= 0.60)
            #expect(marginFalsePositives == 0)
        }
    }

    @Test("Pass 2 foreground-masked residual prevents dense multi-column dictionary blocks from depressing background estimates")
    func testDenseMultiColumnTextDoesNotDepressBackgroundEstimateInPass2() {
        let width = 960
        let height = 1120
        var denseGT = BinaryBitmap(width: width, height: height, initialBlack: false)

        // Create two dense dictionary columns set solid: every glyph body spans the full 24-px line
        // (bold ascender-to-baseline entry face), so with 4-px leading and 4-px inter-glyph gaps every
        // 4x4 Pass 1 block overlaps ink or stroke skirts, while 2-px clean paper channels survive at
        // the gap centres for Pass 2's per-pixel paper sampling.
        let colRanges = [(90, 445), (515, 870)]
        for (colX0, colX1) in colRanges {
            var y = 110
            var row = 0
            while y + 26 < height - 110 {
                var x = colX0
                var g = 0
                while x + 24 < colX1 {
                    let isBoldHeadword = (row % 3 == 0 && g < 3)
                    let sw = isBoldHeadword ? 7 : 5
                    Self.fillRect(&denseGT, Rect2I(x: x, y: y, width: sw, height: 24))
                    Self.fillRect(&denseGT, Rect2I(x: x + sw + 4, y: y, width: sw, height: 24))
                    Self.fillRect(&denseGT, Rect2I(x: x, y: y, width: 2 * sw + 4, height: 4))
                    if isBoldHeadword || g % 3 == 1 {
                        // Bold headword baseline bars and closed bowls
                        Self.fillRect(&denseGT, Rect2I(x: x, y: y + 20, width: 2 * sw + 4, height: 4))
                    }
                    x += 2 * sw + 8
                    g += 1
                    if g % 5 == 0 { x += 1 }
                }
                // Tight 28-px baseline spacing (only 4-px vertical gap between lines!)
                y += 28
                row += 1
            }
        }

        // Ground-truth smooth paper illumination surface (222 at top-right -> 172 at bottom-left), with
        // printing ink (85% absorption) imaged through a realistic 3x3 binomial optical PSF (sigma ~ 0.7 px):
        // stroke edges sit at partial coverage and soft 25%-coverage skirts bleed into every narrow gap.
        let inkAbsorption = 0.85
        var truePaper = ContiguousArray<UInt8>(repeating: 214, count: width * height)
        var sourcePixels = ContiguousArray<UInt8>(repeating: 214, count: width * height)
        for y in 0..<height {
            let vy = Double(y) / Double(height - 1)
            for x in 0..<width {
                let vx = Double(x) / Double(width - 1)
                let p = Int((172.0 + 30.0 * vx + 20.0 * (1.0 - vy)).rounded())
                let paperVal = UInt8(clamping: p)
                truePaper[y * width + x] = paperVal

                var coverageWeight = 0
                for ny in max(0, y - 1)...min(height - 1, y + 1) {
                    for nx in max(0, x - 1)...min(width - 1, x + 1) where denseGT[nx, ny] {
                        coverageWeight += (nx == x && ny == y) ? 4 : ((nx == x || ny == y) ? 2 : 1)
                    }
                }
                let lum = Double(paperVal) * (1.0 - inkAbsorption * Double(coverageWeight) / 16.0)
                sourcePixels[y * width + x] = UInt8(clamping: Int(lum.rounded()))
            }
        }

        let source = GrayscaleBuffer(width: width, height: height, dpi: 300, pixels: sourcePixels)
        let accelerator = PortableComputeAccelerator()

        let pass1OnlyBg = BackgroundNormalizer(
            configuration: .init(enableDualPassFlattening: false)
        ).estimateBackground(for: source, accelerator: accelerator)

        let dualPassBg = BackgroundNormalizer(
            configuration: .init(enableDualPassFlattening: true)
        ).estimateBackground(for: source, accelerator: accelerator)

        var errPass1Sum: Double = 0.0
        var errPass2Sum: Double = 0.0
        var sampleCount = 0

        for (colX0, colX1) in colRanges {
            for y in 130..<(height - 130) {
                for x in (colX0 + 15)..<(colX1 - 15) {
                    let gtP = Double(truePaper[y * width + x])
                    errPass1Sum += abs(Double(pass1OnlyBg[x, y]) - gtP)
                    errPass2Sum += abs(Double(dualPassBg[x, y]) - gtP)
                    sampleCount += 1
                }
            }
        }

        let maePass1 = errPass1Sum / Double(max(1, sampleCount))
        let maePass2 = errPass2Sum / Double(max(1, sampleCount))

        // Pass 1 sags significantly inside dense columns because every block averages ink and PSF skirts,
        // while Pass 2's skirt-rejecting per-pixel paper sampling reconstructs the true illumination surface
        // within a fraction of a gray level!
        #expect(maePass1 > 8.0)
        #expect(maePass2 < 3.0)
        #expect(maePass2 < maePass1 * 0.35)
    }

    @Test("Dual-pass flattening eliminates steep spine-boundary shadow blind spots caused by wide glyph-bridging closing")
    func testSteepBoundarySpineShadowFlattensRightUpToPageEdgeWithoutGutterCloud() {
        // High-resolution 72-DPI camera recto slice with large characters (xHeight = 56 px, stroke = 16 px -> R_closing >= 70 px)
        // and a sharp cylindrical book-spine shadow right at the x = 0 split boundary (paper drops to 88 at x = 0).
        let width = 1120
        let height = 1280
        let (groundTruth, _) = Self.drawSymmetricUpperLowerTypesetPage(
            width: width,
            height: height,
            xHeight: 56,
            capHeight: 84,
            stemWidth: 16,
            crossbarHeight: 12,
            leftMargin: 44, // Text starts close to the dark spine crease!
            rightMargin: 90,
            linesPerHalf: 3,
            lineSpacing: 145
        )

        var pixels = ContiguousArray<UInt8>(repeating: 236, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // Steep exponential spine shadow ramp near x = 0 (88 at x = 0 -> 236 in interior)
                let spinePaper = 88.0 + 148.0 * (1.0 - exp(-Double(x) / 52.0))
                let lum = groundTruth[x, y] ? (spinePaper * 0.32) : spinePaper
                pixels[y * width + x] = UInt8(clamping: Int(lum.rounded()))
            }
        }
        let source = GrayscaleBuffer(width: width, height: height, dpi: 72, pixels: pixels)
        let accelerator = PortableComputeAccelerator()

        let singlePassConfig = BackgroundNormalizer.Configuration(enableDualPassFlattening: false)
        let dualPassConfig = BackgroundNormalizer.Configuration(enableDualPassFlattening: true)

        let singleNorm = BackgroundNormalizer(configuration: singlePassConfig).normalize(source, accelerator: accelerator)
        let dualNorm = BackgroundNormalizer(configuration: dualPassConfig).normalize(source, accelerator: accelerator)

        // Check normalized paper in the steep spine crease (`x = 6..28`, pure paper margin):
        // Single-pass wide morphological closing (R >= 70 px) bridges out to x = 80+ and overestimates spine background,
        // leaving spine paper dark (< 165); Pass 2 tracks the pure spine paper right to x = 6 (>= 242)!
        var singleSpineSum = 0
        var dualSpineSum = 0
        var spineCount = 0
        for y in stride(from: 120, to: height - 120, by: 4) {
            for x in 6..<28 {
                singleSpineSum += Int(singleNorm[x, y])
                dualSpineSum += Int(dualNorm[x, y])
                spineCount += 1
            }
        }
        let singleMeanSpinePaper = Double(singleSpineSum) / Double(spineCount)
        let dualMeanSpinePaper = Double(dualSpineSum) / Double(spineCount)

        #expect(singleMeanSpinePaper < 165.0)
        #expect(dualMeanSpinePaper >= 242.0)

        // Verify Wolf-Jolion binarization with Dual-Pass produces 0 false black gutter shadow pixels in x = 4..<32
        // while recovering >= 94% of spine-adjacent character pixels (`x = 44..<220`)!
        let dualBinary = AdaptiveBinarizer(
            configuration: .init(method: .wolfJolion, backgroundNormalization: dualPassConfig)
        ).binarize(source, accelerator: accelerator)

        var spineMarginFalsePositives = 0
        for y in 80..<(height - 80) {
            for x in 4..<32 where dualBinary[x, y] {
                spineMarginFalsePositives += 1
            }
        }

        var nearSpineHits = 0
        var nearSpineTotal = 0
        for y in 0..<height {
            for x in 44..<220 where groundTruth[x, y] {
                nearSpineTotal += 1
                if dualBinary[x, y] { nearSpineHits += 1 }
            }
        }

        #expect(spineMarginFalsePositives == 0)
        #expect(Double(nearSpineHits) / Double(max(1, nearSpineTotal)) >= 0.94)

        // Unit invariant behind the fix: Pass 2's point-reflected boundary smoothing reproduces a steep
        // linear boundary ramp exactly (including the outermost cells), whereas clamp-to-edge replication
        // drags the boundary cell toward the brighter interior and leaves a gray gutter cloud.
        let rampW = 24
        let rampH = 6
        let ramp = ContiguousArray<Float>((0..<(rampW * rampH)).map { Float(100 + 6 * ($0 % rampW)) })
        let unitWeights = ContiguousArray<Float>(repeating: 1.0, count: rampW * rampH)
        let reflected = BackgroundNormalizer.inpaintAndSmoothNormalized2D(
            values: ramp,
            weights: unitWeights,
            width: rampW,
            height: rampH,
            sigma: 4.0,
            fallbackValue: 255.0,
            boundary: .linearExtrapolate
        )
        let replicated = BackgroundNormalizer.inpaintAndSmoothNormalized2D(
            values: ramp,
            weights: unitWeights,
            width: rampW,
            height: rampH,
            sigma: 4.0,
            fallbackValue: 255.0
        )
        let maxReflectedError = zip(reflected, ramp).map { abs($0 - $1) }.max() ?? .infinity
        #expect(maxReflectedError < 0.01)
        #expect(replicated[0] > ramp[0] + 6.0)
    }

    @Test("Soft C1 noise gate protects reverse-side bleed-through and paper fiber grain during anti-starvation contrast leveling")
    func testBleedThroughAndPaperGrainAreProtectedBySoftNoiseGate() {
        let width = 880
        let height = 1040
        let (groundTruth, _) = Self.drawSymmetricUpperLowerTypesetPage(
            width: width,
            height: height,
            xHeight: 24,
            capHeight: 36,
            stemWidth: 6,
            crossbarHeight: 4,
            leftMargin: 90,
            rightMargin: 90,
            linesPerHalf: 4,
            lineSpacing: 68
        )

        // Define faint bleed-through ghost bars in the middle blank gap (`y = 435..<495`)
        // with ~5.5% ghost contrast (`paper = 214 -> bleed = 202`, normalized ~241 -> absorption = 14 <= 16 gate)
        var bleedMask = BinaryBitmap(width: width, height: height, initialBlack: false)
        for bx in stride(from: 120, to: width - 160, by: 64) {
            Self.fillRect(&bleedMask, Rect2I(x: bx, y: 445, width: 42, height: 8))
            Self.fillRect(&bleedMask, Rect2I(x: bx + 8, y: 465, width: 34, height: 8))
        }

        var pixels = ContiguousArray<UInt8>(repeating: 214, count: width * height)
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        for y in 0..<height {
            let isGlaredTop = (y < height / 2)
            let paper = isGlaredTop ? 216.0 : 208.0
            let ink = isGlaredTop ? 150.0 : 74.0 // Glared top half triggers contrast leveling gain!

            for x in 0..<width {
                rng = rng &* 6364136223846793005 &+ 1442695040888963407
                let grain = Double(Int((rng >> 58) & 0x7) - 3) // [-3, +4] paper fiber noise

                let lum: Double
                if groundTruth[x, y] {
                    lum = ink + grain * 0.5
                } else if bleedMask[x, y] {
                    lum = paper - 11.5 // Reverse-side bleed-through ghosting
                } else {
                    lum = paper + grain
                }
                pixels[y * width + x] = UInt8(clamping: Int(lum.rounded()))
            }
        }

        let source = GrayscaleBuffer(width: width, height: height, dpi: 300, pixels: pixels)
        let accelerator = PortableComputeAccelerator()
        let bgConfig = BackgroundNormalizer.Configuration()

        let normResult = BackgroundNormalizer(configuration: bgConfig).normalizeWithTelemetry(source, accelerator: accelerator)
        #expect(normResult.parameters.contrastLevelingApplied == true)
        #expect(normResult.parameters.peakContrastGain > 1.30)

        let binary = AdaptiveBinarizer(
            configuration: .init(method: .wolfJolion, backgroundNormalization: bgConfig)
        ).binarize(source, accelerator: accelerator)

        var bleedFalsePositives = 0
        var marginFalsePositives = 0
        var glaredTextHits = 0
        var glaredTextTotal = 0

        for y in 0..<height {
            for x in 0..<width {
                if bleedMask[x, y] && binary[x, y] {
                    bleedFalsePositives += 1
                }
                if (y < 45 || y >= height - 45) && binary[x, y] {
                    marginFalsePositives += 1
                }
                if y < height / 2 && groundTruth[x, y] {
                    glaredTextTotal += 1
                    if binary[x, y] { glaredTextHits += 1 }
                }
            }
        }

        #expect(bleedFalsePositives == 0)
        #expect(marginFalsePositives == 0)
        #expect(Double(glaredTextHits) / Double(max(1, glaredTextTotal)) >= 0.95)
    }

    @Test("Codable backward compatibility, blend strength edge cases, and BookPipelineCoordinator Pass 1 uniformity")
    func testCodableBackwardCompatibilityEdgeCasesAndBookPipelineUniformity() async throws {
        // 1. Configuration & DerivedKernelParameters Codable round-trip + legacy JSON decoding
        let config = BackgroundNormalizer.Configuration(
            downsampleFactor: 4,
            referenceClosingRadiusAt300DPI: 26,
            downsampledBlurSigma: 3.2,
            minimumBackgroundDivisor: 36,
            strength: 0.85,
            enableGlyphScaleAdaptation: true,
            closingRadiusXHeightMultiplier: 1.30,
            closingRadiusStrokeWidthMultiplier: 6.50,
            minimumGlyphConfidence: 0.40,
            enableDualPassFlattening: true,
            secondPassBlurSigmaScale: 0.70,
            enableAntiStarvationContrastLeveling: true,
            maximumContrastGain: 1.95
        )
        let encodedCfg = try JSONEncoder().encode(config)
        let decodedCfg = try JSONDecoder().decode(BackgroundNormalizer.Configuration.self, from: encodedCfg)
        #expect(decodedCfg == config)

        let legacyCfgJSON = Data(#"{"downsampleFactor":4,"referenceClosingRadiusAt300DPI":24,"downsampledBlurSigma":3.0,"minimumBackgroundDivisor":32,"strength":1.0}"#.utf8)
        let legacyCfg = try JSONDecoder().decode(BackgroundNormalizer.Configuration.self, from: legacyCfgJSON)
        #expect(legacyCfg.enableDualPassFlattening == true)
        #expect(abs(legacyCfg.secondPassBlurSigmaScale - 0.65) < 1e-9)
        #expect(legacyCfg.enableAntiStarvationContrastLeveling == true)
        #expect(abs(legacyCfg.maximumContrastGain - 2.50) < 1e-9)

        let legacyParamsJSON = Data(#"{"fullResolutionClosingRadius":25,"fullResolutionBlurSigma":12.5,"effectiveDownsampleFactor":4,"downsampledClosingRadius":7,"downsampledErosionRadius":6,"downsampledBlurSigma":3.125,"usedGlyphScale":true}"#.utf8)
        let legacyParams = try JSONDecoder().decode(BackgroundNormalizer.DerivedKernelParameters.self, from: legacyParamsJSON)
        #expect(legacyParams.dualPassApplied == false)
        #expect(legacyParams.secondPassDownsampledBlurSigma == 0.0)
        #expect(legacyParams.contrastLevelingApplied == false)
        #expect(legacyParams.peakContrastGain == 1.0)

        // 2. Strength = 0.0 passthrough & uniform dark/white sheets
        let accelerator = PortableComputeAccelerator()
        let zeroStrength = BackgroundNormalizer(configuration: .init(strength: 0.0))
        let rampBuf = GrayscaleBuffer(
            width: 80,
            height: 80,
            dpi: 300,
            pixels: ContiguousArray((0..<(80 * 80)).map { UInt8(80 + ($0 % 120)) })
        )
        let passthrough = zeroStrength.normalizeWithTelemetry(rampBuf, accelerator: accelerator)
        #expect(passthrough.buffer.pixels == rampBuf.pixels)

        let darkSheet = GrayscaleBuffer(width: 120, height: 120, dpi: 300, initialValue: 20)
        let darkBinary = AdaptiveBinarizer().binarize(darkSheet, accelerator: accelerator)
        #expect(darkBinary.countBlackPixels() == 120 * 120)

        // 3. End-to-end BookPipelineCoordinator Pass 1 verification on a Simpson-like shaded + glared page
        let pW = 960
        let pH = 1280
        let (gt, _) = Self.drawSymmetricUpperLowerTypesetPage(
            width: pW,
            height: pH,
            xHeight: 24,
            capHeight: 36,
            stemWidth: 6,
            crossbarHeight: 4,
            leftMargin: 96,
            rightMargin: 96,
            linesPerHalf: 5,
            lineSpacing: 68
        )
        var pagePixels = ContiguousArray<UInt8>(repeating: 214, count: pW * pH)
        for y in 0..<pH {
            // Simpson 1968 Page 2 contrast asymmetry: top paper=214/ink=91, bottom paper=192/ink=128 + spine ramp
            let isTop = y < pH / 2
            let baseP = isTop ? 214.0 : 192.0
            let baseI = isTop ? 91.0 : 128.0
            for x in 0..<pW {
                let hFactor = 0.72 + 0.28 * (Double(x) / Double(pW - 1))
                let lum = (gt[x, y] ? baseI : baseP) * hFactor
                pagePixels[y * pW + x] = UInt8(clamping: Int(lum.rounded()))
            }
        }
        let rawPage = GrayscaleBuffer(width: pW, height: pH, dpi: 300, pixels: pagePixels)

        struct NullPDFWriter: PDFDocumentWriter, ~Copyable {
            mutating func appendPage(
                bitmap: borrowing BinaryBitmap,
                dpi: Int,
                pageBoxPoints: Rect2D,
                ocrLayer: [RecognizedTextObservation]
            ) throws(PDFWriteError) {}
            consuming func finalize() throws(PDFWriteError) {}
        }

        let coordinator = BookPipelineCoordinator(
            configuration: .init(
                processingDPI: 300,
                outputDPI: 150,
                splitMode: .singlePage,
                enableDewarp: false,
                enableAutomaticFontScaleCalibration: false
            )
        )
        let output = try await coordinator.processGrayscalePages(
            [rawPage],
            writer: NullPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )
        #expect(output.cleanedBitmapsAtProcessingDPI.count == 1)
        let cleaned = output.cleanedBitmapsAtProcessingDPI[0]

        var topHits = 0, topTotal = 0
        var botHits = 0, botTotal = 0
        for y in 0..<pH {
            for x in 0..<pW where gt[x, y] {
                if y < pH / 2 {
                    topTotal += 1
                    if cleaned[x, y] { topHits += 1 }
                } else {
                    botTotal += 1
                    if cleaned[x, y] { botHits += 1 }
                }
            }
        }
        let topRecall = Double(topHits) / Double(max(1, topTotal))
        let botRecall = Double(botHits) / Double(max(1, botTotal))
        #expect(topRecall >= 0.95)
        #expect(botRecall >= 0.95)
        #expect(abs(topRecall - botRecall) <= 0.03)
    }
}
