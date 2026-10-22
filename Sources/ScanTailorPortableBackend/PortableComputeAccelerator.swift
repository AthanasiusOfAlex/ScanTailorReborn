import Foundation
import ScanTailorContracts
import ScanTailorCore

/// A pure Swift, zero-Apple-framework implementation of `ComputeAccelerator` using CPU/SIMD loops.
///
/// Serves both as the cross-platform reference implementation (Linux/Windows) and as a fallback
/// when GPU acceleration is unavailable or bypassed.
public struct PortableComputeAccelerator: ComputeAccelerator, Sendable {

    /// Creates a new portable CPU compute accelerator.
    public init() {}

    // MARK: - Integral Image

    public func integralImage(of buffer: borrowing GrayscaleBuffer) -> IntegralBuffer {
        let width = buffer.width
        let height = buffer.height
        let stride = width + 1
        let tableCount = stride * (height + 1)

        var sumTable = ContiguousArray<UInt64>(repeating: 0, count: tableCount)
        var sumSqTable = ContiguousArray<UInt64>(repeating: 0, count: tableCount)

        buffer.pixels.withUnsafeBufferPointer { srcPtr in
            sumTable.withUnsafeMutableBufferPointer { sumPtr in
                sumSqTable.withUnsafeMutableBufferPointer { sqPtr in
                    for y in 0..<height {
                        let srcRowBase = y * width
                        let prevTableRow = y * stride
                        let currTableRow = (y + 1) * stride

                        var rowSum: UInt64 = 0
                        var rowSumSq: UInt64 = 0

                        for x in 0..<width {
                            let val = UInt64(srcPtr[srcRowBase + x])
                            rowSum &+= val
                            rowSumSq &+= val &* val

                            let colIdx = x + 1
                            sumPtr[currTableRow + colIdx] = sumPtr[prevTableRow + colIdx] &+ rowSum
                            sqPtr[currTableRow + colIdx] = sqPtr[prevTableRow + colIdx] &+ rowSumSq
                        }
                    }
                }
            }
        }

        return IntegralBuffer(
            width: width,
            height: height,
            sumTable: sumTable,
            sumSqTable: sumSqTable
        )
    }

    // MARK: - Gaussian Blur

    public func gaussianBlur(_ buffer: borrowing GrayscaleBuffer, sigma: Double) -> GrayscaleBuffer {
        guard sigma > 0.05 else { return copy buffer }

        let width = buffer.width
        let height = buffer.height
        let (weights, radius) = Self.makeGaussianKernel(sigma: sigma)

        var horizontalPass = ContiguousArray<Float>(repeating: 0, count: width * height)
        var outputPixels = ContiguousArray<UInt8>(repeating: 255, count: width * height)

        buffer.pixels.withUnsafeBufferPointer { srcPtr in
            weights.withUnsafeBufferPointer { kPtr in
                horizontalPass.withUnsafeMutableBufferPointer { tempPtr in
                    // 1. Horizontal separable pass (UInt8 -> Float)
                    for y in 0..<height {
                        let rowBase = y * width
                        for x in 0..<width {
                            var acc: Float = 0
                            for k in -radius...radius {
                                let clampedX = min(max(x + k, 0), width - 1)
                                acc += Float(srcPtr[rowBase + clampedX]) * kPtr[k + radius]
                            }
                            tempPtr[rowBase + x] = acc
                        }
                    }

                    // 2. Vertical separable pass (Float -> UInt8)
                    outputPixels.withUnsafeMutableBufferPointer { dstPtr in
                        for y in 0..<height {
                            let dstRowBase = y * width
                            for x in 0..<width {
                                var acc: Float = 0
                                for k in -radius...radius {
                                    let clampedY = min(max(y + k, 0), height - 1)
                                    acc += tempPtr[clampedY * width + x] * kPtr[k + radius]
                                }
                                dstPtr[dstRowBase + x] = UInt8(clamping: Int(acc + 0.5))
                            }
                        }
                    }
                }
            }
        }

        return GrayscaleBuffer(width: width, height: height, dpi: buffer.dpi, pixels: outputPixels)
    }

    /// Constructs a normalized 1D Gaussian kernel of radius `max(1, min(64, ceil(3 * sigma)))`.
    public static func makeGaussianKernel(sigma: Double) -> (weights: ContiguousArray<Float>, radius: Int) {
        let radius = max(1, min(64, Int(ceil(3.0 * sigma))))
        let size = 2 * radius + 1
        var weights = ContiguousArray<Float>(repeating: 0, count: size)
        let invTwoSigmaSq = Float(1.0 / (2.0 * sigma * sigma))

        var sum: Float = 0
        for i in -radius...radius {
            let d = Float(i)
            let w = exp(-(d * d) * invTwoSigmaSq)
            weights[i + radius] = w
            sum += w
        }

        let invSum = 1.0 / sum
        for idx in 0..<size {
            weights[idx] *= invSum
        }

        return (weights, radius)
    }

    // MARK: - Affine Warp

    public func affineWarp(
        _ buffer: borrowing GrayscaleBuffer,
        transform: AffineTransform2D,
        outputSize: Size2I
    ) -> GrayscaleBuffer {
        let dstWidth = max(1, outputSize.width)
        let dstHeight = max(1, outputSize.height)

        guard let inv = try? transform.inverted() else {
            return GrayscaleBuffer(width: dstWidth, height: dstHeight, dpi: buffer.dpi, initialValue: 255)
        }

        let srcWidth = buffer.width
        let srcHeight = buffer.height
        let maxSrcX = Float(srcWidth - 1)
        let maxSrcY = Float(srcHeight - 1)

        let invA = Float(inv.a)
        let invB = Float(inv.b)
        let invC = Float(inv.c)
        let invD = Float(inv.d)
        let invTX = Float(inv.tx)
        let invTY = Float(inv.ty)

        var outputPixels = ContiguousArray<UInt8>(repeating: 255, count: dstWidth * dstHeight)

        buffer.pixels.withUnsafeBufferPointer { srcPtr in
            outputPixels.withUnsafeMutableBufferPointer { dstPtr in
                for dstY in 0..<dstHeight {
                    let fyDst = Float(dstY)
                    let rowXBase = invC * fyDst + invTX
                    let rowYBase = invD * fyDst + invTY
                    let dstRowOffset = dstY * dstWidth

                    for dstX in 0..<dstWidth {
                        let fxDst = Float(dstX)
                        let sx = invA * fxDst + rowXBase
                        let sy = invB * fxDst + rowYBase

                        dstPtr[dstRowOffset + dstX] = Self.sampleBilinear(
                            srcPtr: srcPtr,
                            srcWidth: srcWidth,
                            srcHeight: srcHeight,
                            maxSrcX: maxSrcX,
                            maxSrcY: maxSrcY,
                            sx: sx,
                            sy: sy
                        )
                    }
                }
            }
        }

        return GrayscaleBuffer(width: dstWidth, height: dstHeight, dpi: buffer.dpi, pixels: outputPixels)
    }

    // MARK: - Non-Linear Mesh Warp

    public func meshWarp(
        _ buffer: borrowing GrayscaleBuffer,
        displacementGrid: borrowing DewarpGrid,
        outputSize: Size2I
    ) -> GrayscaleBuffer {
        let dstWidth = max(1, outputSize.width)
        let dstHeight = max(1, outputSize.height)
        let srcWidth = buffer.width
        let srcHeight = buffer.height
        let maxSrcX = Float(srcWidth - 1)
        let maxSrcY = Float(srcHeight - 1)

        let gridCols = displacementGrid.columns
        let gridRows = displacementGrid.rows
        let normScaleX = 1.0 / Float(max(1, displacementGrid.outputSize.width))
        let normScaleY = 1.0 / Float(max(1, displacementGrid.outputSize.height))
        let colSpan = Float(gridCols - 1)
        let rowSpan = Float(gridRows - 1)

        var outputPixels = ContiguousArray<UInt8>(repeating: 255, count: dstWidth * dstHeight)

        buffer.pixels.withUnsafeBufferPointer { srcPtr in
            displacementGrid.sourcePoints.withUnsafeBufferPointer { gridPtr in
                outputPixels.withUnsafeMutableBufferPointer { dstPtr in
                    for dstY in 0..<dstHeight {
                        let normY = min(max(Float(dstY) * normScaleY, 0.0), 1.0)
                        let gy = normY * rowSpan
                        let r0 = min(Int(gy), gridRows - 2)
                        let r1 = r0 + 1
                        let fyGrid = gy - Float(r0)

                        let gridRow0 = r0 * gridCols
                        let gridRow1 = r1 * gridCols
                        let dstRowOffset = dstY * dstWidth

                        for dstX in 0..<dstWidth {
                            let normX = min(max(Float(dstX) * normScaleX, 0.0), 1.0)
                            let gx = normX * colSpan
                            let c0 = min(Int(gx), gridCols - 2)
                            let c1 = c0 + 1
                            let fxGrid = gx - Float(c0)

                            let p00 = gridPtr[gridRow0 + c0]
                            let p10 = gridPtr[gridRow0 + c1]
                            let p01 = gridPtr[gridRow1 + c0]
                            let p11 = gridPtr[gridRow1 + c1]

                            let topX = Float(p00.x) + fxGrid * Float(p10.x - p00.x)
                            let topY = Float(p00.y) + fxGrid * Float(p10.y - p00.y)
                            let botX = Float(p01.x) + fxGrid * Float(p11.x - p01.x)
                            let botY = Float(p01.y) + fxGrid * Float(p11.y - p01.y)

                            let sx = topX + fyGrid * (botX - topX)
                            let sy = topY + fyGrid * (botY - topY)

                            dstPtr[dstRowOffset + dstX] = Self.sampleBilinear(
                                srcPtr: srcPtr,
                                srcWidth: srcWidth,
                                srcHeight: srcHeight,
                                maxSrcX: maxSrcX,
                                maxSrcY: maxSrcY,
                                sx: sx,
                                sy: sy
                            )
                        }
                    }
                }
            }
        }

        return GrayscaleBuffer(width: dstWidth, height: dstHeight, dpi: buffer.dpi, pixels: outputPixels)
    }

    // MARK: - Binary Downsampling

    public func downsampleBinaryTo300DPI(_ bitmap: borrowing BinaryBitmap) -> BinaryBitmap {
        BinaryDownsampler.downsample2x(bitmap, minBlackSubpixels: 2)
    }

    // MARK: - Bilinear Helper

    @inline(__always)
    internal static func sampleBilinear(
        srcPtr: UnsafeBufferPointer<UInt8>,
        srcWidth: Int,
        srcHeight: Int,
        maxSrcX: Float,
        maxSrcY: Float,
        sx: Float,
        sy: Float
    ) -> UInt8 {
        if sx < 0.0 || sy < 0.0 || sx > maxSrcX || sy > maxSrcY {
            return 255
        }

        let x0 = Int(sx)
        let y0 = Int(sy)
        let x1 = min(x0 + 1, srcWidth - 1)
        let y1 = min(y0 + 1, srcHeight - 1)

        let fx = sx - Float(x0)
        let fy = sy - Float(y0)

        let row0 = y0 * srcWidth
        let row1 = y1 * srcWidth

        let p00 = Float(srcPtr[row0 + x0])
        let p10 = Float(srcPtr[row0 + x1])
        let p01 = Float(srcPtr[row1 + x0])
        let p11 = Float(srcPtr[row1 + x1])

        let top = p00 + fx * (p10 - p00)
        let bot = p01 + fx * (p11 - p01)
        let value = top + fy * (bot - top)

        return UInt8(clamping: Int(value + 0.5))
    }
}
