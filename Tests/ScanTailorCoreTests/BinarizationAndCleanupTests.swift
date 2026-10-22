import ScanTailorContracts
import ScanTailorCore
import ScanTailorPortableBackend
import Testing

@Suite("Background Normalization, Adaptive Binarization & Cleanup Tests")
struct BinarizationAndCleanupTests {
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

    @Test("BackgroundNormalizer flattens uneven illumination gradient while preserving dark text strokes")
    func backgroundNormalizationFlattensGradientAndPreservesText() {
        let width = 320
        let height = 240
        var source = GrayscaleBuffer(width: width, height: height, dpi: 300, initialValue: 240)

        // Apply a severe horizontal illumination gradient (dark gutter shadow on the left at ~95, bright on the right at ~240)
        // plus a vertical falloff near the top/bottom edges.
        for y in 0..<height {
            let vFactor = 1.0 - 0.15 * abs(Double(y) - Double(height) * 0.5) / (Double(height) * 0.5)
            for x in 0..<width {
                let hFactor = 0.40 + 0.60 * (Double(x) / Double(width - 1))
                let bg = Int((240.0 * hFactor * vFactor).rounded())
                source[x, y] = UInt8(clamping: bg)
            }
        }

        // Paint synthetic dark text strokes in both the shaded gutter region and the bright region
        let strokeRects = [
            Rect2I(x: 36, y: 70, width: 40, height: 4),
            Rect2I(x: 36, y: 84, width: 32, height: 4),
            Rect2I(x: 200, y: 70, width: 50, height: 4),
            Rect2I(x: 200, y: 84, width: 44, height: 4)
        ]
        for rect in strokeRects {
            for y in rect.minY..<rect.maxY {
                for x in rect.minX..<rect.maxX {
                    // Ink is roughly 25% of the local paper brightness
                    source[x, y] = UInt8(clamping: Int(Double(source[x, y]) * 0.25))
                }
            }
        }

        let accelerator = PortableComputeAccelerator()
        let normalizer = BackgroundNormalizer()
        let normalized = normalizer.normalize(source, accelerator: accelerator)

        // Paper background in both shaded left region (x=25, y=150) and bright right region (x=280, y=150)
        // should be normalized close to white (>= 230).
        let leftPaper = Int(normalized[25, 150])
        let rightPaper = Int(normalized[280, 150])
        #expect(leftPaper >= 230)
        #expect(rightPaper >= 235)
        #expect(abs(leftPaper - rightPaper) <= 20)

        // Ink strokes in both shaded and bright regions should remain distinctly dark (< 110).
        let shadedStrokeCenter = Int(normalized[50, 72])
        let brightStrokeCenter = Int(normalized[220, 72])
        #expect(shadedStrokeCenter < 110)
        #expect(brightStrokeCenter < 110)
    }

    @Test("AdaptiveBinarizer recovers crisp text across gutter shadows under both Wolf-Jolion and Sauvola")
    func adaptiveBinarizerRecoversTextUnderWolfJolionAndSauvola() {
        let width = 320
        let height = 220
        var source = GrayscaleBuffer(width: width, height: height, dpi: 300, initialValue: 235)

        // Simulate gutter shadow on left side
        for y in 0..<height {
            for x in 0..<width {
                let t = Double(x) / Double(width - 1)
                let bg = 85.0 + 155.0 * t
                source[x, y] = UInt8(clamping: Int(bg.rounded()))
            }
        }

        // Ground-truth foreground mask of synthetic text blocks & strokes
        var groundTruth = BinaryBitmap(width: width, height: height)
        for row in 0..<4 {
            let y0 = 40 + row * 36
            for col in 0..<6 {
                let x0 = 28 + col * 44
                // Horizontal stem
                Self.fillRect(&groundTruth, Rect2I(x: x0, y: y0, width: 26, height: 4))
                // Vertical stem
                Self.fillRect(&groundTruth, Rect2I(x: x0 + 4, y: y0 - 6, width: 4, height: 16))
            }
        }

        for y in 0..<height {
            for x in 0..<width where groundTruth[x, y] {
                source[x, y] = UInt8(clamping: Int(Double(source[x, y]) * 0.28))
            }
        }

        let accelerator = PortableComputeAccelerator()

        for method in [AdaptiveBinarizer.Method.wolfJolion, AdaptiveBinarizer.Method.sauvola] {
            let config = AdaptiveBinarizer.Configuration(
                method: method,
                referenceWindowRadiusAt300DPI: 24,
                k: 0.28,
                minimumContrastDelta: 6.0,
                backgroundNormalization: BackgroundNormalizer.Configuration()
            )
            let binarizer = AdaptiveBinarizer(configuration: config)
            let binary = binarizer.binarize(source, accelerator: accelerator)

            var truePositives = 0
            var groundTruthPositives = 0
            var falsePositivesInMargin = 0

            for y in 0..<height {
                for x in 0..<width {
                    if groundTruth[x, y] {
                        groundTruthPositives += 1
                        if binary[x, y] {
                            truePositives += 1
                        }
                    } else if y < 20 || y >= height - 20 {
                        // Shaded empty top/bottom margins should not hallucinate black clouds
                        if binary[x, y] {
                            falsePositivesInMargin += 1
                        }
                    }
                }
            }

            let recall = Double(truePositives) / Double(max(1, groundTruthPositives))
            #expect(recall >= 0.90)
            #expect(falsePositivesInMargin == 0)
        }
    }

    @Test("BorderAndSpeckleCleaner removes scan borders and isolated speckles while preserving diacritics")
    func borderAndSpeckleCleanerPreservesDiacritics() {
        let width = 300
        let height = 260
        var bitmap = BinaryBitmap(width: width, height: height)

        // 1. Dark scan border along the left edge (touches x=0, spans full height, 10px thick)
        Self.fillRect(&bitmap, Rect2I(x: 0, y: 0, width: 10, height: height))

        // 2. Dark scan border wedge along the top edge (touches y=0, spans 180px width, 8px thick)
        Self.fillRect(&bitmap, Rect2I(x: 30, y: 0, width: 180, height: 8))

        // 3. Main text character stems (pixelCount > maxSpecklePixels = 24)
        let stemRect = Rect2I(x: 110, y: 110, width: 5, height: 14) // 70 pixels
        let wordRect = Rect2I(x: 122, y: 110, width: 18, height: 6) // 108 pixels
        Self.fillRect(&bitmap, stemRect)
        Self.fillRect(&bitmap, wordRect)

        // 4. Diacritic ('i'-dot) directly above `stemRect` within diacriticProtectionRadius (20px)
        // Size: 3x3 = 9 pixels (>= minDiacriticPixels=2 and <= maxSpecklePixels=24)
        let iDotRect = Rect2I(x: 111, y: 101, width: 3, height: 3)
        Self.fillRect(&bitmap, iDotRect)

        // 5. Period punctuation right next to `wordRect` within diacriticProtectionRadius
        // Size: 2x2 = 4 pixels
        let periodRect = Rect2I(x: 144, y: 114, width: 2, height: 2)
        Self.fillRect(&bitmap, periodRect)

        // 6. Isolated dust speckle far from any text body (size: 3x3 = 9 pixels)
        let isolatedSpeckleRect = Rect2I(x: 240, y: 200, width: 3, height: 3)
        Self.fillRect(&bitmap, isolatedSpeckleRect)

        // 7. Single-pixel thermal noise spike near the text stem (1 pixel < minDiacriticPixels = 2)
        bitmap[105, 112] = true

        let cleaner = BorderAndSpeckleCleaner(
            configuration: .init(
                removeBorders: true,
                borderProximityMargin: 12,
                maxBorderStripThicknessRatio: 0.14,
                minBorderSpanRatio: 0.20,
                minBorderEdgePixelThreshold: 20,
                despeckle: true,
                maxSpecklePixels: 24,
                minDiacriticPixels: 2,
                diacriticProtectionRadius: 20
            )
        )

        let cleaned = cleaner.clean(bitmap)

        // Left and top scan borders must be removed
        #expect(!cleaned[2, 120])
        #expect(!cleaned[100, 3])

        // Main text bodies must remain intact
        #expect(cleaned[112, 115])
        #expect(cleaned[130, 112])

        // Diacritic ('i'-dot) and period near text bodies must be preserved
        #expect(cleaned[112, 102])
        #expect(cleaned[144, 114])

        // Far isolated speckle must be removed
        #expect(!cleaned[241, 201])

        // 1-pixel spike near text must be removed despite proximity
        #expect(!cleaned[105, 112])
    }
}
