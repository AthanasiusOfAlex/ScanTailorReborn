import Foundation

/// A 2D floating-point size representing physical dimensions or coordinate extents.
public struct Size2D: Sendable, Equatable, Hashable, Codable {
    public var width: Double
    public var height: Double

    /// Creates a 2D size.
    /// - Parameters:
    ///   - width: The width extent.
    ///   - height: The height extent.
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// A zero size `(0.0, 0.0)`.
    public static let zero = Size2D(width: 0, height: 0)

    /// The aspect ratio (width / height). Returns 0.0 if height is zero.
    public var aspectRatio: Double {
        height > 0 ? (width / height) : 0
    }

    /// Whether either dimension is non-positive.
    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }
}
