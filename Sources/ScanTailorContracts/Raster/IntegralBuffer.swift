import Foundation

/// Dual integral image buffer storing first-order pixel sums ($\Sigma I$) and second-order
/// sums-of-squares ($\Sigma I^2$) in 64-bit precision to enable $O(1)$ local mean and variance queries.
///
/// Uses standard $(W+1) \times (H+1)$ 1-based indexing so that window sums require zero boundary branches:
/// $$\text{Sum}([x_0, x_1) \times [y_0, y_1)) = I(x_1, y_1) - I(x_0, y_1) - I(x_1, y_0) + I(x_0, y_0)$$
public struct IntegralBuffer: Sendable, Equatable {
    /// Original image width in pixels.
    public let width: Int

    /// Original image height in pixels.
    public let height: Int

    /// Stride of the integral table: `width + 1`.
    public let tableStride: Int

    /// First-order integral table ($\Sigma I$) of size `(width + 1) * (height + 1)`.
    public var sumTable: ContiguousArray<UInt64>

    /// Second-order integral table ($\Sigma I^2$) of size `(width + 1) * (height + 1)`.
    public var sumSqTable: ContiguousArray<UInt64>

    /// Creates an integral buffer from existing tables.
    /// - Parameters:
    ///   - width: Image width.
    ///   - height: Image height.
    ///   - sumTable: First-order table of size `(width + 1) * (height + 1)`.
    ///   - sumSqTable: Second-order table of size `(width + 1) * (height + 1)`.
    public init(
        width: Int,
        height: Int,
        sumTable: ContiguousArray<UInt64>,
        sumSqTable: ContiguousArray<UInt64>
    ) {
        precondition(width > 0 && height > 0, "Dimensions must be strictly positive")
        let expectedCount = (width + 1) * (height + 1)
        precondition(sumTable.count == expectedCount, "sumTable count (\(sumTable.count)) does not match expected (\(expectedCount))")
        precondition(sumSqTable.count == expectedCount, "sumSqTable count (\(sumSqTable.count)) does not match expected (\(expectedCount))")

        self.width = width
        self.height = height
        self.tableStride = width + 1
        self.sumTable = sumTable
        self.sumSqTable = sumSqTable
    }

    /// Evaluates the sum of pixel values within the specified half-open rectangle `[minX, maxX) x [minY, maxY)`.
    /// Coordinates are clamped to valid image bounds.
    public func sum(in rect: Rect2I) -> UInt64 {
        let x0 = max(0, min(width, rect.minX))
        let x1 = max(0, min(width, rect.maxX))
        let y0 = max(0, min(height, rect.minY))
        let y1 = max(0, min(height, rect.maxY))

        guard x1 > x0, y1 > y0 else { return 0 }

        let r0 = y0 * tableStride
        let r1 = y1 * tableStride

        let br = sumTable[r1 + x1]
        let bl = sumTable[r1 + x0]
        let tr = sumTable[r0 + x1]
        let tl = sumTable[r0 + x0]

        return br - bl - tr + tl
    }

    /// Evaluates the sum of squared pixel values ($\Sigma I^2$) within the specified rectangle.
    public func sumOfSquares(in rect: Rect2I) -> UInt64 {
        let x0 = max(0, min(width, rect.minX))
        let x1 = max(0, min(width, rect.maxX))
        let y0 = max(0, min(height, rect.minY))
        let y1 = max(0, min(height, rect.maxY))

        guard x1 > x0, y1 > y0 else { return 0 }

        let r0 = y0 * tableStride
        let r1 = y1 * tableStride

        let br = sumSqTable[r1 + x1]
        let bl = sumSqTable[r1 + x0]
        let tr = sumSqTable[r0 + x1]
        let tl = sumSqTable[r0 + x0]

        return br - bl - tr + tl
    }

    /// Computes the local mean and standard deviation for a given rectangular window.
    /// - Parameter rect: The window rectangle.
    /// - Returns: A tuple `(mean: Double, stdDev: Double)` or `(0.0, 0.0)` if empty.
    public func windowStatistics(in rect: Rect2I) -> (mean: Double, stdDev: Double) {
        let x0 = max(0, min(width, rect.minX))
        let x1 = max(0, min(width, rect.maxX))
        let y0 = max(0, min(height, rect.minY))
        let y1 = max(0, min(height, rect.maxY))

        let pixelCount = (x1 - x0) * (y1 - y0)
        guard pixelCount > 0 else { return (0, 0) }

        let s = sum(in: Rect2I(minX: x0, minY: y0, maxX: x1, maxY: y1))
        let sq = sumOfSquares(in: Rect2I(minX: x0, minY: y0, maxX: x1, maxY: y1))

        let n = Double(pixelCount)
        let mean = Double(s) / n
        let meanSq = Double(sq) / n
        let variance = max(0, meanSq - mean * mean)
        return (mean: mean, stdDev: variance.squareRoot())
    }
}
