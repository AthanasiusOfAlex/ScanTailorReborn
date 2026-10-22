import CoreGraphics
import Foundation
import ScanTailorContracts
import Vision

/// Apple `Vision` framework implementation of `OCREngine` using `VNRecognizeTextRequest`.
///
/// Converts 1-bit `BinaryBitmap` pages into CoreGraphics images, executes accurate neural
/// optical character recognition, and returns `RecognizedTextObservation` values with
/// normalized top-left `[0, 1] x [0, 1]` bounding boxes.
public struct AppleVisionOCREngine: OCREngine, Sendable {

    /// Whether language-model correction is enabled during OCR recognition.
    public let usesLanguageCorrection: Bool

    /// Optional minimum text height fraction `[0, 1]` relative to image height.
    public let minimumTextHeight: Float?

    /// Creates an Apple Vision OCR engine.
    /// - Parameters:
    ///   - usesLanguageCorrection: Whether Vision applies language correction (default: `true`).
    ///   - minimumTextHeight: Optional minimum text line height relative to image height.
    public init(usesLanguageCorrection: Bool = true, minimumTextHeight: Float? = nil) {
        self.usesLanguageCorrection = usesLanguageCorrection
        self.minimumTextHeight = minimumTextHeight
    }

    /// Recognizes text lines within a 1-bit monochrome bitmap.
    ///
    /// Returned bounding boxes use normalized top-left page coordinates `[0.0, 1.0] x [0.0, 1.0]`
    /// where `(0, 0)` is the top-left corner of the bitmap and `(1, 1)` is the bottom-right corner.
    ///
    /// - Parameters:
    ///   - bitmap: The 1-bit monochrome page image.
    ///   - dpi: Image resolution in dots per inch (typically 300).
    ///   - languages: BCP-47 language identifiers (e.g., `["en-US"]`).
    /// - Returns: Recognized text observations ordered from top to bottom.
    /// - Throws: `OCRError` if recognition fails or is cancelled.
    public func recognizeText(
        in bitmap: borrowing BinaryBitmap,
        dpi: Int,
        languages: [String]
    ) async throws(OCRError) -> [ScanTailorContracts.RecognizedTextObservation] {
        if Task.isCancelled {
            throw .cancelled
        }

        // Fast-path: if the bitmap has no black foreground pixels, return empty immediately.
        guard !bitmap.isEmpty else {
            return []
        }

        guard let cgImage = BinaryBitmapCGImageBridge.make8BitCGImage(from: bitmap) else {
            throw .recognitionFailed(reason: "Failed to convert BinaryBitmap (\(bitmap.width)x\(bitmap.height)) to CGImage")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }
        if let minHeight = minimumTextHeight {
            request.minimumTextHeight = minHeight
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            if Task.isCancelled {
                throw .cancelled
            }
            // Fallback when Apple Neural Engine e5rt model compilation cache is restricted
            // (e.g., inside a process sandbox): retry with in-process .fast recognition level.
            request.recognitionLevel = .fast
            do {
                try handler.perform([request])
            } catch {
                throw .recognitionFailed(reason: error.localizedDescription)
            }
        }

        if Task.isCancelled {
            throw .cancelled
        }

        guard let visionResults = request.results else {
            return []
        }

        var observations: [ScanTailorContracts.RecognizedTextObservation] = []
        observations.reserveCapacity(visionResults.count)

        for obs in visionResults {
            guard let topCandidate = obs.topCandidates(1).first else { continue }
            let trimmed = topCandidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Vision's boundingBox is in normalized [0, 1] coordinates with bottom-left origin (0, 0).
            // Convert to normalized [0, 1] coordinates with top-left origin (0, 0).
            let vbox = obs.boundingBox
            let normX = max(0.0, min(1.0, Double(vbox.origin.x)))
            let normY = max(0.0, min(1.0, Double(1.0 - (vbox.origin.y + vbox.size.height))))
            let normW = max(0.0, min(1.0 - normX, Double(vbox.size.width)))
            let normH = max(0.0, min(1.0 - normY, Double(vbox.size.height)))

            let rect = Rect2D(x: normX, y: normY, width: normW, height: normH)
            observations.append(
                ScanTailorContracts.RecognizedTextObservation(
                    text: trimmed,
                    confidence: topCandidate.confidence,
                    boundingBox: rect
                )
            )
        }

        // Order top-to-bottom, then left-to-right
        observations.sort { lhs, rhs in
            if abs(lhs.boundingBox.minY - rhs.boundingBox.minY) > 0.008 {
                return lhs.boundingBox.minY < rhs.boundingBox.minY
            }
            return lhs.boundingBox.minX < rhs.boundingBox.minX
        }

        return observations
    }
}
