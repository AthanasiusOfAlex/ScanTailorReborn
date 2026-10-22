import Foundation

/// Performs optical character recognition on monochrome or grayscale page rasters.
public protocol OCREngine: Sendable {
    /// Recognizes text lines and words within a binary bitmap.
    /// - Parameters:
    ///   - bitmap: The 1-bit monochrome page image.
    ///   - dpi: Image resolution in dots per inch (typically 300).
    ///   - languages: BCP-47 language identifiers (e.g., `["en-US"]`).
    /// - Returns: An array of recognized text elements with bounding boxes and confidence.
    /// - Throws: `OCRError` if recognition fails.
    func recognizeText(
        in bitmap: borrowing BinaryBitmap,
        dpi: Int,
        languages: [String]
    ) async throws(OCRError) -> [RecognizedTextObservation]
}
