import Foundation

/// A 2D regular sampling mesh representing an inverse mapping from rectified output coordinates
/// `(u, v)` to distorted source coordinates `(x, y)`.
public struct DewarpGrid: Sendable, Equatable, Codable {
    /// The target rectified output raster size in pixels.
    public let outputSize: Size2I

    /// Number of control columns in the grid.
    public let columns: Int

    /// Number of control rows in the grid.
    public let rows: Int

    /// Source image coordinates `(x, y)` for each grid node in row-major order.
    /// Count must equal `columns * rows`.
    public var sourcePoints: ContiguousArray<Point2D>

    /// Creates a dewarp mesh grid.
    /// - Parameters:
    ///   - outputSize: The target rectified raster dimensions.
    ///   - columns: Number of horizontal grid vertices (>= 2).
    ///   - rows: Number of vertical grid vertices (>= 2).
    ///   - sourcePoints: Array of source points of size `columns * rows`.
    public init(outputSize: Size2I, columns: Int, rows: Int, sourcePoints: ContiguousArray<Point2D>) {
        precondition(columns >= 2 && rows >= 2, "DewarpGrid must have at least 2 columns and 2 rows")
        precondition(sourcePoints.count == columns * rows, "sourcePoints count (\(sourcePoints.count)) does not match columns * rows (\(columns * rows))")
        self.outputSize = outputSize
        self.columns = columns
        self.rows = rows
        self.sourcePoints = sourcePoints
    }

    /// Creates an identity grid where each output point maps directly to itself.
    public static func identity(outputSize: Size2I, columns: Int = 32, rows: Int = 32) -> DewarpGrid {
        var points = ContiguousArray<Point2D>()
        points.reserveCapacity(columns * rows)

        let stepX = Double(outputSize.width) / Double(max(1, columns - 1))
        let stepY = Double(outputSize.height) / Double(max(1, rows - 1))

        for r in 0..<rows {
            let y = Double(r) * stepY
            for c in 0..<columns {
                let x = Double(c) * stepX
                points.append(Point2D(x: x, y: y))
            }
        }
        return DewarpGrid(outputSize: outputSize, columns: columns, rows: rows, sourcePoints: points)
    }

    /// Evaluates the source coordinates for a given output pixel coordinate using bilinear interpolation.
    /// - Parameters:
    ///   - outputX: Horizontal coordinate in output image space `[0, outputSize.width)`.
    ///   - outputY: Vertical coordinate in output image space `[0, outputSize.height)`.
    /// - Returns: Corresponding `(x, y)` coordinate in distorted source image space.
    public func sampleSource(outputX: Double, outputY: Double) -> Point2D {
        guard columns >= 2 && rows >= 2 else { return Point2D(x: outputX, y: outputY) }

        let normalizedX = max(0, min(1, outputX / Double(max(1, outputSize.width))))
        let normalizedY = max(0, min(1, outputY / Double(max(1, outputSize.height))))

        let gridX = normalizedX * Double(columns - 1)
        let gridY = normalizedY * Double(rows - 1)

        let c0 = min(Int(gridX), columns - 2)
        let r0 = min(Int(gridY), rows - 2)
        let c1 = c0 + 1
        let r1 = r0 + 1

        let fx = gridX - Double(c0)
        let fy = gridY - Double(r0)

        let p00 = sourcePoints[r0 * columns + c0]
        let p10 = sourcePoints[r0 * columns + c1]
        let p01 = sourcePoints[r1 * columns + c0]
        let p11 = sourcePoints[r1 * columns + c1]

        let topX = p00.x + fx * (p10.x - p00.x)
        let topY = p00.y + fx * (p10.y - p00.y)

        let botX = p01.x + fx * (p11.x - p01.x)
        let botY = p01.y + fx * (p11.y - p01.y)

        let finalX = topX + fy * (botX - topX)
        let finalY = topY + fy * (botY - topY)

        return Point2D(x: finalX, y: finalY)
    }
}
