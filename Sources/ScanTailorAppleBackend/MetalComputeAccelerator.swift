import Accelerate
import Foundation
@preconcurrency import Metal
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPortableBackend

/// Apple Silicon hardware-accelerated implementation of `ComputeAccelerator`.
///
/// Uses **Metal compute shaders** with zero-copy Unified Memory (`MTLResourceOptions.storageModeShared`)
/// for integral image generation, separable Gaussian blur, affine warping, and non-linear 2D dewarp mesh
/// resampling, paired with `Accelerate` and word-parallel 64-bit downsampling.
/// Automatically falls back to `PortableComputeAccelerator` if no Metal device is available.
public final class MetalComputeAccelerator: ComputeAccelerator, Sendable {

    /// Whether a working Metal GPU device and compiled shader pipelines are active.
    public var isMetalAvailable: Bool {
        context != nil
    }

    /// Minimum pixel count (`width * height`) required to dispatch work to the Metal GPU.
    /// Defaults to `0` so all sizes use the GPU when available.
    public let minimumPixelsForGPU: Int

    private let context: MetalContext?
    private let fallback = PortableComputeAccelerator()

    /// Creates a new Apple Metal + Accelerate compute accelerator.
    /// - Parameter minimumPixelsForGPU: Minimum image area (`width * height`) to dispatch to Metal GPU. Default is `0`.
    public init(minimumPixelsForGPU: Int = 0) {
        self.minimumPixelsForGPU = minimumPixelsForGPU
        self.context = MetalContext.shared
    }

    // MARK: - Integral Image (Metal 2-Pass Parallel Scan)

    public func integralImage(of buffer: borrowing GrayscaleBuffer) -> IntegralBuffer {
        let pixelCount = buffer.width * buffer.height
        guard pixelCount >= minimumPixelsForGPU,
              let ctx = context,
              let result = ctx.computeIntegralImage(of: buffer)
        else {
            return fallback.integralImage(of: buffer)
        }
        return result
    }

    // MARK: - Gaussian Blur (Metal Separable 1D Convolution + Accelerate vDSP)

    public func gaussianBlur(_ buffer: borrowing GrayscaleBuffer, sigma: Double) -> GrayscaleBuffer {
        guard sigma > 0.05 else { return copy buffer }
        let pixelCount = buffer.width * buffer.height
        if pixelCount >= minimumPixelsForGPU,
           let ctx = context,
           let result = ctx.computeGaussianBlur(of: buffer, sigma: sigma) {
            return result
        }
        return computeAccelerateGaussianBlur(of: buffer, sigma: sigma)
    }

    /// Vectorized Apple `Accelerate` (`vDSP`) separable 1D Gaussian convolution.
    public func computeAccelerateGaussianBlur(
        of buffer: borrowing GrayscaleBuffer,
        sigma: Double
    ) -> GrayscaleBuffer {
        guard sigma > 0.05 else { return copy buffer }

        let width = buffer.width
        let height = buffer.height
        let (weights, radius) = PortableComputeAccelerator.makeGaussianKernel(sigma: sigma)
        let kernelLength = vDSP_Length(weights.count)

        var horizontalPass = ContiguousArray<Float>(repeating: 0, count: width * height)
        var paddedRow = ContiguousArray<Float>(repeating: 0, count: width + 2 * radius)
        var paddedCol = ContiguousArray<Float>(repeating: 0, count: height + 2 * radius)
        var convCol = ContiguousArray<Float>(repeating: 0, count: height)
        var outputPixels = ContiguousArray<UInt8>(repeating: 255, count: width * height)

        buffer.pixels.withUnsafeBufferPointer { srcPtr in
            weights.withUnsafeBufferPointer { kPtr in
                guard let kBase = kPtr.baseAddress else { return }

                horizontalPass.withUnsafeMutableBufferPointer { tempPtr in
                    paddedRow.withUnsafeMutableBufferPointer { padR in
                        guard let padRBase = padR.baseAddress,
                              let tempBase = tempPtr.baseAddress
                        else { return }

                        // 1. Horizontal pass with clamp-to-edge padding and vDSP_conv
                        for y in 0..<height {
                            let rowOffset = y * width
                            let leftVal = Float(srcPtr[rowOffset])
                            let rightVal = Float(srcPtr[rowOffset + width - 1])

                            for i in 0..<radius {
                                padR[i] = leftVal
                                padR[radius + width + i] = rightVal
                            }
                            for x in 0..<width {
                                padR[radius + x] = Float(srcPtr[rowOffset + x])
                            }

                            vDSP_conv(
                                padRBase, 1,
                                kBase, 1,
                                tempBase + rowOffset, 1,
                                vDSP_Length(width),
                                kernelLength
                            )
                        }
                    }

                    // 2. Vertical pass with clamp-to-edge padding and vDSP_conv
                    outputPixels.withUnsafeMutableBufferPointer { dstPtr in
                        paddedCol.withUnsafeMutableBufferPointer { padC in
                            convCol.withUnsafeMutableBufferPointer { outC in
                                guard let padCBase = padC.baseAddress,
                                      let outCBase = outC.baseAddress
                                else { return }

                                for x in 0..<width {
                                    let topVal = tempPtr[x]
                                    let botVal = tempPtr[(height - 1) * width + x]

                                    for i in 0..<radius {
                                        padC[i] = topVal
                                        padC[radius + height + i] = botVal
                                    }
                                    for y in 0..<height {
                                        padC[radius + y] = tempPtr[y * width + x]
                                    }

                                    vDSP_conv(
                                        padCBase, 1,
                                        kBase, 1,
                                        outCBase, 1,
                                        vDSP_Length(height),
                                        kernelLength
                                    )

                                    for y in 0..<height {
                                        dstPtr[y * width + x] = UInt8(clamping: Int(outC[y] + 0.5))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return GrayscaleBuffer(width: width, height: height, dpi: buffer.dpi, pixels: outputPixels)
    }

    // MARK: - Affine Warp (Metal 2D Bilinear Resampling)

    public func affineWarp(
        _ buffer: borrowing GrayscaleBuffer,
        transform: AffineTransform2D,
        outputSize: Size2I
    ) -> GrayscaleBuffer {
        let dstArea = max(1, outputSize.width) * max(1, outputSize.height)
        guard dstArea >= minimumPixelsForGPU,
              let ctx = context,
              let result = ctx.computeAffineWarp(of: buffer, transform: transform, outputSize: outputSize)
        else {
            return fallback.affineWarp(buffer, transform: transform, outputSize: outputSize)
        }
        return result
    }

    // MARK: - Non-Linear Mesh Warp (Metal 2D Dewarp Grid Resampling)

    public func meshWarp(
        _ buffer: borrowing GrayscaleBuffer,
        displacementGrid: borrowing DewarpGrid,
        outputSize: Size2I
    ) -> GrayscaleBuffer {
        let dstArea = max(1, outputSize.width) * max(1, outputSize.height)
        guard dstArea >= minimumPixelsForGPU,
              let ctx = context,
              let result = ctx.computeMeshWarp(
                  of: buffer,
                  displacementGrid: displacementGrid,
                  outputSize: outputSize
              )
        else {
            return fallback.meshWarp(buffer, displacementGrid: displacementGrid, outputSize: outputSize)
        }
        return result
    }

    // MARK: - Binary Downsampling

    public func downsampleBinaryTo300DPI(_ bitmap: borrowing BinaryBitmap) -> BinaryBitmap {
        BinaryDownsampler.downsample2x(bitmap, minBlackSubpixels: 2)
    }
}

// MARK: - Internal Metal Context & Shader Pipelines

private struct IntegralUniforms {
    var width: UInt32
    var height: UInt32
    var stride: UInt32
}

private struct GaussianUniforms {
    var width: UInt32
    var height: UInt32
    var radius: Int32
}

private struct AffineWarpUniforms {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var dstWidth: UInt32
    var dstHeight: UInt32
    var invA: Float
    var invB: Float
    var invC: Float
    var invD: Float
    var invTX: Float
    var invTY: Float
}

private struct MeshWarpUniforms {
    var srcWidth: UInt32
    var srcHeight: UInt32
    var dstWidth: UInt32
    var dstHeight: UInt32
    var gridCols: UInt32
    var gridRows: UInt32
    var normScaleX: Float
    var normScaleY: Float
}

private final class MetalContext: Sendable {
    static let shared = MetalContext()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let integralRowPipeline: MTLComputePipelineState
    let integralColPipeline: MTLComputePipelineState
    let gaussianHorizPipeline: MTLComputePipelineState
    let gaussianVertPipeline: MTLComputePipelineState
    let affineWarpPipeline: MTLComputePipelineState
    let meshWarpPipeline: MTLComputePipelineState

    init?() {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue()
        else {
            return nil
        }

        do {
            let library = try dev.makeLibrary(source: Self.mslShaderSource, options: nil)
            guard let intRowFn = library.makeFunction(name: "integralRowScanKernel"),
                  let intColFn = library.makeFunction(name: "integralColScanKernel"),
                  let gaussHFn = library.makeFunction(name: "gaussianHorizontalKernel"),
                  let gaussVFn = library.makeFunction(name: "gaussianVerticalKernel"),
                  let affineFn = library.makeFunction(name: "affineWarpKernel"),
                  let meshFn = library.makeFunction(name: "meshWarpKernel")
            else {
                return nil
            }

            self.device = dev
            self.commandQueue = queue
            self.integralRowPipeline = try dev.makeComputePipelineState(function: intRowFn)
            self.integralColPipeline = try dev.makeComputePipelineState(function: intColFn)
            self.gaussianHorizPipeline = try dev.makeComputePipelineState(function: gaussHFn)
            self.gaussianVertPipeline = try dev.makeComputePipelineState(function: gaussVFn)
            self.affineWarpPipeline = try dev.makeComputePipelineState(function: affineFn)
            self.meshWarpPipeline = try dev.makeComputePipelineState(function: meshFn)
        } catch {
            return nil
        }
    }

    // MARK: - Integral Image Dispatch

    func computeIntegralImage(of buffer: borrowing GrayscaleBuffer) -> IntegralBuffer? {
        let width = buffer.width
        let height = buffer.height
        let stride = width + 1
        let tableCount = stride * (height + 1)
        let tableByteSize = tableCount * MemoryLayout<UInt64>.stride

        guard let srcBuf = buffer.withUnsafeBytes({ rawPtr -> MTLBuffer? in
            guard let base = rawPtr.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: rawPtr.count, options: .storageModeShared)
        }),
        let sumBuf = device.makeBuffer(length: tableByteSize, options: .storageModeShared),
        let sqBuf = device.makeBuffer(length: tableByteSize, options: .storageModeShared),
        let cmdBuf = commandQueue.makeCommandBuffer(),
        let encoder = cmdBuf.makeComputeCommandEncoder()
        else {
            return nil
        }

        // Zero out row 0 of sumBuf and sqBuf
        memset(sumBuf.contents(), 0, stride * MemoryLayout<UInt64>.stride)
        memset(sqBuf.contents(), 0, stride * MemoryLayout<UInt64>.stride)

        var uniforms = IntegralUniforms(
            width: UInt32(width),
            height: UInt32(height),
            stride: UInt32(stride)
        )

        // Pass 1: Parallel horizontal row prefix scan (1 thread per row)
        encoder.setComputePipelineState(integralRowPipeline)
        encoder.setBuffer(srcBuf, offset: 0, index: 0)
        encoder.setBuffer(sumBuf, offset: 0, index: 1)
        encoder.setBuffer(sqBuf, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<IntegralUniforms>.stride, index: 3)
        dispatch1D(encoder: encoder, pipeline: integralRowPipeline, count: height)

        // Pass 2: Parallel vertical column prefix scan (1 thread per column 1...width)
        encoder.setComputePipelineState(integralColPipeline)
        encoder.setBuffer(sumBuf, offset: 0, index: 0)
        encoder.setBuffer(sqBuf, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<IntegralUniforms>.stride, index: 2)
        dispatch1D(encoder: encoder, pipeline: integralColPipeline, count: width)

        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        guard cmdBuf.status == .completed else { return nil }

        let sumPtr = sumBuf.contents().bindMemory(to: UInt64.self, capacity: tableCount)
        let sqPtr = sqBuf.contents().bindMemory(to: UInt64.self, capacity: tableCount)

        let sumTable = ContiguousArray(UnsafeBufferPointer(start: sumPtr, count: tableCount))
        let sumSqTable = ContiguousArray(UnsafeBufferPointer(start: sqPtr, count: tableCount))

        return IntegralBuffer(width: width, height: height, sumTable: sumTable, sumSqTable: sumSqTable)
    }

    // MARK: - Gaussian Blur Dispatch

    func computeGaussianBlur(of buffer: borrowing GrayscaleBuffer, sigma: Double) -> GrayscaleBuffer? {
        let width = buffer.width
        let height = buffer.height
        let pixelCount = width * height
        let (weights, radius) = PortableComputeAccelerator.makeGaussianKernel(sigma: sigma)

        guard let srcBuf = buffer.withUnsafeBytes({ rawPtr -> MTLBuffer? in
            guard let base = rawPtr.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: rawPtr.count, options: .storageModeShared)
        }),
        let weightBuf = weights.withUnsafeBytes({ rawPtr -> MTLBuffer? in
            guard let base = rawPtr.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: rawPtr.count, options: .storageModeShared)
        }),
        let tempBuf = device.makeBuffer(length: pixelCount * MemoryLayout<Float>.stride, options: .storageModeShared),
        let dstBuf = device.makeBuffer(length: pixelCount * MemoryLayout<UInt8>.stride, options: .storageModeShared),
        let cmdBuf = commandQueue.makeCommandBuffer(),
        let encoder = cmdBuf.makeComputeCommandEncoder()
        else {
            return nil
        }

        var uniforms = GaussianUniforms(
            width: UInt32(width),
            height: UInt32(height),
            radius: Int32(radius)
        )

        // Pass 1: Horizontal convolution (UInt8 -> Float)
        encoder.setComputePipelineState(gaussianHorizPipeline)
        encoder.setBuffer(srcBuf, offset: 0, index: 0)
        encoder.setBuffer(weightBuf, offset: 0, index: 1)
        encoder.setBuffer(tempBuf, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<GaussianUniforms>.stride, index: 3)
        dispatch2D(encoder: encoder, pipeline: gaussianHorizPipeline, width: width, height: height)

        // Pass 2: Vertical convolution (Float -> UInt8)
        encoder.setComputePipelineState(gaussianVertPipeline)
        encoder.setBuffer(tempBuf, offset: 0, index: 0)
        encoder.setBuffer(weightBuf, offset: 0, index: 1)
        encoder.setBuffer(dstBuf, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<GaussianUniforms>.stride, index: 3)
        dispatch2D(encoder: encoder, pipeline: gaussianVertPipeline, width: width, height: height)

        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        guard cmdBuf.status == .completed else { return nil }

        let dstPtr = dstBuf.contents().bindMemory(to: UInt8.self, capacity: pixelCount)
        let pixels = ContiguousArray(UnsafeBufferPointer(start: dstPtr, count: pixelCount))
        return GrayscaleBuffer(width: width, height: height, dpi: buffer.dpi, pixels: pixels)
    }

    // MARK: - Affine Warp Dispatch

    func computeAffineWarp(
        of buffer: borrowing GrayscaleBuffer,
        transform: AffineTransform2D,
        outputSize: Size2I
    ) -> GrayscaleBuffer? {
        let dstWidth = max(1, outputSize.width)
        let dstHeight = max(1, outputSize.height)
        let dstCount = dstWidth * dstHeight

        guard let inv = try? transform.inverted() else {
            return GrayscaleBuffer(width: dstWidth, height: dstHeight, dpi: buffer.dpi, initialValue: 255)
        }

        guard let srcBuf = buffer.withUnsafeBytes({ rawPtr -> MTLBuffer? in
            guard let base = rawPtr.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: rawPtr.count, options: .storageModeShared)
        }),
        let dstBuf = device.makeBuffer(length: dstCount * MemoryLayout<UInt8>.stride, options: .storageModeShared),
        let cmdBuf = commandQueue.makeCommandBuffer(),
        let encoder = cmdBuf.makeComputeCommandEncoder()
        else {
            return nil
        }

        var uniforms = AffineWarpUniforms(
            srcWidth: UInt32(buffer.width),
            srcHeight: UInt32(buffer.height),
            dstWidth: UInt32(dstWidth),
            dstHeight: UInt32(dstHeight),
            invA: Float(inv.a),
            invB: Float(inv.b),
            invC: Float(inv.c),
            invD: Float(inv.d),
            invTX: Float(inv.tx),
            invTY: Float(inv.ty)
        )

        encoder.setComputePipelineState(affineWarpPipeline)
        encoder.setBuffer(srcBuf, offset: 0, index: 0)
        encoder.setBuffer(dstBuf, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<AffineWarpUniforms>.stride, index: 2)
        dispatch2D(encoder: encoder, pipeline: affineWarpPipeline, width: dstWidth, height: dstHeight)

        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        guard cmdBuf.status == .completed else { return nil }

        let dstPtr = dstBuf.contents().bindMemory(to: UInt8.self, capacity: dstCount)
        let pixels = ContiguousArray(UnsafeBufferPointer(start: dstPtr, count: dstCount))
        return GrayscaleBuffer(width: dstWidth, height: dstHeight, dpi: buffer.dpi, pixels: pixels)
    }

    // MARK: - Mesh Warp Dispatch

    func computeMeshWarp(
        of buffer: borrowing GrayscaleBuffer,
        displacementGrid: borrowing DewarpGrid,
        outputSize: Size2I
    ) -> GrayscaleBuffer? {
        let dstWidth = max(1, outputSize.width)
        let dstHeight = max(1, outputSize.height)
        let dstCount = dstWidth * dstHeight

        // Pack DewarpGrid control points as SIMD2<Float> in shared memory
        var gridFloat2 = ContiguousArray<SIMD2<Float>>()
        gridFloat2.reserveCapacity(displacementGrid.sourcePoints.count)
        for pt in displacementGrid.sourcePoints {
            gridFloat2.append(SIMD2<Float>(Float(pt.x), Float(pt.y)))
        }

        guard let srcBuf = buffer.withUnsafeBytes({ rawPtr -> MTLBuffer? in
            guard let base = rawPtr.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: rawPtr.count, options: .storageModeShared)
        }),
        let gridBuf = gridFloat2.withUnsafeBytes({ rawPtr -> MTLBuffer? in
            guard let base = rawPtr.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: rawPtr.count, options: .storageModeShared)
        }),
        let dstBuf = device.makeBuffer(length: dstCount * MemoryLayout<UInt8>.stride, options: .storageModeShared),
        let cmdBuf = commandQueue.makeCommandBuffer(),
        let encoder = cmdBuf.makeComputeCommandEncoder()
        else {
            return nil
        }

        var uniforms = MeshWarpUniforms(
            srcWidth: UInt32(buffer.width),
            srcHeight: UInt32(buffer.height),
            dstWidth: UInt32(dstWidth),
            dstHeight: UInt32(dstHeight),
            gridCols: UInt32(displacementGrid.columns),
            gridRows: UInt32(displacementGrid.rows),
            normScaleX: 1.0 / Float(max(1, displacementGrid.outputSize.width)),
            normScaleY: 1.0 / Float(max(1, displacementGrid.outputSize.height))
        )

        encoder.setComputePipelineState(meshWarpPipeline)
        encoder.setBuffer(srcBuf, offset: 0, index: 0)
        encoder.setBuffer(gridBuf, offset: 0, index: 1)
        encoder.setBuffer(dstBuf, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<MeshWarpUniforms>.stride, index: 3)
        dispatch2D(encoder: encoder, pipeline: meshWarpPipeline, width: dstWidth, height: dstHeight)

        encoder.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        guard cmdBuf.status == .completed else { return nil }

        let dstPtr = dstBuf.contents().bindMemory(to: UInt8.self, capacity: dstCount)
        let pixels = ContiguousArray(UnsafeBufferPointer(start: dstPtr, count: dstCount))
        return GrayscaleBuffer(width: dstWidth, height: dstHeight, dpi: buffer.dpi, pixels: pixels)
    }

    // MARK: - Threadgroup Dispatch Helpers

    private func dispatch1D(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, count: Int) {
        let w = min(max(1, count), pipeline.maxTotalThreadsPerThreadgroup)
        let threadsPerGroup = MTLSize(width: w, height: 1, depth: 1)
        let gridSize = MTLSize(width: count, height: 1, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
    }

    private func dispatch2D(
        encoder: MTLComputeCommandEncoder,
        pipeline: MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let w = min(16, pipeline.threadExecutionWidth)
        let h = min(16, max(1, pipeline.maxTotalThreadsPerThreadgroup / max(1, w)))
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let gridSize = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadsPerGroup)
    }

    // MARK: - Metal Shading Language (MSL) Source

    private static let mslShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct IntegralUniforms {
        uint width;
        uint height;
        uint stride;
    };

    struct GaussianUniforms {
        uint width;
        uint height;
        int radius;
    };

    struct AffineWarpUniforms {
        uint srcWidth;
        uint srcHeight;
        uint dstWidth;
        uint dstHeight;
        float invA;
        float invB;
        float invC;
        float invD;
        float invTX;
        float invTY;
    };

    struct MeshWarpUniforms {
        uint srcWidth;
        uint srcHeight;
        uint dstWidth;
        uint dstHeight;
        uint gridCols;
        uint gridRows;
        float normScaleX;
        float normScaleY;
    };

    inline uchar sampleBilinearGray(
        device const uchar* srcPixels,
        uint srcWidth,
        uint srcHeight,
        float sx,
        float sy
    ) {
        float maxSrcX = float(srcWidth - 1);
        float maxSrcY = float(srcHeight - 1);
        if (sx < 0.0f || sy < 0.0f || sx > maxSrcX || sy > maxSrcY) {
            return 255;
        }

        uint x0 = uint(sx);
        uint y0 = uint(sy);
        uint x1 = min(x0 + 1, srcWidth - 1);
        uint y1 = min(y0 + 1, srcHeight - 1);

        float fx = sx - float(x0);
        float fy = sy - float(y0);

        uint row0 = y0 * srcWidth;
        uint row1 = y1 * srcWidth;

        float p00 = float(srcPixels[row0 + x0]);
        float p10 = float(srcPixels[row0 + x1]);
        float p01 = float(srcPixels[row1 + x0]);
        float p11 = float(srcPixels[row1 + x1]);

        float top = p00 + fx * (p10 - p00);
        float bot = p01 + fx * (p11 - p01);
        float val = top + fy * (bot - top);

        return uchar(clamp(int(val + 0.5f), 0, 255));
    }

    kernel void integralRowScanKernel(
        device const uchar* srcPixels [[buffer(0)]],
        device ulong* sumTable [[buffer(1)]],
        device ulong* sqTable [[buffer(2)]],
        constant IntegralUniforms& u [[buffer(3)]],
        uint y [[thread_position_in_grid]]
    ) {
        if (y >= u.height) return;

        uint srcRow = y * u.width;
        uint dstRow = (y + 1) * u.stride;

        sumTable[dstRow] = 0;
        sqTable[dstRow] = 0;

        ulong rowSum = 0;
        ulong rowSq = 0;

        for (uint x = 0; x < u.width; ++x) {
            ulong val = ulong(srcPixels[srcRow + x]);
            rowSum += val;
            rowSq += val * val;
            sumTable[dstRow + x + 1] = rowSum;
            sqTable[dstRow + x + 1] = rowSq;
        }
    }

    kernel void integralColScanKernel(
        device ulong* sumTable [[buffer(0)]],
        device ulong* sqTable [[buffer(1)]],
        constant IntegralUniforms& u [[buffer(2)]],
        uint colZeroBased [[thread_position_in_grid]]
    ) {
        if (colZeroBased >= u.width) return;
        uint col = colZeroBased + 1;

        ulong accSum = 0;
        ulong accSq = 0;
        for (uint y = 1; y <= u.height; ++y) {
            uint idx = y * u.stride + col;
            accSum += sumTable[idx];
            accSq += sqTable[idx];
            sumTable[idx] = accSum;
            sqTable[idx] = accSq;
        }
    }

    kernel void gaussianHorizontalKernel(
        device const uchar* srcPixels [[buffer(0)]],
        device const float* weights [[buffer(1)]],
        device float* tempBuffer [[buffer(2)]],
        constant GaussianUniforms& u [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.width || gid.y >= u.height) return;

        int w = int(u.width);
        int x = int(gid.x);
        uint rowBase = gid.y * u.width;

        float acc = 0.0f;
        for (int k = -u.radius; k <= u.radius; ++k) {
            int cx = clamp(x + k, 0, w - 1);
            acc += float(srcPixels[rowBase + uint(cx)]) * weights[k + u.radius];
        }
        tempBuffer[rowBase + gid.x] = acc;
    }

    kernel void gaussianVerticalKernel(
        device const float* tempBuffer [[buffer(0)]],
        device const float* weights [[buffer(1)]],
        device uchar* dstPixels [[buffer(2)]],
        constant GaussianUniforms& u [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.width || gid.y >= u.height) return;

        int h = int(u.height);
        int y = int(gid.y);

        float acc = 0.0f;
        for (int k = -u.radius; k <= u.radius; ++k) {
            int cy = clamp(y + k, 0, h - 1);
            acc += tempBuffer[uint(cy) * u.width + gid.x] * weights[k + u.radius];
        }
        dstPixels[gid.y * u.width + gid.x] = uchar(clamp(int(acc + 0.5f), 0, 255));
    }

    kernel void affineWarpKernel(
        device const uchar* srcPixels [[buffer(0)]],
        device uchar* dstPixels [[buffer(1)]],
        constant AffineWarpUniforms& u [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.dstWidth || gid.y >= u.dstHeight) return;

        float fxDst = float(gid.x);
        float fyDst = float(gid.y);

        float sx = u.invA * fxDst + u.invC * fyDst + u.invTX;
        float sy = u.invB * fxDst + u.invD * fyDst + u.invTY;

        dstPixels[gid.y * u.dstWidth + gid.x] = sampleBilinearGray(
            srcPixels, u.srcWidth, u.srcHeight, sx, sy
        );
    }

    kernel void meshWarpKernel(
        device const uchar* srcPixels [[buffer(0)]],
        device const float2* gridPoints [[buffer(1)]],
        device uchar* dstPixels [[buffer(2)]],
        constant MeshWarpUniforms& u [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        if (gid.x >= u.dstWidth || gid.y >= u.dstHeight) return;

        float normX = clamp(float(gid.x) * u.normScaleX, 0.0f, 1.0f);
        float normY = clamp(float(gid.y) * u.normScaleY, 0.0f, 1.0f);

        float gx = normX * float(u.gridCols - 1);
        float gy = normY * float(u.gridRows - 1);

        uint c0 = min(uint(gx), u.gridCols - 2);
        uint r0 = min(uint(gy), u.gridRows - 2);
        uint c1 = c0 + 1;
        uint r1 = r0 + 1;

        float fxGrid = gx - float(c0);
        float fyGrid = gy - float(r0);

        float2 p00 = gridPoints[r0 * u.gridCols + c0];
        float2 p10 = gridPoints[r0 * u.gridCols + c1];
        float2 p01 = gridPoints[r1 * u.gridCols + c0];
        float2 p11 = gridPoints[r1 * u.gridCols + c1];

        float2 top = p00 + fxGrid * (p10 - p00);
        float2 bot = p01 + fxGrid * (p11 - p01);
        float2 srcPt = top + fyGrid * (bot - top);

        dstPixels[gid.y * u.dstWidth + gid.x] = sampleBilinearGray(
            srcPixels, u.srcWidth, u.srcHeight, srcPt.x, srcPt.y
        );
    }
    """
}
