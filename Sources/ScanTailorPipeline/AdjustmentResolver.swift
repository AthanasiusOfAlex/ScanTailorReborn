import Foundation
import ScanTailorContracts
import ScanTailorCore

/// Applies a ``PageAdjustments`` file while a book is processed, and records what took effect.
///
/// Scans are matched by their number in the source PDF (`s12`), pages by scan and half (`s12L`) or by their
/// output number (`45`). When several entries name the same page, the more specific one wins:
/// `45` is overridden by `s12`, which is overridden by `s12L`.
struct AdjustmentResolver: Sendable {
    let adjustments: PageAdjustments
    /// Scan number (1-based, counted from the start of the source PDF) of each processed scan, in order.
    let scanNumbers: [Int]
    let processingDPI: Int

    private var appliedFields: [PageReference: Set<String>] = [:]
    private var pageNotes: [AdjustmentReport.Ignored] = []

    init(adjustments: PageAdjustments, scanNumbers: [Int], processingDPI: Int) {
        self.adjustments = adjustments
        self.scanNumbers = scanNumbers
        self.processingDPI = processingDPI
    }

    var isActive: Bool { !adjustments.isEmpty }

    /// The edits for the processed scan at `index` (its position among the processed scans), if any.
    mutating func scanAdjustment(forScanAt index: Int) -> ScanAdjustment? {
        guard index < scanNumbers.count else { return nil }
        let key = PageReference.scan(scanNumbers[index], .whole)
        guard let adj = adjustments.scans[key] else { return nil }
        appliedFields[key, default: []].formUnion(adj.fieldNames)
        return adj
    }

    /// The manual override for one output page: the adjustments file overlaid on `base` (a stored manifest's override).
    mutating func override(
        outputIndex: Int,
        scanIndex: Int,
        side: PageSide,
        base: PageManualOverride?
    ) -> PageManualOverride? {
        guard isActive, scanIndex < scanNumbers.count else { return base }
        let scan = scanNumbers[scanIndex]
        var keys: [PageReference] = [.outputPage(outputIndex + 1), .scan(scan, .whole)]
        switch side {
        case .leftVerso: keys.append(.scan(scan, .left))
        case .rightRecto: keys.append(.scan(scan, .right))
        case .single: break
        }
        var merged: PageAdjustment? = nil
        for key in keys {
            guard let adj = adjustments.pages[key] else { continue }
            appliedFields[key, default: []].formUnion(adj.fieldNames)
            merged = merged.map { $0.merged(with: adj) } ?? adj
        }
        guard let merged else { return base }
        return makeOverride(from: merged).overlaid(on: base)
    }

    /// Notes that part of an entry could not be applied to a page it matched.
    mutating func note(page outputIndex: Int, ignored field: String, reason: String) {
        pageNotes.append(AdjustmentReport.Ignored(reference: "page \(outputIndex + 1) \(field)", reason: reason))
    }

    /// The final report.
    /// - Parameters:
    ///   - outputPageCount: Number of pages in the finished book.
    ///   - producedScans: Scan numbers that produced at least one page.
    ///   - splitScans: Scan numbers that were cut into two pages.
    func report(outputPageCount: Int, producedScans: Set<Int>, splitScans: Set<Int>) -> AdjustmentReport {
        var report = AdjustmentReport(source: adjustments.source)
        let processed = Set(scanNumbers)

        func reason(for key: PageReference) -> String {
            switch key {
            case .outputPage(let n):
                return "there is no output page \(n) (the book has \(outputPageCount) pages)"
            case .scan(let n, let half):
                if !processed.contains(n) { return "scan \(n) was not processed (outside --page-range, excluded, or not in the PDF)" }
                if !producedScans.contains(n) { return "scan \(n) produced no page (dropped or pruned as blank)" }
                if half != .whole && !splitScans.contains(n) { return "scan \(n) was not split into two pages" }
                return "scan \(n) has no such page"
            }
        }

        let scanKeys = adjustments.scans.keys.sorted()
        for key in scanKeys {
            if let fields = appliedFields[key] {
                report.applied.append(.init(reference: key.description, fields: fields.sorted()))
            } else {
                report.ignored.append(.init(reference: key.description, reason: reason(for: key)))
            }
        }
        for key in adjustments.pages.keys.sorted() {
            if let fields = appliedFields[key] {
                report.applied.append(.init(reference: key.description, fields: fields.sorted()))
            } else {
                report.ignored.append(.init(reference: key.description, reason: reason(for: key)))
            }
        }
        report.ignored.append(contentsOf: pageNotes)
        return report
    }

    // MARK: - Conversion

    private func makeOverride(from a: PageAdjustment) -> PageManualOverride {
        var o = PageManualOverride()
        let dpi = processingDPI
        o.overrideSkewDegrees = a.skewDegrees
        o.disableDewarp = a.disableDewarp
        if let r = a.contentBoxRect {
            let left = r.left.pixels(atDPI: dpi), top = r.top.pixels(atDPI: dpi)
            let right = r.right.pixels(atDPI: dpi), bottom = r.bottom.pixels(atDPI: dpi)
            if right > left && bottom > top {
                o.overrideContentBox = Rect2I(x: left, y: top, width: right - left, height: bottom - top)
            }
        }
        if let n = a.contentBoxNudge {
            o.contentBoxNudge = PageManualOverride.ContentBoxNudge(
                top: n.top?.pixels(atDPI: dpi) ?? 0,
                left: n.left?.pixels(atDPI: dpi) ?? 0,
                bottom: n.bottom?.pixels(atDPI: dpi) ?? 0,
                right: n.right?.pixels(atDPI: dpi) ?? 0
            )
        }
        if a.offsetX != nil || a.offsetY != nil {
            o.destinationOffset = Point2I(x: a.offsetX?.pixels(atDPI: dpi) ?? 0, y: a.offsetY?.pixels(atDPI: dpi) ?? 0)
        }
        o.forcedTier = a.tier
        o.dimensionClass = a.outlier.map { $0 ? .outlier : .canonical }
        o.pageSizeInches = a.pageSize?.sizeInInches
        o.keep = a.keep
        o.drop = a.drop
        o.runningHeader = a.runningHeader
        o.verticalRegistration = a.verticalRegistration
        o.borderFallback = a.borderFallback
        return o
    }

    /// The cut position of a spread of `width` pixels from a ``ScanAdjustment/splitX``, clamped inside the scan.
    static func splitCenter(_ x: AdjustmentLength, width: Int, dpi: Int) -> Double {
        let px = Double(x.pixels(atDPI: dpi, extent: width))
        return min(max(px, Double(width) * 0.05), Double(width) * 0.95)
    }

    /// The override built from the scan-based entries alone (`s12`, `s12L`), without recording them as applied.
    ///
    /// Pass 1 runs scans in parallel before the output page numbers are known; this is the best guess of a
    /// page's pixel-changing edits at that point. Entries by page number, and a stored manifest's overrides,
    /// are matched later, and a page whose final edits differ is processed again.
    func scanBasedOverride(scanIndex: Int, side: PageSide) -> PageManualOverride? {
        guard isActive, scanIndex < scanNumbers.count else { return nil }
        let scan = scanNumbers[scanIndex]
        var keys: [PageReference] = [.scan(scan, .whole)]
        switch side {
        case .leftVerso: keys.append(.scan(scan, .left))
        case .rightRecto: keys.append(.scan(scan, .right))
        case .single: break
        }
        var merged: PageAdjustment? = nil
        for key in keys {
            guard let adj = adjustments.pages[key] else { continue }
            merged = merged.map { $0.merged(with: adj) } ?? adj
        }
        return merged.map(makeOverride(from:))
    }
}
