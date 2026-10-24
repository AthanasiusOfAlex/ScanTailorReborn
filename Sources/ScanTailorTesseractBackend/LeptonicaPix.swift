@preconcurrency import CTesseract
import Foundation
import ScanTailorContracts

/// Non-copyable (`~Copyable`) RAII wrapper managing a Leptonica `Pix` C structure.
///
/// Automatically frees the underlying `Pix` allocation via `pixDestroy` when deinitialized,
/// preventing memory leaks across normal execution and error paths.
public struct LeptonicaPix: ~Copyable {
    /// Raw opaque C pointer to the underlying Leptonica `struct Pix`.
    internal let pointer: OpaquePointer

    /// Creates a 1-bit Leptonica `Pix` from a `BinaryBitmap`.
    ///
    /// - Parameters:
    ///   - bitmap: The 1-bit MSB-packed monochrome bitmap (`1` = black foreground ink, `0` = white background).
    ///   - dpi: Resolution in dots per inch (default: `300`).
    /// - Throws: `OCRError.recognitionFailed` if Leptonica fails to allocate the `Pix` structure.
    public init(bitmap: borrowing BinaryBitmap, dpi: Int = 300) throws(OCRError) {
        let width = bitmap.width
        let height = bitmap.height
        let wordsPerRow = bitmap.wordsPerRow
        let effectiveDPI = max(72, dpi)

        let rawPix: OpaquePointer? = bitmap.withUnsafeWords { wordBuffer in
            guard let baseAddress = wordBuffer.baseAddress else { return nil }
            return st_pix_create_from_binary_words(
                Int32(width),
                Int32(height),
                Int32(effectiveDPI),
                baseAddress,
                Int32(wordsPerRow)
            )
        }

        guard let validPix = rawPix else {
            throw .recognitionFailed(
                reason: "Failed to allocate 1-bit Leptonica Pix (\(width)x\(height) at \(effectiveDPI) DPI)"
            )
        }
        self.pointer = validPix
    }

    /// Creates an 8-bit Leptonica `Pix` from a `GrayscaleBuffer` (`GrayscaleImage`).
    ///
    /// - Parameters:
    ///   - grayscale: The 8-bit continuous-tone grayscale image (`0` = black, `255` = white).
    ///   - dpi: Optional resolution override in dots per inch; defaults to `grayscale.dpi`.
    /// - Throws: `OCRError.recognitionFailed` if Leptonica fails to allocate the `Pix` structure.
    public init(grayscale: borrowing GrayscaleBuffer, dpi: Int? = nil) throws(OCRError) {
        let width = grayscale.width
        let height = grayscale.height
        let rowBytes = grayscale.rowBytes
        let effectiveDPI = max(72, dpi ?? grayscale.dpi)

        let rawPix: OpaquePointer? = grayscale.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            return st_pix_create_from_grayscale_bytes(
                Int32(width),
                Int32(height),
                Int32(effectiveDPI),
                baseAddress,
                Int32(rowBytes)
            )
        }

        guard let validPix = rawPix else {
            throw .recognitionFailed(
                reason: "Failed to allocate 8-bit Leptonica Pix (\(width)x\(height) at \(effectiveDPI) DPI)"
            )
        }
        self.pointer = validPix
    }

    /// Width of the `Pix` raster in pixels.
    public var width: Int {
        Int(pixGetWidth(pointer))
    }

    /// Height of the `Pix` raster in pixels.
    public var height: Int {
        Int(pixGetHeight(pointer))
    }

    /// Bit depth per pixel (`1` for binary, `8` for grayscale).
    public var depth: Int {
        Int(pixGetDepth(pointer))
    }

    /// Number of 32-bit words per raster line inside Leptonica's backing buffer.
    public var wordsPerLine: Int {
        Int(pixGetWpl(pointer))
    }

    /// Reads a single pixel value `(x, y)` from the Leptonica `Pix` (`0` or `1` for 1-bpp; `0..255` for 8-bpp).
    /// - Returns: The pixel value, or `nil` if `(x, y)` is out of bounds.
    public func pixelValue(x: Int, y: Int) -> UInt32? {
        guard x >= 0 && x < width && y >= 0 && y < height else {
            return nil
        }
        var value: UInt32 = 0
        let status = pixGetPixel(pointer, Int32(x), Int32(y), &value)
        return status == 0 ? value : nil
    }

    deinit {
        st_pix_destroy(pointer)
    }
}
