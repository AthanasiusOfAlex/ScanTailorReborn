import Foundation
import ScanTailorContracts
import ScanTailorCore

/// User-editable per-source-page geometry overrides stored in a ``SourcePageGeometryRecord``.
///
/// Perspective rectification runs before spread splitting, so these overrides are keyed by
/// source page rather than by output page (contrast ``PageManualOverride``).
public struct SourcePageGeometryOverride: Sendable, Equatable, Codable {
    /// Manual document quadrangle (TL, TR, BR, BL) in the coordinates of the owning record's
    /// ``SourcePageGeometryRecord/rasterSize``; rescaled automatically when a re-run rasterizes the
    /// page at a different size. Bypasses automatic detection.
    public var overrideQuad: DocumentQuad?
    /// When `true`, the page is passed through without perspective rectification.
    public var disableRectification: Bool?

    public init(overrideQuad: DocumentQuad? = nil, disableRectification: Bool? = nil) {
        self.overrideQuad = overrideQuad
        self.disableRectification = disableRectification
    }
}

/// Document-quadrangle detection and perspective-rectification telemetry for one source page.
public struct SourcePageGeometryRecord: Sendable, Equatable, Codable {
    /// Index of the source page within the processed (filtered) page sequence.
    public var sourcePageIndex: Int
    /// Size of the processing raster the quadrangle coordinates refer to.
    public var rasterSize: Size2I
    /// Automatic detection result (`nil` when detection was skipped: disabled, or a manual quad).
    public var detection: DocumentQuadDetection?
    /// `true` when the page was resampled through a perspective homography.
    public var rectified: Bool
    /// Rectification geometry (quad, aspect, output size, homographies) when ``rectified``.
    public var plan: RectificationPlan?
    /// Optional user override carried forward from the input manifest.
    public var manualOverride: SourcePageGeometryOverride?

    public init(
        sourcePageIndex: Int,
        rasterSize: Size2I,
        detection: DocumentQuadDetection?,
        rectified: Bool,
        plan: RectificationPlan?,
        manualOverride: SourcePageGeometryOverride? = nil
    ) {
        self.sourcePageIndex = sourcePageIndex
        self.rasterSize = rasterSize
        self.detection = detection
        self.rectified = rectified
        self.plan = plan
        self.manualOverride = manualOverride
    }
}

extension DocumentQuad {
    /// Returns the quadrangle rescaled from a `from` raster to a `to` raster.
    func rescaled(from: Size2I, to: Size2I) -> DocumentQuad {
        guard from.width > 0, from.height > 0, from != to else { return self }
        let sx = Double(to.width) / Double(from.width)
        let sy = Double(to.height) / Double(from.height)
        func s(_ p: Point2D) -> Point2D { Point2D(x: p.x * sx, y: p.y * sy) }
        return DocumentQuad(topLeft: s(topLeft), topRight: s(topRight), bottomRight: s(bottomRight), bottomLeft: s(bottomLeft))
    }
}

extension BookPipelineCoordinator {
    /// Detects the document quadrangle of `page` and rectifies it unless the result is
    /// `fullFrame`/`rejected`, rectification is disabled, or the plan is degenerate (all of which
    /// pass the page through byte-identical).
    func rectifySourcePage(
        _ page: GrayscaleBuffer,
        sourcePageIndex: Int,
        priorRecord: SourcePageGeometryRecord?,
        targetPageSize: PhysicalSizeSpec?
    ) -> (page: GrayscaleBuffer, record: SourcePageGeometryRecord) {
        let rasterSize = Size2I(width: page.width, height: page.height)
        let manualOverride = priorRecord?.manualOverride
        let passthrough: (DocumentQuadDetection?) -> (GrayscaleBuffer, SourcePageGeometryRecord) = { detection in
            (page, SourcePageGeometryRecord(
                sourcePageIndex: sourcePageIndex,
                rasterSize: rasterSize,
                detection: detection,
                rectified: false,
                plan: nil,
                manualOverride: manualOverride
            ))
        }

        let plan: RectificationPlan?
        let detection: DocumentQuadDetection?
        if let manualQuad = manualOverride?.overrideQuad {
            guard manualOverride?.disableRectification != true else { return passthrough(nil) }
            detection = nil
            let quad = manualQuad.rescaled(from: priorRecord?.rasterSize ?? rasterSize, to: rasterSize)
            plan = PerspectiveRectifier.plan(
                for: quad,
                sourceSize: rasterSize,
                targetPageSize: targetPageSize,
                configuration: configuration.rectifierConfiguration
            )
        } else {
            guard configuration.enablePerspectiveRectification else { return passthrough(nil) }
            let detector = DocumentQuadDetector(configuration: configuration.quadDetectorConfiguration)
            let result = detector.detect(in: page)
            guard manualOverride?.disableRectification != true else { return passthrough(result) }
            detection = result
            plan = PerspectiveRectifier.plan(
                for: result,
                sourceSize: rasterSize,
                targetPageSize: targetPageSize,
                configuration: configuration.rectifierConfiguration
            )
        }

        guard let plan else { return passthrough(detection) }
        let rectified = PerspectiveRectifier.rectify(page, plan: plan)
        return (rectified, SourcePageGeometryRecord(
            sourcePageIndex: sourcePageIndex,
            rasterSize: rasterSize,
            detection: detection,
            rectified: true,
            plan: plan,
            manualOverride: manualOverride
        ))
    }
}
