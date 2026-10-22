import Foundation

/// Reads pages from an input PDF document or image bundle and rasterizes them at a target DPI.
public protocol PDFSourceReader: Sendable {
    /// Total number of pages available in the source document.
    var pageCount: Int { get }

    /// Rasterizes the page at `index` (0-based) into an 8-bit planar grayscale buffer at `targetDPI`.
    /// - Parameters:
    ///   - index: 0-based page index.
    ///   - targetDPI: Target raster resolution (e.g., 600).
    /// - Returns: An 8-bit planar grayscale raster buffer.
    /// - Throws: `PDFReadError` if the page cannot be accessed or rasterized.
    func rasterizePage(at index: Int, targetDPI: Int) async throws(PDFReadError) -> GrayscaleBuffer
}
