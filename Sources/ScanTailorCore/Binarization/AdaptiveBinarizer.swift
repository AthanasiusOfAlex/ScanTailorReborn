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

    /// Derives the local adaptive thresholding half-window radius in full-resolution source pixels,
    /// scaling dynamically to measured character $x$-height and vertical stem stroke width when available
    /// so thick camera or display strokes never suffer interior window starvation.
    /// - Parameters:
    ///   - source: Input grayscale image.
    ///   - glyphScale: Optional measured glyph scale in `source` pixel coordinates.
    /// - Returns: Half-window radius in pixels (`windowSideLength = 2 * radius + 1`).
    public func deriveWindowRadius(
        for source: borrowing GrayscaleBuffer,
        glyphScale: BackgroundNormalizer.GlyphScale? = nil
    ) -> Int {
        let minDim = max(1, min(source.width, source.height))
        let dpiScale = Double(max(72, source.dpi)) / 300.0
        let dpiRadius = max(2.0, Double(configuration.referenceWindowRadiusAt300DPI) * dpiScale)

        let allowGlyphAdaptation = configuration.backgroundNormalization?.enableGlyphScaleAdaptation ?? true
        let minConfidence = configuration.backgroundNormalization?.minimumGlyphConfidence ?? 0.35

        if allowGlyphAdaptation,
           let gs = glyphScale,
           gs.confidence >= minConfidence,
           gs.xHeightPixels.isFinite, gs.xHeightPixels >= 3.0,
           gs.strokeWidthPixels.isFinite, gs.strokeWidthPixels >= 1.0
        {
            let userWindowScale = Double(configuration.referenceWindowRadiusAt300DPI) / 25.0
            let xRadius = 1.25 * userWindowScale * gs.xHeightPixels
            let strokeRadius = 6.25 * userWindowScale * gs.strokeWidthPixels
            let capRadius: Double
            if let capH = gs.capHeightPixels, capH.isFinite, capH > 0.0 {
                capRadius = 0.85 * userWindowScale * capH
            } else {
                capRadius = 0.0
            }
            let rawGlyphRadius = max(xRadius, max(strokeRadius, capRadius))
            let minAllowed = (gs.confidence < 0.55) ? max(4.0, 0.50 * dpiRadius) : 4.0
            let maxAllowed = max(minAllowed, Double(minDim) * 0.35)
            return max(2, Int(min(maxAllowed, max(minAllowed, rawGlyphRadius)).rounded()))
        }

        return max(2, Int(dpiRadius.rounded()))
    }

    /// Binarizes `source` into a packed 1-bit `BinaryBitmap` (`1 = black ink`, `0 = white paper`).
    /// - Parameters:
    ///   - source: Input grayscale image.
    ///   - accelerator: Compute accelerator used for integral buffer construction and optional background smoothing.
    ///   - glyphScale: Optional pre-measured glyph scale in `source` pixel coordinates.
    /// - Returns: A `BinaryBitmap` of the same width and height as `source`.
    public func binarize(
        _ source: borrowing GrayscaleBuffer,
        accelerator: any ComputeAccelerator,
        glyphScale: BackgroundNormalizer.GlyphScale? = nil
    ) -> BinaryBitmap {
        if let bgConfig = configuration.backgroundNormalization {
            let normalizer = BackgroundNormalizer(configuration: bgConfig)
            let normResult = normalizer.normalizeWithTelemetry(
                source,
                accelerator: accelerator,
                glyphScale: glyphScale
            )
            let integral = accelerator.integralImage(of: normResult.buffer)
            return binarize(
                normResult.buffer,
                integralBuffer: integral,
                glyphScale: normResult.parameters.resolvedGlyphScale ?? glyphScale
            )
        } else {
            let integral = accelerator.integralImage(of: source)
            return binarize(source, integralBuffer: integral, glyphScale: glyphScale)
        }
    }

    /// Binarizes `source` using a precomputed `IntegralBuffer`.
    /// - Parameters:
    ///   - source: Input grayscale image.
    ///   - integralBuffer: Precomputed first- and second-order integral tables for `source`.
    ///   - glyphScale: Optional pre-measured glyph scale in `source` pixel coordinates.
    /// - Returns: A packed 1-bit `BinaryBitmap`.
    public func binarize(
        _ source: borrowing GrayscaleBuffer,
        integralBuffer: borrowing IntegralBuffer,
        glyphScale: BackgroundNormalizer.GlyphScale? = nil
    ) -> BinaryBitmap {
        precondition(
            source.width == integralBuffer.width && source.height == integralBuffer.height,
            "Source dimensions must match IntegralBuffer dimensions"
        )

        let radius = deriveWindowRadius(for: source, glyphScale: glyphScale)

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

    internal static func binarizeSauvolaExplicitRadius(
        source: borrowing GrayscaleBuffer,
        integral: borrowing IntegralBuffer,
        radius: Int,
        k: Double,
        dynamicRange: Double,
        minDelta: Double,
        whiteCeiling: UInt8
    ) -> BinaryBitmap {
        binarizeSauvola(
            source: source,
            integral: integral,
            radius: max(2, radius),
            k: k,
            dynamicRange: dynamicRange,
            minDelta: minDelta,
            whiteCeiling: whiteCeiling
        )
    }

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

        // Pass 1: Determine outlier-robust dark anchor M and peak active window standard deviation R_max.
        // Prefer the interior region [8.3%..91.7%] when sufficient contrast exists there so peripheral
        // camera desk borders or corner wedges cannot drag M to 0 and inflate R_max across the page;
        // automatically fall back to the full page if the interior is blank.
        let sampleStep = max(1, radius / 4)
        let marginX = width >= 96 ? (width / 12) : 0
        let marginY = height >= 96 ? (height / 12) : 0

        var anchors = Self.measureWolfJolionAnchors(
            source: source,
            integral: integral,
            radius: radius,
            sampleStep: sampleStep,
            ax0: marginX,
            ay0: marginY,
            ax1: width - marginX,
            ay1: height - marginY
        )
        if (marginX > 0 || marginY > 0) && anchors.maxStdDev < 3.0 {
            anchors = Self.measureWolfJolionAnchors(
                source: source,
                integral: integral,
                radius: radius,
                sampleStep: sampleStep,
                ax0: 0,
                ay0: 0,
                ax1: width,
                ay1: height
            )
        }

        let minGray = anchors.minGray
        let minIntensity = Double(minGray)
        let maxStdDev = anchors.maxStdDev

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

                                    // Wolf-Jolion formula: T = m - k * (1 - s / R) * max(0, m - M)
                                    let threshold = mean - k * (1.0 - stdDev * invMaxStd) * max(0.0, mean - minIntensity)
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

    private static func measureWolfJolionAnchors(
        source: borrowing GrayscaleBuffer,
        integral: borrowing IntegralBuffer,
        radius: Int,
        sampleStep: Int,
        ax0: Int,
        ay0: Int,
        ax1: Int,
        ay1: Int
    ) -> (minGray: UInt8, maxStdDev: Double) {
        let width = source.width
        let height = source.height
        let stride = integral.tableStride
        let rx0 = max(0, min(width, ax0))
        let rx1 = max(rx0, min(width, ax1))
        let ry0 = max(0, min(height, ay0))
        let ry1 = max(ry0, min(height, ay1))
        let regionCount = (rx1 - rx0) * (ry1 - ry0)
        guard regionCount > 0 else {
            return (255, 0.0)
        }

        var grayHist = [Int](repeating: 0, count: 256)
        source.pixels.withUnsafeBufferPointer { srcPtr in
            for y in ry0..<ry1 {
                let row = y * width
                for x in rx0..<rx1 {
                    grayHist[Int(srcPtr[row + x])] += 1
                }
            }
        }

        let targetDarkRank = max(1, regionCount / 2000)
        var cumDark = 0
        var resolvedMinGray: UInt8 = 255
        for g in 0..<256 {
            cumDark += grayHist[g]
            if cumDark >= targetDarkRank {
                resolvedMinGray = UInt8(g)
                break
            }
        }

        var maxVariance: Double = 0.0
        var stdHist = [Int](repeating: 0, count: 256)
        var stdBinPeak = [Double](repeating: 0.0, count: 256)
        var activeCount = 0

        integral.sumTable.withUnsafeBufferPointer { sumPtr in
            integral.sumSqTable.withUnsafeBufferPointer { sqPtr in
                var y = ry0
                while y < ry1 {
                    let y0 = max(0, y - radius)
                    let y1 = min(height, y + radius + 1)
                    let r0 = y0 * stride
                    let r1 = y1 * stride
                    let hSpan = y1 - y0

                    var x = rx0
                    while x < rx1 {
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
                        if variance > 4.0 {
                            let s = variance.squareRoot()
                            let bin = min(255, max(0, Int(s * 2.0)))
                            stdHist[bin] += 1
                            if s > stdBinPeak[bin] {
                                stdBinPeak[bin] = s
                            }
                            activeCount += 1
                        }

                        x += sampleStep
                    }
                    y += sampleStep
                }
            }
        }

        let resolvedMaxStdDev: Double
        if activeCount >= 16 {
            let targetStdRank = max(1, (activeCount * 98 + 99) / 100)
            var cumStd = 0
            var pctStd = maxVariance.squareRoot()
            for bin in 0..<256 {
                cumStd += stdHist[bin]
                if cumStd >= targetStdRank {
                    pctStd = stdBinPeak[bin]
                    break
                }
            }
            resolvedMaxStdDev = pctStd
        } else {
            resolvedMaxStdDev = maxVariance.squareRoot()
        }

        return (resolvedMinGray, resolvedMaxStdDev)
    }
}
