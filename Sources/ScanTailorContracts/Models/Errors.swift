import Foundation

/// Errors occurring during geometric transformations and calculations.
public enum GeometryError: Error, Sendable, Equatable, CustomStringConvertible {
    case singularMatrix(description: String)
    case invalidDimensions(width: Int, height: Int)
    case outOfBounds(description: String)

    public var description: String {
        switch self {
        case .singularMatrix(let desc):
            return "Singular matrix (non-invertible): \(desc)"
        case .invalidDimensions(let w, let h):
            return "Invalid dimensions: width=\(w), height=\(h)"
        case .outOfBounds(let desc):
            return "Out of bounds: \(desc)"
        }
    }
}

/// Errors occurring when reading or rasterizing input PDF pages.
public enum PDFReadError: Error, Sendable, Equatable, CustomStringConvertible {
    case fileNotFound(url: URL)
    case invalidPDF(reason: String)
    case pageOutOfBounds(index: Int, total: Int)
    case rasterizationFailed(reason: String)

    public var description: String {
        switch self {
        case .fileNotFound(let url):
            return "PDF file not found at: \(url.path)"
        case .invalidPDF(let reason):
            return "Invalid PDF: \(reason)"
        case .pageOutOfBounds(let index, let total):
            return "Page index \(index) out of bounds (total pages: \(total))"
        case .rasterizationFailed(let reason):
            return "Rasterization failed: \(reason)"
        }
    }
}

/// Errors occurring when assembling or writing output PDF documents.
public enum PDFWriteError: Error, Sendable, Equatable, CustomStringConvertible {
    case destinationInitializationFailed(url: URL)
    case encodingFailed(reason: String)
    case pageAdditionFailed(pageIndex: Int, reason: String)
    case finalizationFailed(reason: String)

    public var description: String {
        switch self {
        case .destinationInitializationFailed(let url):
            return "Failed to initialize PDF destination at: \(url.path)"
        case .encodingFailed(let reason):
            return "PDF image encoding failed: \(reason)"
        case .pageAdditionFailed(let index, let reason):
            return "Failed to append page \(index): \(reason)"
        case .finalizationFailed(let reason):
            return "Failed to finalize PDF document: \(reason)"
        }
    }
}

/// Errors occurring during optical character recognition.
public enum OCRError: Error, Sendable, Equatable, CustomStringConvertible {
    case engineUnavailable(reason: String)
    case recognitionFailed(reason: String)
    case cancelled

    public var description: String {
        switch self {
        case .engineUnavailable(let reason):
            return "OCR engine unavailable: \(reason)"
        case .recognitionFailed(let reason):
            return "OCR recognition failed: \(reason)"
        case .cancelled:
            return "OCR operation was cancelled"
        }
    }
}
