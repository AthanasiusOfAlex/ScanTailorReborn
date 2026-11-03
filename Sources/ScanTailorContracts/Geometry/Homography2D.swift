import Foundation

/// A 2D projective transformation (planar homography) represented by a row-major 3×3 matrix:
/// ```
/// [ m0  m1  m2 ]
/// [ m3  m4  m5 ]
/// [ m6  m7  m8 ]
/// ```
/// mapping a point `(x, y)` to `((m0·x + m1·y + m2) / w, (m3·x + m4·y + m5) / w)` with
/// `w = m6·x + m7·y + m8`.
///
/// Matrices are kept normalized so that `m8 == 1` whenever `m8` is not near zero; this makes
/// equality and `Codable` round-trips meaningful for every homography produced by this type.
public struct Homography2D: Sendable, Equatable, Hashable, Codable {
    /// Row-major matrix entries (always 9 elements).
    public private(set) var matrix: [Double]

    /// Creates a homography from 9 row-major matrix entries.
    ///
    /// - Parameter matrix: Row-major entries. Must contain exactly 9 finite values.
    /// - Throws: `GeometryError.invalidDimensions` for a wrong entry count, or
    ///   `GeometryError.singularMatrix` when the matrix is non-finite or singular.
    public init(matrix: [Double]) throws(GeometryError) {
        guard matrix.count == 9 else {
            throw GeometryError.invalidDimensions(width: matrix.count, height: 1)
        }
        guard matrix.allSatisfy(\.isFinite), abs(Self.determinant(of: matrix)) > 1e-300 else {
            throw GeometryError.singularMatrix(description: "Homography matrix is singular or non-finite")
        }
        self.matrix = Self.normalized(matrix)
    }

    private init(unchecked matrix: [Double]) {
        self.matrix = Self.normalized(matrix)
    }

    /// Promotes an affine transform to a homography.
    public init(_ affine: AffineTransform2D) {
        self.init(unchecked: [affine.a, affine.c, affine.tx, affine.b, affine.d, affine.ty, 0, 0, 1])
    }

    /// The identity homography.
    public static let identity = Homography2D(unchecked: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// Estimates the homography mapping each `source[i]` onto `destination[i]`.
    ///
    /// Uses the normalized direct linear transform: both point sets are translated to their
    /// centroids and scaled to a mean distance of √2 before the 8-parameter linear system
    /// (least squares when more than four correspondences are given) is solved with partially
    /// pivoted Gaussian elimination.
    ///
    /// - Parameters:
    ///   - source: Source points (at least 4).
    ///   - destination: Corresponding destination points (same count as `source`).
    /// - Returns: The homography, or `nil` when the configuration is degenerate (fewer than four
    ///   points, mismatched counts, three collinear points, or a singular system).
    public init?(mapping source: [Point2D], to destination: [Point2D]) {
        guard source.count >= 4, source.count == destination.count,
              source.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              destination.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let (sourceNorm, sourceT) = Self.normalization(source),
              let (destinationNorm, destinationT) = Self.normalization(destination)
        else { return nil }
        if source.count == 4, Self.hasCollinearTriple(sourceNorm) || Self.hasCollinearTriple(destinationNorm) {
            return nil
        }

        // Accumulate normal equations AᵀA·h = Aᵀb for the 8 unknowns (m8 fixed at 1).
        var ata = [Double](repeating: 0, count: 64)
        var atb = [Double](repeating: 0, count: 8)
        for (p, q) in zip(sourceNorm, destinationNorm) {
            let rows: [([Double], Double)] = [
                ([p.x, p.y, 1, 0, 0, 0, -p.x * q.x, -p.y * q.x], q.x),
                ([0, 0, 0, p.x, p.y, 1, -p.x * q.y, -p.y * q.y], q.y),
            ]
            for (row, rhs) in rows {
                for i in 0..<8 {
                    atb[i] += row[i] * rhs
                    for j in 0..<8 { ata[i * 8 + j] += row[i] * row[j] }
                }
            }
        }
        guard let h = Self.solve(ata, atb, size: 8) else { return nil }
        let normalizedH = h + [1]

        // Denormalize: H = T_dst⁻¹ · Ĥ · T_src.
        let full = Self.multiply(Self.multiply(Self.inverseSimilarity(destinationT), normalizedH), sourceT)
        guard full.allSatisfy(\.isFinite), abs(Self.determinant(of: full)) > 1e-300 else { return nil }
        self.init(unchecked: full)
    }

    /// Whether any three of the (normalized) points are numerically collinear.
    private static func hasCollinearTriple(_ points: [Point2D]) -> Bool {
        let n = points.count
        for i in 0..<n {
            for j in (i + 1)..<n {
                for k in (j + 1)..<n {
                    let a = points[j] - points[i]
                    let b = points[k] - points[i]
                    if abs(a.x * b.y - a.y * b.x) < 1e-9 { return true }
                }
            }
        }
        return false
    }

    /// Determinant of the 3×3 matrix.
    public var determinant: Double { Self.determinant(of: matrix) }

    /// Whether this homography is an affine transform (projective row equal to `[0, 0, 1]`).
    public var isAffine: Bool { abs(matrix[6]) < 1e-15 && abs(matrix[7]) < 1e-15 }

    /// Projects a point.
    ///
    /// - Parameter point: Source point.
    /// - Returns: The projected point, or `nil` when the point lies on (or numerically at) the
    ///   line at infinity of this transform (`|w| ≤ 1e-12`).
    public func transform(_ point: Point2D) -> Point2D? {
        let m = matrix
        let w = m[6] * point.x + m[7] * point.y + m[8]
        guard abs(w) > 1e-12 else { return nil }
        return Point2D(
            x: (m[0] * point.x + m[1] * point.y + m[2]) / w,
            y: (m[3] * point.x + m[4] * point.y + m[5]) / w
        )
    }

    /// Returns the homography applying `self` first and then `other` (`other · self`).
    public func concatenating(_ other: Homography2D) -> Homography2D {
        Homography2D(unchecked: Self.multiply(other.matrix, matrix))
    }

    /// Inverts the homography.
    ///
    /// - Throws: `GeometryError.singularMatrix` if the matrix is not invertible.
    public func inverted() throws(GeometryError) -> Homography2D {
        let m = matrix
        let det = determinant
        guard abs(det) > 1e-300, det.isFinite else {
            throw GeometryError.singularMatrix(description: "Homography determinant \(det) is approximately zero")
        }
        let adjugate = [
            m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
            m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
            m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
        ]
        return Homography2D(unchecked: adjugate.map { $0 / det })
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case matrix }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.decode([Double].self, forKey: .matrix)
        do {
            try self.init(matrix: values)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .matrix, in: container, debugDescription: error.description
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(matrix, forKey: .matrix)
    }

    // MARK: - Linear Algebra Helpers

    private static func normalized(_ m: [Double]) -> [Double] {
        guard abs(m[8]) > 1e-12 else { return m }
        let s = 1.0 / m[8]
        return m.map { $0 * s }
    }

    private static func determinant(of m: [Double]) -> Double {
        m[0] * (m[4] * m[8] - m[5] * m[7])
            - m[1] * (m[3] * m[8] - m[5] * m[6])
            + m[2] * (m[3] * m[7] - m[4] * m[6])
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var r = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j]
            }
        }
        return r
    }

    /// Hartley normalization: returns normalized points and the similarity `T` (row-major 3×3).
    private static func normalization(_ points: [Point2D]) -> ([Point2D], [Double])? {
        let n = Double(points.count)
        let cx = points.reduce(0) { $0 + $1.x } / n
        let cy = points.reduce(0) { $0 + $1.y } / n
        let meanDistance = points.reduce(0) { $0 + (($1.x - cx) * ($1.x - cx) + ($1.y - cy) * ($1.y - cy)).squareRoot() } / n
        guard meanDistance > 1e-12 else { return nil }
        let s = 2.0.squareRoot() / meanDistance
        return (points.map { Point2D(x: ($0.x - cx) * s, y: ($0.y - cy) * s) }, [s, 0, -s * cx, 0, s, -s * cy, 0, 0, 1])
    }

    private static func inverseSimilarity(_ t: [Double]) -> [Double] {
        let s = t[0]
        return [1 / s, 0, -t[2] / s, 0, 1 / s, -t[5] / s, 0, 0, 1]
    }

    /// Solves `A·x = b` (row-major `size × size`) with partial pivoting; `nil` when singular.
    private static func solve(_ matrix: [Double], _ rhs: [Double], size n: Int) -> [Double]? {
        var a = matrix
        var b = rhs
        let scale = a.map(abs).max() ?? 0
        guard scale > 0 else { return nil }
        for column in 0..<n {
            var pivot = column
            for row in (column + 1)..<n where abs(a[row * n + column]) > abs(a[pivot * n + column]) {
                pivot = row
            }
            guard abs(a[pivot * n + column]) > 1e-12 * scale else { return nil }
            if pivot != column {
                for k in 0..<n { a.swapAt(column * n + k, pivot * n + k) }
                b.swapAt(column, pivot)
            }
            let diagonal = a[column * n + column]
            for row in (column + 1)..<n {
                let factor = a[row * n + column] / diagonal
                guard factor != 0 else { continue }
                for k in column..<n { a[row * n + k] -= factor * a[column * n + k] }
                b[row] -= factor * b[column]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<n { sum -= a[row * n + k] * x[k] }
            x[row] = sum / a[row * n + row]
        }
        return x
    }
}
