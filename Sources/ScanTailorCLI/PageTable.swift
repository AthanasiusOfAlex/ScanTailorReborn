import Foundation
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline

extension ScanTailorCLI {
    /// One page of `inspect --pages`: everything an agent needs to judge size and margins, in inches.
    public struct PageRow: Codable, Equatable {
        public struct Inches: Codable, Equatable {
            public var width: Double
            public var height: Double
        }

        public struct Margins: Codable, Equatable {
            public var left: Double
            public var top: Double
            public var right: Double
            public var bottom: Double
        }

        /// 1-based output page number.
        public var page: Int
        /// Stable scan-based name for adjustments files (`s12`, `s12L`, `s12R`).
        public var scan: String
        public var side: String
        public var tier: String
        /// Why the page is a dimensional outlier (empty for canonical pages).
        public var outlierKinds: [String]
        /// `true` when the page is drawn on a canvas of its own.
        public var ownCanvas: Bool
        /// The page's canvas in inches at the processing resolution (before any anti-billboard scaling).
        public var canvasInches: Inches
        /// The PDF page size in inches when the page has its own canvas.
        public var pdfPageInches: Inches?
        public var textBlockInches: Inches?
        /// Space between the text block and each edge of the page.
        public var marginsInches: Margins?
        public var skewDegrees: Double
        public var dewarped: Bool
        public var confidence: Double
        public var flaggedLowConfidence: Bool
        /// Names of the manual overrides stored for the page.
        public var overrides: [String]
    }

    private static func inches(_ pixels: Int, dpi: Int) -> Double {
        (Double(pixels) / Double(max(1, dpi)) * 1000).rounded() / 1000
    }

    private static func overrideNames(_ o: PageManualOverride?) -> [String] {
        guard let o else { return [] }
        var names: [String] = []
        if o.overrideSkewDegrees != nil { names.append("skew") }
        if o.disableDewarp != nil { names.append("disableDewarp") }
        if o.overrideContentBox != nil { names.append("contentBox") }
        if o.overrideDestinationOrigin != nil { names.append("origin") }
        if o.destinationOffset != nil { names.append("offset") }
        if o.forcedTier != nil { names.append("tier") }
        if o.dimensionClass != nil { names.append("outlier") }
        if o.pageSizeInches != nil { names.append("pageSize") }
        if o.keep != nil { names.append("keep") }
        if o.runningHeader != nil { names.append("runningHeader") }
        if o.verticalRegistration != nil { names.append("verticalRegistration") }
        if o.borderFallback != nil { names.append("borderFallback") }
        return names
    }

    /// The per-page table behind `inspect --pages`.
    public static func pageRows(_ manifest: BookProcessingManifest) -> [PageRow] {
        let dpi = manifest.processingDPI
        return manifest.pages.map { record in
            let plan = record.layoutPlan
            var margins: PageRow.Margins? = nil
            var block: PageRow.Inches? = nil
            if let box = plan.sourceContentBox, !box.isEmpty {
                block = .init(width: inches(box.width, dpi: dpi), height: inches(box.height, dpi: dpi))
                margins = .init(
                    left: inches(plan.destinationOrigin.x, dpi: dpi),
                    top: inches(plan.destinationOrigin.y, dpi: dpi),
                    right: inches(plan.canvasSize.width - plan.destinationOrigin.x - box.width, dpi: dpi),
                    bottom: inches(plan.canvasSize.height - plan.destinationOrigin.y - box.height, dpi: dpi)
                )
            }
            let own = record.dimension?.pdfPageSizePoints
            return PageRow(
                page: record.outputPageIndex + 1,
                scan: manifest.scanReference(of: record),
                side: record.bookSide.rawValue,
                tier: plan.tier.rawValue,
                outlierKinds: plan.isDimensionOutlier ? (record.dimension?.kinds.map(\.rawValue) ?? []) : [],
                ownCanvas: own != nil,
                canvasInches: .init(width: inches(plan.canvasSize.width, dpi: dpi), height: inches(plan.canvasSize.height, dpi: dpi)),
                pdfPageInches: own.map { .init(width: ($0.width / 72 * 1000).rounded() / 1000, height: ($0.height / 72 * 1000).rounded() / 1000) },
                textBlockInches: block,
                marginsInches: margins,
                skewDegrees: (record.skewAngleDegrees * 100).rounded() / 100,
                dewarped: record.dewarpApplied,
                confidence: (record.overallConfidence * 100).rounded() / 100,
                flaggedLowConfidence: record.flaggedLowConfidence,
                overrides: overrideNames(record.manualOverride)
            )
        }
    }

    /// A compact text table of the pages, followed by how uniform the margins of ordinary full-body pages are.
    public static func formatPageTable(_ manifest: BookProcessingManifest) -> String {
        let rows = pageRows(manifest)
        var lines: [String] = []
        lines.append("page scan   side   tier  page(in)     text(in)     margins L/T/R/B (in)       skew   conf  notes")
        for row in rows {
            let page = row.pdfPageInches ?? row.canvasInches
            let pageText = String(format: "%.2fx%.2f", page.width, page.height)
            let textBlock = row.textBlockInches.map { String(format: "%.2fx%.2f", $0.width, $0.height) } ?? "-"
            let margins = row.marginsInches.map { String(format: "%.2f/%.2f/%.2f/%.2f", $0.left, $0.top, $0.right, $0.bottom) } ?? "-"
            var notes: [String] = []
            if row.ownCanvas { notes.append("own canvas") }
            if !row.outlierKinds.isEmpty { notes.append("outlier:" + row.outlierKinds.joined(separator: "+")) }
            else if row.ownCanvas { notes.append("outlier") }
            if row.flaggedLowConfidence { notes.append("LOW-CONF") }
            if row.dewarped { notes.append("dewarped") }
            if !row.overrides.isEmpty { notes.append("set:" + row.overrides.joined(separator: ",")) }
            let tier: String
            switch row.tier {
            case "fullBody": tier = "T1"
            case "edgeAnchoredPartial": tier = "T2"
            default: tier = "T3"
            }
            func pad(_ text: String, _ width: Int) -> String {
                text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
            }
            lines.append(
                String(format: "%4d ", row.page) + pad(row.scan, 6) + " " + pad(row.side, 6) + " " + pad(tier, 5) + " "
                    + pad(pageText, 12) + " " + pad(textBlock, 12) + " " + pad(margins, 25) + " "
                    + String(format: "%+5.2f  %4.2f  ", row.skewDegrees, row.confidence) + notes.joined(separator: " ")
            )
        }

        // Uniformity of ordinary full-body pages, per side: the number to drive toward zero.
        func spread(_ values: [Double]) -> String {
            guard let lo = values.min(), let hi = values.max() else { return "-" }
            return String(format: "%.3f", hi - lo)
        }
        for side in ["verso", "recto", "single"] {
            let group = rows.filter { $0.side == side && $0.tier == "fullBody" && !$0.ownCanvas }
            guard group.count >= 2 else { continue }
            let m = group.compactMap(\.marginsInches)
            lines.append(
                "Full-body \(side) pages (\(group.count)): margin spread left \(spread(m.map(\.left))) · top \(spread(m.map(\.top))) · right \(spread(m.map(\.right))) · bottom \(spread(m.map(\.bottom))) in"
            )
        }
        let ownCanvasPages = rows.filter(\.ownCanvas).map { String($0.page) }
        if !ownCanvasPages.isEmpty {
            lines.append("Pages on their own canvas (outliers): " + ownCanvasPages.joined(separator: ", "))
        }
        let flagged = rows.filter(\.flaggedLowConfidence).map { String($0.page) }
        if !flagged.isEmpty {
            lines.append("Low-confidence pages: " + flagged.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}
