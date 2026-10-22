import Testing
@testable import ScanTailorContracts
import Foundation

@Suite("BinaryBitmap and IntegralBuffer Tests")
struct BinaryBitmapTests {

    @Test("BinaryBitmap wordsPerRow and trailing bit masking")
    func testWordPackingAndTrailingMask() {
        // Test edge widths
        let widths = [1, 63, 64, 65, 127, 128, 129]
        for w in widths {
            let expectedWords = (w + 63) / 64
            let bmWhite = BinaryBitmap(width: w, height: 10, initialBlack: false)
            #expect(bmWhite.wordsPerRow == expectedWords)
            #expect(bmWhite.countBlackPixels() == 0)
            #expect(bmWhite.isEmpty)

            let bmBlack = BinaryBitmap(width: w, height: 10, initialBlack: true)
            #expect(bmBlack.wordsPerRow == expectedWords)
            #expect(bmBlack.countBlackPixels() == w * 10)
            #expect(!bmBlack.isEmpty)

            // Test trailing bit mask: after inverting white, trailing bits MUST remain 0!
            let inverted = bmWhite.inverted()
            #expect(inverted.countBlackPixels() == w * 10)

            // Double inversion should match original
            let roundtrip = inverted.inverted()
            #expect(roundtrip.countBlackPixels() == 0)
        }
    }

    @Test("BinaryBitmap pixel get and set across 64-bit word boundaries")
    func testPixelAccessAcrossWordBoundaries() {
        var bm = BinaryBitmap(width: 130, height: 5, initialBlack: false)

        let testCoords = [
            (0, 0),
            (63, 0),
            (64, 0),
            (65, 0),
            (127, 0),
            (128, 0),
            (129, 0),
            (0, 4),
            (129, 4)
        ]

        for (x, y) in testCoords {
            #expect(!bm[x, y])
            bm[x, y] = true
            #expect(bm[x, y])
            #expect(bm.isBlack(x: x, y: y) == true)
        }

        #expect(bm.countBlackPixels() == testCoords.count)

        for (x, y) in testCoords {
            bm[x, y] = false
            #expect(!bm[x, y])
        }

        #expect(bm.isEmpty)
    }

    @Test("BinaryBitmap bitwise boolean operations")
    func testBitwiseOperations() {
        var bm1 = BinaryBitmap(width: 100, height: 10, initialBlack: false)
        var bm2 = BinaryBitmap(width: 100, height: 10, initialBlack: false)

        // Set left half black in bm1
        for y in 0..<10 {
            for x in 0..<50 {
                bm1[x, y] = true
            }
        }

        // Set middle half black in bm2
        for y in 0..<10 {
            for x in 25..<75 {
                bm2[x, y] = true
            }
        }

        let andResult = bm1.bitwiseAnd(bm2)
        // Overlap is x in [25, 50) -> width 25 * height 10 = 250
        #expect(andResult.countBlackPixels() == 250)

        let orResult = bm1.bitwiseOr(bm2)
        // Union is x in [0, 75) -> width 75 * height 10 = 750
        #expect(orResult.countBlackPixels() == 750)

        let xorResult = bm1.bitwiseXor(bm2)
        // XOR is [0, 25) U [50, 75) -> 25 + 25 = 50 * 10 = 500
        #expect(xorResult.countBlackPixels() == 500)

        let subResult = bm1.subtracting(bm2)
        // bm1 - bm2 is [0, 25) -> 25 * 10 = 250
        #expect(subResult.countBlackPixels() == 250)
    }

    @Test("BinaryBitmap contentBoundingBox computation")
    func testContentBoundingBox() {
        var bm = BinaryBitmap(width: 200, height: 200, initialBlack: false)
        #expect(bm.contentBoundingBox() == nil)

        // Draw a rectangle from x=37 to x=153, y=20 to y=85
        for y in 20..<85 {
            for x in 37..<153 {
                bm[x, y] = true
            }
        }

        let bbox = bm.contentBoundingBox()
        #expect(bbox != nil)
        #expect(bbox == Rect2I(minX: 37, minY: 20, maxX: 153, maxY: 85))
    }

    @Test("BinaryBitmap non-word-aligned ROI cropping")
    func testUnalignedCrop() {
        var bm = BinaryBitmap(width: 256, height: 50, initialBlack: false)
        // Set a checkerboard or recognizable strip
        for y in 10..<30 {
            for x in 25..<105 { // width = 80, unaligned x start (25 % 64 != 0)
                bm[x, y] = true
            }
        }

        let cropRect = Rect2I(x: 25, y: 10, width: 80, height: 20)
        let cropped = bm.cropped(to: cropRect)

        #expect(cropped.width == 80)
        #expect(cropped.height == 20)
        #expect(cropped.countBlackPixels() == 80 * 20)

        // All cropped pixels should be black
        for y in 0..<20 {
            for x in 0..<80 {
                #expect(cropped[x, y])
            }
        }
    }

    @Test("BinaryBitmap blit replace and or")
    func testBlit() {
        var canvas = BinaryBitmap(width: 100, height: 100, initialBlack: false)
        let stamp = BinaryBitmap(width: 20, height: 20, initialBlack: true)

        canvas.blit(from: stamp, at: Point2I(x: 10, y: 10), blendMode: .replace)
        #expect(canvas.countBlackPixels() == 400)
        #expect(canvas.contentBoundingBox() == Rect2I(minX: 10, minY: 10, maxX: 30, maxY: 30))

        // Blit partially off-screen at bottom-right
        canvas.blit(from: stamp, at: Point2I(x: 90, y: 90), blendMode: .or)
        // Overlap is [90, 100) x [90, 100) = 10 x 10 = 100 pixels
        #expect(canvas.countBlackPixels() == 400 + 100)
    }

    @Test("IntegralBuffer window sum and variance")
    func testIntegralBuffer() {
        // Create 4x4 image
        // [ 1, 2, 3, 4 ]
        // [ 5, 6, 7, 8 ]
        // [ 9, 1, 2, 3 ]
        // [ 4, 5, 6, 7 ]
        let width = 4
        let height = 4
        let stride = width + 1

        var sumTable = ContiguousArray<UInt64>(repeating: 0, count: stride * (height + 1))
        var sumSqTable = ContiguousArray<UInt64>(repeating: 0, count: stride * (height + 1))

        let pixels: [UInt8] = [
            1, 2, 3, 4,
            5, 6, 7, 8,
            9, 1, 2, 3,
            4, 5, 6, 7
        ]

        // Build integral tables
        for y in 0..<height {
            var rowSum: UInt64 = 0
            var rowSumSq: UInt64 = 0
            for x in 0..<width {
                let val = UInt64(pixels[y * width + x])
                rowSum += val
                rowSumSq += val * val

                let idx = (y + 1) * stride + (x + 1)
                let aboveIdx = y * stride + (x + 1)
                sumTable[idx] = sumTable[aboveIdx] + rowSum
                sumSqTable[idx] = sumSqTable[aboveIdx] + rowSumSq
            }
        }

        let integral = IntegralBuffer(
            width: width,
            height: height,
            sumTable: sumTable,
            sumSqTable: sumSqTable
        )

        // Whole image sum
        let totalSum = integral.sum(in: Rect2I(x: 0, y: 0, width: 4, height: 4))
        let expectedTotal: UInt64 = pixels.reduce(0) { $0 + UInt64($1) }
        #expect(totalSum == expectedTotal)

        // Sub-window [1, 3) x [1, 3)
        // [ 6, 7 ]
        // [ 1, 2 ]
        // Sum = 16
        let subSum = integral.sum(in: Rect2I(minX: 1, minY: 1, maxX: 3, maxY: 3))
        #expect(subSum == 6 + 7 + 1 + 2)

        let stats = integral.windowStatistics(in: Rect2I(minX: 1, minY: 1, maxX: 3, maxY: 3))
        #expect(stats.mean == 4.0)
    }
}
