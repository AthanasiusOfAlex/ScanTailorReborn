import Foundation
import ScanTailorContracts

/// Binarizes grayscale document images into crisp 1-bit monochrome bitmaps using integral-image
/// accelerated local adaptive thresholding (Sauvola and Wolf-Jolion).
///
/// Both algorithms evaluate local window mean $\mu(x, y)$ and standard deviation $\sigma(x, y)$ in
/// $O(1)$ time per pixel regardless of window radius using a dual 64-bit `IntegralBuffer` ($\Sigma I$ and $\Sigma I^2$):
/// - **Sauvola**:
///   $$T(x, y) = \mu(x, y) \cdot \left[1 + k \cdot \left(\frac{\sigma(x, y)}{R} - 1\right)\right]$$
///   where $R = 128.0$ is the maximum standard deviation of an 8-bit grayscale image.
/// - **Wolf-Jolion**:
///   $$T(x, y) = \mu(x, y) - k \cdot \left(1 - \frac{\sigma(x, y)}{R_{\max}}\right) \cdot (\mu(x, y) - M)$$
///   where $M = \min_{x,y} I(x, y)$ is the darkest gray value in the page and $R_{\max} = \max_{x,y} \sigma(x, y)$
///   is the maximum local standard deviation across the page. Wolf-Jolion adapts gracefully when overall page
///   contrast varies or when faint characters sit near darker strokes.
public struct AdaptiveBinarizer: Sendable {

    /// Local adaptive thresholding formula.
    public enum Method: String, Sendable, Equatable, CaseIterable {
        /// Classic Sauvola thresholding with fixed dynamic range $R = 128$.
        case sauvola
        /// Wolf-Jolion contrast-normalized thresholding using global minimum $M$ and maximum $\sigma$.
        case wolfJolion
    }

    /// Configuration parameters for adaptive binarization.
    public struct Configuration: Sendable, Equatable {
        /// Adaptive thresholding method (`.sauvola` or `.wolfJolion`).
        public var method: Method

        /// Half-window radius in pixels at 300 DPI (window side length = `2 * radius + 1`).
        /// Automatically scaled proportionally to the input buffer's DPI.
        public var referenceWindowRadiusAt300DPI: Int

        /// Sensitivity parameter $k \in [0.05, 0.80]$ controlling how aggressively faint strokes are kept.
        /// Lower values retain thinner/fainter strokes; higher values suppress background grain.
        public var k: Double

        /// Dynamic range constant $R$ for Sauvola thresholding (default: `128.0`).
        public var sauvolaDynamicRange: Double

        /// Minimum required difference $(\mu(x, y) - I(x, y))$ for a pixel to be classified as ink when local
        /// variance is very low, preventing salt-and-pepper threshold chatter on uniform paper margins.
        public var minimumContrastDelta: Double

        /// Hard brightness ceiling above which a pixel is always classified as white paper (`0` = black, `255` = white).
        public var whiteCeiling: UInt8

        /// Optional background illumination normalization applied prior to local thresholding.
        public var backgroundNormalization: BackgroundNormalizer.Configuration?

        /// Creates an adaptive binarization configuration.
        public init(
            method: Method = .wolfJolion,
            referenceWindowRadiusAt300DPI: Int = 25,
            k: Double = 0.30,
            sauvolaDynamicRange: Double = 128.0,
            minimumContrastDelta: Double = 6.0,
            whiteCeiling: UInt8 = 250,
            backgroundNormalization: BackgroundNormalizer.Configuration? = nil
        ) {
            self.method = method
            self.referenceWindowRadiusAt300DPI = max(2, referenceWindowRadiusAt300DPI)
            self.k = min(0.95, max(0.01, k))
            self.sauvolaDynamicRange = max(1.0, sauvolaDynamicRange)
            self.minimumContrastDelta = max(0.0, minimumContrastDelta)
            self.whiteCeiling = whiteCeiling
            self.backgroundNormalization = backgroundNormalization
        }
    }

    /// Configuration used by this binarizer instance.
    public let configuration: Configuration

    /// Initializes an adaptive binarizer with the given configuration.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Binarizes `source` into a packed 1-bit `BinaryBitmap` (`1 = black ink`, `0 = white paper`).
    /// - Parameters:
    ///   - source: Input grayscale image.
    ///   - accelerator: Compute accelerator used for integral buffer construction and optional background smoothing.
    /// - Returns: A `BinaryBitmap` of the same width and height as `source`.
    public func binarize(
        _ source: borrowing GrayscaleBuffer,
        accelerator: any ComputeAccelerator
    ) -> BinaryBitmap {
        if let bgConfig = configuration.backgroundNormalization {
            let normalizer = BackgroundNormalizer(configuration: bgConfig)
            let normalized = normalizer.normalize(source, accelerator: accelerator)
            let integral = accelerator.integralImage(of: normalized)
            return binarize(normalized, integralBuffer: integral)
        } else {
            let integral = accelerator.integralImage(of: source)
            return binarize(source, integralBuffer: integral)
        }
    }

    /// Binarizes `source` using a precomputed `IntegralBuffer`.
    /// - Parameters:
    ///   - source: Input grayscale image.
    ///   - integralBuffer: Precomputed first- and second-order integral tables for `source`.
    /// - Returns: A packed 1-bit `BinaryBitmap`.
    public func binarize(
        _ source: borrowing GrayscaleBuffer,
        integralBuffer: borrowing IntegralBuffer
    ) -> BinaryBitmap {
        precondition(
            source.width == integralBuffer.width && source.height == integralBuffer.height,
            "Source dimensions must match IntegralBuffer dimensions"
        )

        let dpiScale = Double(max(72, source.dpi)) / 300.0
        let radius = max(2, Int((Double(configuration.referenceWindowRadiusAt300DPI) * dpiScale).rounded()))

        switch configuration.method {
        case .sauvola:
            return Self.binarizeSauvola(
                source: source,
                integral: integralBuffer,
                radius: radius,
                k: configuration.k,
                dynamicRange: configuration.sauvolaDynamicRange,
                minDelta: configuration.minimumContrastDelta,
                whiteCeiling: configuration.whiteCeiling
            )
        case .wolfJolion:
            return Self.binarizeWolfJolion(
                source: source,
                integral: integralBuffer,
                radius: radius,
                k: configuration.k,
                minDelta: configuration.minimumContrastDelta,
                whiteCeiling: configuration.whiteCeiling
            )
        }
    }

    // MARK: - Core Implementations

    private static func binarizeSauvola(
        source: borrowing GrayscaleBuffer,
        integral: borrowing IntegralBuffer,
        radius: Int,
        k: Double,
        dynamicRange: Double,
        minDelta: Double,
        whiteCeiling: UInt8
    ) -> BinaryBitmap {
        let width = source.width
        let height = source.height
        let stride = integral.tableStride
        let wordsPerRow = (width + 63) / 64
        var words = ContiguousArray<UInt64>(repeating: 0, count: wordsPerRow * height)
        let invR = 1.0 / max(1.0, dynamicRange)

        source.pixels.withUnsafeBufferPointer { srcPtr in
            integral.sumTable.withUnsafeBufferPointer { sumPtr in
                integral.sumSqTable.withUnsafeBufferPointer { sqPtr in
                    words.withUnsafeMutableBufferPointer { dstWords in
                        for y in 0..<height {
                            let y0 = max(0, y - radius)
                            let y1 = min(height, y + radius + 1)
                            let r0 = y0 * stride
                            let r1 = y1 * stride
                            let hSpan = y1 - y0
                            let srcRow = y * width
                            let wordRow = y * wordsPerRow

                            for wordIdx in 0..<wordsPerRow {
                                let baseX = wordIdx * 64
                                let maxBit = min(64, width - baseX)
                                var packedWord: UInt64 = 0

                                for bit in 0..<maxBit {
                                    let x = baseX + bit
                                    let pixelVal = srcPtr[srcRow + x]
                                    if pixelVal >= whiteCeiling {
                                        continue
                                    }

                                    let x0 = max(0, x - radius)
                                    let x1 = min(width, x + radius + 1)
                                    let count = Double((x1 - x0) * hSpan)
                                    let invCount = 1.0 / count

                                    let sum = (sumPtr[r1 + x1] + sumPtr[r0 + x0]) - (sumPtr[r1 + x0] + sumPtr[r0 + x1])
                                    let sqSum = (sqPtr[r1 + x1] + sqPtr[r0 + x0]) - (sqPtr[r1 + x0] + sqPtr[r0 + x1])

                                    let mean = Double(sum) * invCount
                                    let p = Double(pixelVal)

                                    if mean - p < minDelta && p > 128.0 {
                                        continue
                                    }

                                    let meanSq = Double(sqSum) * invCount
                                    let variance = max(0.0, meanSq - mean * mean)
                                    let stdDev = variance.squareRoot()

                                    let threshold = mean * (1.0 + k * (stdDev * invR - 1.0))
                                    if p <= threshold {
                                        packedWord |= (UInt64(1) << (63 - bit))
                                    }
                                }

                                dstWords[wordRow + wordIdx] = packedWord
                            }
                        }
                    }
                }
            }
        }

        return BinaryBitmap(width: width, height: height, words: words)
    }

    private static func binarizeWolfJolion(
        source: borrowing GrayscaleBuffer,
        integral: borrowing IntegralBuffer,
        radius: Int,
        k: Double,
        minDelta: Double,
        whiteCeiling: UInt8
    ) -> BinaryBitmap {
        let width = source.width
        let height = source.height
        let stride = integral.tableStride
        let wordsPerRow = (width + 63) / 64
        var words = ContiguousArray<UInt64>(repeating: 0, count: wordsPerRow * height)

        // Pass 1: Determine global minimum pixel intensity M and maximum window standard deviation R_max.
        // Sampling R_max at a coarse stride of max(1, radius / 4) accurately captures the peak local
        // standard deviation while keeping Pass 1 negligible in runtime.
        var minGray: UInt8 = 255
        var maxVariance: Double = 0.0
        let sampleStep = max(1, radius / 4)

        source.pixels.withUnsafeBufferPointer { srcPtr in
            for i in 0..<(width * height) {
                let v = srcPtr[i]
                if v < minGray { minGray = v }
            }
        }

        integral.sumTable.withUnsafeBufferPointer { sumPtr in
            integral.sumSqTable.withUnsafeBufferPointer { sqPtr in
                var y = 0
                while y < height {
                    let y0 = max(0, y - radius)
                    let y1 = min(height, y + radius + 1)
                    let r0 = y0 * stride
                    let r1 = y1 * stride
                    let hSpan = y1 - y0

                    var x = 0
                    while x < width {
                        let x0 = max(0, x - radius)
                        let x1 = min(width, x + radius + 1)
                        let invCount = 1.0 / Double((x1 - x0) * hSpan)

                        let sum = (sumPtr[r1 + x1] + sumPtr[r0 + x0]) - (sumPtr[r1 + x0] + sumPtr[r0 + x1])
                        let sqSum = (sqPtr[r1 + x1] + sqPtr[r0 + x0]) - (sqPtr[r1 + x0] + sqPtr[r0 + x1])

                        let mean = Double(sum) * invCount
                        let meanSq = Double(sqSum) * invCount
                        let variance = max(0.0, meanSq - mean * mean)
                        if variance > maxVariance {
                            maxVariance = variance
                        }

                        x += sampleStep
                    }
                    y += sampleStep
                }
            }
        }

        let minIntensity = Double(minGray)
        let maxStdDev = maxVariance.squareRoot()

        // If the entire image has near-zero variance (uniform sheet), fall back to simple dark check.
        guard maxStdDev > 1e-4 else {
            let isAllDark = minGray < 128 && minGray < whiteCeiling
            return BinaryBitmap(width: width, height: height, initialBlack: isAllDark)
        }

        let invMaxStd = 1.0 / maxStdDev

        // Pass 2: Evaluate Wolf-Jolion threshold per pixel and pack 64-bit bitmap words.
        source.pixels.withUnsafeBufferPointer { srcPtr in
            integral.sumTable.withUnsafeBufferPointer { sumPtr in
                integral.sumSqTable.withUnsafeBufferPointer { sqPtr in
                    words.withUnsafeMutableBufferPointer { dstWords in
                        for y in 0..<height {
                            let y0 = max(0, y - radius)
                            let y1 = min(height, y + radius + 1)
                            let r0 = y0 * stride
                            let r1 = y1 * stride
                            let hSpan = y1 - y0
                            let srcRow = y * width
                            let wordRow = y * wordsPerRow

                            for wordIdx in 0..<wordsPerRow {
                                let baseX = wordIdx * 64
                                let maxBit = min(64, width - baseX)
                                var packedWord: UInt64 = 0

                                for bit in 0..<maxBit {
                                    let x = baseX + bit
                                    let pixelVal = srcPtr[srcRow + x]
                                    if pixelVal >= whiteCeiling {
                                        continue
                                    }

                                    let x0 = max(0, x - radius)
                                    let x1 = min(width, x + radius + 1)
                                    let invCount = 1.0 / Double((x1 - x0) * hSpan)

                                    let sum = (sumPtr[r1 + x1] + sumPtr[r0 + x0]) - (sumPtr[r1 + x0] + sumPtr[r0 + x1])
                                    let sqSum = (sqPtr[r1 + x1] + sqPtr[r0 + x0]) - (sqPtr[r1 + x0] + sqPtr[r0 + x1])

                                    let mean = Double(sum) * invCount
                                    let p = Double(pixelVal)

                                    if mean - p < minDelta && p > 128.0 {
                                        continue
                                    }

                                    let meanSq = Double(sqSum) * invCount
                                    let variance = max(0.0, meanSq - mean * mean)
                                    let stdDev = min(maxStdDev, variance.squareRoot())

                                    // Wolf-Jolion formula: T = m - k * (1 - s / R) * (m - M)
                                    let threshold = mean - k * (1.0 - stdDev * invMaxStd) * (mean - minIntensity)
                                    if p <= threshold {
                                        packedWord |= (UInt64(1) << (63 - bit))
                                    }
                                }

                                dstWords[wordRow + wordIdx] = packedWord
                            }
                        }
                    }
                }
            }
        }

        return BinaryBitmap(width: width, height: height, words: words)
    }
}
