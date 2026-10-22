import Foundation

/// A high-performance word-packed 1-bit monochrome bitmap.
///
/// Pixels are packed into 64-bit unsigned words (`UInt64`) in Big-Endian (MSB-first) order:
/// - Bit `63` of a word represents the leftmost pixel (lowest x-coordinate).
/// - Bit `0` represents the rightmost pixel in that 64-pixel chunk.
/// - Value `1` represents black foreground ink.
/// - Value `0` represents white background paper.
public struct BinaryBitmap: Sendable, Equatable {
    /// Width of the bitmap in pixels.
    public let width: Int

    /// Height of the bitmap in pixels.
    public let height: Int

    /// Number of 64-bit words required to represent each row of pixels: `(width + 63) / 64`.
    public let wordsPerRow: Int

    /// The packed words in row-major order: index = `y * wordsPerRow + (x / 64)`.
    public var words: ContiguousArray<UInt64>

    /// Mask for the valid pixels in the final word of each row.
    /// Unused trailing padding bits are always maintained as `0`.
    public let trailingWordMask: UInt64

    // MARK: - Initializers

    /// Creates an empty or uniformly filled binary bitmap.
    /// - Parameters:
    ///   - width: Image width in pixels (> 0).
    ///   - height: Image height in pixels (> 0).
    ///   - initialBlack: If `true`, all valid pixels are initialized to black (`1`); otherwise white (`0`).
    public init(width: Int, height: Int, initialBlack: Bool = false) {
        precondition(width > 0 && height > 0, "Dimensions must be strictly positive")
        self.width = width
        self.height = height
        self.wordsPerRow = (width + 63) / 64

        let remainder = width % 64
        self.trailingWordMask = (remainder == 0) ? ~UInt64(0) : (~UInt64(0) << (64 - remainder))

        let fillWord: UInt64 = initialBlack ? ~UInt64(0) : UInt64(0)
        var array = ContiguousArray<UInt64>(repeating: fillWord, count: wordsPerRow * height)

        if initialBlack && remainder != 0 {
            // Clean up trailing bits in each row
            for y in 0..<height {
                array[y * wordsPerRow + (wordsPerRow - 1)] &= trailingWordMask
            }
        }

        self.words = array
    }

    /// Creates a binary bitmap from an existing array of packed words.
    /// - Parameters:
    ///   - width: Image width in pixels (> 0).
    ///   - height: Image height in pixels (> 0).
    ///   - words: Packed words matching `((width + 63) / 64) * height`.
    public init(width: Int, height: Int, words: ContiguousArray<UInt64>) {
        precondition(width > 0 && height > 0, "Dimensions must be strictly positive")
        self.width = width
        self.height = height
        self.wordsPerRow = (width + 63) / 64
        let expectedCount = wordsPerRow * height
        precondition(words.count == expectedCount, "Word count (\(words.count)) does not match expected (\(expectedCount))")

        let remainder = width % 64
        self.trailingWordMask = (remainder == 0) ? ~UInt64(0) : (~UInt64(0) << (64 - remainder))
        self.words = words

        cleanTrailingBits()
    }

    // MARK: - Pixel Access

    /// Accesses the pixel at `(x, y)`: `true` for black, `false` for white.
    @inlinable
    public subscript(x: Int, y: Int) -> Bool {
        get {
            assert(x >= 0 && x < width && y >= 0 && y < height, "Index (\(x), \(y)) out of bounds for \(width)x\(height)")
            let wordIndex = y * wordsPerRow + (x / 64)
            let bitOffset = 63 - (x & 63)
            return (words[wordIndex] & (UInt64(1) << bitOffset)) != 0
        }
        set {
            assert(x >= 0 && x < width && y >= 0 && y < height, "Index (\(x), \(y)) out of bounds for \(width)x\(height)")
            let wordIndex = y * wordsPerRow + (x / 64)
            let bitOffset = 63 - (x & 63)
            let mask = UInt64(1) << bitOffset
            if newValue {
                words[wordIndex] |= mask
            } else {
                words[wordIndex] &= ~mask
            }
        }
    }

    /// Returns `true` if the pixel is black, or `nil` if out of bounds.
    public func isBlack(x: Int, y: Int) -> Bool? {
        guard x >= 0 && x < width && y >= 0 && y < height else { return nil }
        return self[x, y]
    }

    /// Sets the pixel value at `(x, y)` if within bounds.
    public mutating func setPixel(x: Int, y: Int, isBlack: Bool) {
        guard x >= 0 && x < width && y >= 0 && y < height else { return }
        self[x, y] = isBlack
    }

    // MARK: - Bitwise Operations

    /// Bitwise AND with another bitmap of identical dimensions.
    public func bitwiseAnd(_ other: borrowing BinaryBitmap) -> BinaryBitmap {
        precondition(width == other.width && height == other.height, "Dimension mismatch in bitwise operation")
        var result = self
        result.formBitwiseAnd(other)
        return result
    }

    /// Mutating bitwise AND.
    public mutating func formBitwiseAnd(_ other: borrowing BinaryBitmap) {
        precondition(width == other.width && height == other.height, "Dimension mismatch in bitwise operation")
        for i in 0..<words.count {
            words[i] &= other.words[i]
        }
    }

    /// Bitwise OR with another bitmap of identical dimensions.
    public func bitwiseOr(_ other: borrowing BinaryBitmap) -> BinaryBitmap {
        precondition(width == other.width && height == other.height, "Dimension mismatch in bitwise operation")
        var result = self
        result.formBitwiseOr(other)
        return result
    }

    /// Mutating bitwise OR.
    public mutating func formBitwiseOr(_ other: borrowing BinaryBitmap) {
        precondition(width == other.width && height == other.height, "Dimension mismatch in bitwise operation")
        for i in 0..<words.count {
            words[i] |= other.words[i]
        }
    }

    /// Bitwise XOR with another bitmap of identical dimensions.
    public func bitwiseXor(_ other: borrowing BinaryBitmap) -> BinaryBitmap {
        precondition(width == other.width && height == other.height, "Dimension mismatch in bitwise operation")
        var result = self
        result.formBitwiseXor(other)
        return result
    }

    /// Mutating bitwise XOR.
    public mutating func formBitwiseXor(_ other: borrowing BinaryBitmap) {
        precondition(width == other.width && height == other.height, "Dimension mismatch in bitwise operation")
        for i in 0..<words.count {
            words[i] ^= other.words[i]
        }
        cleanTrailingBits()
    }

    /// Inverts all pixels (black becomes white, white becomes black).
    public func inverted() -> BinaryBitmap {
        var result = self
        result.invert()
        return result
    }

    /// Mutates the bitmap by inverting all pixels.
    public mutating func invert() {
        for i in 0..<words.count {
            words[i] = ~words[i]
        }
        cleanTrailingBits()
    }

    /// Computes `self AND NOT other`.
    public func subtracting(_ other: borrowing BinaryBitmap) -> BinaryBitmap {
        precondition(width == other.width && height == other.height, "Dimension mismatch in bitwise operation")
        var result = self
        for i in 0..<words.count {
            result.words[i] &= ~other.words[i]
        }
        return result
    }

    // MARK: - Analysis & Metrics

    /// Total number of black (foreground) pixels in the bitmap.
    public func countBlackPixels() -> Int {
        var count = 0
        for word in words {
            count += word.nonzeroBitCount
        }
        return count
    }

    /// Whether the bitmap contains zero black pixels.
    public var isEmpty: Bool {
        for word in words {
            if word != 0 { return false }
        }
        return true
    }

    /// Computes the minimal integer bounding box enclosing all black pixels, or `nil` if empty.
    public func contentBoundingBox() -> Rect2I? {
        guard !isEmpty else { return nil }

        // Find minY
        var minY: Int?
        for y in 0..<height {
            let rowStart = y * wordsPerRow
            var rowHasBlack = false
            for c in 0..<wordsPerRow {
                if words[rowStart + c] != 0 {
                    rowHasBlack = true
                    break
                }
            }
            if rowHasBlack {
                minY = y
                break
            }
        }

        guard let firstY = minY else { return nil }

        // Find maxY
        var maxY = firstY
        for y in stride(from: height - 1, through: firstY, by: -1) {
            let rowStart = y * wordsPerRow
            var rowHasBlack = false
            for c in 0..<wordsPerRow {
                if words[rowStart + c] != 0 {
                    rowHasBlack = true
                    break
                }
            }
            if rowHasBlack {
                maxY = y
                break
            }
        }

        // Find minX and maxX across active rows
        var minX = width
        var maxX = 0

        for y in firstY...maxY {
            let rowStart = y * wordsPerRow
            for c in 0..<wordsPerRow {
                let w = words[rowStart + c]
                if w != 0 {
                    let wordBaseX = c * 64
                    let leadingZeros = w.leadingZeroBitCount
                    let trailingZeros = w.trailingZeroBitCount

                    let firstBitInWord = wordBaseX + leadingZeros
                    let lastBitInWord = wordBaseX + (63 - trailingZeros)

                    if firstBitInWord < minX { minX = firstBitInWord }
                    if lastBitInWord > maxX { maxX = lastBitInWord }
                }
            }
        }

        guard minX <= maxX else { return nil }
        return Rect2I(minX: minX, minY: firstY, maxX: maxX + 1, maxY: maxY + 1)
    }

    // MARK: - ROI Cropping & Blitting

    /// Extracts a cropped sub-region into a new binary bitmap, handling arbitrary bit-alignment.
    /// - Parameter rect: The crop region. Clamped to current bounds.
    /// - Returns: A new cropped `BinaryBitmap`.
    public func cropped(to rect: Rect2I) -> BinaryBitmap {
        let bounds = Rect2I(x: 0, y: 0, width: width, height: height)
        guard let clamped = rect.clamped(to: bounds), clamped.width > 0, clamped.height > 0 else {
            return BinaryBitmap(width: 1, height: 1, initialBlack: false)
        }

        var result = BinaryBitmap(width: clamped.width, height: clamped.height, initialBlack: false)
        let destWordsPerRow = result.wordsPerRow
        let bitShift = clamped.minX % 64
        let srcWordOffset = clamped.minX / 64

        for dstY in 0..<clamped.height {
            let srcY = clamped.minY + dstY
            let srcRowStart = srcY * wordsPerRow
            let dstRowStart = dstY * destWordsPerRow

            for dstCol in 0..<destWordsPerRow {
                let srcCol = srcWordOffset + dstCol
                let srcIdx0 = srcRowStart + srcCol

                var word: UInt64 = 0
                if srcCol < wordsPerRow {
                    let w0 = words[srcIdx0]
                    if bitShift == 0 {
                        word = w0
                    } else {
                        let part0 = w0 << bitShift
                        let part1: UInt64
                        if srcCol + 1 < wordsPerRow {
                            part1 = words[srcIdx0 + 1] >> (64 - bitShift)
                        } else {
                            part1 = 0
                        }
                        word = part0 | part1
                    }
                }

                if dstCol == destWordsPerRow - 1 {
                    word &= result.trailingWordMask
                }
                result.words[dstRowStart + dstCol] = word
            }
        }

        return result
    }

    /// Blits (ORs or copies) another binary bitmap into this bitmap at the specified pixel coordinate.
    /// - Parameters:
    ///   - source: The source bitmap.
    ///   - point: The destination top-left coordinate.
    ///   - blendMode: Blending mode (`.replace` or `.or`). Default is `.replace`.
    public mutating func blit(
        from source: borrowing BinaryBitmap,
        at point: Point2I,
        blendMode: BlitBlendMode = .replace
    ) {
        let destBounds = Rect2I(x: 0, y: 0, width: width, height: height)
        let srcRect = Rect2I(x: point.x, y: point.y, width: source.width, height: source.height)
        guard let overlap = srcRect.clamped(to: destBounds) else { return }

        let srcStartX = overlap.minX - point.x
        let srcStartY = overlap.minY - point.y

        // Pixel-accurate blit for overlapping region
        for row in 0..<overlap.height {
            let curSrcY = srcStartY + row
            let curDstY = overlap.minY + row

            for col in 0..<overlap.width {
                let curSrcX = srcStartX + col
                let curDstX = overlap.minX + col
                let isBlack = source[curSrcX, curSrcY]

                switch blendMode {
                case .replace:
                    self[curDstX, curDstY] = isBlack
                case .or:
                    if isBlack {
                        self[curDstX, curDstY] = true
                    }
                }
            }
        }
    }

    // MARK: - Internal Helpers

    /// Ensures all unused trailing bits in the last word of every row are set to `0`.
    private mutating func cleanTrailingBits() {
        guard trailingWordMask != ~UInt64(0) else { return }
        for y in 0..<height {
            words[y * wordsPerRow + (wordsPerRow - 1)] &= trailingWordMask
        }
    }

    /// Directly accesses packed words through an unsafe buffer.
    public func withUnsafeWords<R>(_ body: (UnsafeBufferPointer<UInt64>) throws -> R) rethrows -> R {
        try words.withUnsafeBufferPointer(body)
    }

    /// Directly mutates packed words through an unsafe mutable buffer.
    public mutating func withUnsafeMutableWords<R>(_ body: (inout UnsafeMutableBufferPointer<UInt64>) throws -> R) rethrows -> R {
        try words.withUnsafeMutableBufferPointer(body)
    }
}

/// Blending behavior when blitting one bitmap onto another.
public enum BlitBlendMode: Sendable, Equatable {
    /// Overwrites existing destination pixels with source pixels.
    case replace
    /// Performs bitwise OR (adds foreground ink without erasing existing ink).
    case or
}
