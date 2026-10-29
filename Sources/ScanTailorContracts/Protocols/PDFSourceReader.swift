import Foundation

/// Reads pages from an input PDF document or image bundle and rasterizes them at a target DPI.
public protocol PDFSourceReader: Sendable {
    /// Total number of pages available in the source document.
    var pageCount: Int { get }

    /// Returns the effective visual page box in 72 DPI PDF points `(0, 0, width, height)` for the 0-based page index,
    /// accounting for `/CropBox`, `/MediaBox`, and `/Rotate`.
    /// - Parameter index: 0-based page index.
    /// - Returns: Effective page dimensions in 72 DPI points.
    /// - Throws: `PDFReadError` if the index is out of bounds or the page dictionary is unreadable.
    func pageBoxPoints(at index: Int) throws(PDFReadError) -> Rect2D

    /// Rasterizes the page at `index` (0-based) into an 8-bit planar grayscale buffer at `targetDPI`.
    /// - Parameters:
    ///   - index: 0-based page index.
    ///   - targetDPI: Target raster resolution (e.g., 600).
    /// - Returns: An 8-bit planar grayscale raster buffer.
    /// - Throws: `PDFReadError` if the page cannot be accessed or rasterized.
    func rasterizePage(at index: Int, targetDPI: Int) async throws(PDFReadError) -> GrayscaleBuffer
}
