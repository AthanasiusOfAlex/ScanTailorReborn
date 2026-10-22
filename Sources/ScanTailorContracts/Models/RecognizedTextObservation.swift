import Foundation

/// A single unit of text detected during optical character recognition,
/// with bounding geometry and confidence.
public struct RecognizedTextObservation: Sendable, Equatable, Codable {
    /// The recognized text string.
    public let text: String

    /// Recognition confidence score between `0.0` (unreliable) and `1.0` (certain).
    public let confidence: Float

    /// Bounding rectangle in page coordinates (typically 72 DPI PDF points or raster pixels).
    public let boundingBox: Rect2D

    /// Creates a recognized text observation.
    /// - Parameters:
    ///   - text: The recognized text.
    ///   - confidence: Recognition confidence `[0, 1]`.
    ///   - boundingBox: Bounding box in target coordinate space.
    public init(text: String, confidence: Float, boundingBox: Rect2D) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
    }
}
