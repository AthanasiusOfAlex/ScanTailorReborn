import Foundation
import ScanTailorContracts

/// Normalizes uneven page illumination, smartphone camera vignetting, and dark book-spine shadows
/// by estimating and dividing out a smooth low-frequency background luminance surface.
///
/// The algorithm operates in four stages:
/// 1. **Area-average downsampling**: Reduces the source image by `downsampleFactor` to suppress
///    single-pixel noise and accelerate large-scale morphological filtering.
/// 2. **Separable Grayscale Morphological Closing**: Applies a 2D grayscale dilation (maximum filter)
///    followed by a 2D grayscale erosion (minimum filter) with radius scaled to the image DPI.
///    Closing bridges across dark ink strokes and characters while preserving linear illumination
///    gradients without bias.
/// 3. **Gaussian Smoothing & Bilinear Upsampling**: Smooths the closed background map via
///    `ComputeAccelerator.gaussianBlur` and reconstructs a full-resolution background estimate.
/// 4. **Gain-Clamped Quotient Normalization**: Computes `min(255, (src * 255) / max(bg, floor))`
///    with optional blend factor so paper regions flatten to `255` (pure white) while dark ink
///    retains crisp contrast.
public struct BackgroundNormalizer: Sendable {

    /// Configuration parameters for background illumination normalization.
    public struct Configuration: Sendable, Equatable {
        /// Downsampling factor for background estimation (default: 4).
        public var downsampleFactor: Int

        /// Morphological closing kernel radius in pixels at 300 DPI (scaled proportionally to buffer DPI).
        /// Must be larger than half the thickest expected stroke/character width so text is bridged.
        public var referenceClosingRadiusAt300DPI: Int

        /// Gaussian blur sigma applied on the downsampled background grid after morphological closing.
        public var downsampledBlurSigma: Double

        /// Minimum allowed background luminance divisor `[1, 255]` to avoid amplifying deep black borders
        /// into high-contrast static noise.
        public var minimumBackgroundDivisor: UInt8

        /// Blend strength in `[0.0, 1.0]` between original (`0.0`) and fully normalized (`1.0`) image.
        public var strength: Double

        /// Creates a background normalization configuration.
        public init(
            downsampleFactor: Int = 4,
            referenceClosingRadiusAt300DPI: Int = 24,
            downsampledBlurSigma: Double = 3.0,
            minimumBackgroundDivisor: UInt8 = 32,
            strength: Double = 1.0
        ) {
            self.downsampleFactor = max(1, downsampleFactor)
            self.referenceClosingRadiusAt300DPI = max(2, referenceClosingRadiusAt300DPI)
            self.downsampledBlurSigma = max(0.0, downsampledBlurSigma)
            self.minimumBackgroundDivisor = max(1, minimumBackgroundDivisor)
            self.strength = min(1.0, max(0.0, strength))
        }
    }

    /// Configuration used by this normalizer instance.
    public let configuration: Configuration

    /// Initializes a background normalizer with the given configuration.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Estimates the low-frequency background illumination map at the full resolution of `source`.
    /// - Parameters:
    ///   - source: Input grayscale image.
    ///   - accelerator: Compute accelerator used for Gaussian smoothing.
    /// - Returns: A `GrayscaleBuffer` of the same dimensions as `source` representing the paper background luminance.
    public func estimateBackground(
        for source: borrowing GrayscaleBuffer,
        accelerator: any ComputeAccelerator
    ) -> GrayscaleBuffer {
        let factor = max(1, min(configuration.downsampleFactor, min(source.width, source.height)))
        let small = Self.downsampleAreaAverage(source, factor: factor)

        let dpiScale = Double(max(72, source.dpi)) / 300.0
        let fullResRadius = max(2, Int((Double(configuration.referenceClosingRadiusAt300DPI) * dpiScale).rounded()))
        let smallRadius = max(1, (fullResRadius + factor - 1) / factor)

        // Morphological closing (dilation followed by erosion) erases dark ink valleys narrower
        // than 2 * smallRadius while remaining unbiased on linear illumination ramps.
        let dilated = Self.grayscaleDilateSeparable(small, radius: smallRadius)
        // Use a slightly smaller erosion radius (max(1, smallRadius - 1)) near image borders to
        // ensure foreground strokes near edges never pull the background estimate down.
        let erosionRadius = max(1, smallRadius - 1)
        let closed = Self.grayscaleErodeSeparable(dilated, radius: erosionRadius)

        let smoothed: GrayscaleBuffer
        if configuration.downsampledBlurSigma > 0.05 && closed.width > 2 && closed.height > 2 {
            smoothed = accelerator.gaussianBlur(closed, sigma: configuration.downsampledBlurSigma)
        } else {
            smoothed = closed
        }

        if factor == 1 && smoothed.width == source.width && smoothed.height == source.height {
            return smoothed
        }

        return Self.upsampleBilinear(
            smoothed,
            targetWidth: source.width,
            targetHeight: source.height,
            dpi: source.dpi
        )
    }

    /// Normalizes the illumination of `source` by dividing out the estimated background surface.
    /// - Parameters:
    ///   - source: Input grayscale image with potentially uneven lighting or spine shadows.
    ///   - accelerator: Compute accelerator used for Gaussian smoothing.
    /// - Returns: Illumination-normalized `GrayscaleBuffer` where paper background is flattened toward `255`.
    public func normalize(
        _ source: borrowing GrayscaleBuffer,
        accelerator: any ComputeAccelerator
    ) -> GrayscaleBuffer {
        guard configuration.strength > 0.0 else {
            return GrayscaleBuffer(
                width: source.width,
                height: source.height,
                dpi: source.dpi,
                pixels: source.pixels
            )
        }

        let background = estimateBackground(for: source, accelerator: accelerator)
        let count = source.width * source.height
        let minDivisor = Int(max(1, configuration.minimumBackgroundDivisor))
        let blendMilli = Int((configuration.strength * 1024.0).rounded())

        var outPixels = ContiguousArray<UInt8>(repeating: 255, count: count)

        source.pixels.withUnsafeBufferPointer { srcPtr in
            background.pixels.withUnsafeBufferPointer { bgPtr in
                outPixels.withUnsafeMutableBufferPointer { dstPtr in
                    for i in 0..<count {
                        let s = Int(srcPtr[i])
                        let bg = max(Int(bgPtr[i]), minDivisor)
                        let normalized = min(255, (s * 255 + (bg >> 1)) / bg)
                        if blendMilli >= 1024 {
                            dstPtr[i] = UInt8(normalized)
                        } else {
                            let blended = ((1024 - blendMilli) * s + blendMilli * normalized + 512) >> 10
                            dstPtr[i] = UInt8(min(255, max(0, blended)))
                        }
                    }
                }
            }
        }

        return GrayscaleBuffer(
            width: source.width,
            height: source.height,
            dpi: source.dpi,
            pixels: outPixels
        )
    }

    // MARK: - Internal Helpers

    /// Downsamples a grayscale buffer by `factor` using block area averaging.
    internal static func downsampleAreaAverage(
        _ source: borrowing GrayscaleBuffer,
        factor: Int
    ) -> GrayscaleBuffer {
        guard factor > 1 else {
            return GrayscaleBuffer(
                width: source.width,
                height: source.height,
                dpi: source.dpi,
                pixels: source.pixels
            )
        }

        let dstWidth = max(1, (source.width + factor - 1) / factor)
        let dstHeight = max(1, (source.height + factor - 1) / factor)
        let dstDPI = max(1, source.dpi / factor)
        var dstPixels = ContiguousArray<UInt8>(repeating: 255, count: dstWidth * dstHeight)

        let srcW = source.width
        let srcH = source.height

        source.pixels.withUnsafeBufferPointer { srcPtr in
            dstPixels.withUnsafeMutableBufferPointer { dstPtr in
                for dy in 0..<dstHeight {
                    let y0 = dy * factor
                    let y1 = min(srcH, y0 + factor)
                    let dstRow = dy * dstWidth

                    for dx in 0..<dstWidth {
                        let x0 = dx * factor
                        let x1 = min(srcW, x0 + factor)

                        var sum = 0
                        let area = (y1 - y0) * (x1 - x0)
                        for sy in y0..<y1 {
                            let rowOffset = sy * srcW
                            for sx in x0..<x1 {
                                sum += Int(srcPtr[rowOffset + sx])
                            }
                        }
                        dstPtr[dstRow + dx] = UInt8((sum + (area >> 1)) / max(1, area))
                    }
                }
            }
        }

        return GrayscaleBuffer(width: dstWidth, height: dstHeight, dpi: dstDPI, pixels: dstPixels)
    }

    /// Separable 2D grayscale dilation (sliding-window maximum) with clamped edge handling.
    internal static func grayscaleDilateSeparable(
        _ buffer: borrowing GrayscaleBuffer,
        radius: Int
    ) -> GrayscaleBuffer {
        guard radius > 0 else {
            return GrayscaleBuffer(
                width: buffer.width,
                height: buffer.height,
                dpi: buffer.dpi,
                pixels: buffer.pixels
            )
        }

        let w = buffer.width
        let h = buffer.height
        var horizontal = ContiguousArray<UInt8>(repeating: 0, count: w * h)
        var vertical = ContiguousArray<UInt8>(repeating: 0, count: w * h)

        buffer.pixels.withUnsafeBufferPointer { srcPtr in
            horizontal.withUnsafeMutableBufferPointer { tmpPtr in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        let x0 = max(0, x - radius)
                        let x1 = min(w - 1, x + radius)
                        var maxVal: UInt8 = 0
                        for sx in x0...x1 {
                            let v = srcPtr[row + sx]
                            if v > maxVal { maxVal = v }
                        }
                        tmpPtr[row + x] = maxVal
                    }
                }
            }
        }

        horizontal.withUnsafeBufferPointer { tmpPtr in
            vertical.withUnsafeMutableBufferPointer { dstPtr in
                for y in 0..<h {
                    let y0 = max(0, y - radius)
                    let y1 = min(h - 1, y + radius)
                    let dstRow = y * w
                    for x in 0..<w {
                        var maxVal: UInt8 = 0
                        for sy in y0...y1 {
                            let v = tmpPtr[sy * w + x]
                            if v > maxVal { maxVal = v }
                        }
                        dstPtr[dstRow + x] = maxVal
                    }
                }
            }
        }

        return GrayscaleBuffer(width: w, height: h, dpi: buffer.dpi, pixels: vertical)
    }

    /// Separable 2D grayscale erosion (sliding-window minimum) with clamped edge handling.
    internal static func grayscaleErodeSeparable(
        _ buffer: borrowing GrayscaleBuffer,
        radius: Int
    ) -> GrayscaleBuffer {
        guard radius > 0 else {
            return GrayscaleBuffer(
                width: buffer.width,
                height: buffer.height,
                dpi: buffer.dpi,
                pixels: buffer.pixels
            )
        }

        let w = buffer.width
        let h = buffer.height
        var horizontal = ContiguousArray<UInt8>(repeating: 255, count: w * h)
        var vertical = ContiguousArray<UInt8>(repeating: 255, count: w * h)

        buffer.pixels.withUnsafeBufferPointer { srcPtr in
            horizontal.withUnsafeMutableBufferPointer { tmpPtr in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        let x0 = max(0, x - radius)
                        let x1 = min(w - 1, x + radius)
                        var minVal: UInt8 = 255
                        for sx in x0...x1 {
                            let v = srcPtr[row + sx]
                            if v < minVal { minVal = v }
                        }
                        tmpPtr[row + x] = minVal
                    }
                }
            }
        }

        horizontal.withUnsafeBufferPointer { tmpPtr in
            vertical.withUnsafeMutableBufferPointer { dstPtr in
                for y in 0..<h {
                    let y0 = max(0, y - radius)
                    let y1 = min(h - 1, y + radius)
                    let dstRow = y * w
                    for x in 0..<w {
                        var minVal: UInt8 = 255
                        for sy in y0...y1 {
                            let v = tmpPtr[sy * w + x]
                            if v < minVal { minVal = v }
                        }
                        dstPtr[dstRow + x] = minVal
                    }
                }
            }
        }

        return GrayscaleBuffer(width: w, height: h, dpi: buffer.dpi, pixels: vertical)
    }

    /// Bilinearly upsamples a low-resolution grayscale buffer to `(targetWidth, targetHeight)`.
    internal static func upsampleBilinear(
        _ small: borrowing GrayscaleBuffer,
        targetWidth: Int,
        targetHeight: Int,
        dpi: Int
    ) -> GrayscaleBuffer {
        let srcW = small.width
        let srcH = small.height
        var outPixels = ContiguousArray<UInt8>(repeating: 255, count: targetWidth * targetHeight)

        let scaleX = Double(srcW) / Double(max(1, targetWidth))
        let scaleY = Double(srcH) / Double(max(1, targetHeight))

        small.pixels.withUnsafeBufferPointer { srcPtr in
            outPixels.withUnsafeMutableBufferPointer { dstPtr in
                for y in 0..<targetHeight {
                    // Map destination pixel center to source pixel center coordinates
                    let srcY = max(0.0, min(Double(srcH - 1), (Double(y) + 0.5) * scaleY - 0.5))
                    let y0 = Int(srcY)
                    let y1 = min(srcH - 1, y0 + 1)
                    let fy = Int(((srcY - Double(y0)) * 256.0).rounded())
                    let invFy = 256 - fy

                    let row0 = y0 * srcW
                    let row1 = y1 * srcW
                    let dstRow = y * targetWidth

                    for x in 0..<targetWidth {
                        let srcX = max(0.0, min(Double(srcW - 1), (Double(x) + 0.5) * scaleX - 0.5))
                        let x0 = Int(srcX)
                        let x1 = min(srcW - 1, x0 + 1)
                        let fx = Int(((srcX - Double(x0)) * 256.0).rounded())
                        let invFx = 256 - fx

                        let p00 = Int(srcPtr[row0 + x0])
                        let p10 = Int(srcPtr[row0 + x1])
                        let p01 = Int(srcPtr[row1 + x0])
                        let p11 = Int(srcPtr[row1 + x1])

                        let top = p00 * invFx + p10 * fx
                        let bottom = p01 * invFx + p11 * fx
                        let value = (top * invFy + bottom * fy + 32768) >> 16
                        dstPtr[dstRow + x] = UInt8(min(255, max(0, value)))
                    }
                }
            }
        }

        return GrayscaleBuffer(width: targetWidth, height: targetHeight, dpi: dpi, pixels: outPixels)
    }
}
