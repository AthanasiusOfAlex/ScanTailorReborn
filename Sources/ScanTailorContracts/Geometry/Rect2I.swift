import Foundation

/// An axis-aligned 2D rectangle in integer pixel coordinates (e.g., regions of interest).
public struct Rect2I: Sendable, Equatable, Hashable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    /// Creates an integer pixel rectangle.
    /// - Parameters:
    ///   - x: Left pixel coordinate.
    ///   - y: Top pixel coordinate.
    ///   - width: Width in pixels.
    ///   - height: Height in pixels.
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = max(0, width)
        self.height = max(0, height)
    }

    /// Creates a pixel rectangle from min/max bounds (half-open: `[minX, maxX)`).
    /// - Parameters:
    ///   - minX: Left-most inclusive pixel index.
    ///   - minY: Top-most inclusive pixel index.
    ///   - maxX: Right-most exclusive pixel index.
    ///   - maxY: Bottom-most exclusive pixel index.
    public init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        let left = min(minX, maxX)
        let right = max(minX, maxX)
        let top = min(minY, maxY)
        let bottom = max(minY, maxY)
        self.x = left
        self.y = top
        self.width = right - left
        self.height = bottom - top
    }

    /// Creates an integer rectangle covering a given size located at the origin.
    public init(size: Size2I) {
        self.init(x: 0, y: 0, width: size.width, height: size.height)
    }

    /// A zero rectangle.
    public static let zero = Rect2I(x: 0, y: 0, width: 0, height: 0)

    public var minX: Int { x }
    public var minY: Int { y }
    public var maxX: Int { x + width }
    public var maxY: Int { y + height }

    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    public var origin: Point2I {
        Point2I(x: x, y: y)
    }

    public var size: Size2I {
        Size2I(width: width, height: height)
    }

    public var asRect2D: Rect2D {
        Rect2D(x: Double(x), y: Double(y), width: Double(width), height: Double(height))
    }

    /// Tests if a pixel coordinate is within this rectangle: `x in [minX, maxX)` and `y in [minY, maxY)`.
    public func contains(x px: Int, y py: Int) -> Bool {
        px >= minX && px < maxX && py >= minY && py < maxY
    }

    /// Tests if a pixel point is within this rectangle.
    public func contains(_ point: Point2I) -> Bool {
        contains(x: point.x, y: point.y)
    }

    /// Computes intersection with another integer rectangle, returning `nil` if disjoint.
    public func intersection(_ other: Rect2I) -> Rect2I? {
        let newMinX = max(minX, other.minX)
        let newMaxX = min(maxX, other.maxX)
        let newMinY = max(minY, other.minY)
        let newMaxY = min(maxY, other.maxY)

        guard newMinX < newMaxX, newMinY < newMaxY else {
            return nil
        }
        return Rect2I(minX: newMinX, minY: newMinY, maxX: newMaxX, maxY: newMaxY)
    }

    /// Clamps this rectangle to lie entirely within the given boundary rectangle.
    public func clamped(to bounds: Rect2I) -> Rect2I? {
        intersection(bounds)
    }

    /// Computes the minimal integer bounding box containing both rectangles.
    public func union(_ other: Rect2I) -> Rect2I {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return Rect2I(
            minX: min(minX, other.minX),
            minY: min(minY, other.minY),
            maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY)
        )
    }

    /// Offsets the rectangle by `(dx, dy)`.
    public func offsetBy(dx: Int, dy: Int) -> Rect2I {
        Rect2I(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// Insets the rectangle by `(dx, dy)`.
    public func insetBy(dx: Int, dy: Int) -> Rect2I {
        Rect2I(
            x: x + dx,
            y: y + dy,
            width: max(0, width - 2 * dx),
            height: max(0, height - 2 * dy)
        )
    }
}
