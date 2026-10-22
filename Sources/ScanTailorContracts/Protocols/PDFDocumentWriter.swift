import Foundation

/// Assembles 1-bit compressed pages and invisible OCR text layers into a final output PDF document.
///
/// Conforms to `~Copyable` to guarantee that file handles and PDF context resources are safely managed
/// without accidental duplication.
public protocol PDFDocumentWriter: ~Copyable {
    /// Appends a new 1-bit monochrome page with an optional invisible OCR text layer.
    /// - Parameters:
    ///   - bitmap: The 1-bit monochrome page image (typically 300 DPI).
    ///   - dpi: Image resolution in dots per inch (typically 300).
    ///   - pageBoxPoints: PDF page boundaries in 72 DPI points (e.g., `Rect2D(x: 0, y: 0, width: 432, height: 648)`).
    ///   - ocrLayer: Recognized text observations to embed as an invisible searchable text layer.
    /// - Throws: `PDFWriteError` if page encoding or addition fails.
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap,
        dpi: Int,
        pageBoxPoints: Rect2D,
        ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError)

    /// Finalizes the PDF document, closes streams, and writes the trailer dictionary.
    /// Consumes `self` so no further operations can occur on this document writer.
    /// - Throws: `PDFWriteError` if final disk write fails.
    consuming func finalize() throws(PDFWriteError)
}
