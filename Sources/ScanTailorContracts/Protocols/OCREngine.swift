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

    /// A stable description of everything that changes the recognized text (engine, version, settings), used to
    /// key cached results. Two engines with the same identity must return the same text for the same image.
    var cacheIdentity: String { get }
}

extension OCREngine {
    /// The engine's type and stored settings (`String(reflecting:)`). Engines whose settings include unordered
    /// collections, or whose output depends on the system, provide their own.
    public var cacheIdentity: String { String(reflecting: self) }
}

/// Available OCR engine implementations.
public enum OCREngineType: String, Sendable, Equatable, CaseIterable, Codable {
    /// Apple Vision neural text recognition (`VNRecognizeTextRequest`). Primary and fast on macOS.
    case apple = "apple"
    /// Tesseract OCR via `libtesseract` C bindings. Scholarly, Fraktur, Polytonic Greek, Latin, portable.
    case tesseract = "tesseract"
    /// Dual-engine synthesis running both Apple Vision and Tesseract concurrently, merging high-confidence and classical text.
    case dual = "dual"
}

