import Foundation
import ScanTailorContracts

/// Normalizes uneven page illumination, smartphone camera vignetting, specular glare ramps,
/// and dark book-spine shadows by estimating and dividing out a dual-pass low-frequency
/// background luminance surface prior to adaptive thresholding.
///
/// The algorithm operates in five stages:
/// 1. **Glyph-Scale Kernel Derivation**: Dynamically scales the full-resolution morphological closing
///    radius $R_{\text{closing}}$, Gaussian smoothing $\sigma$, and working pyramid downsample factor
///    to the page's measured character $x$-height ($H_x$) and vertical stem stroke width ($W_{\text{stroke}}$),
///    falling back gracefully to DPI-proportional defaults on blank or non-text pages.
/// 2. **Pass 1 — Coarse Glyph-Bridging Morphological Surface**: Downsamples the source image by
///    `effectiveDownsampleFactor`, applies exact $O(1)$-per-pixel van Herk / Gil-Werman 2D grayscale
///    closing to bridge across dark ink strokes without eroding glyph interiors, and smooths via
///    `ComputeAccelerator.gaussianBlur`.
/// 3. **Pass 2 — Foreground-Masked Residual Quotient Flattening**: Evaluates the unclipped Pass 1
///    quotient against a mode-seeking per-block paper crest to segment pure exposed paper pixels from
///    foreground ink, rejects soft optical-PSF stroke skirts that border ink, inpaints ink-covered regions
///    via multi-stride normalized diffusion, and smooths the pure-paper residual surface with point-reflected
///    (linear-ramp-preserving) boundaries, so dense multi-column text never depresses the background
///    estimate and steep boundary spine shadows flatten cleanly right to the page edge.
/// 4. **Anti-Starvation Ink Contrast Harmonization**: Measures the macro low-frequency stroke-core
///    absorption envelope across paper-supported text cells (rejecting desk/border outliers) and restores
///    glare-veiled absorption multiplicatively toward the crisp reference, gated by local peak absorption
///    so stroke-edge pixels inherit their stroke's gain (uniform stroke weight) while isolated paper grain
///    and faint bleed-through stay untouched.
/// 5. **Sub-Gray-Level Quotient Reconstruction**: Applies `min(255, (src * 255) / max(bgEff, floor))`
///    in fixed-point sub-gray-level precision with optional `strength` blending.
public struct BackgroundNormalizer: Sendable {

    /// Typographic pixel scale on the target grayscale buffer used to size morphological closing
    /// and Gaussian smoothing kernels without relying on potentially bogus wrapper DPI headers.
    public struct GlyphScale: Sendable, Equatable, Codable {
        /// Estimated lowercase character $x$-height ($H_x$) in full-resolution pixels.
        public let xHeightPixels: Double
        /// Estimated vertical stem stroke thickness ($W_{\text{stroke}}$) in full-resolution pixels.
        public let strokeWidthPixels: Double
        /// Optional capital / ascender height ($H_{\text{cap}}$) in full-resolution pixels.
        public let capHeightPixels: Double?
        /// Measurement confidence score in `[0, 1]`.
        public let confidence: Double

        /// Creates a glyph scale descriptor in full-resolution source pixels.
        /// - Parameters:
        ///   - xHeightPixels: Lowercase $x$-height in pixels.
        ///   - strokeWidthPixels: Vertical stem stroke width in pixels.
        ///   - capHeightPixels: Optional capital/ascender height in pixels.
        ///   - confidence: Measurement confidence in `[0, 1]` (default: `1.0`).
        public init(
            xHeightPixels: Double,
            strokeWidthPixels: Double,
            capHeightPixels: Double? = nil,
            confidence: Double = 1.0
        ) {
            self.xHeightPixels = xHeightPixels
            self.strokeWidthPixels = strokeWidthPixels
            self.capHeightPixels = capHeightPixels
            self.confidence = min(1.0, max(0.0, confidence))
        }

        /// Creates a glyph scale descriptor from `FontScaleAnalyzer.PageGlyphMetrics`, optionally scaled
        /// when metrics were measured on a downsampled probe raster.
        /// - Parameters:
        ///   - metrics: Measured typographic page metrics.
        ///   - scaleFactor: Multiplicative pixel coordinate ratio from the analyzed bitmap to the target buffer (default: `1.0`).
        public init(metrics: FontScaleAnalyzer.PageGlyphMetrics, scaleFactor: Double = 1.0) {
            let s = (scaleFactor.isFinite && scaleFactor > 0.0) ? scaleFactor : 1.0
            self.init(
                xHeightPixels: metrics.xHeightPixels * s,
                strokeWidthPixels: metrics.strokeWidthPixels * s,
                capHeightPixels: metrics.capHeightPixels * s,
                confidence: metrics.confidence
            )
        }
    }

    /// Concrete full-resolution and downsampled filter parameters resolved for a specific page buffer.
    public struct DerivedKernelParameters: Sendable, Equatable, Codable {
        /// Morphological closing radius $R_{\text{closing}}$ in full-resolution source pixels.
        public let fullResolutionClosingRadius: Int
        /// Gaussian smoothing standard deviation $\sigma_{\text{full}}$ in full-resolution source pixels.
        public let fullResolutionBlurSigma: Double
        /// Effective block area-average downsampling factor $F \ge 1$ used for background estimation.
        public let effectiveDownsampleFactor: Int
        /// Morphological dilation radius on the downsampled background grid.
        public let downsampledClosingRadius: Int
        /// Morphological erosion radius on the downsampled background grid.
        public let downsampledErosionRadius: Int
        /// Gaussian blur $\sigma$ applied on the downsampled background grid.
        public let downsampledBlurSigma: Double
        /// `true` when valid glyph-scale measurements drove kernel derivation; `false` when DPI fallback was used.
        public let usedGlyphScale: Bool
        /// Resolved glyph scale associated with this page (if measured or supplied).
        public let resolvedGlyphScale: GlyphScale?
        /// `true` when Pass 2 foreground-masked residual background quotient division was executed.
        public let dualPassApplied: Bool
        /// Gaussian smoothing $\sigma$ applied on the downsampled grid during Pass 2 residual estimation.
        public let secondPassDownsampledBlurSigma: Double
        /// `true` when anti-starvation foreground contrast leveling actively boosted low-contrast regions.
        public let contrastLevelingApplied: Bool
        /// Maximum regional foreground absorption gain ($\ge 1.0$) applied during normalization.
        public let peakContrastGain: Double

        /// Creates a derived kernel parameter record.
        public init(
            fullResolutionClosingRadius: Int,
            fullResolutionBlurSigma: Double,
            effectiveDownsampleFactor: Int,
            downsampledClosingRadius: Int,
            downsampledErosionRadius: Int,
            downsampledBlurSigma: Double,
            usedGlyphScale: Bool,
            resolvedGlyphScale: GlyphScale?,
            dualPassApplied: Bool = false,
            secondPassDownsampledBlurSigma: Double = 0.0,
            contrastLevelingApplied: Bool = false,
            peakContrastGain: Double = 1.0
        ) {
            self.fullResolutionClosingRadius = fullResolutionClosingRadius
            self.fullResolutionBlurSigma = fullResolutionBlurSigma
            self.effectiveDownsampleFactor = effectiveDownsampleFactor
            self.downsampledClosingRadius = downsampledClosingRadius
            self.downsampledErosionRadius = downsampledErosionRadius
            self.downsampledBlurSigma = downsampledBlurSigma
            self.usedGlyphScale = usedGlyphScale
            self.resolvedGlyphScale = resolvedGlyphScale
            self.dualPassApplied = dualPassApplied
            self.secondPassDownsampledBlurSigma = max(0.0, secondPassDownsampledBlurSigma)
            self.contrastLevelingApplied = contrastLevelingApplied
            self.peakContrastGain = max(1.0, peakContrastGain)
        }

        private enum CodingKeys: String, CodingKey {
            case fullResolutionClosingRadius
            case fullResolutionBlurSigma
            case effectiveDownsampleFactor
            case downsampledClosingRadius
            case downsampledErosionRadius
            case downsampledBlurSigma
            case usedGlyphScale
            case resolvedGlyphScale
            case dualPassApplied
            case secondPassDownsampledBlurSigma
            case contrastLevelingApplied
            case peakContrastGain
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                fullResolutionClosingRadius: try c.decode(Int.self, forKey: .fullResolutionClosingRadius),
                fullResolutionBlurSigma: try c.decode(Double.self, forKey: .fullResolutionBlurSigma),
                effectiveDownsampleFactor: try c.decode(Int.self, forKey: .effectiveDownsampleFactor),
                downsampledClosingRadius: try c.decode(Int.self, forKey: .downsampledClosingRadius),
                downsampledErosionRadius: try c.decode(Int.self, forKey: .downsampledErosionRadius),
                downsampledBlurSigma: try c.decode(Double.self, forKey: .downsampledBlurSigma),
                usedGlyphScale: try c.decode(Bool.self, forKey: .usedGlyphScale),
                resolvedGlyphScale: try c.decodeIfPresent(GlyphScale.self, forKey: .resolvedGlyphScale),
                dualPassApplied: try c.decodeIfPresent(Bool.self, forKey: .dualPassApplied) ?? false,
                secondPassDownsampledBlurSigma: try c.decodeIfPresent(Double.self, forKey: .secondPassDownsampledBlurSigma) ?? 0.0,
                contrastLevelingApplied: try c.decodeIfPresent(Bool.self, forKey: .contrastLevelingApplied) ?? false,
                peakContrastGain: try c.decodeIfPresent(Double.self, forKey: .peakContrastGain) ?? 1.0
            )
        }
    }

    /// Result of background estimation or normalization paired with the resolved kernel telemetry.
    public struct NormalizationResult: Sendable, Equatable {
        /// Resulting background luminance map or illumination-normalized grayscale buffer.
        public let buffer: GrayscaleBuffer
        /// Kernel radii, Gaussian sigmas, and glyph-scale telemetry used during filtering.
        public let parameters: DerivedKernelParameters

        /// Creates a normalization result.
        public init(buffer: GrayscaleBuffer, parameters: DerivedKernelParameters) {
            self.buffer = buffer
            self.parameters = parameters
        }
    }

    /// Configuration parameters for background illumination normalization.
    public struct Configuration: Sendable, Equatable, Codable {
        /// Base downsampling factor for background estimation at standard 300–600 DPI scales (default: `4`).
        /// Automatically expanded proportionally when oversized glyphs produce large closing radii so
        /// downsampled morphological and Gaussian kernels stay compact and free of truncation.
        public var downsampleFactor: Int

        /// Morphological closing kernel radius in pixels at 300 DPI (`10 pt` reference prose, default: `24`).
        /// Used directly as the DPI-proportional fallback and as the reference scale anchor for glyph multipliers.
        public var referenceClosingRadiusAt300DPI: Int

        /// Reference Gaussian blur sigma applied on the `downsampleFactor` grid at 300 DPI (default: `3.0`,
        /// corresponding to `12.0 px` full-resolution smoothing at `downsampleFactor = 4`).
        public var downsampledBlurSigma: Double

        /// Minimum allowed background luminance divisor `[1, 255]` to avoid amplifying deep black borders
        /// into high-contrast static noise.
        public var minimumBackgroundDivisor: UInt8

        /// Blend strength in `[0.0, 1.0]` between original (`0.0`) and fully normalized (`1.0`) image.
        public var strength: Double

        /// Whether to dynamically scale $R_{\text{closing}}$ and Gaussian $\sigma$ to character $x$-height
        /// and vertical stem stroke width rather than assuming fixed 300/600 DPI typography (default: `true`).
        public var enableGlyphScaleAdaptation: Bool

        /// Multiplier relating character $x$-height ($H_x$) to full-resolution closing radius $R_{\text{closing}}$
        /// at default `referenceClosingRadiusAt300DPI = 24` (default: `1.25`, yielding `25 px` for `20 px` 300-DPI prose).
        public var closingRadiusXHeightMultiplier: Double

        /// Multiplier relating vertical stem stroke thickness ($W_{\text{stroke}}$) to full-resolution closing radius
        /// $R_{\text{closing}}$ at default `referenceClosingRadiusAt300DPI = 24` (default: `6.25`).
        public var closingRadiusStrokeWidthMultiplier: Double

        /// Minimum `GlyphScale.confidence` in `[0, 1]` required to drive dynamic glyph-scale kernel sizing (default: `0.35`).
        public var minimumGlyphConfidence: Double

        /// Whether to execute Pass 2 foreground-masked residual background quotient division so dense text
        /// blocks never depress the paper estimate and steep boundary spine shadows flatten cleanly (default: `true`).
        public var enableDualPassFlattening: Bool

        /// Ratio `[0.25, 2.0]` scaling Pass 2's foreground-masked Gaussian $\sigma_2$ relative to Pass 1's
        /// `downsampledBlurSigma` (default: `0.65`).
        public var secondPassBlurSigmaScale: Double

        /// Whether to harmonize low-frequency foreground ink absorption across glare-veiled or compressed-contrast
        /// camera regions so stroke weight stays uniform across the page (default: `true`).
        public var enableAntiStarvationContrastLeveling: Bool

        /// Maximum regional foreground contrast gain `[1.0, 3.5]` applied above the paper noise gate (default: `2.50`).
        public var maximumContrastGain: Double

        /// Creates a background normalization configuration.
        public init(
            downsampleFactor: Int = 4,
            referenceClosingRadiusAt300DPI: Int = 24,
            downsampledBlurSigma: Double = 3.0,
            minimumBackgroundDivisor: UInt8 = 32,
            strength: Double = 1.0,
            enableGlyphScaleAdaptation: Bool = true,
            closingRadiusXHeightMultiplier: Double = 1.25,
            closingRadiusStrokeWidthMultiplier: Double = 6.25,
            minimumGlyphConfidence: Double = 0.35,
            enableDualPassFlattening: Bool = true,
            secondPassBlurSigmaScale: Double = 0.65,
            enableAntiStarvationContrastLeveling: Bool = true,
            maximumContrastGain: Double = 2.50
        ) {
            self.downsampleFactor = max(1, downsampleFactor)
            self.referenceClosingRadiusAt300DPI = max(2, referenceClosingRadiusAt300DPI)
            self.downsampledBlurSigma = max(0.0, downsampledBlurSigma)
            self.minimumBackgroundDivisor = max(1, minimumBackgroundDivisor)
            self.strength = min(1.0, max(0.0, strength))
            self.enableGlyphScaleAdaptation = enableGlyphScaleAdaptation
            self.closingRadiusXHeightMultiplier = max(0.60, min(4.0, closingRadiusXHeightMultiplier))
            self.closingRadiusStrokeWidthMultiplier = max(2.0, min(16.0, closingRadiusStrokeWidthMultiplier))
            self.minimumGlyphConfidence = max(0.10, min(0.95, minimumGlyphConfidence))
            self.enableDualPassFlattening = enableDualPassFlattening
            self.secondPassBlurSigmaScale = max(0.25, min(2.0, secondPassBlurSigmaScale))
            self.enableAntiStarvationContrastLeveling = enableAntiStarvationContrastLeveling
            self.maximumContrastGain = max(1.0, min(3.5, maximumContrastGain))
        }

        private enum CodingKeys: String, CodingKey {
            case downsampleFactor
            case referenceClosingRadiusAt300DPI
            case downsampledBlurSigma
            case minimumBackgroundDivisor
            case strength
            case enableGlyphScaleAdaptation
            case closingRadiusXHeightMultiplier
            case closingRadiusStrokeWidthMultiplier
            case minimumGlyphConfidence
            case enableDualPassFlattening
            case secondPassBlurSigmaScale
            case enableAntiStarvationContrastLeveling
            case maximumContrastGain
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                downsampleFactor: try c.decodeIfPresent(Int.self, forKey: .downsampleFactor) ?? 4,
                referenceClosingRadiusAt300DPI: try c.decodeIfPresent(Int.self, forKey: .referenceClosingRadiusAt300DPI) ?? 24,
                downsampledBlurSigma: try c.decodeIfPresent(Double.self, forKey: .downsampledBlurSigma) ?? 3.0,
                minimumBackgroundDivisor: try c.decodeIfPresent(UInt8.self, forKey: .minimumBackgroundDivisor) ?? 32,
                strength: try c.decodeIfPresent(Double.self, forKey: .strength) ?? 1.0,
                enableGlyphScaleAdaptation: try c.decodeIfPresent(Bool.self, forKey: .enableGlyphScaleAdaptation) ?? true,
                closingRadiusXHeightMultiplier: try c.decodeIfPresent(Double.self, forKey: .closingRadiusXHeightMultiplier) ?? 1.25,
                closingRadiusStrokeWidthMultiplier: try c.decodeIfPresent(Double.self, forKey: .closingRadiusStrokeWidthMultiplier) ?? 6.25,
                minimumGlyphConfidence: try c.decodeIfPresent(Double.self, forKey: .minimumGlyphConfidence) ?? 0.35,
                enableDualPassFlattening: try c.decodeIfPresent(Bool.self, forKey: .enableDualPassFlattening) ?? true,
                secondPassBlurSigmaScale: try c.decodeIfPresent(Double.self, forKey: .secondPassBlurSigmaScale) ?? 0.65,
                enableAntiStarvationContrastLeveling: try c.decodeIfPresent(Bool.self, forKey: .enableAntiStarvationContrastLeveling) ?? true,
                maximumContrastGain: try c.decodeIfPresent(Double.self, forKey: .maximumContrastGain) ?? 2.50
            )
        }
    }

    /// Configuration used by this normalizer instance.
    public let configuration: Configuration

    /// Initializes a background normalizer with the given configuration.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Dynamic Kernel Radius & Sigma Derivation

    /// Derives full-resolution and downsampled morphological closing radii and Gaussian smoothing sigmas
    /// from optional measured glyph geometry (`xHeightPixels`, `strokeWidthPixels`, `capHeightPixels`)
    /// with safe fallback to DPI-proportional defaults.
    /// - Parameters:
    ///   - imageWidth: Source buffer width in pixels.
    ///   - imageHeight: Source buffer height in pixels.
    ///   - dpi: Declared resolution of the source buffer in DPI.
    ///   - glyphScale: Optional measured or caller-provided glyph scale in source pixels.
    /// - Returns: Resolved `DerivedKernelParameters`.
    public func deriveKernelParameters(
        imageWidth: Int,
        imageHeight: Int,
        dpi: Int,
        glyphScale: GlyphScale? = nil
    ) -> DerivedKernelParameters {
        let minDim = max(1, min(imageWidth, imageHeight))
        let maxDim = max(1, max(imageWidth, imageHeight))

        let refRadius300 = Double(configuration.referenceClosingRadiusAt300DPI)
        let userRadiusScale = refRadius300 / 24.0
        let refFullSigmaAt300 = Double(configuration.downsampleFactor) * configuration.downsampledBlurSigma

        // When no glyph text is present on a high-resolution image wrapped with a 72/96-DPI tag
        // (e.g. an uncalibrated camera photo of an illustration plate), elevate the fallback DPI
        // to `nominalProbeDPI` so linework is not eroded by a tiny 6-px closing kernel.
        let effectiveFallbackDPI: Int
        if configuration.enableGlyphScaleAdaptation && dpi <= 96 && maxDim >= 1800 {
            let isLikelySpread = Double(imageWidth) > Double(imageHeight) * 1.15
            let nominal = FontScaleAnalyzer.nominalProbeDPI(
                forPixelSize: Size2I(width: max(1, imageWidth), height: max(1, imageHeight)),
                isLikelySpread: isLikelySpread
            )
            effectiveFallbackDPI = max(72, max(dpi, nominal))
        } else {
            effectiveFallbackDPI = max(72, dpi)
        }

        let dpiScale = Double(effectiveFallbackDPI) / 300.0
        let dpiRadius = max(2.0, refRadius300 * dpiScale)

        let fullResClosingRadius: Int
        let usedGlyphScale: Bool
        let acceptedGlyphScale: GlyphScale?

        if configuration.enableGlyphScaleAdaptation,
           let gs = glyphScale,
           gs.confidence >= configuration.minimumGlyphConfidence,
           gs.xHeightPixels.isFinite, gs.xHeightPixels >= 3.0,
           gs.strokeWidthPixels.isFinite, gs.strokeWidthPixels >= 1.0
        {
            let xRadius = configuration.closingRadiusXHeightMultiplier * userRadiusScale * gs.xHeightPixels
            let strokeRadius = configuration.closingRadiusStrokeWidthMultiplier * userRadiusScale * gs.strokeWidthPixels
            let capRadius: Double
            if let capH = gs.capHeightPixels, capH.isFinite, capH > 0.0 {
                capRadius = 0.85 * userRadiusScale * capH
            } else {
                capRadius = 0.0
            }

            let rawGlyphRadius = max(xRadius, max(strokeRadius, capRadius))
            let minAllowedRadius = (gs.confidence < 0.55)
                ? max(4.0, 0.50 * dpiRadius)
                : 4.0
            let maxAllowedRadius = max(minAllowedRadius, Double(minDim) * 0.35)
            let clamped = min(maxAllowedRadius, max(minAllowedRadius, rawGlyphRadius))

            fullResClosingRadius = max(2, Int(clamped.rounded()))
            usedGlyphScale = true
            acceptedGlyphScale = gs
        } else {
            let maxFallback = max(2.0, Double(minDim) * 0.45)
            fullResClosingRadius = max(2, Int(min(maxFallback, dpiRadius).rounded()))
            usedGlyphScale = false
            acceptedGlyphScale = nil
        }

        let fullResBlurSigma: Double
        if configuration.downsampledBlurSigma > 0.0 {
            fullResBlurSigma = refFullSigmaAt300 * (Double(fullResClosingRadius) / max(1.0, refRadius300))
        } else {
            fullResBlurSigma = 0.0
        }

        // Scale the pyramid downsample factor proportionally when `fullResClosingRadius` grows large
        // so `downsampledClosingRadius` stays around ~6..13 px (preserving pure inter-line paper blocks
        // since `effectiveFactor <= R_closing / 12 ≈ 0.10 * H_x`) and `downsampledBlurSigma` never
        // saturates the 64-tap Gaussian convolution kernel cap.
        let baseFactor = configuration.downsampleFactor
        let effectiveFactor: Int
        if baseFactor > 1 {
            let targetSmallRadius = max(6, 3 * baseFactor)
            let dynamicFactor = max(baseFactor, fullResClosingRadius / targetSmallRadius)
            effectiveFactor = max(1, min(minDim, dynamicFactor))
        } else {
            effectiveFactor = 1
        }

        let smallClosingRadius = max(1, (fullResClosingRadius + effectiveFactor - 1) / effectiveFactor)
        let smallErosionRadius = max(1, smallClosingRadius - 1)
        let smallBlurSigma = fullResBlurSigma > 0.0
            ? min(20.0, fullResBlurSigma / Double(effectiveFactor))
            : 0.0

        return DerivedKernelParameters(
            fullResolutionClosingRadius: fullResClosingRadius,
            fullResolutionBlurSigma: fullResBlurSigma,
            effectiveDownsampleFactor: effectiveFactor,
            downsampledClosingRadius: smallClosingRadius,
            downsampledErosionRadius: smallErosionRadius,
            downsampledBlurSigma: smallBlurSigma,
            usedGlyphScale: usedGlyphScale,
            resolvedGlyphScale: acceptedGlyphScale
        )
    }

    /// Estimates typographic character $x$-height and vertical stem stroke width directly from a
    /// grayscale page buffer without invoking morphological background closing.
    ///
    /// Uses a compact area-averaged probe (`<= 1600 px` longest side) paired with an $O(1)$ integral-image
    /// Sauvola pre-binarization whose window spans `12%` of the page's shorter dimension—wide enough to avoid
    /// hollowing out thick camera/display strokes while remaining unbiased across linear lighting gradients.
    /// - Parameters:
    ///   - source: Input grayscale image.
    ///   - accelerator: Compute accelerator used for integral-image construction.
    /// - Returns: Measured `GlyphScale` in `source` pixel coordinates, or `nil` on blank/non-text pages.
    public func estimateGlyphScale(
        in source: borrowing GrayscaleBuffer,
        accelerator: any ComputeAccelerator
    ) -> GlyphScale? {
        guard source.width >= 32, source.height >= 32 else { return nil }

        let maxDim = max(source.width, source.height)
        let minDim = min(source.width, source.height)
        let rawFactor = max(1, (maxDim + 1599) / 1600)
        let maxSafeFactor = max(1, minDim / 64)
        let probeFactor = min(rawFactor, maxSafeFactor)

        let probeGray = Self.downsampleAreaAverage(source, factor: probeFactor)
        guard probeGray.width >= 32, probeGray.height >= 32 else { return nil }

        // Fast contrast check: skip integral image & connected components on blank/uniform sheets.
        var minLum: UInt8 = 255
        var maxLum: UInt8 = 0
        probeGray.pixels.withUnsafeBufferPointer { ptr in
            for v in ptr {
                if v < minLum { minLum = v }
                if v > maxLum { maxLum = v }
            }
        }
        guard Int(maxLum) - Int(minLum) >= 12 else { return nil }

        let integral = accelerator.integralImage(of: probeGray)
        let probeWindowRadius = max(
            12,
            Int((0.06 * Double(min(probeGray.width, probeGray.height))).rounded())
        )
        let probeBinary = AdaptiveBinarizer.binarizeSauvolaExplicitRadius(
            source: probeGray,
            integral: integral,
            radius: probeWindowRadius,
            k: 0.20,
            dynamicRange: 128.0,
            minDelta: 8.0,
            whiteCeiling: 250
        )

        let invScaleX = Double(source.width) / Double(max(1, probeGray.width))
        let invScaleY = Double(source.height) / Double(max(1, probeGray.height))
        let invScale = 0.5 * (invScaleX + invScaleY)
        let probeDeclaredDPI = max(72, Int((Double(max(72, source.dpi)) / max(1e-6, invScale)).rounded()))

        // Allow up to 20% component height / 30% width so zoomed-in camera crops and display titles are captured.
        let probeAnalyzer = FontScaleAnalyzer(
            configuration: FontScaleAnalyzer.Configuration(
                maxComponentHeightFraction: 0.20,
                maxComponentWidthFraction: 0.30
            )
        )
        guard let metrics = probeAnalyzer.analyzePage(
            in: probeBinary,
            declaredDPI: probeDeclaredDPI,
            ocrObservations: []
        ) else {
            return nil
        }

        return GlyphScale(metrics: metrics, scaleFactor: invScale)
    }

    // MARK: - Background Estimation & Illumination Normalization

    /// Estimates the low-frequency background illumination map at the full resolution of `source`,
    /// returning both the reconstructed background buffer and the resolved kernel parameters.
    /// - Parameters:
    ///   - source: Input grayscale image.
    ///   - accelerator: Compute accelerator used for integral-image probing and Gaussian smoothing.
    ///   - glyphScale: Optional pre-measured glyph scale in `source` pixel coordinates. When `nil` and
    ///     `configuration.enableGlyphScaleAdaptation` is `true`, glyph scale is estimated automatically.
    /// - Returns: A `NormalizationResult` containing the background luminance buffer and kernel telemetry.
    public func estimateBackgroundWithTelemetry(
        for source: borrowing GrayscaleBuffer,
        accelerator: any ComputeAccelerator,
        glyphScale: GlyphScale? = nil
    ) -> NormalizationResult {
        guard source.width > 0, source.height > 0 else {
            let emptyParams = deriveKernelParameters(
                imageWidth: source.width,
                imageHeight: source.height,
                dpi: source.dpi,
                glyphScale: glyphScale
            )
            return NormalizationResult(
                buffer: GrayscaleBuffer(width: source.width, height: source.height, dpi: source.dpi),
                parameters: emptyParams
            )
        }

        let resolved = computeResolvedSmallFields(
            for: source,
            accelerator: accelerator,
            glyphScale: glyphScale,
            computeContrastGain: false
        )
        let background = Self.upsampleBilinearQ6ToUInt8(
            resolved.backgroundSmallQ6,
            smallWidth: resolved.gridWidth,
            smallHeight: resolved.gridHeight,
            targetWidth: source.width,
            targetHeight: source.height,
            dpi: source.dpi
        )
        return NormalizationResult(buffer: background, parameters: resolved.parameters)
    }

    /// Estimates the low-frequency background illumination map at the full resolution of `source`.
    /// - Parameters:
    ///   - source: Input grayscale image.
    ///   - accelerator: Compute accelerator used for Gaussian smoothing.
    ///   - glyphScale: Optional pre-measured glyph scale in `source` pixel coordinates.
    /// - Returns: A `GrayscaleBuffer` of the same dimensions as `source` representing the paper background luminance.
    public func estimateBackground(
        for source: borrowing GrayscaleBuffer,
        accelerator: any ComputeAccelerator,
        glyphScale: GlyphScale? = nil
    ) -> GrayscaleBuffer {
        estimateBackgroundWithTelemetry(
            for: source,
            accelerator: accelerator,
            glyphScale: glyphScale
        ).buffer
    }

    /// Normalizes the illumination of `source` by dividing out the estimated background surface,
    /// returning both the normalized image and the resolved kernel telemetry.
    /// - Parameters:
    ///   - source: Input grayscale image with potentially uneven lighting or spine shadows.
    ///   - accelerator: Compute accelerator used for Gaussian smoothing.
    ///   - glyphScale: Optional pre-measured glyph scale in `source` pixel coordinates.
    /// - Returns: A `NormalizationResult` containing the flattened grayscale buffer and kernel telemetry.
    public func normalizeWithTelemetry(
        _ source: borrowing GrayscaleBuffer,
        accelerator: any ComputeAccelerator,
        glyphScale: GlyphScale? = nil
    ) -> NormalizationResult {
        guard configuration.strength > 0.0, source.width > 0, source.height > 0 else {
            let passthroughParams = deriveKernelParameters(
                imageWidth: source.width,
                imageHeight: source.height,
                dpi: source.dpi,
                glyphScale: glyphScale
            )
            let copyBuffer = GrayscaleBuffer(
                width: source.width,
                height: source.height,
                dpi: source.dpi,
                pixels: source.pixels
            )
            return NormalizationResult(buffer: copyBuffer, parameters: passthroughParams)
        }

        let resolved = computeResolvedSmallFields(
            for: source,
            accelerator: accelerator,
            glyphScale: glyphScale,
            computeContrastGain: configuration.enableAntiStarvationContrastLeveling
        )

        let targetW = source.width
        let targetH = source.height
        let gridW = resolved.gridWidth
        let minDivisorQ6 = Int(max(1, configuration.minimumBackgroundDivisor)) << 6
        let blendMilli = Int((configuration.strength * 1024.0).rounded())

        var outPixels = ContiguousArray<UInt8>(repeating: 255, count: targetW * targetH)
        let xLUT = Self.makeBilinearAxisLUT(srcLength: gridW, targetLength: targetW)
        let yLUT = Self.makeBilinearAxisLUT(srcLength: resolved.gridHeight, targetLength: targetH)

        // Pass A: Unblended sub-gray-level background quotient `min(255, src * 255 / bgEff)`.
        source.pixels.withUnsafeBufferPointer { srcPtr in
            resolved.backgroundSmallQ6.withUnsafeBufferPointer { bgSmallPtr in
                xLUT.i0.withUnsafeBufferPointer { x0Ptr in
                    xLUT.i1.withUnsafeBufferPointer { x1Ptr in
                        xLUT.frac.withUnsafeBufferPointer { fxPtr in
                            outPixels.withUnsafeMutableBufferPointer { dstPtr in
                                for y in 0..<targetH {
                                    let row0 = yLUT.i0[y] * gridW
                                    let row1 = yLUT.i1[y] * gridW
                                    let fy = yLUT.frac[y]
                                    let invFy = 256 - fy
                                    let dstRow = y * targetW

                                    for x in 0..<targetW {
                                        let x0 = x0Ptr[x]
                                        let x1 = x1Ptr[x]
                                        let fx = fxPtr[x]
                                        let invFx = 256 - fx

                                        let bTop = bgSmallPtr[row0 + x0] * invFx + bgSmallPtr[row0 + x1] * fx
                                        let bBot = bgSmallPtr[row1 + x0] * invFx + bgSmallPtr[row1 + x1] * fx
                                        let bgQ6 = max((bTop * invFy + bBot * fy + 32768) >> 16, minDivisorQ6)

                                        // 16320 == 255 * 64 (matches Q6 background fixed-point scaling)
                                        let s = Int(srcPtr[dstRow + x])
                                        dstPtr[dstRow + x] = UInt8(min(255, (s * 16320 + (bgQ6 >> 1)) / bgQ6))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Pass B: Anti-starvation contrast leveling (multiplicative absorption gain, ink-anchored gate).
        if let gainSmallQ8 = resolved.contrastGainSmallQ8 {
            Self.applyContrastLeveling(
                to: &outPixels,
                width: targetW,
                height: targetH,
                gainSmallQ8: gainSmallQ8,
                gridWidth: gridW,
                xLUT: xLUT,
                yLUT: yLUT
            )
        }

        // Pass C: Optional `strength` blend between the original and fully normalized image.
        if blendMilli < 1024 {
            source.pixels.withUnsafeBufferPointer { srcPtr in
                outPixels.withUnsafeMutableBufferPointer { dstPtr in
                    for i in 0..<(targetW * targetH) {
                        let s = Int(srcPtr[i])
                        let blended = ((1024 - blendMilli) * s + blendMilli * Int(dstPtr[i]) + 512) >> 10
                        dstPtr[i] = UInt8(min(255, max(0, blended)))
                    }
                }
            }
        }

        let normalizedBuffer = GrayscaleBuffer(
            width: targetW,
            height: targetH,
            dpi: source.dpi,
            pixels: outPixels
        )
        return NormalizationResult(buffer: normalizedBuffer, parameters: resolved.parameters)
    }

    /// Normalizes the illumination of `source` by dividing out the estimated background surface.
    /// - Parameters:
    ///   - source: Input grayscale image with potentially uneven lighting or spine shadows.
    ///   - accelerator: Compute accelerator used for Gaussian smoothing.
    ///   - glyphScale: Optional pre-measured glyph scale in `source` pixel coordinates.
    /// - Returns: Illumination-normalized `GrayscaleBuffer` where paper background is flattened toward `255`.
    public func normalize(
        _ source: borrowing GrayscaleBuffer,
        accelerator: any ComputeAccelerator,
        glyphScale: GlyphScale? = nil
    ) -> GrayscaleBuffer {
        normalizeWithTelemetry(
            source,
            accelerator: accelerator,
            glyphScale: glyphScale
        ).buffer
    }

    // MARK: - Dual-Pass Surface & Contrast Leveling Engine

    private struct ResolvedSmallFields {
        let gridWidth: Int
        let gridHeight: Int
        let backgroundSmallQ6: ContiguousArray<Int>
        let contrastGainSmallQ8: ContiguousArray<Int>?
        let parameters: DerivedKernelParameters
    }

    private func computeResolvedSmallFields(
        for source: borrowing GrayscaleBuffer,
        accelerator: any ComputeAccelerator,
        glyphScale: GlyphScale?,
        computeContrastGain: Bool
    ) -> ResolvedSmallFields {
        let candidateGlyphScale: GlyphScale?
        if let explicitScale = glyphScale {
            candidateGlyphScale = explicitScale
        } else if configuration.enableGlyphScaleAdaptation {
            candidateGlyphScale = estimateGlyphScale(in: source, accelerator: accelerator)
        } else {
            candidateGlyphScale = nil
        }

        let baseParams = deriveKernelParameters(
            imageWidth: source.width,
            imageHeight: source.height,
            dpi: source.dpi,
            glyphScale: candidateGlyphScale
        )

        let factor = baseParams.effectiveDownsampleFactor
        let small = Self.downsampleAreaAverage(source, factor: factor)
        let w1 = small.width
        let h1 = small.height

        // Pass 1: Morphological closing (dilation followed by erosion) erases dark ink valleys
        // narrower than 2 * downsampledClosingRadius while remaining unbiased on linear ramps.
        let dilated = Self.grayscaleDilateSeparable(small, radius: baseParams.downsampledClosingRadius)
        let closed = Self.grayscaleErodeSeparable(dilated, radius: baseParams.downsampledErosionRadius)

        let smoothed1: GrayscaleBuffer
        if baseParams.downsampledBlurSigma > 0.05 && w1 > 2 && h1 > 2 {
            smoothed1 = accelerator.gaussianBlur(closed, sigma: baseParams.downsampledBlurSigma)
        } else {
            smoothed1 = closed
        }

        let cellCount = w1 * h1
        guard configuration.enableDualPassFlattening,
              source.width >= 16, source.height >= 16,
              w1 >= 2, h1 >= 2
        else {
            var bgQ6 = ContiguousArray<Int>(repeating: 16320, count: cellCount)
            smoothed1.pixels.withUnsafeBufferPointer { p1 in
                bgQ6.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<cellCount {
                        dst[i] = max(64, Int(p1[i]) << 6)
                    }
                }
            }
            return ResolvedSmallFields(
                gridWidth: w1,
                gridHeight: h1,
                backgroundSmallQ6: bgQ6,
                contrastGainSmallQ8: nil,
                parameters: baseParams
            )
        }

        // Reconstruct full-resolution Pass 1 background to evaluate unclipped Pass 1 quotients Q_1.
        let bgPass1: GrayscaleBuffer
        if factor == 1 && w1 == source.width && h1 == source.height {
            bgPass1 = smoothed1
        } else {
            bgPass1 = Self.upsampleBilinear(
                smoothed1,
                targetWidth: source.width,
                targetHeight: source.height,
                dpi: source.dpi
            )
        }

        // Determine lit-paper sanity reference (85th percentile of Pass 1 background) so dark non-paper
        // border blocks (< 22% of lit paper) are never mistaken for exposed white paper.
        var bgHist = [Int](repeating: 0, count: 256)
        smoothed1.pixels.withUnsafeBufferPointer { p1 in
            for i in 0..<cellCount {
                bgHist[Int(p1[i])] += 1
            }
        }
        let targetLitRank = max(1, (cellCount * 85) / 100)
        var cumBg = 0
        var litPaperRef = 235
        for lum in 0..<256 {
            cumBg += bgHist[lum]
            if cumBg >= targetLitRank {
                litPaperRef = lum
                break
            }
        }

        let minDivisor = Int(max(1, configuration.minimumBackgroundDivisor))
        let rawPaperFloor = max(minDivisor, min(96, Int((Double(litPaperRef) * 0.22).rounded())))
        let srcW = source.width
        let srcH = source.height
        let fullPixelCount = srcW * srcH

        // Precompute unclipped Pass 1 quotient Q_1 (`255` = `1.0x` Pass 1 background; capped at `1020` = `4.0x`)
        // in a single linear scan so subsequent tile passes perform zero redundant divisions.
        var q1Full = ContiguousArray<UInt16>(repeating: 255, count: fullPixelCount)
        source.pixels.withUnsafeBufferPointer { srcPtr in
            bgPass1.pixels.withUnsafeBufferPointer { bg1Ptr in
                q1Full.withUnsafeMutableBufferPointer { q1Ptr in
                    for i in 0..<fullPixelCount {
                        let s = Int(srcPtr[i])
                        let b1 = max(Int(bg1Ptr[i]), minDivisor)
                        q1Ptr[i] = UInt16(min(1020, (s * 255 + (b1 >> 1)) / b1))
                    }
                }
            }
        }

        // Step 2a: Compute a spike-immune, mode-seeking per-block crest of unclipped Pass 1 quotient Q_1:
        // two successive trimmed upper means (`q1 >= 15/16 * current`) re-centre on the bright paper mode,
        // so soft optical-PSF stroke skirts in dense text cannot drag the crest (and paper gate) down,
        // while a lone sharpening spike is still diluted by the surrounding paper pixels.
        var upperQ1 = ContiguousArray<UInt16>(repeating: 255, count: cellCount)
        q1Full.withUnsafeBufferPointer { q1Ptr in
            upperQ1.withUnsafeMutableBufferPointer { upPtr in
                for dy in 0..<h1 {
                    let y0 = dy * factor
                    let y1 = min(srcH, y0 + factor)
                    let cellRow = dy * w1

                    for dx in 0..<w1 {
                        let x0 = dx * factor
                        let x1 = min(srcW, x0 + factor)
                        let area = max(1, (y1 - y0) * (x1 - x0))

                        var sumQ1 = 0
                        for sy in y0..<y1 {
                            let rowOff = sy * srcW
                            for sx in x0..<x1 {
                                sumQ1 += Int(q1Ptr[rowOff + sx])
                            }
                        }
                        let meanQ1 = sumQ1 / area

                        if area >= 4 {
                            var crest = meanQ1
                            for _ in 0..<2 {
                                let cut = (crest * 15) >> 4
                                var upSum = 0
                                var upCnt = 0
                                for sy in y0..<y1 {
                                    let rowOff = sy * srcW
                                    for sx in x0..<x1 {
                                        let q1 = Int(q1Ptr[rowOff + sx])
                                        if q1 >= cut {
                                            upSum += q1
                                            upCnt += 1
                                        }
                                    }
                                }
                                guard upCnt > 0 else { break }
                                crest = upSum / upCnt
                            }
                            upPtr[cellRow + dx] = UInt16(crest)
                        } else {
                            upPtr[cellRow + dx] = UInt16(meanQ1)
                        }
                    }
                }
            }
        }

        if factor == 1 && w1 >= 3 && h1 >= 3 {
            upperQ1 = Self.boxSmooth3x3UInt16(upperQ1, width: w1, height: h1)
        }

        // Step 2b: Slope-unbiased morphological closing (`closeSlopeAwareUInt16`) bridges narrow
        // ink-stem dips (`1..crestRadius` cells) while preserving monotonic spine-shadow and
        // camera-vignette ramps with zero upward slope bias right down to image boundaries!
        let crestRadius: Int
        if let gs = baseParams.resolvedGlyphScale {
            let strokeCells = Int(ceil(1.5 * gs.strokeWidthPixels / Double(max(1, factor))))
            crestRadius = max(1, min(max(2, baseParams.downsampledClosingRadius / 2), strokeCells))
        } else {
            crestRadius = max(1, min(3, max(1, baseParams.downsampledClosingRadius / 3)))
        }
        let localCrest = Self.closeSlopeAwareUInt16(upperQ1, width: w1, height: h1, radius: crestRadius)

        // Step 2c: Sample pure exposed paper Q_1 values (excluding ink cores and stroke halos)
        // and optionally measure cell stroke-core foreground Q_1 for anti-starvation contrast leveling.
        let wantContrast = computeContrastGain && configuration.maximumContrastGain > 1.001
        var rawB2 = ContiguousArray<Float>(repeating: 0.0, count: cellCount)
        var paperWeight = ContiguousArray<Float>(repeating: 0.0, count: cellCount)
        var fgCoreQ1 = ContiguousArray<Float>(repeating: 0.0, count: wantContrast ? cellCount : 0)
        var fgHasInk = ContiguousArray<Bool>(repeating: false, count: wantContrast ? cellCount : 0)

        source.pixels.withUnsafeBufferPointer { srcPtr in
            q1Full.withUnsafeBufferPointer { q1Ptr in
                localCrest.withUnsafeBufferPointer { crestPtr in
                    rawB2.withUnsafeMutableBufferPointer { rawB2Ptr in
                        paperWeight.withUnsafeMutableBufferPointer { pwPtr in
                            for dy in 0..<h1 {
                                let y0 = dy * factor
                                let y1 = min(srcH, y0 + factor)
                                let cellRow = dy * w1

                                for dx in 0..<w1 {
                                    let x0 = dx * factor
                                    let x1 = min(srcW, x0 + factor)
                                    let area = max(1, (y1 - y0) * (x1 - x0))
                                    let cellIdx = cellRow + dx

                                    let crest = Int(crestPtr[cellIdx])
                                    let paperMinQ1 = max(96, (crest * 88) / 100)
                                    let fgMaxQ1 = (crest * 78) / 100
                                    // Candidates in the soft skirt band [paperMinQ1, skirtBandQ1) are only
                                    // trusted as paper when no foreground pixel touches them: faint optical
                                    // PSF skirts of veiled strokes sit here and would bias B_2 low, whereas
                                    // smooth illumination ramps (spine, vignette) have no adjacent ink.
                                    let skirtBandQ1 = (crest * 96) / 100
                                    let minPaperPixels = max(1, area / 12)
                                    let minFgPixels = max(1, area / 16)

                                    var paperSum = 0
                                    var paperCnt = 0
                                    var fgSum = 0
                                    var fgCnt = 0

                                    for sy in y0..<y1 {
                                        let rowOff = sy * srcW
                                        for sx in x0..<x1 {
                                            let s = Int(srcPtr[rowOff + sx])
                                            let q1 = Int(q1Ptr[rowOff + sx])

                                            if s >= rawPaperFloor && q1 >= paperMinQ1 {
                                                if q1 < skirtBandQ1 && Self.touchesForeground(
                                                    q1Ptr,
                                                    x: sx,
                                                    y: sy,
                                                    width: srcW,
                                                    height: srcH,
                                                    foregroundMaxQ1: fgMaxQ1
                                                ) {
                                                    continue
                                                }
                                                paperSum += q1
                                                paperCnt += 1
                                            } else if wantContrast && q1 <= fgMaxQ1 {
                                                fgSum += q1
                                                fgCnt += 1
                                            }
                                        }
                                    }

                                    if paperCnt >= minPaperPixels {
                                        rawB2Ptr[cellIdx] = Float(paperSum) / Float(paperCnt)
                                        pwPtr[cellIdx] = 1.0
                                    }

                                    if wantContrast && fgCnt >= minFgPixels {
                                        let fgMean = fgSum / fgCnt
                                        var coreSum = 0
                                        var coreCnt = 0
                                        for sy in y0..<y1 {
                                            let rowOff = sy * srcW
                                            for sx in x0..<x1 {
                                                let q1 = Int(q1Ptr[rowOff + sx])
                                                if q1 <= fgMean && q1 <= fgMaxQ1 {
                                                    coreSum += q1
                                                    coreCnt += 1
                                                }
                                            }
                                        }
                                        fgCoreQ1[cellIdx] = coreCnt > 0
                                            ? (Float(coreSum) / Float(coreCnt))
                                            : (Float(fgSum) / Float(fgCnt))
                                        fgHasInk[cellIdx] = true
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Step 2d: Inpaint ink-covered cells and Gaussian-smooth pure-paper residual surface B_2.
        let sigma2 = baseParams.downsampledBlurSigma > 0.0
            ? max(1.25, baseParams.downsampledBlurSigma * configuration.secondPassBlurSigmaScale)
            : 0.0

        // Point-reflected boundaries keep B_2 unbiased on steep edge ramps (book-spine shadows,
        // vignette fall-off) instead of dragging the interior paper ratio into the boundary cells.
        let b2Small = Self.inpaintAndSmoothNormalized2D(
            values: rawB2,
            weights: paperWeight,
            width: w1,
            height: h1,
            sigma: sigma2,
            fallbackValue: 255.0,
            boundary: .linearExtrapolate
        )

        var bgSmallQ6 = ContiguousArray<Int>(repeating: 16320, count: cellCount)
        smoothed1.pixels.withUnsafeBufferPointer { p1 in
            b2Small.withUnsafeBufferPointer { b2 in
                bgSmallQ6.withUnsafeMutableBufferPointer { dst in
                    for i in 0..<cellCount {
                        let eff = min(255.0, max(1.0, (Float(p1[i]) * b2[i]) / 255.0))
                        dst[i] = max(64, min(16320, Int((eff * 64.0).rounded())))
                    }
                }
            }
        }

        // Step 2e: Anti-starvation macro foreground absorption harmonization.
        var resolvedGainSmallQ8: ContiguousArray<Int>? = nil
        var contrastApplied = false
        var peakGain = 1.0

        if wantContrast {
            var inkAbsValues = ContiguousArray<Float>(repeating: 0.0, count: cellCount)
            var inkAbsWeights = ContiguousArray<Float>(repeating: 0.0, count: cellCount)
            var absHist = [Int](repeating: 0, count: 256)
            var validInkCells = 0

            // Ink absorption is only trusted where it was measured against paper exposed in the same
            // cell, so dark desk strips, black scanner borders and photo plates (no paper samples) never
            // masquerade as crisp text and inflate the glare envelope of neighbouring veiled text.
            var inkBins = ContiguousArray<Int>(repeating: -1, count: cellCount)
            for i in 0..<cellCount where fgHasInk[i] && paperWeight[i] > 0.0 {
                let q2Ink = min(255.0, max(0.0, (fgCoreQ1[i] * 255.0) / max(1.0, b2Small[i])))
                let absVal = 255.0 - q2Ink
                if absVal >= 36.0 {
                    inkAbsValues[i] = absVal
                    inkAbsWeights[i] = 1.0
                    let bin = min(255, max(0, Int(absVal.rounded())))
                    inkBins[i] = bin
                    absHist[bin] += 1
                    validInkCells += 1
                }
            }

            // Reject non-text absorption outliers (e.g. desk/paper boundary cells) lying far beyond the
            // crisp text mode before measuring the envelope reference percentiles.
            let minRequiredInkCells = max(4, cellCount / 250)
            if validInkCells >= minRequiredInkCells {
                let outlierBin = Self.histogramPercentile(absHist, total: validInkCells, percent: 90) + 40
                if outlierBin < 255 {
                    for bin in (outlierBin + 1)..<256 {
                        validInkCells -= absHist[bin]
                        absHist[bin] = 0
                    }
                    for i in 0..<cellCount where inkBins[i] > outlierBin {
                        inkAbsValues[i] = 0.0
                        inkAbsWeights[i] = 0.0
                    }
                }
            }

            if validInkCells >= minRequiredInkCells {
                // Crisp reference: the 90th-percentile ink-core absorption (upper shoulder of the crisp
                // mode), so veiled strokes are lifted to the crisp stroke darkness rather than below it.
                let p10Abs = Float(Self.histogramPercentile(absHist, total: validInkCells, percent: 10))
                let p90Abs = Float(Self.histogramPercentile(absHist, total: validInkCells, percent: 90))
                let targetAbs = min(Float(175.0), max(Float(145.0), p90Abs))
                if p10Abs < targetAbs - 6.0 {
                    let glareSigma = max(6.0, 0.10 * Double(min(w1, h1)))
                    let smoothedAbs = Self.inpaintAndSmoothNormalized2D(
                        values: inkAbsValues,
                        weights: inkAbsWeights,
                        width: w1,
                        height: h1,
                        sigma: glareSigma,
                        fallbackValue: targetAbs
                    )

                    let maxGainFloat = Float(configuration.maximumContrastGain)
                    var gainQ8 = ContiguousArray<Int>(repeating: 256, count: cellCount)
                    var maxGainQ8Observed = 256

                    for i in 0..<cellCount {
                        // Veiling glare compresses absorption multiplicatively, so the gain that restores
                        // the veiled core envelope to the crisp reference is the plain ratio target / env.
                        let env = max(Float(28.0), smoothedAbs[i])
                        let rawGain: Float
                        if env + 2.0 < targetAbs {
                            rawGain = targetAbs / env
                        } else {
                            rawGain = 1.0
                        }
                        let g = min(maxGainFloat, max(Float(1.0), rawGain))
                        let gQ8 = max(256, Int((g * 256.0).rounded()))
                        gainQ8[i] = gQ8
                        if gQ8 > maxGainQ8Observed {
                            maxGainQ8Observed = gQ8
                        }
                    }

                    if maxGainQ8Observed > 260 {
                        resolvedGainSmallQ8 = gainQ8
                        contrastApplied = true
                        peakGain = Double(maxGainQ8Observed) / 256.0
                    }
                }
            }
        }

        let finalParams = DerivedKernelParameters(
            fullResolutionClosingRadius: baseParams.fullResolutionClosingRadius,
            fullResolutionBlurSigma: baseParams.fullResolutionBlurSigma,
            effectiveDownsampleFactor: baseParams.effectiveDownsampleFactor,
            downsampledClosingRadius: baseParams.downsampledClosingRadius,
            downsampledErosionRadius: baseParams.downsampledErosionRadius,
            downsampledBlurSigma: baseParams.downsampledBlurSigma,
            usedGlyphScale: baseParams.usedGlyphScale,
            resolvedGlyphScale: baseParams.resolvedGlyphScale,
            dualPassApplied: true,
            secondPassDownsampledBlurSigma: sigma2,
            contrastLevelingApplied: contrastApplied,
            peakContrastGain: peakGain
        )

        return ResolvedSmallFields(
            gridWidth: w1,
            gridHeight: h1,
            backgroundSmallQ6: bgSmallQ6,
            contrastGainSmallQ8: resolvedGainSmallQ8,
            parameters: finalParams
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

    /// Separable 2D grayscale dilation (sliding-window maximum) in $O(1)$ per pixel via van Herk / Gil-Werman.
    internal static func grayscaleDilateSeparable(
        _ buffer: borrowing GrayscaleBuffer,
        radius: Int
    ) -> GrayscaleBuffer {
        let w = buffer.width
        let h = buffer.height
        guard radius > 0, w > 0, h > 0 else {
            return GrayscaleBuffer(
                width: w,
                height: h,
                dpi: buffer.dpi,
                pixels: buffer.pixels
            )
        }

        let rx = min(radius, max(0, w - 1))
        let ry = min(radius, max(0, h - 1))
        var horizontal = ContiguousArray<UInt8>(repeating: 0, count: w * h)
        var vertical = ContiguousArray<UInt8>(repeating: 0, count: w * h)

        let maxPaddedLen = max(w + 2 * rx, h + 2 * ry)
        var padded = ContiguousArray<UInt8>(repeating: 0, count: maxPaddedLen)
        var prefix = ContiguousArray<UInt8>(repeating: 0, count: maxPaddedLen)
        var suffix = ContiguousArray<UInt8>(repeating: 0, count: maxPaddedLen)

        buffer.pixels.withUnsafeBufferPointer { srcPtr in
            horizontal.withUnsafeMutableBufferPointer { tmpPtr in
                padded.withUnsafeMutableBufferPointer { padPtr in
                    prefix.withUnsafeMutableBufferPointer { prePtr in
                        suffix.withUnsafeMutableBufferPointer { sufPtr in
                            if rx == 0 {
                                for i in 0..<(w * h) { tmpPtr[i] = srcPtr[i] }
                            } else {
                                let win = 2 * rx + 1
                                let len = w + 2 * rx
                                for i in 0..<rx { padPtr[i] = 0 }
                                for i in (rx + w)..<len { padPtr[i] = 0 }

                                for y in 0..<h {
                                    let row = y * w
                                    for x in 0..<w {
                                        padPtr[rx + x] = srcPtr[row + x]
                                    }

                                    var bStart = 0
                                    while bStart < len {
                                        let bEnd = min(len, bStart + win)
                                        var fwd = padPtr[bStart]
                                        prePtr[bStart] = fwd
                                        if bStart + 1 < bEnd {
                                            for k in (bStart + 1)..<bEnd {
                                                let v = padPtr[k]
                                                if v > fwd { fwd = v }
                                                prePtr[k] = fwd
                                            }
                                        }

                                        var bwd = padPtr[bEnd - 1]
                                        sufPtr[bEnd - 1] = bwd
                                        if bEnd - 1 > bStart {
                                            var k = bEnd - 2
                                            while k >= bStart {
                                                let v = padPtr[k]
                                                if v > bwd { bwd = v }
                                                sufPtr[k] = bwd
                                                k -= 1
                                            }
                                        }
                                        bStart += win
                                    }

                                    for x in 0..<w {
                                        let a = sufPtr[x]
                                        let b = prePtr[x + win - 1]
                                        tmpPtr[row + x] = a >= b ? a : b
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        horizontal.withUnsafeBufferPointer { tmpPtr in
            vertical.withUnsafeMutableBufferPointer { dstPtr in
                padded.withUnsafeMutableBufferPointer { padPtr in
                    prefix.withUnsafeMutableBufferPointer { prePtr in
                        suffix.withUnsafeMutableBufferPointer { sufPtr in
                            if ry == 0 {
                                for i in 0..<(w * h) { dstPtr[i] = tmpPtr[i] }
                            } else {
                                let win = 2 * ry + 1
                                let len = h + 2 * ry
                                for i in 0..<ry { padPtr[i] = 0 }
                                for i in (ry + h)..<len { padPtr[i] = 0 }

                                for x in 0..<w {
                                    for y in 0..<h {
                                        padPtr[ry + y] = tmpPtr[y * w + x]
                                    }

                                    var bStart = 0
                                    while bStart < len {
                                        let bEnd = min(len, bStart + win)
                                        var fwd = padPtr[bStart]
                                        prePtr[bStart] = fwd
                                        if bStart + 1 < bEnd {
                                            for k in (bStart + 1)..<bEnd {
                                                let v = padPtr[k]
                                                if v > fwd { fwd = v }
                                                prePtr[k] = fwd
                                            }
                                        }

                                        var bwd = padPtr[bEnd - 1]
                                        sufPtr[bEnd - 1] = bwd
                                        if bEnd - 1 > bStart {
                                            var k = bEnd - 2
                                            while k >= bStart {
                                                let v = padPtr[k]
                                                if v > bwd { bwd = v }
                                                sufPtr[k] = bwd
                                                k -= 1
                                            }
                                        }
                                        bStart += win
                                    }

                                    for y in 0..<h {
                                        let a = sufPtr[y]
                                        let b = prePtr[y + win - 1]
                                        dstPtr[y * w + x] = a >= b ? a : b
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return GrayscaleBuffer(width: w, height: h, dpi: buffer.dpi, pixels: vertical)
    }

    /// Separable 2D grayscale erosion (sliding-window minimum) in $O(1)$ per pixel via van Herk / Gil-Werman.
    internal static func grayscaleErodeSeparable(
        _ buffer: borrowing GrayscaleBuffer,
        radius: Int
    ) -> GrayscaleBuffer {
        let w = buffer.width
        let h = buffer.height
        guard radius > 0, w > 0, h > 0 else {
            return GrayscaleBuffer(
                width: w,
                height: h,
                dpi: buffer.dpi,
                pixels: buffer.pixels
            )
        }

        let rx = min(radius, max(0, w - 1))
        let ry = min(radius, max(0, h - 1))
        var horizontal = ContiguousArray<UInt8>(repeating: 255, count: w * h)
        var vertical = ContiguousArray<UInt8>(repeating: 255, count: w * h)

        let maxPaddedLen = max(w + 2 * rx, h + 2 * ry)
        var padded = ContiguousArray<UInt8>(repeating: 255, count: maxPaddedLen)
        var prefix = ContiguousArray<UInt8>(repeating: 255, count: maxPaddedLen)
        var suffix = ContiguousArray<UInt8>(repeating: 255, count: maxPaddedLen)

        buffer.pixels.withUnsafeBufferPointer { srcPtr in
            horizontal.withUnsafeMutableBufferPointer { tmpPtr in
                padded.withUnsafeMutableBufferPointer { padPtr in
                    prefix.withUnsafeMutableBufferPointer { prePtr in
                        suffix.withUnsafeMutableBufferPointer { sufPtr in
                            if rx == 0 {
                                for i in 0..<(w * h) { tmpPtr[i] = srcPtr[i] }
                            } else {
                                let win = 2 * rx + 1
                                let len = w + 2 * rx
                                for i in 0..<rx { padPtr[i] = 255 }
                                for i in (rx + w)..<len { padPtr[i] = 255 }

                                for y in 0..<h {
                                    let row = y * w
                                    for x in 0..<w {
                                        padPtr[rx + x] = srcPtr[row + x]
                                    }

                                    var bStart = 0
                                    while bStart < len {
                                        let bEnd = min(len, bStart + win)
                                        var fwd = padPtr[bStart]
                                        prePtr[bStart] = fwd
                                        if bStart + 1 < bEnd {
                                            for k in (bStart + 1)..<bEnd {
                                                let v = padPtr[k]
                                                if v < fwd { fwd = v }
                                                prePtr[k] = fwd
                                            }
                                        }

                                        var bwd = padPtr[bEnd - 1]
                                        sufPtr[bEnd - 1] = bwd
                                        if bEnd - 1 > bStart {
                                            var k = bEnd - 2
                                            while k >= bStart {
                                                let v = padPtr[k]
                                                if v < bwd { bwd = v }
                                                sufPtr[k] = bwd
                                                k -= 1
                                            }
                                        }
                                        bStart += win
                                    }

                                    for x in 0..<w {
                                        let a = sufPtr[x]
                                        let b = prePtr[x + win - 1]
                                        tmpPtr[row + x] = a <= b ? a : b
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        horizontal.withUnsafeBufferPointer { tmpPtr in
            vertical.withUnsafeMutableBufferPointer { dstPtr in
                padded.withUnsafeMutableBufferPointer { padPtr in
                    prefix.withUnsafeMutableBufferPointer { prePtr in
                        suffix.withUnsafeMutableBufferPointer { sufPtr in
                            if ry == 0 {
                                for i in 0..<(w * h) { dstPtr[i] = tmpPtr[i] }
                            } else {
                                let win = 2 * ry + 1
                                let len = h + 2 * ry
                                for i in 0..<ry { padPtr[i] = 255 }
                                for i in (ry + h)..<len { padPtr[i] = 255 }

                                for x in 0..<w {
                                    for y in 0..<h {
                                        padPtr[ry + y] = tmpPtr[y * w + x]
                                    }

                                    var bStart = 0
                                    while bStart < len {
                                        let bEnd = min(len, bStart + win)
                                        var fwd = padPtr[bStart]
                                        prePtr[bStart] = fwd
                                        if bStart + 1 < bEnd {
                                            for k in (bStart + 1)..<bEnd {
                                                let v = padPtr[k]
                                                if v < fwd { fwd = v }
                                                prePtr[k] = fwd
                                            }
                                        }

                                        var bwd = padPtr[bEnd - 1]
                                        sufPtr[bEnd - 1] = bwd
                                        if bEnd - 1 > bStart {
                                            var k = bEnd - 2
                                            while k >= bStart {
                                                let v = padPtr[k]
                                                if v < bwd { bwd = v }
                                                sufPtr[k] = bwd
                                                k -= 1
                                            }
                                        }
                                        bStart += win
                                    }

                                    for y in 0..<h {
                                        let a = sufPtr[y]
                                        let b = prePtr[y + win - 1]
                                        dstPtr[y * w + x] = a <= b ? a : b
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return GrayscaleBuffer(width: w, height: h, dpi: buffer.dpi, pixels: vertical)
    }

    private struct BilinearAxisLUT {
        let i0: ContiguousArray<Int>
        let i1: ContiguousArray<Int>
        let frac: ContiguousArray<Int>
    }

    /// Returns `true` when any pixel in the `3 x 3` neighbourhood of `(x, y)` has an unclipped
    /// Pass 1 quotient at or below `foregroundMaxQ1` (i.e. the pixel borders an ink stroke).
    @inline(__always)
    private static func touchesForeground(
        _ q1: UnsafeBufferPointer<UInt16>,
        x: Int,
        y: Int,
        width w: Int,
        height h: Int,
        foregroundMaxQ1: Int
    ) -> Bool {
        let yLo = max(0, y - 1)
        let yHi = min(h - 1, y + 1)
        let xLo = max(0, x - 1)
        let xHi = min(w - 1, x + 1)
        for ny in yLo...yHi {
            let row = ny * w
            for nx in xLo...xHi where Int(q1[row + nx]) <= foregroundMaxQ1 {
                return true
            }
        }
        return false
    }

    /// Returns the smallest histogram bin whose cumulative count reaches `percent`% of `total`.
    private static func histogramPercentile(_ hist: [Int], total: Int, percent: Int) -> Int {
        let rank = max(1, (total * percent) / 100)
        var cumulative = 0
        for bin in 0..<hist.count {
            cumulative += hist[bin]
            if cumulative >= rank {
                return bin
            }
        }
        return hist.count - 1
    }

    /// Absorption (`255 - normalized`) at or below which isolated structure (paper grain, faint
    /// bleed-through ghosts) receives no anti-starvation contrast gain.
    private static let contrastGateFloor = 16

    /// Local peak absorption at and above which pixels receive the full multiplicative contrast gain.
    private static let contrastGateFullGain = 40

    /// Applies the regional anti-starvation contrast gain field to an unblended normalized image.
    ///
    /// Veiling glare adds a luminance pedestal that compresses ink absorption $A = 255 - I$
    /// multiplicatively, so absorption is restored multiplicatively: $A' = A \cdot (1 + (g - 1) \cdot w)$,
    /// where $g$ is the bilinearly interpolated regional gain. The gate weight $w$ is a smoothstep of the
    /// local `3 x 3` peak absorption between `contrastGateFloor` and `contrastGateFullGain`, so
    /// partial-coverage stroke-edge pixels inherit the full gain of the stroke core they border (keeping
    /// stroke weight uniform across veiled and crisp regions), while isolated faint structure such as
    /// paper grain and bleed-through ghosts stays untouched. For an isolated pixel the mapping is
    /// $C^1$-continuous and strictly monotonic in $A$.
    /// - Parameters:
    ///   - pixels: Unblended normalized image, modified in place.
    ///   - w: Image width in pixels.
    ///   - h: Image height in pixels.
    ///   - gainSmallQ8: Regional gain grid in Q8 fixed point (`256 == 1.0x`).
    ///   - gridW: Gain grid width in cells.
    ///   - xLUT: Horizontal bilinear lookup from image columns to grid cells.
    ///   - yLUT: Vertical bilinear lookup from image rows to grid cells.
    private static func applyContrastLeveling(
        to pixels: inout ContiguousArray<UInt8>,
        width w: Int,
        height h: Int,
        gainSmallQ8: borrowing ContiguousArray<Int>,
        gridWidth gridW: Int,
        xLUT: borrowing BilinearAxisLUT,
        yLUT: borrowing BilinearAxisLUT
    ) {
        guard w > 0, h > 0 else { return }

        let gateFloor = contrastGateFloor
        var gateQ8 = ContiguousArray<Int>(repeating: 0, count: 256)
        let gateSpan = Double(contrastGateFullGain - contrastGateFloor)
        for n in 0..<256 {
            let t = min(1.0, max(0.0, Double(n - gateFloor) / gateSpan))
            gateQ8[n] = Int((t * t * (3.0 - 2.0 * t) * 256.0).rounded())
        }

        // Horizontal 3-tap minimum of the base quotient (darkest value == peak absorption).
        var hMin = ContiguousArray<UInt8>(repeating: 255, count: w * h)
        pixels.withUnsafeBufferPointer { src in
            hMin.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let row = y * w
                    for x in 0..<w {
                        var m = src[row + x]
                        if x > 0 { m = min(m, src[row + x - 1]) }
                        if x + 1 < w { m = min(m, src[row + x + 1]) }
                        dst[row + x] = m
                    }
                }
            }
        }

        gainSmallQ8.withUnsafeBufferPointer { gainPtr in
            gateQ8.withUnsafeBufferPointer { gatePtr in
                hMin.withUnsafeBufferPointer { minPtr in
                    xLUT.i0.withUnsafeBufferPointer { x0Ptr in
                        xLUT.i1.withUnsafeBufferPointer { x1Ptr in
                            xLUT.frac.withUnsafeBufferPointer { fxPtr in
                                pixels.withUnsafeMutableBufferPointer { dstPtr in
                                    for y in 0..<h {
                                        let row0 = yLUT.i0[y] * gridW
                                        let row1 = yLUT.i1[y] * gridW
                                        let fy = yLUT.frac[y]
                                        let invFy = 256 - fy
                                        let row = y * w
                                        let rowUp = max(0, y - 1) * w
                                        let rowDown = min(h - 1, y + 1) * w

                                        for x in 0..<w {
                                            let base = Int(dstPtr[row + x])
                                            let peakBase = min(minPtr[row + x], min(minPtr[rowUp + x], minPtr[rowDown + x]))
                                            let peakAbsorption = 255 - Int(peakBase)
                                            guard base < 255, peakAbsorption > gateFloor else { continue }

                                            let x0 = x0Ptr[x]
                                            let x1 = x1Ptr[x]
                                            let fx = fxPtr[x]
                                            let invFx = 256 - fx
                                            let gTop = gainPtr[row0 + x0] * invFx + gainPtr[row0 + x1] * fx
                                            let gBot = gainPtr[row1 + x0] * invFx + gainPtr[row1 + x1] * fx
                                            let gainQ8 = (gTop * invFy + gBot * fy + 32768) >> 16
                                            guard gainQ8 > 256 else { continue }

                                            let absorption = 255 - base
                                            let boost = ((gainQ8 - 256) * absorption * gatePtr[peakAbsorption] + 32768) >> 16
                                            dstPtr[row + x] = UInt8(max(0, base - boost))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func makeBilinearAxisLUT(srcLength: Int, targetLength: Int) -> BilinearAxisLUT {
        var i0 = ContiguousArray<Int>(repeating: 0, count: max(0, targetLength))
        var i1 = ContiguousArray<Int>(repeating: 0, count: max(0, targetLength))
        var frac = ContiguousArray<Int>(repeating: 0, count: max(0, targetLength))
        guard srcLength > 0, targetLength > 0 else {
            return BilinearAxisLUT(i0: i0, i1: i1, frac: frac)
        }
        let scale = Double(srcLength) / Double(targetLength)
        let maxIdx = srcLength - 1
        i0.withUnsafeMutableBufferPointer { p0 in
            i1.withUnsafeMutableBufferPointer { p1 in
                frac.withUnsafeMutableBufferPointer { pf in
                    for idx in 0..<targetLength {
                        let s = max(0.0, min(Double(maxIdx), (Double(idx) + 0.5) * scale - 0.5))
                        let base = Int(s)
                        p0[idx] = base
                        p1[idx] = min(maxIdx, base + 1)
                        pf[idx] = Int(((s - Double(base)) * 256.0).rounded())
                    }
                }
            }
        }
        return BilinearAxisLUT(i0: i0, i1: i1, frac: frac)
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
        let scaleY = Double(srcH) / Double(max(1, targetHeight))
        let xLUT = makeBilinearAxisLUT(srcLength: srcW, targetLength: targetWidth)

        small.pixels.withUnsafeBufferPointer { srcPtr in
            xLUT.i0.withUnsafeBufferPointer { x0Ptr in
                xLUT.i1.withUnsafeBufferPointer { x1Ptr in
                    xLUT.frac.withUnsafeBufferPointer { fxPtr in
                        outPixels.withUnsafeMutableBufferPointer { dstPtr in
                            for y in 0..<targetHeight {
                                let srcY = max(0.0, min(Double(srcH - 1), (Double(y) + 0.5) * scaleY - 0.5))
                                let y0 = Int(srcY)
                                let y1 = min(srcH - 1, y0 + 1)
                                let fy = Int(((srcY - Double(y0)) * 256.0).rounded())
                                let invFy = 256 - fy

                                let row0 = y0 * srcW
                                let row1 = y1 * srcW
                                let dstRow = y * targetWidth

                                for x in 0..<targetWidth {
                                    let x0 = x0Ptr[x]
                                    let x1 = x1Ptr[x]
                                    let fx = fxPtr[x]
                                    let invFx = 256 - fx

                                    let top = Int(srcPtr[row0 + x0]) * invFx + Int(srcPtr[row0 + x1]) * fx
                                    let bottom = Int(srcPtr[row1 + x0]) * invFx + Int(srcPtr[row1 + x1]) * fx
                                    let value = (top * invFy + bottom * fy + 32768) >> 16
                                    dstPtr[dstRow + x] = UInt8(min(255, max(0, value)))
                                }
                            }
                        }
                    }
                }
            }
        }

        return GrayscaleBuffer(width: targetWidth, height: targetHeight, dpi: dpi, pixels: outPixels)
    }

    /// Bilinearly upsamples a Q6 fixed-point grid (`value * 64`) to a full-resolution `UInt8` `GrayscaleBuffer`.
    internal static func upsampleBilinearQ6ToUInt8(
        _ smallQ6: borrowing ContiguousArray<Int>,
        smallWidth srcW: Int,
        smallHeight srcH: Int,
        targetWidth: Int,
        targetHeight: Int,
        dpi: Int
    ) -> GrayscaleBuffer {
        guard srcW > 0, srcH > 0, targetWidth > 0, targetHeight > 0 else {
            return GrayscaleBuffer(width: targetWidth, height: targetHeight, dpi: dpi)
        }

        var outPixels = ContiguousArray<UInt8>(repeating: 255, count: targetWidth * targetHeight)
        if srcW == targetWidth && srcH == targetHeight {
            smallQ6.withUnsafeBufferPointer { srcPtr in
                outPixels.withUnsafeMutableBufferPointer { dstPtr in
                    for i in 0..<(targetWidth * targetHeight) {
                        let v = (srcPtr[i] + 32) >> 6
                        dstPtr[i] = UInt8(min(255, max(0, v)))
                    }
                }
            }
            return GrayscaleBuffer(width: targetWidth, height: targetHeight, dpi: dpi, pixels: outPixels)
        }

        let scaleY = Double(srcH) / Double(max(1, targetHeight))
        let xLUT = makeBilinearAxisLUT(srcLength: srcW, targetLength: targetWidth)

        smallQ6.withUnsafeBufferPointer { srcPtr in
            xLUT.i0.withUnsafeBufferPointer { x0Ptr in
                xLUT.i1.withUnsafeBufferPointer { x1Ptr in
                    xLUT.frac.withUnsafeBufferPointer { fxPtr in
                        outPixels.withUnsafeMutableBufferPointer { dstPtr in
                            for y in 0..<targetHeight {
                                let srcY = max(0.0, min(Double(srcH - 1), (Double(y) + 0.5) * scaleY - 0.5))
                                let y0 = Int(srcY)
                                let y1 = min(srcH - 1, y0 + 1)
                                let fy = Int(((srcY - Double(y0)) * 256.0).rounded())
                                let invFy = 256 - fy

                                let row0 = y0 * srcW
                                let row1 = y1 * srcW
                                let dstRow = y * targetWidth

                                for x in 0..<targetWidth {
                                    let x0 = x0Ptr[x]
                                    let x1 = x1Ptr[x]
                                    let fx = fxPtr[x]
                                    let invFx = 256 - fx

                                    let top = srcPtr[row0 + x0] * invFx + srcPtr[row0 + x1] * fx
                                    let bottom = srcPtr[row1 + x0] * invFx + srcPtr[row1 + x1] * fx
                                    let bgQ6 = (top * invFy + bottom * fy + 32768) >> 16
                                    let v = (bgQ6 + 32) >> 6
                                    dstPtr[dstRow + x] = UInt8(min(255, max(0, v)))
                                }
                            }
                        }
                    }
                }
            }
        }

        return GrayscaleBuffer(width: targetWidth, height: targetHeight, dpi: dpi, pixels: outPixels)
    }

    /// Dilutes single-pixel USM sharpening spikes on `factor == 1` grids via a clamped `3 x 3` box average.
    private static func boxSmooth3x3UInt16(
        _ input: borrowing ContiguousArray<UInt16>,
        width w: Int,
        height h: Int
    ) -> ContiguousArray<UInt16> {
        var out = ContiguousArray<UInt16>(repeating: 0, count: w * h)
        input.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let ym = max(0, y - 1) * w
                    let y0 = y * w
                    let yp = min(h - 1, y + 1) * w
                    for x in 0..<w {
                        let xm = max(0, x - 1)
                        let xp = min(w - 1, x + 1)
                        let sum =
                            Int(src[ym + xm]) + Int(src[ym + x]) + Int(src[ym + xp]) +
                            Int(src[y0 + xm]) + Int(src[y0 + x]) + Int(src[y0 + xp]) +
                            Int(src[yp + xm]) + Int(src[yp + x]) + Int(src[yp + xp])
                        dst[y0 + x] = UInt16((sum + 4) / 9)
                    }
                }
            }
        }
        return out
    }

    /// Separable 2D morphological closing (`erode(dilate(x, r), r)`) on `UInt16` quotient grids with
    /// continuous boundary-slope extrapolation so narrow ink-stem valleys are bridged while steep
    /// boundary spine shadows incur zero upward slope bias right down to `x = 0` and `x = w - 1`.
    private static func closeSlopeAwareUInt16(
        _ input: borrowing ContiguousArray<UInt16>,
        width w: Int,
        height h: Int,
        radius: Int
    ) -> ContiguousArray<UInt16> {
        guard radius > 0, w > 0, h > 0 else {
            return copy input
        }

        let rx = min(radius, max(0, w - 1))
        let ry = min(radius, max(0, h - 1))
        var horizontal = ContiguousArray<UInt16>(repeating: 0, count: w * h)
        var vertical = ContiguousArray<UInt16>(repeating: 0, count: w * h)

        let maxDim = max(w, h)
        let maxR = max(rx, ry)
        var extBuf = ContiguousArray<UInt16>(repeating: 0, count: maxDim + 4 * maxR)
        var dilBuf = ContiguousArray<UInt16>(repeating: 0, count: maxDim + 2 * maxR)

        @inline(__always)
        func close1D(
            lineLength n: Int,
            r: Int,
            ext: UnsafeMutableBufferPointer<UInt16>,
            dil: UnsafeMutableBufferPointer<UInt16>
        ) {
            let vLeft = Int(ext[2 * r])
            let leftDist = max(1, min(n - 1, r))
            let vLeftRef = Int(ext[2 * r + leftDist])
            let smoothLeft = (vLeft >= 96) && (abs(vLeft - vLeftRef) <= 28 * leftDist)
            if smoothLeft {
                let diff = vLeft - vLeftRef
                for k in 1...(2 * r) {
                    let extrap = max(0, min(1020, vLeft + (k * diff) / leftDist))
                    ext[2 * r - k] = UInt16(extrap)
                }
            } else {
                for k in 1...(2 * r) {
                    ext[2 * r - k] = 0
                }
            }

            let vRight = Int(ext[2 * r + n - 1])
            let rightDist = max(1, min(n - 1, r))
            let vRightRef = Int(ext[2 * r + n - 1 - rightDist])
            let smoothRight = (vRight >= 96) && (abs(vRight - vRightRef) <= 28 * rightDist)
            if smoothRight {
                let diff = vRight - vRightRef
                for k in 1...(2 * r) {
                    let extrap = max(0, min(1020, vRight + (k * diff) / rightDist))
                    ext[2 * r + n - 1 + k] = UInt16(extrap)
                }
            } else {
                for k in 1...(2 * r) {
                    ext[2 * r + n - 1 + k] = 0
                }
            }

            let dilLen = n + 2 * r
            for j in 0..<dilLen {
                if !smoothLeft && j < r {
                    dil[j] = 1020
                    continue
                }
                if !smoothRight && j >= n + r {
                    dil[j] = 1020
                    continue
                }
                let center = j + r
                var m: UInt16 = 0
                for d in -r...r {
                    let v = ext[center + d]
                    if v > m { m = v }
                }
                dil[j] = m
            }

            for i in 0..<n {
                let center = i + r
                var m: UInt16 = 1020
                for d in -r...r {
                    let v = dil[center + d]
                    if v < m { m = v }
                }
                ext[2 * r + i] = m
            }
        }

        input.withUnsafeBufferPointer { srcPtr in
            horizontal.withUnsafeMutableBufferPointer { tmpPtr in
                extBuf.withUnsafeMutableBufferPointer { extPtr in
                    dilBuf.withUnsafeMutableBufferPointer { dilPtr in
                        if rx == 0 {
                            for i in 0..<(w * h) { tmpPtr[i] = srcPtr[i] }
                        } else {
                            for y in 0..<h {
                                let row = y * w
                                for x in 0..<w { extPtr[2 * rx + x] = srcPtr[row + x] }
                                close1D(lineLength: w, r: rx, ext: extPtr, dil: dilPtr)
                                for x in 0..<w { tmpPtr[row + x] = extPtr[2 * rx + x] }
                            }
                        }
                    }
                }
            }
        }

        horizontal.withUnsafeBufferPointer { tmpPtr in
            vertical.withUnsafeMutableBufferPointer { dstPtr in
                extBuf.withUnsafeMutableBufferPointer { extPtr in
                    dilBuf.withUnsafeMutableBufferPointer { dilPtr in
                        if ry == 0 {
                            for i in 0..<(w * h) { dstPtr[i] = tmpPtr[i] }
                        } else {
                            for x in 0..<w {
                                for y in 0..<h { extPtr[2 * ry + y] = tmpPtr[y * w + x] }
                                close1D(lineLength: h, r: ry, ext: extPtr, dil: dilPtr)
                                for y in 0..<h { dstPtr[y * w + x] = extPtr[2 * ry + y] }
                            }
                        }
                    }
                }
            }
        }

        return vertical
    }

    /// Boundary extension rule applied by `inpaintAndSmoothNormalized2D` beyond the grid edges.
    internal enum SmoothingBoundary: Sendable {
        /// Replicates the outermost cell (clamp-to-edge). Biases steep boundary ramps toward the interior.
        case replicate
        /// Point-reflects values about the outermost cell (`v(-k) = 2 v(0) - v(k)`) with mirrored weights,
        /// so any symmetric kernel reproduces linear boundary ramps exactly and returns `v(0)` at the edge.
        case linearExtrapolate
    }

    /// Inpaints `weights == 0` holes via multi-stride normalized diffusion and applies separable
    /// normalized 2D Gaussian (or $O(1)$ 3-pass box-Gaussian for macro sigmas) convolution so
    /// missing foreground cells never pull down background estimates.
    /// - Parameters:
    ///   - values: Per-cell sample values (ignored where `weights == 0`).
    ///   - weights: Per-cell sample confidence (`0` marks a hole to inpaint).
    ///   - w: Grid width in cells.
    ///   - h: Grid height in cells.
    ///   - sigma: Gaussian smoothing $\sigma$ in cells (`<= 0.05` skips smoothing).
    ///   - fallbackValue: Value returned when the grid holds no valid samples.
    ///   - boundary: Boundary extension rule used by the smoothing kernel (default: `.replicate`).
    /// - Returns: The inpainted and smoothed grid.
    internal static func inpaintAndSmoothNormalized2D(
        values: borrowing ContiguousArray<Float>,
        weights: borrowing ContiguousArray<Float>,
        width w: Int,
        height h: Int,
        sigma: Double,
        fallbackValue: Float,
        boundary: SmoothingBoundary = .replicate
    ) -> ContiguousArray<Float> {
        let count = w * h
        guard count > 0 else { return [] }

        var filled = ContiguousArray<Float>(repeating: fallbackValue, count: count)
        var knownMask = ContiguousArray<UInt8>(repeating: 0, count: count)
        var confWeight = ContiguousArray<Float>(repeating: 0.0, count: count)

        var validCount = 0
        var validSum: Double = 0.0
        values.withUnsafeBufferPointer { valIn in
            weights.withUnsafeBufferPointer { wIn in
                filled.withUnsafeMutableBufferPointer { fillPtr in
                    knownMask.withUnsafeMutableBufferPointer { maskPtr in
                        confWeight.withUnsafeMutableBufferPointer { cwPtr in
                            for i in 0..<count {
                                let wt = wIn[i]
                                if wt > 0.0 {
                                    let v = valIn[i]
                                    fillPtr[i] = v
                                    maskPtr[i] = 1
                                    cwPtr[i] = wt
                                    validCount += 1
                                    validSum += Double(v)
                                }
                            }
                        }
                    }
                }
            }
        }

        guard validCount > 0 else {
            return ContiguousArray<Float>(repeating: fallbackValue, count: count)
        }

        var missingCount = count - validCount
        if missingCount > 0 {
            let strides = [1, 1, 2, 4, 8, 16, 32]
            var nextFilled = filled
            var nextMask = knownMask

            for step in strides {
                if missingCount <= 0 { break }
                nextFilled = filled
                nextMask = knownMask

                filled.withUnsafeBufferPointer { fillIn in
                    knownMask.withUnsafeBufferPointer { maskIn in
                        nextFilled.withUnsafeMutableBufferPointer { fillOut in
                            nextMask.withUnsafeMutableBufferPointer { maskOut in
                                confWeight.withUnsafeMutableBufferPointer { cwPtr in
                                    for y in 0..<h {
                                        let row = y * w
                                        for x in 0..<w {
                                            let idx = row + x
                                            if maskIn[idx] != 0 { continue }

                                            var vSum: Float = 0.0
                                            var wSum: Float = 0.0

                                            for dy in -1...1 {
                                                let ny = y + dy * step
                                                if ny < 0 || ny >= h { continue }
                                                let nRow = ny * w
                                                for dx in -1...1 {
                                                    if dx == 0 && dy == 0 { continue }
                                                    let nx = x + dx * step
                                                    if nx < 0 || nx >= w { continue }
                                                    let nIdx = nRow + nx
                                                    if maskIn[nIdx] != 0 {
                                                        let spatialW: Float = (dx == 0 || dy == 0) ? 2.0 : 1.4142135
                                                        vSum += fillIn[nIdx] * spatialW
                                                        wSum += spatialW
                                                    }
                                                }
                                            }

                                            if wSum > 0.0 {
                                                fillOut[idx] = vSum / wSum
                                                maskOut[idx] = 1
                                                cwPtr[idx] = 0.20
                                                missingCount -= 1
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                filled = nextFilled
                knownMask = nextMask
            }

            if missingCount > 0 {
                let globalMean = Float(validSum / Double(validCount))
                knownMask.withUnsafeBufferPointer { maskIn in
                    filled.withUnsafeMutableBufferPointer { fillPtr in
                        confWeight.withUnsafeMutableBufferPointer { cwPtr in
                            for i in 0..<count where maskIn[i] == 0 {
                                fillPtr[i] = globalMean
                                cwPtr[i] = 0.10
                            }
                        }
                    }
                }
            }
        }

        guard sigma > 0.05, w > 1 || h > 1 else {
            return filled
        }

        switch boundary {
        case .replicate:
            return smoothNormalized2D(
                values: filled,
                weights: confWeight,
                width: w,
                height: h,
                sigma: sigma,
                fallbackValue: fallbackValue
            )
        case .linearExtrapolate:
            let pad = smoothingSupportRadius(sigma: sigma)
            let padded = padByLinearReflection(
                values: filled,
                weights: confWeight,
                width: w,
                height: h,
                pad: pad
            )
            let paddedW = w + 2 * pad
            let smoothedPadded = smoothNormalized2D(
                values: padded.values,
                weights: padded.weights,
                width: paddedW,
                height: h + 2 * pad,
                sigma: sigma,
                fallbackValue: fallbackValue
            )
            var cropped = ContiguousArray<Float>(repeating: fallbackValue, count: count)
            smoothedPadded.withUnsafeBufferPointer { src in
                cropped.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        let srcRow = (y + pad) * paddedW + pad
                        let dstRow = y * w
                        for x in 0..<w {
                            dst[dstRow + x] = src[srcRow + x]
                        }
                    }
                }
            }
            return cropped
        }
    }

    /// Full one-sided reach (in cells) of the kernel applied by `smoothNormalized2D` for `sigma`.
    private static func smoothingSupportRadius(sigma: Double) -> Int {
        if sigma > 5.0 {
            return 3 * max(2, Int(sigma.rounded()))
        }
        return min(20, max(1, Int(ceil(3.0 * sigma))))
    }

    /// Pads a grid by `pad` cells on every side, point-reflecting values about the outermost
    /// row/column (`v(-k) = 2 v(0) - v(k)`) and mirroring weights, so linear trends continue
    /// unbiased across the boundary. Reflection indices clamp to the grid on undersized grids.
    private static func padByLinearReflection(
        values: borrowing ContiguousArray<Float>,
        weights: borrowing ContiguousArray<Float>,
        width w: Int,
        height h: Int,
        pad p: Int
    ) -> (values: ContiguousArray<Float>, weights: ContiguousArray<Float>) {
        let pw = w + 2 * p
        let ph = h + 2 * p
        var outV = ContiguousArray<Float>(repeating: 0.0, count: pw * ph)
        var outW = ContiguousArray<Float>(repeating: 0.0, count: pw * ph)

        values.withUnsafeBufferPointer { vIn in
            weights.withUnsafeBufferPointer { wIn in
                outV.withUnsafeMutableBufferPointer { vOut in
                    outW.withUnsafeMutableBufferPointer { wOut in
                        // Horizontal extension of every original row.
                        for y in 0..<h {
                            let srcRow = y * w
                            let dstRow = (y + p) * pw
                            let leftPivot = vIn[srcRow]
                            let rightPivot = vIn[srcRow + w - 1]
                            for px in 0..<pw {
                                let ox = px - p
                                if ox < 0 {
                                    let j = min(w - 1, -ox)
                                    vOut[dstRow + px] = 2.0 * leftPivot - vIn[srcRow + j]
                                    wOut[dstRow + px] = wIn[srcRow + j]
                                } else if ox >= w {
                                    let j = max(0, 2 * (w - 1) - ox)
                                    vOut[dstRow + px] = 2.0 * rightPivot - vIn[srcRow + j]
                                    wOut[dstRow + px] = wIn[srcRow + j]
                                } else {
                                    vOut[dstRow + px] = vIn[srcRow + ox]
                                    wOut[dstRow + px] = wIn[srcRow + ox]
                                }
                            }
                        }

                        // Vertical extension of every (already horizontally padded) column.
                        let topRow = p * pw
                        let bottomRow = (p + h - 1) * pw
                        for py in 0..<ph {
                            let oy = py - p
                            guard oy < 0 || oy >= h else { continue }
                            let dstRow = py * pw
                            let pivotRow: Int
                            let mirrorRow: Int
                            if oy < 0 {
                                pivotRow = topRow
                                mirrorRow = (p + min(h - 1, -oy)) * pw
                            } else {
                                pivotRow = bottomRow
                                mirrorRow = (p + max(0, 2 * (h - 1) - oy)) * pw
                            }
                            for px in 0..<pw {
                                vOut[dstRow + px] = 2.0 * vOut[pivotRow + px] - vOut[mirrorRow + px]
                                wOut[dstRow + px] = wOut[mirrorRow + px]
                            }
                        }
                    }
                }
            }
        }

        return (outV, outW)
    }

    /// Separable normalized 2D Gaussian (or $O(1)$ 3-pass box-Gaussian for `sigma > 5`) convolution
    /// of `values` weighted by `weights`, with clamp-to-edge replication at the grid boundary.
    private static func smoothNormalized2D(
        values filled: borrowing ContiguousArray<Float>,
        weights confWeight: borrowing ContiguousArray<Float>,
        width w: Int,
        height h: Int,
        sigma: Double,
        fallbackValue: Float
    ) -> ContiguousArray<Float> {
        let count = w * h

        // For macro smoothing scales (`sigma > 5.0`), 3-pass separable running-sum box smoothing
        // runs in exact O(w * h) time independent of radius and has zero truncation cap.
        if sigma > 5.0 {
            let boxRadius = max(2, Int(sigma.rounded()))
            var numField = ContiguousArray<Float>(repeating: 0.0, count: count)
            var denField = copy confWeight
            filled.withUnsafeBufferPointer { fPtr in
                confWeight.withUnsafeBufferPointer { wPtr in
                    numField.withUnsafeMutableBufferPointer { nPtr in
                        for i in 0..<count { nPtr[i] = fPtr[i] * wPtr[i] }
                    }
                }
            }
            for _ in 0..<3 {
                numField = boxBlur2DClampedFloat(numField, width: w, height: h, radius: boxRadius)
                denField = boxBlur2DClampedFloat(denField, width: w, height: h, radius: boxRadius)
            }
            var out = ContiguousArray<Float>(repeating: fallbackValue, count: count)
            numField.withUnsafeBufferPointer { nPtr in
                denField.withUnsafeBufferPointer { dPtr in
                    filled.withUnsafeBufferPointer { fPtr in
                        out.withUnsafeMutableBufferPointer { oPtr in
                            for i in 0..<count {
                                let d = dPtr[i]
                                oPtr[i] = d > 1e-6 ? (nPtr[i] / d) : fPtr[i]
                            }
                        }
                    }
                }
            }
            return out
        }

        let radius = min(20, max(1, Int(ceil(3.0 * sigma))))
        let invTwoSigmaSq = 1.0 / (2.0 * sigma * sigma)
        var kernel = ContiguousArray<Float>(repeating: 0.0, count: 2 * radius + 1)
        var kSum: Double = 0.0
        for k in -radius...radius {
            let weight = exp(-Double(k * k) * invTwoSigmaSq)
            kernel[k + radius] = Float(weight)
            kSum += weight
        }
        let invKSum = Float(1.0 / max(1e-12, kSum))
        for i in 0..<kernel.count {
            kernel[i] *= invKSum
        }

        var hNum = ContiguousArray<Float>(repeating: 0.0, count: count)
        var hDen = ContiguousArray<Float>(repeating: 0.0, count: count)
        var out = ContiguousArray<Float>(repeating: fallbackValue, count: count)

        filled.withUnsafeBufferPointer { valPtr in
            confWeight.withUnsafeBufferPointer { wPtr in
                kernel.withUnsafeBufferPointer { kPtr in
                    hNum.withUnsafeMutableBufferPointer { hNumPtr in
                        hDen.withUnsafeMutableBufferPointer { hDenPtr in
                            for y in 0..<h {
                                let row = y * w
                                for x in 0..<w {
                                    var num: Float = 0.0
                                    var den: Float = 0.0
                                    for k in -radius...radius {
                                        let nx = min(w - 1, max(0, x + k))
                                        let kw = kPtr[k + radius]
                                        let cw = wPtr[row + nx]
                                        let prod = kw * cw
                                        num += valPtr[row + nx] * prod
                                        den += prod
                                    }
                                    hNumPtr[row + x] = num
                                    hDenPtr[row + x] = den
                                }
                            }
                        }
                    }

                    hNum.withUnsafeBufferPointer { hNumPtr in
                        hDen.withUnsafeBufferPointer { hDenPtr in
                            out.withUnsafeMutableBufferPointer { outPtr in
                                for y in 0..<h {
                                    let row = y * w
                                    for x in 0..<w {
                                        var num: Float = 0.0
                                        var den: Float = 0.0
                                        for k in -radius...radius {
                                            let ny = min(h - 1, max(0, y + k))
                                            let kw = kPtr[k + radius]
                                            let idx = ny * w + x
                                            num += hNumPtr[idx] * kw
                                            den += hDenPtr[idx] * kw
                                        }
                                        outPtr[row + x] = den > 1e-6 ? (num / den) : valPtr[row + x]
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return out
    }

    /// Separable $O(1)$-per-cell 2D running-sum box average with clamped boundary replication.
    private static func boxBlur2DClampedFloat(
        _ input: borrowing ContiguousArray<Float>,
        width w: Int,
        height h: Int,
        radius r: Int
    ) -> ContiguousArray<Float> {
        guard r > 0, w > 0, h > 0 else { return copy input }
        let count = w * h
        let invWin = Float(1.0 / Double(2 * r + 1))
        var horiz = ContiguousArray<Float>(repeating: 0.0, count: count)
        var vert = ContiguousArray<Float>(repeating: 0.0, count: count)

        input.withUnsafeBufferPointer { src in
            horiz.withUnsafeMutableBufferPointer { tmp in
                for y in 0..<h {
                    let row = y * w
                    var running: Float = 0.0
                    let first = src[row]
                    for k in -r...r {
                        let nx = min(w - 1, max(0, k))
                        running += (k < 0) ? first : src[row + nx]
                    }
                    tmp[row] = running * invWin
                    if w > 1 {
                        for x in 1..<w {
                            let subIdx = max(0, x - r - 1)
                            let addIdx = min(w - 1, x + r)
                            running += src[row + addIdx] - src[row + subIdx]
                            tmp[row + x] = running * invWin
                        }
                    }
                }
            }
        }

        horiz.withUnsafeBufferPointer { tmp in
            vert.withUnsafeMutableBufferPointer { dst in
                for x in 0..<w {
                    var running: Float = 0.0
                    let first = tmp[x]
                    for k in -r...r {
                        let ny = min(h - 1, max(0, k))
                        running += (k < 0) ? first : tmp[ny * w + x]
                    }
                    dst[x] = running * invWin
                    if h > 1 {
                        for y in 1..<h {
                            let subIdx = max(0, y - r - 1)
                            let addIdx = min(h - 1, y + r)
                            running += tmp[addIdx * w + x] - tmp[subIdx * w + x]
                            dst[y * w + x] = running * invWin
                        }
                    }
                }
            }
        }

        return vert
    }
}
