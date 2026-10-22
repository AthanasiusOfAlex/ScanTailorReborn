import Testing
import ScanTailorContracts
@testable import ScanTailorCore

@Suite("Binary Morphology, SeedFill & Connected Components Tests")
struct MorphologyTests {

    // MARK: - Naive Reference Implementations for Bit-Exact Verification

    private func naiveDilate(
        _ bitmap: BinaryBitmap,
        brickWidth: Int,
        brickHeight: Int
    ) -> BinaryBitmap {
        let left = (brickWidth - 1) / 2
        let right = brickWidth - 1 - left
        let top = (brickHeight - 1) / 2
        let bottom = brickHeight - 1 - top

        var out = BinaryBitmap(width: bitmap.width, height: bitmap.height, initialBlack: false)
        for y in 0..<bitmap.height {
            let minY = max(0, y - top)
            let maxY = min(bitmap.height - 1, y + bottom)
            for x in 0..<bitmap.width {
                let minX = max(0, x - left)
                let maxX = min(bitmap.width - 1, x + right)
                var found = false
                outer: for sy in minY...maxY {
                    for sx in minX...maxX {
                        if bitmap[sx, sy] {
                            found = true
                            break outer
                        }
                    }
                }
                out[x, y] = found
            }
        }
        return out
    }

    private func naiveErode(
        _ bitmap: BinaryBitmap,
        brickWidth: Int,
        brickHeight: Int,
        borderFillBlack: Bool
    ) -> BinaryBitmap {
        let left = (brickWidth - 1) / 2
        let right = brickWidth - 1 - left
        let top = (brickHeight - 1) / 2
        let bottom = brickHeight - 1 - top

        // Adjoint erosion window: [x - right, x + left] x [y - bottom, y + top]
        var out = BinaryBitmap(width: bitmap.width, height: bitmap.height, initialBlack: false)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                var allBlack = true
                outer: for sy in (y - bottom)...(y + top) {
                    for sx in (x - right)...(x + left) {
                        let isBlack: Bool
                        if sx < 0 || sx >= bitmap.width || sy < 0 || sy >= bitmap.height {
                            isBlack = borderFillBlack
                        } else {
                            isBlack = bitmap[sx, sy]
                        }
                        if !isBlack {
                            allBlack = false
                            break outer
                        }
                    }
                }
                out[x, y] = allBlack
            }
        }
        return out
    }

    // MARK: - Dilation & Erosion Tests

    @Test("Word-parallel dilation and erosion match naive reference across odd, even, and multi-word bricks")
    func dilationAndErosionMatchNaiveReference() {
        var bitmap = BinaryBitmap(width: 137, height: 83, initialBlack: false)

        // Populate patterns including across 64-bit word boundaries (x = 63..64, 127..128) and edges
        bitmap[0, 0] = true
        bitmap[136, 0] = true
        bitmap[0, 82] = true
        bitmap[136, 82] = true
        bitmap[63, 40] = true
        bitmap[64, 40] = true
        bitmap[127, 20] = true
        bitmap[128, 20] = true

        // Solid rectangle straddling word boundary
        for y in 10..<25 {
            for x in 55..<75 {
                bitmap[x, y] = true
            }
        }

        // Border block
        for y in 0..<8 {
            for x in 0..<10 {
                bitmap[x, y] = true
            }
        }

        let brickSizes: [(Int, Int)] = [
            (1, 1),
            (3, 3),
            (2, 4),
            (5, 2),
            (15, 1),
            (1, 19),
            (73, 9) // Spans more than a full 64-bit word horizontally
        ]

        for (bw, bh) in brickSizes {
            let fastDilated = BinaryMorphology.dilateBrick(bitmap, width: bw, height: bh)
            let refDilated = naiveDilate(bitmap, brickWidth: bw, brickHeight: bh)
            #expect(fastDilated == refDilated, "Dilation mismatch for brick \(bw)x\(bh)")

            let fastErodedBlackBorder = BinaryMorphology.erodeBrick(
                bitmap,
                width: bw,
                height: bh,
                borderFillBlack: true
            )
            let refErodedBlackBorder = naiveErode(
                bitmap,
                brickWidth: bw,
                brickHeight: bh,
                borderFillBlack: true
            )
            #expect(
                fastErodedBlackBorder == refErodedBlackBorder,
                "Erosion (borderFillBlack: true) mismatch for brick \(bw)x\(bh)"
            )

            let fastErodedWhiteBorder = BinaryMorphology.erodeBrick(
                bitmap,
                width: bw,
                height: bh,
                borderFillBlack: false
            )
            let refErodedWhiteBorder = naiveErode(
                bitmap,
                brickWidth: bw,
                brickHeight: bh,
                borderFillBlack: false
            )
            #expect(
                fastErodedWhiteBorder == refErodedWhiteBorder,
                "Erosion (borderFillBlack: false) mismatch for brick \(bw)x\(bh)"
            )
        }
    }

    @Test("Opening and closing are idempotent and preserve single-pixel position under adjointeven/odd bricks")
    func openingAndClosingProperties() {
        var single = BinaryBitmap(width: 90, height: 60, initialBlack: false)
        single[45, 30] = true

        // Dilate then erode a single pixel with both odd (7x5) and even (6x4) bricks
        for (bw, bh) in [(7, 5), (6, 4), (12, 8)] {
            let closed = BinaryMorphology.closeBrick(single, width: bw, height: bh)
            #expect(closed == single, "Closing single pixel with \(bw)x\(bh) should return exact pixel")
        }

        // Opening removes small noise while preserving large block and is idempotent
        var noisy = BinaryBitmap(width: 100, height: 60, initialBlack: false)
        for y in 20..<40 {
            for x in 30..<70 {
                noisy[x, y] = true
            }
        }
        // Add 2x2 speckle
        noisy[10, 10] = true
        noisy[11, 10] = true
        noisy[10, 11] = true
        noisy[11, 11] = true

        let openedOnce = BinaryMorphology.openBrick(noisy, width: 5, height: 5)
        let openedTwice = BinaryMorphology.openBrick(openedOnce, width: 5, height: 5)
        #expect(openedOnce == openedTwice)
        #expect(!openedOnce[10, 10])
        #expect(openedOnce[50, 30])
        #expect(openedOnce.countBlackPixels() == 40 * 20)
    }

    // MARK: - SeedFill Tests

    @Test("SeedFill reconstructs 4-connected and 8-connected components across 64-bit word boundaries")
    func seedFillConnectivityAndWordBoundaries() {
        var mask = BinaryBitmap(width: 140, height: 40, initialBlack: false)
        // Diagonal staircase crossing word boundary at x = 63 -> 64
        mask[62, 10] = true
        mask[63, 11] = true
        mask[64, 12] = true
        mask[65, 13] = true
        // Connected horizontal segment from x = 65..130 on y = 13
        for x in 65...130 {
            mask[x, 13] = true
        }
        // Disconnected island
        mask[20, 20] = true
        mask[21, 20] = true

        var seed = BinaryBitmap(width: 140, height: 40, initialBlack: false)
        seed[62, 10] = true

        // Under 4-connectivity, diagonal step from (62, 10) to (63, 11) is not traversed
        let fill4 = SeedFill.reconstruct(seed: seed, mask: mask, connectivity: .four)
        #expect(fill4.countBlackPixels() == 1)
        #expect(fill4[62, 10])

        // Under 8-connectivity, the entire diagonal + horizontal chain is reconstructed, excluding island
        let fill8 = SeedFill.reconstruct(seed: seed, mask: mask, connectivity: .eight)
        #expect(fill8.countBlackPixels() == 3 + (130 - 65 + 1))
        #expect(fill8[130, 13])
        #expect(!fill8[20, 20])
    }

    @Test("SeedFill removes border-connected shadows and fills interior holes")
    func borderRemovalAndHoleFilling() {
        var page = BinaryBitmap(width: 100, height: 80, initialBlack: false)

        // Dark photocopier border along top and left + thumb shadow on right edge
        for x in 0..<100 { page[x, 0] = true }
        for y in 0..<80 { page[0, y] = true }
        for y in 30..<50 {
            for x in 90..<100 {
                page[x, y] = true
            }
        }

        // Interior hollow ring (20..40 x 20..40 with hollow 25..35 x 25..35)
        for y in 20..<40 {
            for x in 20..<40 {
                let isHole = (x >= 25 && x < 35 && y >= 25 && y < 35)
                if !isHole {
                    page[x, y] = true
                }
            }
        }

        let borderCleaned = SeedFill.removeBorderConnected(from: page, connectivity: .eight)
        // Border and thumb shadow should be completely gone
        #expect(!borderCleaned[0, 0])
        #expect(!borderCleaned[95, 40])
        // Hollow ring should remain intact (400 - 100 = 300 pixels)
        #expect(borderCleaned.countBlackPixels() == 300)

        // Filling holes on borderCleaned should fill the 10x10 interior hole (total 400 pixels)
        let holesFilled = SeedFill.fillHoles(in: borderCleaned, connectivity: .four)
        #expect(holesFilled.countBlackPixels() == 400)
        #expect(holesFilled[30, 30])
    }

    // MARK: - Connected Component Tests

    @Test("ConnectedComponentAnalyzer extracts components, masks, and despeckles noise")
    func connectedComponentsAndDespeckle() {
        var bitmap = BinaryBitmap(width: 150, height: 70, initialBlack: false)

        // Component 1: 10x5 solid block straddling x = 60..<70, y = 10..<15 (50 pixels)
        for y in 10..<15 {
            for x in 60..<70 {
                bitmap[x, y] = true
            }
        }

        // Component 2: L-shape at x = 100..<110, y = 30..<40 (19 pixels)
        for x in 100..<110 { bitmap[x, 30] = true }
        for y in 31..<40 { bitmap[100, y] = true }

        // Speckles of size 1, 2, 3
        bitmap[5, 5] = true
        bitmap[15, 5] = true
        bitmap[16, 5] = true
        bitmap[25, 5] = true
        bitmap[26, 5] = true
        bitmap[25, 6] = true

        let allComponents = ConnectedComponentAnalyzer.extractComponents(from: bitmap, connectivity: .eight)
        #expect(allComponents.count == 5)

        let withMasks = ConnectedComponentAnalyzer.extractComponentsWithMasks(from: bitmap, connectivity: .eight)
        #expect(withMasks.count == 5)
        for item in withMasks {
            #expect(item.mask.width == item.component.boundingBox.width)
            #expect(item.mask.height == item.component.boundingBox.height)
            #expect(item.mask.countBlackPixels() == item.component.pixelCount)
        }

        let despeckled = ConnectedComponentAnalyzer.despeckle(bitmap, maxSpecklePixels: 3)
        let remaining = ConnectedComponentAnalyzer.extractComponents(from: despeckled, connectivity: .eight)
        #expect(remaining.count == 2)
        #expect(remaining[0].pixelCount == 50)
        #expect(remaining[0].boundingBox == Rect2I(minX: 60, minY: 10, maxX: 70, maxY: 15))
        #expect(remaining[1].pixelCount == 19)
        #expect(remaining[1].boundingBox == Rect2I(minX: 100, minY: 30, maxX: 110, maxY: 40))
    }

    // MARK: - BinaryDownsampler Tests

    @Test("Word-parallel 2x2 binary downsampler matches exact block counting across all thresholds")
    func binaryDownsamplerMatchesReference() {
        var bitmap = BinaryBitmap(width: 145, height: 67, initialBlack: false)
        // Deterministic pseudo-random pattern with varying 2x2 block densities (0, 1, 2, 3, 4)
        for by in 0..<(bitmap.height / 2) {
            for bx in 0..<(bitmap.width / 2) {
                let density = (bx * 7 + by * 13) % 5 // 0..4 black subpixels
                if density >= 1 { bitmap[bx * 2, by * 2] = true }
                if density >= 2 { bitmap[bx * 2 + 1, by * 2] = true }
                if density >= 3 { bitmap[bx * 2, by * 2 + 1] = true }
                if density >= 4 { bitmap[bx * 2 + 1, by * 2 + 1] = true }
            }
        }

        for threshold in 1...4 {
            let downsampled = BinaryDownsampler.downsample2x(bitmap, minBlackSubpixels: threshold)
            #expect(downsampled.width == 72)
            #expect(downsampled.height == 33)

            for by in 0..<downsampled.height {
                for bx in 0..<downsampled.width {
                    let expectedDensity = (bx * 7 + by * 13) % 5
                    let expectedBlack = expectedDensity >= threshold
                    #expect(
                        downsampled[bx, by] == expectedBlack,
                        "Mismatch at (\(bx), \(by)) for threshold \(threshold)"
                    )
                }
            }
        }
    }
}
