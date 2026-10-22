import CoreGraphics
import Foundation
import ImageIO
import ScanTailorContracts
import UniformTypeIdentifiers

/// Renders color-coded PNG diagnostic overlays showing the page's detected content box (green),
/// retained text clusters (cyan), rejected margin noise/smudges (red), and traced 3D dewarp
/// text-line polylines (blue).
public struct DiagnosticOverlayRenderer: Sendable {
    public init() {}

    /// Renders a diagnostic PNG image to `destinationURL`.
    /// - Parameters:
    ///   - bitmap: Cleaned 1-bit page bitmap in source page coordinates.
    ///   - contentBox: Final detected/refined content bounding box (drawn in green).
    ///   - retainedClusterBoxes: Retained foreground cluster bounding boxes (drawn in cyan).
    ///   - rejectedBoxes: Rejected margin noise / Pass 2 trimmed smudge boxes (drawn in red).
    ///   - tracedLines: Traced text-line polylines used for 3D cubic-sheet dewarping (drawn in blue).
    ///   - destinationURL: File URL where the PNG image will be written.
    public func writePNGOverlay(
        bitmap: borrowing BinaryBitmap,
        contentBox: Rect2I?,
        retainedClusterBoxes: [Rect2I],
        rejectedBoxes: [Rect2I],
        tracedLines: [PolyLine2D],
        to destinationURL: URL
    ) throws {
        let pngData = try encodePNGOverlay(
            bitmap: bitmap,
            contentBox: contentBox,
            retainedClusterBoxes: retainedClusterBoxes,
            rejectedBoxes: rejectedBoxes,
            tracedLines: tracedLines
        )
        try pngData.write(to: destinationURL, options: .atomic)
    }

    /// Encodes a diagnostic PNG overlay into in-memory `Data`.
    public func encodePNGOverlay(
        bitmap: borrowing BinaryBitmap,
        contentBox: Rect2I?,
        retainedClusterBoxes: [Rect2I],
        rejectedBoxes: [Rect2I],
        tracedLines: [PolyLine2D]
    ) throws -> Data {
        let width = max(1, bitmap.width)
        let height = max(1, bitmap.height)

        guard let baseCGImage = BinaryBitmapCGImageBridge.make1BitCGImage(from: bitmap) else {
            throw CocoaError(.coderInvalidValue)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw CocoaError(.coderInvalidValue)
        }

        // Draw base 1-bit image in standard bottom-left CoreGraphics space first
        ctx.draw(baseCGImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Flip coordinate system to top-left origin so (x, y) matches BinaryBitmap & Rect2I
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1.0, y: -1.0)

        let strokeScale = max(2.0, CGFloat(max(width, height)) / 600.0)

        // 1. Draw retained clusters in translucent cyan
        ctx.setStrokeColor(red: 0.0, green: 0.68, blue: 0.88, alpha: 0.75)
        ctx.setLineWidth(strokeScale * 0.75)
        for box in retainedClusterBoxes where !box.isEmpty {
            let rect = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
            ctx.stroke(rect)
        }

        // 2. Draw rejected margin noise / smudges in crimson red with light fill
        ctx.setFillColor(red: 0.92, green: 0.15, blue: 0.18, alpha: 0.22)
        ctx.setStrokeColor(red: 0.92, green: 0.15, blue: 0.18, alpha: 0.95)
        ctx.setLineWidth(strokeScale)
        for box in rejectedBoxes where !box.isEmpty {
            let rect = CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
            ctx.fill(rect)
            ctx.stroke(rect)
        }

        // 3. Draw traced dewarp text baselines in royal blue
        ctx.setStrokeColor(red: 0.12, green: 0.38, blue: 0.96, alpha: 0.90)
        ctx.setLineWidth(strokeScale * 0.9)
        for line in tracedLines where line.points.count >= 2 {
            ctx.beginPath()
            let p0 = line.points[0]
            ctx.move(to: CGPoint(x: p0.x, y: p0.y))
            for pt in line.points.dropFirst() {
                ctx.addLine(to: CGPoint(x: pt.x, y: pt.y))
            }
            ctx.strokePath()
        }

        // 4. Draw final content bounding box in bold emerald green
        if let contentBox, !contentBox.isEmpty {
            ctx.setStrokeColor(red: 0.08, green: 0.76, blue: 0.28, alpha: 0.98)
            ctx.setLineWidth(strokeScale * 1.5)
            let rect = CGRect(
                x: contentBox.minX,
                y: contentBox.minY,
                width: contentBox.width,
                height: contentBox.height
            )
            ctx.stroke(rect)
        }

        guard let renderedImage = ctx.makeImage() else {
            throw CocoaError(.coderInvalidValue)
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.coderInvalidValue)
        }

        CGImageDestinationAddImage(destination, renderedImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.coderInvalidValue)
        }

        return mutableData as Data
    }
}
