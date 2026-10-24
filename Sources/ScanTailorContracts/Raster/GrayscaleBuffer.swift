import Foundation

/// A planar 8-bit continuous-tone grayscale raster buffer with resolution metadata.
///
/// Pixel values range from `0` (pure black) to `255` (pure white).
public struct GrayscaleBuffer: Sendable, Equatable {
    /// Image width in pixels.
    public let width: Int

    /// Image height in pixels.
    public let height: Int

    /// Dots per inch (typically 600 or 300).
    public let dpi: Int

    /// Planar 8-bit pixel values in row-major order: index = `y * width + x`.
    public var pixels: ContiguousArray<UInt8>

    /// Row stride in bytes (always equal to `width` for planar grayscale).
    public var rowBytes: Int { width }

    /// Creates a grayscale buffer with a uniform initial fill value.
    /// - Parameters:
    ///   - width: Image width in pixels (> 0).
    ///   - height: Image height in pixels (> 0).
    ///   - dpi: Scan resolution (default: 600).
    ///   - initialValue: Fill value for all pixels (default: 255 = white).
    public init(width: Int, height: Int, dpi: Int = 600, initialValue: UInt8 = 255) {
        precondition(width > 0 && height > 0, "Dimensions must be strictly positive")
        self.width = width
        self.height = height
        self.dpi = dpi
        self.pixels = ContiguousArray<UInt8>(repeating: initialValue, count: width * height)
    }

    /// Creates a grayscale buffer from an existing contiguous array of pixels.
    /// - Parameters:
    ///   - width: Image width in pixels (> 0).
    ///   - height: Image height in pixels (> 0).
    ///   - dpi: Scan resolution.
    ///   - pixels: Contiguous pixel array of length `width * height`.
    public init(width: Int, height: Int, dpi: Int, pixels: ContiguousArray<UInt8>) {
        precondition(width > 0 && height > 0, "Dimensions must be strictly positive")
        precondition(pixels.count == width * height, "Pixel count (\(pixels.count)) does not match dimensions (\(width) * \(height) = \(width * height))")
        self.width = width
        self.height = height
        self.dpi = dpi
        self.pixels = pixels
    }

    /// Accesses the pixel at `(x, y)`.
    @inlinable
    public subscript(x: Int, y: Int) -> UInt8 {
        get {
            assert(x >= 0 && x < width && y >= 0 && y < height, "Coordinates (\(x), \(y)) out of bounds for \(width)x\(height)")
            return pixels[y * width + x]
        }
        set {
            assert(x >= 0 && x < width && y >= 0 && y < height, "Coordinates (\(x), \(y)) out of bounds for \(width)x\(height)")
            pixels[y * width + x] = newValue
        }
    }

    /// Returns the pixel value at `(x, y)` or `nil` if out of bounds.
    public func pixel(atX x: Int, y: Int) -> UInt8? {
        guard x >= 0 && x < width && y >= 0 && y < height else { return nil }
        return pixels[y * width + x]
    }

    /// Sets the pixel value at `(x, y)` if within bounds.
    public mutating func setPixel(atX x: Int, y: Int, to value: UInt8) {
        guard x >= 0 && x < width && y >= 0 && y < height else { return }
        pixels[y * width + x] = value
    }

    /// Extracts a cropped rectangular region of interest.
    /// - Parameter rect: The rectangle in pixel coordinates to crop. Clamped to buffer bounds.
    /// - Returns: A new `GrayscaleBuffer` containing the cropped pixels.
    public func cropped(to rect: Rect2I) -> GrayscaleBuffer {
        let bounds = Rect2I(x: 0, y: 0, width: width, height: height)
        guard let clamped = rect.clamped(to: bounds), clamped.width > 0, clamped.height > 0 else {
            return GrayscaleBuffer(width: 1, height: 1, dpi: dpi, initialValue: 255)
        }

        var croppedPixels = ContiguousArray<UInt8>()
        croppedPixels.reserveCapacity(clamped.width * clamped.height)

        for y in clamped.minY..<clamped.maxY {
            let rowStart = y * width + clamped.minX
            let rowEnd = rowStart + clamped.width
            croppedPixels.append(contentsOf: pixels[rowStart..<rowEnd])
        }

        return GrayscaleBuffer(
            width: clamped.width,
            height: clamped.height,
            dpi: dpi,
            pixels: croppedPixels
        )
    }

    /// Blits (copies) pixels from a source buffer into this buffer at an offset.
    /// - Parameters:
    ///   - source: The source grayscale buffer.
    ///   - point: The destination top-left pixel position.
    public mutating func blit(from source: borrowing GrayscaleBuffer, at point: Point2I) {
        let destBounds = Rect2I(x: 0, y: 0, width: width, height: height)
        let sourceRect = Rect2I(x: point.x, y: point.y, width: source.width, height: source.height)

        guard let overlap = sourceRect.clamped(to: destBounds) else { return }

        let srcOffsetX = overlap.minX - point.x
        let srcOffsetY = overlap.minY - point.y

        for row in 0..<overlap.height {
            let srcY = srcOffsetY + row
            let dstY = overlap.minY + row

            let srcStart = srcY * source.width + srcOffsetX
            let dstStart = dstY * width + overlap.minX

            for col in 0..<overlap.width {
                pixels[dstStart + col] = source.pixels[srcStart + col]
            }
        }
    }

    /// Directly accesses the raw pixel buffer through an unsafe pointer.
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try pixels.withUnsafeBytes(body)
    }

    /// Directly mutates the raw pixel buffer through an unsafe mutable pointer.
    public mutating func withUnsafeMutableBytes<R>(_ body: (UnsafeMutableRawBufferPointer) throws -> R) rethrows -> R {
        try pixels.withUnsafeMutableBytes(body)
    }
}

/// Typealias for continuous-tone 8-bit grayscale raster buffers.
public typealias GrayscaleImage = GrayscaleBuffer
