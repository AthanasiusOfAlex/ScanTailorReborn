import Foundation

/// A 2D integer size representing raster or pixel dimensions.
public struct Size2I: Sendable, Equatable, Hashable, Codable {
    public var width: Int
    public var height: Int

    /// Creates an integer size.
    /// - Parameters:
    ///   - width: The width in pixels.
    ///   - height: The height in pixels.
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// A zero size `(0, 0)`.
    public static let zero = Size2I(width: 0, height: 0)

    /// Total number of pixels contained in this size.
    public var pixelCount: Int {
        width > 0 && height > 0 ? (width * height) : 0
    }

    /// The aspect ratio (width / height) as a floating-point number.
    public var aspectRatio: Double {
        height > 0 ? (Double(width) / Double(height)) : 0
    }

    /// Whether either dimension is non-positive.
    public var isEmpty: Bool {
        width <= 0 || height <= 0
    }

    /// Converts to a floating-point `Size2D`.
    public var asSize2D: Size2D {
        Size2D(width: Double(width), height: Double(height))
    }
}
