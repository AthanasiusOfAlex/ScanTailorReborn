import Foundation

/// An axis-aligned 2D rectangle in continuous floating-point coordinates.
public struct Rect2D: Sendable, Equatable, Hashable, Codable {
    public var origin: Point2D
    public var size: Size2D

    /// Creates a rectangle from an origin point and size.
    /// - Parameters:
    ///   - origin: The top-left or reference origin point.
    ///   - size: The dimensions of the rectangle.
    public init(origin: Point2D, size: Size2D) {
        self.origin = origin
        self.size = size
    }

    /// Creates a rectangle from coordinates and dimensions.
    /// - Parameters:
    ///   - x: Origin x-coordinate.
    ///   - y: Origin y-coordinate.
    ///   - width: Width dimension.
    ///   - height: Height dimension.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.origin = Point2D(x: x, y: y)
        self.size = Size2D(width: width, height: height)
    }

    /// Creates a normalized rectangle from minimum and maximum bounding coordinates.
    /// - Parameters:
    ///   - minX: Left-most coordinate.
    ///   - minY: Top-most coordinate.
    ///   - maxX: Right-most coordinate.
    ///   - maxY: Bottom-most coordinate.
    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        let left = min(minX, maxX)
        let right = max(minX, maxX)
        let top = min(minY, maxY)
        let bottom = max(minY, maxY)
        self.origin = Point2D(x: left, y: top)
        self.size = Size2D(width: right - left, height: bottom - top)
    }

    /// A zero-sized rectangle at the origin.
    public static let zero = Rect2D(origin: .zero, size: .zero)

    // MARK: - Derived Coordinates

    public var x: Double {
        get { origin.x }
        set { origin.x = newValue }
    }

    public var y: Double {
        get { origin.y }
        set { origin.y = newValue }
    }

    public var width: Double {
        get { size.width }
        set { size.width = newValue }
    }

    public var height: Double {
        get { size.height }
        set { size.height = newValue }
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }
    public var midX: Double { origin.x + size.width * 0.5 }
    public var midY: Double { origin.y + size.height * 0.5 }

    public var isEmpty: Bool {
        size.width <= 0 || size.height <= 0
    }

    // MARK: - Queries and Operations

    /// Tests if a point lies within the rectangle (closed interval).
    public func contains(_ point: Point2D) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// Tests if another rectangle is fully enclosed within this rectangle.
    public func contains(_ other: Rect2D) -> Bool {
        other.minX >= minX && other.maxX <= maxX && other.minY >= minY && other.maxY <= maxY
    }

    /// Tests if another rectangle intersects with this rectangle.
    public func intersects(_ other: Rect2D) -> Bool {
        minX < other.maxX && maxX > other.minX && minY < other.maxY && maxY > other.minY
    }

    /// Computes the intersection rectangle, returning `nil` if disjoint.
    public func intersection(_ other: Rect2D) -> Rect2D? {
        let newMinX = max(minX, other.minX)
        let newMaxX = min(maxX, other.maxX)
        let newMinY = max(minY, other.minY)
        let newMaxY = min(maxY, other.maxY)

        guard newMinX < newMaxX, newMinY < newMaxY else {
            return nil
        }
        return Rect2D(minX: newMinX, minY: newMinY, maxX: newMaxX, maxY: newMaxY)
    }

    /// Computes the smallest bounding box containing both rectangles.
    public func union(_ other: Rect2D) -> Rect2D {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return Rect2D(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY)
        )
    }

    /// Insets the rectangle by `(dx, dy)`.
    public func insetBy(dx: Double, dy: Double) -> Rect2D {
        Rect2D(
            x: origin.x + dx,
            y: origin.y + dy,
            width: max(0, size.width - 2 * dx),
            height: max(0, size.height - 2 * dy)
        )
    }

    /// Offsets the rectangle by `(dx, dy)`.
    public func offsetBy(dx: Double, dy: Double) -> Rect2D {
        Rect2D(
            origin: Point2D(x: origin.x + dx, y: origin.y + dy),
            size: size
        )
    }

    /// Scales the rectangle origin and dimensions by `(sx, sy)`.
    public func scaledBy(sx: Double, sy: Double) -> Rect2D {
        Rect2D(
            x: origin.x * sx,
            y: origin.y * sy,
            width: size.width * sx,
            height: size.height * sy
        )
    }
}
