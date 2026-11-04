import CoreGraphics
import CoreText
import Foundation
import ImageIO
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import UniformTypeIdentifiers

/// Draws the book's layout as a few small PNG contact sheets, so a person or an agent can judge page sizes and
/// margins at a glance without rendering the book (`--stop-after layout`).
///
/// Every page is drawn on its real output canvas at about 40 DPI with its text placed where the layout plan
/// puts it. Facing pages (a verso followed by a recto) touch each other. Colors:
/// - **red** outline: the canonical text frame of the page's side (shared canvas only);
/// - **green** outline: the text block as placed;
/// - **orange** border: a dimensional outlier, drawn on its own canvas;
/// - **blue** label: a page the pipeline flagged for low confidence.
///
/// Each label reads `<page> <scan> T<tier>`, for example `45 s12L T1`; add `outlier` kinds and `!` for a flag.
public struct LayoutContactSheetRenderer: Sendable {
    /// Drawing scale in pixels per inch of output page.
    public var pixelsPerInch: Double
    /// Width of a sheet in pixels.
    public var sheetWidth: Int
    /// A sheet is closed once the next row of pages would make it taller than this.
    public var maxSheetHeight: Int

    public init(pixelsPerInch: Double = 40, sheetWidth: Int = 1800, maxSheetHeight: Int = 1600) {
        self.pixelsPerInch = pixelsPerInch
        self.sheetWidth = sheetWidth
        self.maxSheetHeight = maxSheetHeight
    }

    private struct Item {
        var index: Int
        var width: Int
        var height: Int
        var x: Int = 0
        var y: Int = 0
    }

    private let margin = 14
    private let gap = 12
    private let labelHeight = 16

    /// Renders the sheets as PNG data, in page order.
    /// - Parameters:
    ///   - manifest: The run's manifest (layout plans, sizes, flags).
    ///   - cleanedBitmaps: The cleaned 600 DPI page bitmaps, one per manifest page.
    public func renderSheets(manifest: BookProcessingManifest, cleanedBitmaps: [BinaryBitmap]) throws -> [Data] {
        let scale = pixelsPerInch / Double(max(1, manifest.processingDPI))
        let pages = manifest.pages
        guard !pages.isEmpty, cleanedBitmaps.count == pages.count else { return [] }

        var items = pages.indices.map { i -> Item in
            let canvas = pages[i].layoutPlan.canvasSize
            return Item(
                index: i,
                width: max(8, Int((Double(canvas.width) * scale).rounded())),
                height: max(8, Int((Double(canvas.height) * scale).rounded())) + labelHeight
            )
        }

        // Group facing pages (verso then recto) so they stay together on a row.
        var units: [[Int]] = []
        var i = 0
        while i < pages.count {
            if pages[i].bookSide == .verso, i + 1 < pages.count, pages[i + 1].bookSide == .recto {
                units.append([i, i + 1])
                i += 2
            } else {
                units.append([i])
                i += 1
            }
        }

        // Place units in rows, rows in sheets.
        var sheets: [[Int]] = [[]]
        var sheetHeights: [Int] = [margin]
        var x = margin
        var rowTop = margin
        var rowHeight = 0
        for unit in units {
            let unitWidth = unit.reduce(0) { $0 + items[$1].width }
            let unitHeight = unit.map { items[$0].height }.max() ?? 0
            if x > margin && x + unitWidth > sheetWidth - margin {
                rowTop += rowHeight + gap
                x = margin
                rowHeight = 0
            }
            if !sheets[sheets.count - 1].isEmpty && rowTop + unitHeight + margin > maxSheetHeight {
                sheets.append([])
                sheetHeights.append(margin)
                rowTop = margin
                x = margin
                rowHeight = 0
            }
            var cursor = x
            for index in unit {
                items[index].x = cursor
                items[index].y = rowTop
                cursor += items[index].width
                sheets[sheets.count - 1].append(index)
            }
            x = cursor + gap
            rowHeight = max(rowHeight, unitHeight)
            sheetHeights[sheets.count - 1] = max(sheetHeights[sheets.count - 1], rowTop + rowHeight + margin)
        }

        return try sheets.enumerated().map { sheetIndex, members in
            try renderSheet(
                members: members,
                items: items,
                height: max(sheetHeights[sheetIndex], 64),
                manifest: manifest,
                cleanedBitmaps: cleanedBitmaps,
                scale: scale
            )
        }
    }

    private func renderSheet(
        members: [Int],
        items: [Item],
        height: Int,
        manifest: BookProcessingManifest,
        cleanedBitmaps: [BinaryBitmap],
        scale: Double
    ) throws -> Data {
        guard let ctx = CGContext(
            data: nil,
            width: sheetWidth,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: sheetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CocoaError(.coderInvalidValue) }

        ctx.setFillColor(red: 0.86, green: 0.87, blue: 0.89, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: sheetWidth, height: height))
        ctx.interpolationQuality = .high

        // Converts a rectangle given from the sheet's top-left corner into CoreGraphics' bottom-left space.
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: x, y: Double(height) - y - h, width: w, height: h)
        }

        for index in members {
            let item = items[index]
            let record = manifest.pages[index]
            let plan = record.layoutPlan
            let pageW = Double(item.width)
            let pageH = Double(item.height - labelHeight)
            let top = Double(item.y + labelHeight)
            let left = Double(item.x)

            // Page.
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(rect(left, top, pageW, pageH))

            // Text block as placed (a small, smoothed copy of the cleaned page).
            if let box = plan.sourceContentBox, !box.isEmpty {
                var small = cleanedBitmaps[index].cropped(to: box)
                for _ in 0..<3 where small.width >= 4 && small.height >= 4 {
                    small = BinaryDownsampler.downsample2x(small, minBlackSubpixels: 2)
                }
                if let image = BinaryBitmapCGImageBridge.make1BitCGImage(from: small) {
                    ctx.draw(image, in: rect(
                        left + Double(plan.destinationOrigin.x) * scale,
                        top + Double(plan.destinationOrigin.y) * scale,
                        Double(box.width) * scale,
                        Double(box.height) * scale
                    ))
                }
                ctx.setStrokeColor(red: 0.08, green: 0.62, blue: 0.28, alpha: 1)
                ctx.setLineWidth(1)
                ctx.stroke(rect(
                    left + Double(plan.destinationOrigin.x) * scale,
                    top + Double(plan.destinationOrigin.y) * scale,
                    Double(box.width) * scale,
                    Double(box.height) * scale
                ))
            }

            // Canonical frame (pages on the shared canvas only).
            let isolated = record.dimension?.pdfPageSizePoints != nil
            if !isolated {
                let frame = plan.side == .verso ? manifest.versoCanonicalFrame : manifest.rectoCanonicalFrame
                ctx.setStrokeColor(red: 0.85, green: 0.15, blue: 0.18, alpha: 0.8)
                ctx.setLineWidth(1)
                ctx.stroke(rect(
                    left + Double(frame.minX) * scale,
                    top + Double(frame.minY) * scale,
                    Double(frame.width) * scale,
                    Double(frame.height) * scale
                ))
            }

            // Border: gray, or orange for an outlier.
            let outlier = plan.isDimensionOutlier
            ctx.setStrokeColor(outlier ? CGColor(red: 0.95, green: 0.55, blue: 0.05, alpha: 1) : CGColor(red: 0.45, green: 0.47, blue: 0.5, alpha: 1))
            ctx.setLineWidth(outlier ? 3 : 1)
            ctx.stroke(rect(left, top, pageW, pageH).insetBy(dx: outlier ? 1.5 : 0.5, dy: outlier ? 1.5 : 0.5))

            // Label.
            var label = "\(record.outputPageIndex + 1) \(manifest.scanReference(of: record)) T\(tierNumber(plan.tier))"
            if outlier, let kinds = record.dimension?.kinds, !kinds.isEmpty {
                label += " " + kinds.map(\.rawValue).joined(separator: "+")
            } else if outlier {
                label += " outlier"
            }
            if record.flaggedLowConfidence { label += " !" }
            drawText(
                label,
                in: ctx,
                at: CGPoint(x: left + 2, y: Double(height) - Double(item.y) - 12),
                color: record.flaggedLowConfidence ? CGColor(red: 0.1, green: 0.3, blue: 0.85, alpha: 1) : CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)
            )
        }

        guard let image = ctx.makeImage() else { throw CocoaError(.coderInvalidValue) }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.coderInvalidValue)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.coderInvalidValue) }
        return data as Data
    }

    private func tierNumber(_ tier: MarginHarmonizer.PlacementTier) -> Int {
        switch tier {
        case .fullBody: return 1
        case .edgeAnchoredPartial: return 2
        case .standaloneFloating: return 3
        }
    }

    private func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, color: CGColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 11, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}
