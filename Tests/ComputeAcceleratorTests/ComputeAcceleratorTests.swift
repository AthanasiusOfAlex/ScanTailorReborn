import Foundation
import Testing
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPortableBackend
import ScanTailorAppleBackend

@Suite("ComputeAccelerator Backend Equivalence & Benchmark Tests")
struct ComputeAcceleratorTests {

    private let portable = PortableComputeAccelerator()
    private let apple = MetalComputeAccelerator(minimumPixelsForGPU: 0)

    private func makeTestGrayscale(width: Int = 180, height: Int = 130) -> GrayscaleBuffer {
        var pixels = ContiguousArray<UInt8>(repeating: 255, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                // Smooth gradient + high-frequency synthetic text-like bars
                let grad = (x * 190 / max(1, width)) + (y * 50 / max(1, height))
                let bar = ((x / 7 + y / 11) % 3 == 0) ? 30 : 220
                pixels[y * width + x] = UInt8(clamping: (grad + bar) / 2)
            }
        }
        return GrayscaleBuffer(width: width, height: height, dpi: 600, pixels: pixels)
    }

    private func assertBuffersEquivalent(
        _ a: GrayscaleBuffer,
        _ b: GrayscaleBuffer,
        maxPixelDiff: Int = 1,
        context: String
    ) {
        #expect(a.width == b.width, "\(context): width mismatch")
        #expect(a.height == b.height, "\(context): height mismatch")
        #expect(a.dpi == b.dpi, "\(context): dpi mismatch")

        var worstDiff = 0
        for i in 0..<a.pixels.count {
            let diff = abs(Int(a.pixels[i]) - Int(b.pixels[i]))
            if diff > worstDiff {
                worstDiff = diff
            }
        }
        #expect(
            worstDiff <= maxPixelDiff,
            "\(context): max pixel difference \(worstDiff) exceeded tolerance \(maxPixelDiff)"
        )
    }

    @Test("Integral image matches bit-for-bit between Apple Metal and Portable backends")
    func integralImageEquivalence() {
        let buffer = makeTestGrayscale(width: 193, height: 127)

        let portableIntegral = portable.integralImage(of: buffer)
        let appleIntegral = apple.integralImage(of: buffer)

        #expect(appleIntegral == portableIntegral)

        // Verify window sum and sum-of-squares against direct pixel summation
        let roi = Rect2I(minX: 17, minY: 23, maxX: 142, maxY: 98)
        var expectedSum: UInt64 = 0
        var expectedSq: UInt64 = 0
        for y in roi.minY..<roi.maxY {
            for x in roi.minX..<roi.maxX {
                let v = UInt64(buffer[x, y])
                expectedSum += v
                expectedSq += v * v
            }
        }

        #expect(appleIntegral.sum(in: roi) == expectedSum)
        #expect(appleIntegral.sumOfSquares(in: roi) == expectedSq)
    }

    @Test("Gaussian blur matches within 1 gray level between Apple Metal and Portable backends")
    func gaussianBlurEquivalence() {
        let buffer = makeTestGrayscale(width: 160, height: 120)

        for sigma in [0.0, 1.2, 3.0] {
            let portableBlurred = portable.gaussianBlur(buffer, sigma: sigma)
            let appleBlurred = apple.gaussianBlur(buffer, sigma: sigma)
            let accelerateBlurred = apple.computeAccelerateGaussianBlur(of: buffer, sigma: sigma)

            assertBuffersEquivalent(
                appleBlurred,
                portableBlurred,
                maxPixelDiff: 1,
                context: "Gaussian blur Metal vs Portable (sigma = \(sigma))"
            )
            assertBuffersEquivalent(
                accelerateBlurred,
                portableBlurred,
                maxPixelDiff: 1,
                context: "Gaussian blur Accelerate vDSP vs Portable (sigma = \(sigma))"
            )
        }

        // Uniform buffer must remain strictly invariant under Gaussian blur
        let uniform = GrayscaleBuffer(width: 64, height: 48, dpi: 600, initialValue: 137)
        let blurredUniform = apple.gaussianBlur(uniform, sigma: 2.5)
        #expect(blurredUniform == uniform)
    }

    @Test("Affine warp matches within 1 gray level for identity, subpixel translation, and rotation")
    func affineWarpEquivalence() {
        let buffer = makeTestGrayscale(width: 170, height: 140)
        let outSize = Size2I(width: 170, height: 140)

        // 1. Identity transform must return exact original pixels
        let idApple = apple.affineWarp(buffer, transform: .identity, outputSize: outSize)
        let idPortable = portable.affineWarp(buffer, transform: .identity, outputSize: outSize)
        #expect(idApple == buffer)
        #expect(idPortable == buffer)

        // 2. Sub-pixel translation
        let shift = AffineTransform2D.translation(tx: 4.35, ty: -3.65)
        let shiftApple = apple.affineWarp(buffer, transform: shift, outputSize: outSize)
        let shiftPortable = portable.affineWarp(buffer, transform: shift, outputSize: outSize)
        assertBuffersEquivalent(shiftApple, shiftPortable, maxPixelDiff: 1, context: "Affine subpixel translation")

        // 3. Rotation around center (deskew simulation: -3.5 degrees)
        let center = Point2D(x: 85.0, y: 70.0)
        let rot = AffineTransform2D.rotation(radians: -3.5 * .pi / 180.0, center: center)
        let rotApple = apple.affineWarp(buffer, transform: rot, outputSize: Size2I(width: 180, height: 150))
        let rotPortable = portable.affineWarp(buffer, transform: rot, outputSize: Size2I(width: 180, height: 150))
        assertBuffersEquivalent(rotApple, rotPortable, maxPixelDiff: 1, context: "Affine rotation")
    }

    @Test("Non-linear mesh warp matches within 1 gray level for identity and curved cubic-sheet grids")
    func meshWarpEquivalence() {
        let buffer = makeTestGrayscale(width: 160, height: 120)
        let outSize = Size2I(width: 160, height: 120)

        // 1. Identity DewarpGrid
        let idGrid = DewarpGrid.identity(outputSize: outSize, columns: 17, rows: 13)
        let idApple = apple.meshWarp(buffer, displacementGrid: idGrid, outputSize: outSize)
        let idPortable = portable.meshWarp(buffer, displacementGrid: idGrid, outputSize: outSize)
        assertBuffersEquivalent(idApple, idPortable, maxPixelDiff: 1, context: "Identity mesh warp")

        // 2. Curved page-sag DewarpGrid (parabolic vertical sag + horizontal foreshortening)
        let cols = 21
        let rows = 17
        var controlPoints = ContiguousArray<Point2D>()
        controlPoints.reserveCapacity(cols * rows)

        for r in 0..<rows {
            let v = Double(r) / Double(rows - 1)
            let baseY = v * Double(outSize.height)
            for c in 0..<cols {
                let u = Double(c) / Double(cols - 1)
                let baseX = u * Double(outSize.width)
                let sagY = 8.5 * sin(u * .pi)
                let curveX = 3.0 * u * (1.0 - u)
                controlPoints.append(Point2D(x: baseX + curveX, y: baseY + sagY))
            }
        }

        let curvedGrid = DewarpGrid(outputSize: outSize, columns: cols, rows: rows, sourcePoints: controlPoints)
        let curvedApple = apple.meshWarp(buffer, displacementGrid: curvedGrid, outputSize: outSize)
        let curvedPortable = portable.meshWarp(buffer, displacementGrid: curvedGrid, outputSize: outSize)
        assertBuffersEquivalent(curvedApple, curvedPortable, maxPixelDiff: 1, context: "Curved mesh warp")
    }

    @Test("600 DPI to 300 DPI binary downsampling is bit-for-bit identical across backends")
    func downsampleBinaryEquivalence() {
        var bitmap = BinaryBitmap(width: 256, height: 192, initialBlack: false)
        for y in stride(from: 8, to: 184, by: 6) {
            for x in 12..<244 {
                bitmap[x, y] = true
                bitmap[x, y + 1] = true
            }
        }

        let apple300 = apple.downsampleBinaryTo300DPI(bitmap)
        let portable300 = portable.downsampleBinaryTo300DPI(bitmap)

        #expect(apple300 == portable300)
        #expect(apple300.width == 128)
        #expect(apple300.height == 96)
    }
}
