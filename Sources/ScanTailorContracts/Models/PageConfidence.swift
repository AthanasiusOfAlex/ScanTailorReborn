import Foundation

/// Per-page confidence scores produced during the 3-pass pipeline analysis.
public struct PageConfidence: Sendable, Equatable, Codable {
    /// Overall composite confidence score in `[0.0, 1.0]`.
    public var overall: Double

    /// Confidence score for facing-page split line detection `[0.0, 1.0]`.
    public var splitConfidence: Double

    /// Confidence score for deskew angle estimation `[0.0, 1.0]`.
    public var skewConfidence: Double

    /// Confidence score for content bounding box isolation `[0.0, 1.0]`.
    public var contentBoxConfidence: Double

    /// Confidence score for 3D cubic-sheet curvature dewarp estimation `[0.0, 1.0]`.
    public var dewarpConfidence: Double

    /// Diagnostic warning messages or outlier flags generated during analysis.
    public var flags: [String]

    /// Creates a page confidence evaluation.
    public init(
        overall: Double = 1.0,
        splitConfidence: Double = 1.0,
        skewConfidence: Double = 1.0,
        contentBoxConfidence: Double = 1.0,
        dewarpConfidence: Double = 1.0,
        flags: [String] = []
    ) {
        self.overall = overall
        self.splitConfidence = splitConfidence
        self.skewConfidence = skewConfidence
        self.contentBoxConfidence = contentBoxConfidence
        self.dewarpConfidence = dewarpConfidence
        self.flags = flags
    }

    /// Evaluates if any stage confidence fell below the review threshold.
    /// - Parameter threshold: Minimum confidence required (e.g. `0.75`).
    /// - Returns: `true` if this page warrants manual inspection or diagnostic overlay output.
    public func requiresReview(threshold: Double = 0.75) -> Bool {
        overall < threshold ||
        splitConfidence < threshold ||
        skewConfidence < threshold ||
        contentBoxConfidence < threshold ||
        dewarpConfidence < threshold ||
        !flags.isEmpty
    }
}
