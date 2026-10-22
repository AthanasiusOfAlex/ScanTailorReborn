import CoreGraphics
import Foundation
import PDFKit
import ScanTailorContracts

/// Apple CoreGraphics / PDFKit implementation of `PDFSourceReader`.
///
/// Rasterizes PDF pages into planar 8-bit `GrayscaleBuffer` instances at arbitrary target DPI
/// (typically 600 DPI) with white background fill, proper `/CropBox` and `/Rotate` handling,
/// and lock-free thread-safe concurrency.
public struct ApplePDFSourceReader: PDFSourceReader, Sendable {

    /// File URL of the source PDF document.
    public let sourceURL: URL

    /// Total number of pages available in the source PDF document.
    public let pageCount: Int

    /// Opens and validates a PDF document at the specified file URL.
    /// - Parameter url: File URL of the input PDF.
    /// - Throws: `PDFReadError.fileNotFound` if the file does not exist, or `PDFReadError.invalidPDF`
    ///   if the file cannot be parsed as a valid non-empty PDF document.
    public init(url: URL) throws(PDFReadError) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw .fileNotFound(url: url)
        }

        guard let document = CGPDFDocument(url as CFURL) else {
            throw .invalidPDF(reason: "CoreGraphics could not open PDF document at \(url.path)")
        }

        let count = document.numberOfPages
        guard count > 0 else {
            throw .invalidPDF(reason: "PDF document contains 0 pages")
        }

        self.sourceURL = url
        self.pageCount = count
    }

    /// Returns the effective visual page box in 72 DPI PDF points `(0, 0, width, height)` for the 0-based page index,
    /// accounting for `/CropBox`, `/MediaBox`, and `/Rotate`.
    /// - Parameter index: 0-based page index.
    /// - Returns: Effective page dimensions in 72 DPI points.
    /// - Throws: `PDFReadError` if the index is out of bounds or the page dictionary is unreadable.
    public func pageBoxPoints(at index: Int) throws(PDFReadError) -> Rect2D {
        guard index >= 0 && index < pageCount else {
            throw .pageOutOfBounds(index: index, total: pageCount)
        }

        guard let document = CGPDFDocument(sourceURL as CFURL),
              let page = document.page(at: index + 1)
        else {
            throw .rasterizationFailed(reason: "Unable to open PDF page at index \(index)")
        }

        let cropBox = page.getBoxRect(.cropBox)
        let mediaBox = page.getBoxRect(.mediaBox)
        let rawBox = (!cropBox.isEmpty && cropBox.width > 0 && cropBox.height > 0) ? cropBox : mediaBox

        guard rawBox.width > 0 && rawBox.height > 0 else {
            throw .rasterizationFailed(reason: "PDF page \(index) has zero-sized media/crop box")
        }

        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let isQuarterTurn = (rotation == 90 || rotation == 270)
        let effectiveWidth = Double(isQuarterTurn ? rawBox.height : rawBox.width)
        let effectiveHeight = Double(isQuarterTurn ? rawBox.width : rawBox.height)

        return Rect2D(x: 0, y: 0, width: effectiveWidth, height: effectiveHeight)
    }

    /// Rasterizes the page at `index` (0-based) into an 8-bit planar grayscale buffer at `targetDPI`.
    /// - Parameters:
    ///   - index: 0-based page index.
    ///   - targetDPI: Target raster resolution (e.g., 600).
    /// - Returns: An 8-bit planar `GrayscaleBuffer` with top-left pixel origin.
    /// - Throws: `PDFReadError` if the page cannot be accessed or rasterized.
    public func rasterizePage(at index: Int, targetDPI: Int) async throws(PDFReadError) -> GrayscaleBuffer {
        guard index >= 0 && index < pageCount else {
            throw .pageOutOfBounds(index: index, total: pageCount)
        }

        guard targetDPI > 0 else {
            throw .rasterizationFailed(reason: "Invalid targetDPI (\(targetDPI)); must be > 0")
        }

        if Task.isCancelled {
            throw .rasterizationFailed(reason: "Rasterization task was cancelled")
        }

        // Open an independent CGPDFDocument handle per call so concurrent task groups
        // can rasterize multiple pages in parallel without CGPDFDocument lock contention.
        guard let document = CGPDFDocument(sourceURL as CFURL),
              let page = document.page(at: index + 1)
        else {
            throw .rasterizationFailed(reason: "Could not access page \(index + 1) in PDF document")
        }

        let cropBox = page.getBoxRect(.cropBox)
        let mediaBox = page.getBoxRect(.mediaBox)
        let rawBox = (!cropBox.isEmpty && cropBox.width > 0 && cropBox.height > 0) ? cropBox : mediaBox

        guard rawBox.width > 0 && rawBox.height > 0 else {
            throw .rasterizationFailed(reason: "PDF page \(index) has invalid box dimensions: \(rawBox)")
        }

        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let isQuarterTurn = (rotation == 90 || rotation == 270)
        let effectiveWidthPoints = isQuarterTurn ? rawBox.height : rawBox.width
        let effectiveHeightPoints = isQuarterTurn ? rawBox.width : rawBox.height

        let scale = CGFloat(targetDPI) / 72.0
        let pixelWidth = max(1, Int((effectiveWidthPoints * scale).rounded()))
        let pixelHeight = max(1, Int((effectiveHeightPoints * scale).rounded()))

        var buffer = GrayscaleBuffer(
            width: pixelWidth,
            height: pixelHeight,
            dpi: targetDPI,
            initialValue: 255
        )

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        let rendered: Bool = buffer.withUnsafeMutableBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress,
                  let context = CGContext(
                      data: baseAddress,
                      width: pixelWidth,
                      height: pixelHeight,
                      bitsPerComponent: 8,
                      bytesPerRow: pixelWidth,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo.rawValue
                  )
            else {
                return false
            }

            // Fill background with pure white (255) before drawing PDF page contents
            context.setFillColor(gray: 1.0, alpha: 1.0)
            context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

            context.interpolationQuality = .high
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)

            context.saveGState()

            // Scale from PDF point dimensions to exact target pixel dimensions
            let scaleX = CGFloat(pixelWidth) / effectiveWidthPoints
            let scaleY = CGFloat(pixelHeight) / effectiveHeightPoints
            context.scaleBy(x: scaleX, y: scaleY)

            // Apply PDF page rotation and cropBox origin offset
            switch rotation {
            case 90:
                context.translateBy(x: 0, y: effectiveHeightPoints)
                context.rotate(by: -.pi / 2)
                context.translateBy(x: -rawBox.minX, y: -rawBox.minY)
            case 180:
                context.translateBy(x: effectiveWidthPoints, y: effectiveHeightPoints)
                context.rotate(by: .pi)
                context.translateBy(x: -rawBox.minX, y: -rawBox.minY)
            case 270:
                context.translateBy(x: effectiveWidthPoints, y: 0)
                context.rotate(by: .pi / 2)
                context.translateBy(x: -rawBox.minX, y: -rawBox.minY)
            default:
                context.translateBy(x: -rawBox.minX, y: -rawBox.minY)
            }

            context.drawPDFPage(page)
            context.restoreGState()
            return true
        }

        guard rendered else {
            throw .rasterizationFailed(reason: "Failed to allocate 8-bit grayscale CGContext for \(pixelWidth)x\(pixelHeight)")
        }

        return buffer
    }
}
