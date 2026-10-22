import Foundation

/// A 2D point with integer coordinates representing pixel positions.
public struct Point2I: Sendable, Equatable, Hashable, Codable {
    public var x: Int
    public var y: Int

    /// Creates an integer 2D point.
    /// - Parameters:
    ///   - x: The horizontal pixel index.
    ///   - y: The vertical pixel index.
    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }

    /// The origin pixel `(0, 0)`.
    public static let zero = Point2I(x: 0, y: 0)

    /// Converts to floating-point coordinates.
    public var asPoint2D: Point2D {
        Point2D(x: Double(x), y: Double(y))
    }

    public static func + (lhs: Point2I, rhs: Point2I) -> Point2I {
        Point2I(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    public static func - (lhs: Point2I, rhs: Point2I) -> Point2I {
        Point2I(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }
}
