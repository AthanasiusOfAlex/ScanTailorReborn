import Foundation

/// A 2D affine transformation representing a 3x3 matrix:
/// ```
/// [ a   c   tx ]
/// [ b   d   ty ]
/// [ 0   0   1  ]
/// ```
/// transforming a point `[x, y]` into:
/// `x' = a * x + c * y + tx`
/// `y' = b * x + d * y + ty`
public struct AffineTransform2D: Sendable, Equatable, Hashable, Codable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    /// Creates an affine transform with explicit components.
    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    /// The identity transformation.
    public static let identity = AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    /// Creates a translation transformation.
    public static func translation(tx: Double, ty: Double) -> AffineTransform2D {
        AffineTransform2D(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty)
    }

    /// Creates a uniform or non-uniform scaling transformation.
    public static func scale(sx: Double, sy: Double) -> AffineTransform2D {
        AffineTransform2D(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    /// Creates a rotation transformation around the origin `(0, 0)` by angle in radians.
    public static func rotation(radians: Double) -> AffineTransform2D {
        let cosA = cos(radians)
        let sinA = sin(radians)
        return AffineTransform2D(a: cosA, b: sinA, c: -sinA, d: cosA, tx: 0, ty: 0)
    }

    /// Creates a rotation transformation around an arbitrary center point.
    public static func rotation(radians: Double, center: Point2D) -> AffineTransform2D {
        let toOrigin = translation(tx: -center.x, ty: -center.y)
        let rot = rotation(radians: radians)
        let back = translation(tx: center.x, ty: center.y)
        return toOrigin.concatenating(rot).concatenating(back)
    }

    /// Returns the matrix product of `self` followed by `other`: `other * self`.
    public func concatenating(_ other: AffineTransform2D) -> AffineTransform2D {
        AffineTransform2D(
            a: other.a * a + other.c * b,
            b: other.b * a + other.d * b,
            c: other.a * c + other.c * d,
            d: other.b * c + other.d * d,
            tx: other.a * tx + other.c * ty + other.tx,
            ty: other.b * tx + other.d * ty + other.ty
        )
    }

    /// Computes the determinant of the 2x2 linear portion `(a * d - b * c)`.
    public var determinant: Double {
        a * d - b * c
    }

    /// Checks if the transformation can be inverted.
    public var isInvertible: Bool {
        abs(determinant) > 1e-12
    }

    /// Inverts the affine transformation.
    /// - Throws: `GeometryError.singularMatrix` if the determinant is near zero.
    public func inverted() throws(GeometryError) -> AffineTransform2D {
        let det = determinant
        guard abs(det) > 1e-12 else {
            throw GeometryError.singularMatrix(description: "Determinant \(det) is approximately zero")
        }
        let invDet = 1.0 / det
        return AffineTransform2D(
            a: d * invDet,
            b: -b * invDet,
            c: -c * invDet,
            d: a * invDet,
            tx: (c * ty - d * tx) * invDet,
            ty: (b * tx - a * ty) * invDet
        )
    }

    /// Transforms a 2D point.
    public func transform(_ point: Point2D) -> Point2D {
        Point2D(
            x: a * point.x + c * point.y + tx,
            y: b * point.x + d * point.y + ty
        )
    }

    /// Transforms an axis-aligned rectangle and returns the minimal axis-aligned bounding box enclosing all four transformed corners.
    public func transform(_ rect: Rect2D) -> Rect2D {
        let p1 = transform(Point2D(x: rect.minX, y: rect.minY))
        let p2 = transform(Point2D(x: rect.maxX, y: rect.minY))
        let p3 = transform(Point2D(x: rect.maxX, y: rect.maxY))
        let p4 = transform(Point2D(x: rect.minX, y: rect.maxY))

        let minX = min(p1.x, p2.x, p3.x, p4.x)
        let maxX = max(p1.x, p2.x, p3.x, p4.x)
        let minY = min(p1.y, p2.y, p3.y, p4.y)
        let maxY = max(p1.y, p2.y, p3.y, p4.y)

        return Rect2D(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
}
