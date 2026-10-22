import Foundation

/// A 2D point with double-precision floating-point coordinates.
public struct Point2D: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double

    /// Creates a 2D point with the given coordinates.
    /// - Parameters:
    ///   - x: The horizontal coordinate.
    ///   - y: The vertical coordinate.
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    /// The origin point `(0, 0)`.
    public static let zero = Point2D(x: 0, y: 0)

    /// Calculates the Euclidean distance to another point.
    /// - Parameter other: The destination point.
    /// - Returns: The straight-line Euclidean distance.
    public func distance(to other: Point2D) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Calculates the squared Euclidean distance to another point.
    /// - Parameter other: The destination point.
    /// - Returns: The squared Euclidean distance.
    public func squaredDistance(to other: Point2D) -> Double {
        let dx = other.x - x
        let dy = other.y - y
        return dx * dx + dy * dy
    }

    /// Returns a new point rotated around a given center by an angle in radians.
    /// - Parameters:
    ///   - radians: The angle of rotation in radians (counter-clockwise).
    ///   - center: The pivot point (default: `.zero`).
    /// - Returns: The rotated point.
    public func rotated(by radians: Double, around center: Point2D = .zero) -> Point2D {
        let cosA = cos(radians)
        let sinA = sin(radians)
        let dx = x - center.x
        let dy = y - center.y
        return Point2D(
            x: center.x + (dx * cosA - dy * sinA),
            y: center.y + (dx * sinA + dy * cosA)
        )
    }

    // MARK: - Vector Arithmetic

    public static func + (lhs: Point2D, rhs: Point2D) -> Point2D {
        Point2D(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    public static func - (lhs: Point2D, rhs: Point2D) -> Point2D {
        Point2D(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    public static func * (lhs: Point2D, scalar: Double) -> Point2D {
        Point2D(x: lhs.x * scalar, y: lhs.y * scalar)
    }

    public static func * (scalar: Double, rhs: Point2D) -> Point2D {
        Point2D(x: rhs.x * scalar, y: rhs.y * scalar)
    }

    public static func / (lhs: Point2D, scalar: Double) -> Point2D {
        Point2D(x: lhs.x / scalar, y: lhs.y / scalar)
    }

    public static prefix func - (point: Point2D) -> Point2D {
        Point2D(x: -point.x, y: -point.y)
    }
}
