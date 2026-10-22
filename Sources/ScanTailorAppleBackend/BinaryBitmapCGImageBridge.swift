import CoreGraphics
import Foundation
import ImageIO
import ScanTailorContracts
import UniformTypeIdentifiers

/// Bridges `BinaryBitmap` and `GrayscaleBuffer` with CoreGraphics `CGImage` and ImageIO TIFF CCITT Group 4 streams.
public enum BinaryBitmapCGImageBridge {

    /// Creates a 1-bit monochrome `CGImage` (`bitsPerComponent = 1`, `bitsPerPixel = 1`, `DeviceGray`)
    /// from a `BinaryBitmap`.
    ///
    /// In `BinaryBitmap`, each 64-bit word packs 64 horizontal pixels MSB-first (`1` = black ink, `0` = white paper).
    /// In CoreGraphics 1-bit `DeviceGray` (with default decode `[0, 1]`), each byte packs 8 horizontal pixels
    /// MSB-first where `0` = black (`0.0`) and `1` = white (`1.0`).
    /// Inverting each 64-bit word and storing in big-endian byte order (`(~word).bigEndian`) maps directly
    /// to CoreGraphics' native 1-bit scanline layout.
    ///
    /// - Parameter bitmap: The source 1-bit bitmap.
    /// - Returns: A 1-bit `CGImage`, or `nil` if CoreGraphics allocation fails.
    public static func make1BitCGImage(from bitmap: borrowing BinaryBitmap) -> CGImage? {
        let width = bitmap.width
        let height = bitmap.height
        let wordsPerRow = bitmap.wordsPerRow
        let bytesPerRow = wordsPerRow * MemoryLayout<UInt64>.stride
        let totalWords = wordsPerRow * height

        var invertedBigEndianWords = ContiguousArray<UInt64>(repeating: ~UInt64(0), count: totalWords)
        for i in 0..<totalWords {
            invertedBigEndianWords[i] = (~bitmap.words[i]).bigEndian
        }

        let data = invertedBigEndianWords.withUnsafeBufferPointer { bufferPtr in
            Data(buffer: bufferPtr)
        }

        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 1,
            bitsPerPixel: 1,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Creates an 8-bit grayscale `CGImage` (`0` = black ink, `255` = white paper) from a `BinaryBitmap`.
    ///
    /// Useful for frameworks such as `Vision` (`VNRecognizeTextRequest`) that operate on 8-bit planar buffers.
    /// - Parameter bitmap: The source 1-bit bitmap.
    /// - Returns: An 8-bit `CGImage`, or `nil` if CoreGraphics allocation fails.
    public static func make8BitCGImage(from bitmap: borrowing BinaryBitmap) -> CGImage? {
        let width = bitmap.width
        let height = bitmap.height
        let wordsPerRow = bitmap.wordsPerRow
        var pixels = ContiguousArray<UInt8>(repeating: 255, count: width * height)

        pixels.withUnsafeMutableBufferPointer { dstPtr in
            for y in 0..<height {
                let wordRowStart = y * wordsPerRow
                let pixelRowStart = y * width

                for c in 0..<wordsPerRow {
                    var word = bitmap.words[wordRowStart + c]
                    guard word != 0 else { continue }
                    let baseX = c * 64
                    while word != 0 {
                        let bitIndex = word.leadingZeroBitCount
                        let x = baseX + bitIndex
                        if x < width {
                            dstPtr[pixelRowStart + x] = 0
                        }
                        word &= ~(UInt64(1) << (63 - bitIndex))
                    }
                }
            }
        }

        let data = pixels.withUnsafeBufferPointer { bufferPtr in
            Data(buffer: bufferPtr)
        }

        guard let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Encodes a `BinaryBitmap` into a 1-bit CCITT Group 4 (T.6) compressed TIFF data buffer.
    /// - Parameters:
    ///   - bitmap: The source 1-bit monochrome bitmap.
    ///   - dpi: Resolution in dots per inch.
    /// - Returns: Compressed TIFF data using CCITT Group 4 (`NSTIFFCompressionCCITTFAX4 = 4`).
    /// - Throws: `PDFWriteError.encodingFailed` if TIFF encoding fails.
    public static func encodeCCITTGroup4TIFF(
        from bitmap: borrowing BinaryBitmap,
        dpi: Int
    ) throws(PDFWriteError) -> Data {
        guard let cgImage = make1BitCGImage(from: bitmap) else {
            throw .encodingFailed(reason: "Failed to construct 1-bit CGImage from BinaryBitmap")
        }

        let mutableData = CFDataCreateMutable(kCFAllocatorDefault, 0)!
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            UTType.tiff.identifier as CFString,
            1,
            nil
        ) else {
            throw .encodingFailed(reason: "Failed to create TIFF CGImageDestination")
        }

        // TIFF compression code 4 = CCITT Group 4 (T.6 bilevel compression)
        let ccittGroup4Compression = 4
        let tiffDict: [CFString: Any] = [
            kCGImagePropertyTIFFCompression: ccittGroup4Compression,
            kCGImagePropertyTIFFXResolution: dpi,
            kCGImagePropertyTIFFYResolution: dpi,
            kCGImagePropertyTIFFResolutionUnit: 2 // Inches
        ]
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: tiffDict
        ]

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw .encodingFailed(reason: "Failed to finalize CCITT Group 4 TIFF encoding")
        }

        return mutableData as Data
    }
}
