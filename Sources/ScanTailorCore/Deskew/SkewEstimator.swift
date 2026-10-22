import Foundation
import ScanTailorContracts

/// Result of a multi-scale document skew estimation pass.
public struct SkewEstimate: Sendable, Equatable, Codable {
    /// Detected skew angle in degrees.
    ///
    /// Positive values indicate that text baselines slope downward from left to right (clockwise rotation
    /// in top-left image coordinates where $+x$ points right and $+y$ points down).
    public let angleDegrees: Double

    /// Normalized confidence score in `[0.0, 1.0]` reflecting the sharpness of the horizontal projection peak
    /// relative to baseline projection energy.
    public let confidence: Double

    /// Number of connected foreground components retained as text-like candidates during estimation.
    public let retainedComponentCount: Int

    /// Total number of foreground pixels projected at the working resolution.
    public let retainedPixelCount: Int

    /// Creates a skew estimate descriptor.
    public init(
        angleDegrees: Double,
        confidence: Double,
        retainedComponentCount: Int,
        retainedPixelCount: Int
    ) {
        self.angleDegrees = angleDegrees
        self.confidence = confidence
        self.retainedComponentCount = retainedComponentCount
        self.retainedPixelCount = retainedPixelCount
    }

    /// Computes the counter-rotation affine transformation around the center of `size` that rectifies
    /// the detected skew back to horizontal ($0^\circ$).
    /// - Parameter size: Pixel dimensions of the image to deskew.
    /// - Returns: An `AffineTransform2D` suitable for `ComputeAccelerator.affineWarp`.
    public func deskewTransform(for size: Size2I) -> AffineTransform2D {
        let center = Point2D(x: Double(size.width) * 0.5, y: Double(size.height) * 0.5)
        let radians = -angleDegrees * .pi / 180.0
        return AffineTransform2D.rotation(radians: radians, center: center)
    }
}

/// Multi-scale projection-variance skew estimator with connected-component non-text filtering
/// (adapted from ScanTailor-Advanced `SkewFinder`).
///
/// ### Algorithm Overview
/// 1. **Resolution Pyramid**: Downsamples high-resolution bitmaps or grayscale buffers into a bounded working
///    dimension (`maxWorkingDimension`, default `1600` px) using area-preserving $2 \times 2$ reduction.
/// 2. **Connected-Component Filtering**: Extracts 8-connected components and removes isolated salt-and-pepper
///    noise, tall vertical lines/gutter shadows (`aspectRatio < minTextComponentAspectRatio`), and oversized
///    non-text blocks (`height > maxComponentHeightFraction * H`).
/// 3. **Sub-Pixel Smoothed Projection Energy**: Projects relative foreground coordinates $(dx, dy)$ onto the
///    normal axis $v = dy \cos\theta - dx \sin\theta$ using linear bin interpolation followed by cubic B-spline
///    binomial smoothing to eliminate $0^\circ$ integer-grid aliasing.
/// 4. **Coarse-to-Fine Search**: Evaluates coarse ($0.5^\circ$), medium ($0.05^\circ$), and fine ($0.005^\circ$)
///    angular grids, finishing with 3-point parabolic peak interpolation for sub-$0.01^\circ$ precision.
public enum SkewEstimator {

    /// Configuration parameters governing multi-scale skew estimation.
    public struct Configuration: Sendable, Equatable, Codable {
        /// Maximum absolute skew angle searched, in degrees (default: `15.0`).
        public var maxAngleDegrees: Double

        /// Maximum image dimension (width or height) at the working pyramid level (default: `1600`).
        public var maxWorkingDimension: Int

        /// Minimum pixel count for a connected component to be retained at working resolution (default: `4`).
        public var minComponentPixels: Int

        /// Minimum bounding-box aspect ratio (`width / height`) for tall components; components taller than
        /// the vertical line threshold with a smaller aspect ratio are rejected as vertical lines or gutter shadows (default: `0.25`).
        public var minTextComponentAspectRatio: Double

        /// Maximum fraction of image height a single component may span before being rejected as non-text (default: `0.22`).
        public var maxComponentHeightFraction: Double

        /// Creates a skew estimator configuration.
        public init(
            maxAngleDegrees: Double = 15.0,
            maxWorkingDimension: Int = 1600,
            minComponentPixels: Int = 4,
            minTextComponentAspectRatio: Double = 0.25,
            maxComponentHeightFraction: Double = 0.22
        ) {
            self.maxAngleDegrees = max(0.5, min(45.0, maxAngleDegrees))
            self.maxWorkingDimension = max(256, maxWorkingDimension)
            self.minComponentPixels = max(1, minComponentPixels)
            self.minTextComponentAspectRatio = max(0.05, minTextComponentAspectRatio)
            self.maxComponentHeightFraction = max(0.05, min(1.0, maxComponentHeightFraction))
        }
    }

    /// Estimates the rotational skew of a binary document bitmap.
    /// - Parameters:
    ///   - bitmap: Source 1-bit monochrome bitmap (`1` = black foreground ink).
    ///   - configuration: Estimation configuration parameters.
    /// - Returns: A `SkewEstimate` containing the detected skew angle in degrees and confidence metrics.
    public static func estimateSkew(
        in bitmap: borrowing BinaryBitmap,
        configuration: Configuration = Configuration()
    ) -> SkewEstimate {
        // Step 1: Downsample to bounded working dimension
        var working = copy bitmap
        while max(working.width, working.height) > configuration.maxWorkingDimension,
              working.width >= 64,
              working.height >= 64 {
            working = BinaryDownsampler.downsample2x(working, minBlackSubpixels: 1)
        }

        // Step 2: Filter out non-text components (speckles, tall vertical gutter lines, huge graphic blocks)
        let (filtered, retainedComponents) = filterTextComponents(
            in: working,
            configuration: configuration
        )

        // Step 3: Extract centered foreground points
        let points = extractCenteredForegroundPoints(from: filtered)
        guard points.count >= 8 else {
            return SkewEstimate(
                angleDegrees: 0.0,
                confidence: 0.0,
                retainedComponentCount: retainedComponents,
                retainedPixelCount: points.count
            )
        }

        // Step 4: Hierarchical coarse -> medium -> fine projection energy search
        let diagonal = hypot(Double(filtered.width), Double(filtered.height))
        let profileLength = (Int(ceil(diagonal)) + 16) & ~1
        let profileCenter = Double(profileLength / 2)
        var profile = ContiguousArray<Double>(repeating: 0.0, count: profileLength)
        var scratch = ContiguousArray<Double>(repeating: 0.0, count: profileLength)

        let maxAngle = configuration.maxAngleDegrees

        // Stage A: Coarse search at 0.5° step
        let coarseStep = 0.5
        let (coarseBestAngle, coarseMedianEnergy) = searchAngleGrid(
            minAngle: -maxAngle,
            maxAngle: maxAngle,
            step: coarseStep,
            points: points,
            profileCenter: profileCenter,
            profile: &profile,
            scratch: &scratch
        )

        // Stage B: Medium search at 0.05° step within ±1.0° around coarse peak
        let mediumStep = 0.05
        let (mediumBestAngle, _) = searchAngleGrid(
            minAngle: max(-maxAngle, coarseBestAngle - 1.0),
            maxAngle: min(maxAngle, coarseBestAngle + 1.0),
            step: mediumStep,
            points: points,
            profileCenter: profileCenter,
            profile: &profile,
            scratch: &scratch
        )

        // Stage C: Fine search at 0.005° step within ±0.10° around medium peak with parabolic refinement
        let fineStep = 0.005
        let fineMin = max(-maxAngle, mediumBestAngle - 0.10)
        let fineMax = min(maxAngle, mediumBestAngle + 0.10)
        let (fineBestAngle, peakEnergy) = searchAngleGridWithParabolicRefinement(
            minAngle: fineMin,
            maxAngle: fineMax,
            step: fineStep,
            points: points,
            profileCenter: profileCenter,
            profile: &profile,
            scratch: &scratch
        )

        let ratio = coarseMedianEnergy > 1e-9 ? (peakEnergy / coarseMedianEnergy) : 1.0
        let confidence = min(1.0, max(0.0, (ratio - 1.0) / 4.0))

        return SkewEstimate(
            angleDegrees: fineBestAngle,
            confidence: confidence,
            retainedComponentCount: retainedComponents,
            retainedPixelCount: points.count
        )
    }

    /// Estimates the rotational skew of a continuous-tone grayscale document buffer.
    ///
    /// Performs fast area-averaging pyramid reduction followed by local-contrast integral binarization
    /// so uneven illumination and dark spine shadows do not bias the projection profile.
    /// - Parameters:
    ///   - buffer: Source 8-bit grayscale buffer.
    ///   - configuration: Estimation configuration parameters.
    /// - Returns: A `SkewEstimate` containing the detected skew angle in degrees and confidence metrics.
    public static func estimateSkew(
        in buffer: borrowing GrayscaleBuffer,
        configuration: Configuration = Configuration()
    ) -> SkewEstimate {
        var workingGray = copy buffer
        while max(workingGray.width, workingGray.height) > configuration.maxWorkingDimension,
              workingGray.width >= 64,
              workingGray.height >= 64 {
            workingGray = downsampleGrayscale2x(workingGray)
        }

        let binarized = binarizeForLayoutAnalysis(workingGray)
        return estimateSkew(in: binarized, configuration: configuration)
    }

    /// Counter-rotates a `GrayscaleBuffer` by `-angleDegrees` around its center to rectify document skew.
    ///
    /// If `abs(angleDegrees) < angleThresholdDegrees`, returns a copy of `buffer` without resampling.
    /// - Parameters:
    ///   - buffer: Source grayscale buffer.
    ///   - angleDegrees: Detected skew angle in degrees to correct.
    ///   - accelerator: Compute backend used to perform bilinear affine resampling.
    ///   - angleThresholdDegrees: Minimum absolute angle in degrees required to trigger resampling (default: `0.01`).
    /// - Returns: Deskewed `GrayscaleBuffer` of identical dimensions and DPI.
    public static func deskew(
        _ buffer: borrowing GrayscaleBuffer,
        by angleDegrees: Double,
        accelerator: some ComputeAccelerator,
        angleThresholdDegrees: Double = 0.01
    ) -> GrayscaleBuffer {
        guard abs(angleDegrees) >= angleThresholdDegrees else {
            return copy buffer
        }
        let size = Size2I(width: buffer.width, height: buffer.height)
        let center = Point2D(x: Double(size.width) * 0.5, y: Double(size.height) * 0.5)
        let transform = AffineTransform2D.rotation(
            radians: -angleDegrees * .pi / 180.0,
            center: center
        )
        return accelerator.affineWarp(buffer, transform: transform, outputSize: size)
    }

    // MARK: - Internal Helpers (Shared with PageSplitEstimator)

    /// Downsamples an 8-bit `GrayscaleBuffer` by $2 \times 2$ box averaging.
    internal static func downsampleGrayscale2x(_ buffer: borrowing GrayscaleBuffer) -> GrayscaleBuffer {
        let outW = max(1, buffer.width / 2)
        let outH = max(1, buffer.height / 2)
        guard buffer.width >= 2, buffer.height >= 2 else {
            return copy buffer
        }

        let srcW = buffer.width
        var outPixels = ContiguousArray<UInt8>(repeating: 255, count: outW * outH)

        buffer.pixels.withUnsafeBufferPointer { srcPtr in
            outPixels.withUnsafeMutableBufferPointer { dstPtr in
                for y in 0..<outH {
                    let row0 = (y * 2) * srcW
                    let row1 = row0 + srcW
                    let dstRow = y * outW
                    for x in 0..<outW {
                        let col0 = x * 2
                        let sum = Int(srcPtr[row0 + col0])
                            + Int(srcPtr[row0 + col0 + 1])
                            + Int(srcPtr[row1 + col0])
                            + Int(srcPtr[row1 + col0 + 1])
                        dstPtr[dstRow + x] = UInt8((sum + 2) >> 2)
                    }
                }
            }
        }

        return GrayscaleBuffer(width: outW, height: outH, dpi: max(72, buffer.dpi / 2), pixels: outPixels)
    }

    /// Fast local-contrast adaptive binarization tailored for layout and skew analysis.
    ///
    /// Uses afirst-order integral image with a window radius proportional to page dimensions so that
    /// dark spine shadows with low local contrast are suppressed into background (`0`) while crisp dark
    /// text strokes become foreground (`1`).
    internal static func binarizeForLayoutAnalysis(_ buffer: borrowing GrayscaleBuffer) -> BinaryBitmap {
        let width = buffer.width
        let height = buffer.height
        let stride = width + 1

        // Build first-order integral sum table
        var sumTable = ContiguousArray<UInt64>(repeating: 0, count: stride * (height + 1))
        buffer.pixels.withUnsafeBufferPointer { src in
            sumTable.withUnsafeMutableBufferPointer { sumPtr in
                for y in 0..<height {
                    var rowAcc: UInt64 = 0
                    let srcRow = y * width
                    let prevSumRow = y * stride
                    let curSumRow = (y + 1) * stride
                    for x in 0..<width {
                        rowAcc += UInt64(src[srcRow + x])
                        sumPtr[curSumRow + x + 1] = sumPtr[prevSumRow + x + 1] + rowAcc
                    }
                }
            }
        }

        let totalSum = sumTable[height * stride + width]
        let globalMean = Double(totalSum) / Double(max(1, width * height))
        let globalCap = UInt8(clamping: Int(min(235.0, globalMean - 8.0)))

        let radius = max(12, min(width, height) / 28)
        let contrastDelta = 14

        var bitmap = BinaryBitmap(width: width, height: height, initialBlack: false)
        let wordsPerRow = bitmap.wordsPerRow

        buffer.pixels.withUnsafeBufferPointer { src in
            sumTable.withUnsafeBufferPointer { sumPtr in
                bitmap.withUnsafeMutableWords { words in
                    for y in 0..<height {
                        let y0 = max(0, y - radius)
                        let y1 = min(height, y + radius + 1)
                        let r0 = y0 * stride
                        let r1 = y1 * stride
                        let winH = y1 - y0
                        let srcRow = y * width
                        let wordRow = y * wordsPerRow

                        for x in 0..<width {
                            let px = src[srcRow + x]
                            guard px <= globalCap else { continue }

                            let x0 = max(0, x - radius)
                            let x1 = min(width, x + radius + 1)
                            let area = (x1 - x0) * winH
                            let winSum = (sumPtr[r1 + x1] + sumPtr[r0 + x0]) - (sumPtr[r1 + x0] + sumPtr[r0 + x1])
                            let localMean = Int(winSum) / area

                            if Int(px) + contrastDelta < localMean {
                                let wIdx = wordRow + (x >> 6)
                                let mask = UInt64(1) << (63 - (x & 63))
                                words[wIdx] |= mask
                            }
                        }
                    }
                }
            }
        }

        return bitmap
    }

    // MARK: - Private Implementation

    private struct RelativePoint {
        let dx: Double
        let dy: Double
    }

    private static func filterTextComponents(
        in bitmap: borrowing BinaryBitmap,
        configuration: Configuration
    ) -> (bitmap: BinaryBitmap, retainedCount: Int) {
        let maxHeight = max(24, Int(Double(bitmap.height) * configuration.maxComponentHeightFraction))
        let verticalLineMinHeight = max(20, bitmap.height / 18)
        let minPixels = configuration.minComponentPixels
        let minAspect = configuration.minTextComponentAspectRatio

        var retainedCount = 0
        let filtered = ConnectedComponentAnalyzer.filterComponents(in: bitmap, connectivity: .eight) { comp in
            guard comp.pixelCount >= minPixels else { return false }
            let box = comp.boundingBox
            guard box.height <= maxHeight else { return false }
            // Reject tall, thin vertical lines / gutter borders / margin rules
            if box.height >= verticalLineMinHeight && comp.aspectRatio < minAspect {
                return false
            }
            retainedCount += 1
            return true
        }

        if retainedCount == 0 && !bitmap.isEmpty {
            return (copy bitmap, 1)
        }
        return (filtered, retainedCount)
    }

    private static func extractCenteredForegroundPoints(
        from bitmap: borrowing BinaryBitmap
    ) -> ContiguousArray<RelativePoint> {
        let totalBlack = bitmap.countBlackPixels()
        guard totalBlack > 0 else { return [] }

        // If the bitmap has a dense foreground (> 24,000 points), stride-sample deterministically
        let sampleStride = max(1, totalBlack / 24_000)
        var points = ContiguousArray<RelativePoint>()
        points.reserveCapacity(totalBlack / sampleStride + 16)

        let width = bitmap.width
        let height = bitmap.height
        let wordsPerRow = bitmap.wordsPerRow
        let centerX = Double(width / 2)
        let centerY = Double(height / 2)

        var seen = 0
        bitmap.withUnsafeWords { words in
            for y in 0..<height {
                let dy = Double(y) - centerY
                let rowStart = y * wordsPerRow
                for col in 0..<wordsPerRow {
                    var w = words[rowStart + col]
                    guard w != 0 else { continue }
                    let baseX = col << 6
                    while w != 0 {
                        let lz = w.leadingZeroBitCount
                        let x = baseX + lz
                        if x < width {
                            if sampleStride == 1 || (seen % sampleStride == 0) {
                                points.append(RelativePoint(dx: Double(x) - centerX, dy: dy))
                            }
                            seen += 1
                        }
                        w &= ~(UInt64(1) << (63 - lz))
                    }
                }
            }
        }

        return points
    }

    private static func searchAngleGrid(
        minAngle: Double,
        maxAngle: Double,
        step: Double,
        points: ContiguousArray<RelativePoint>,
        profileCenter: Double,
        profile: inout ContiguousArray<Double>,
        scratch: inout ContiguousArray<Double>
    ) -> (bestAngle: Double, medianEnergy: Double) {
        let count = max(1, Int(round((maxAngle - minAngle) / step)) + 1)
        var energies = ContiguousArray<Double>()
        energies.reserveCapacity(count)

        var bestAngle = 0.0
        var bestEnergy = -1.0

        for i in 0..<count {
            let angle = min(maxAngle, minAngle + Double(i) * step)
            let energy = projectionEnergy(
                atDegrees: angle,
                points: points,
                profileCenter: profileCenter,
                profile: &profile,
                scratch: &scratch
            )
            energies.append(energy)
            if energy > bestEnergy {
                bestEnergy = energy
                bestAngle = angle
            }
        }

        var sorted = Array(energies)
        sorted.sort()
        let median = sorted.isEmpty ? 0.0 : sorted[sorted.count / 2]
        return (bestAngle, median)
    }

    private static func searchAngleGridWithParabolicRefinement(
        minAngle: Double,
        maxAngle: Double,
        step: Double,
        points: ContiguousArray<RelativePoint>,
        profileCenter: Double,
        profile: inout ContiguousArray<Double>,
        scratch: inout ContiguousArray<Double>
    ) -> (bestAngle: Double, peakEnergy: Double) {
        let count = max(1, Int(round((maxAngle - minAngle) / step)) + 1)
        var angles = ContiguousArray<Double>()
        var energies = ContiguousArray<Double>()
        angles.reserveCapacity(count)
        energies.reserveCapacity(count)

        var bestIdx = 0
        var bestEnergy = -1.0

        for i in 0..<count {
            let angle = min(maxAngle, minAngle + Double(i) * step)
            let energy = projectionEnergy(
                atDegrees: angle,
                points: points,
                profileCenter: profileCenter,
                profile: &profile,
                scratch: &scratch
            )
            angles.append(angle)
            energies.append(energy)
            if energy > bestEnergy {
                bestEnergy = energy
                bestIdx = i
            }
        }

        var refinedAngle = angles[bestIdx]
        if bestIdx > 0 && bestIdx + 1 < count {
            let ePrev = energies[bestIdx - 1]
            let eCurr = energies[bestIdx]
            let eNext = energies[bestIdx + 1]
            let denom = ePrev - 2.0 * eCurr + eNext
            if abs(denom) > 1e-12 {
                let delta = 0.5 * (ePrev - eNext) / denom
                let clampedDelta = max(-0.5, min(0.5, delta))
                refinedAngle = angles[bestIdx] + clampedDelta * step
            }
        }

        return (refinedAngle, bestEnergy)
    }

    /// Evaluates the smoothed horizontal projection profile energy at `angleDegrees`.
    ///
    /// Projects points onto $v = dy \cos\theta - dx \sin\theta + \text{profileCenter}$, accumulates
    /// sub-pixel linear weights, applies two passes of `[0.25, 0.5, 0.25]` binomial smoothing to remove
    /// integer-row quantization bias at $0^\circ$, and sums squared density plus central-difference gradient squared.
    @inline(__always)
    private static func projectionEnergy(
        atDegrees angleDegrees: Double,
        points: ContiguousArray<RelativePoint>,
        profileCenter: Double,
        profile: inout ContiguousArray<Double>,
        scratch: inout ContiguousArray<Double>
    ) -> Double {
        let radians = angleDegrees * .pi / 180.0
        let cosA = cos(radians)
        let sinA = sin(radians)
        let n = profile.count

        return profile.withUnsafeMutableBufferPointer { profPtr in
            scratch.withUnsafeMutableBufferPointer { scratchPtr in
                for i in 0..<n {
                    profPtr[i] = 0.0
                }

                var minBin = n - 1
                var maxBin = 0
                let maxValidIdx = n - 2

                points.withUnsafeBufferPointer { ptPtr in
                    for i in 0..<ptPtr.count {
                        let pt = ptPtr[i]
                        let v = pt.dy * cosA - pt.dx * sinA + profileCenter
                        let idx = Int(v)
                        if idx >= 1 && idx < maxValidIdx {
                            let frac = v - Double(idx)
                            profPtr[idx] += (1.0 - frac)
                            profPtr[idx + 1] += frac
                            if idx < minBin { minBin = idx }
                            if idx + 1 > maxBin { maxBin = idx + 1 }
                        }
                    }
                }

                guard minBin <= maxBin else { return 0.0 }
                let lo = max(2, minBin - 2)
                let hi = min(n - 3, maxBin + 2)
                guard lo <= hi else { return 0.0 }

                // Pass 1 of [0.25, 0.5, 0.25] binomial smoothing: profPtr -> scratchPtr
                scratchPtr[lo - 1] = 0.0
                scratchPtr[hi + 1] = 0.0
                for i in lo...hi {
                    scratchPtr[i] = 0.25 * profPtr[i - 1] + 0.5 * profPtr[i] + 0.25 * profPtr[i + 1]
                }

                // Pass 2 of [0.25, 0.5, 0.25] binomial smoothing: scratchPtr -> profPtr
                for i in lo...hi {
                    profPtr[i] = 0.25 * scratchPtr[i - 1] + 0.5 * scratchPtr[i] + 0.25 * scratchPtr[i + 1]
                }

                // Evaluate combined variance + central-difference gradient energy
                var energy = 0.0
                for i in lo...hi {
                    let val = profPtr[i]
                    let diff = profPtr[i + 1] - profPtr[i - 1]
                    energy += val * val + diff * diff
                }
                return energy
            }
        }
    }
}
