import Foundation
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline

extension ScanTailorCLI {
    /// A page that automatic detection could not settle, with the reasons and the adjustments-file entry to start from.
    public struct PageReviewFinding: Codable, Equatable {
        /// 1-based output page number.
        public var page: Int
        /// Scan-based name for the adjustments file (`s12`, `s12L`, `s12R`).
        public var scan: String
        public var reasons: [String]
        /// An adjustments-file entry for `pages` that fixes the box; edit the numbers after looking at the page.
        public var suggestion: String?
    }

    /// Smallest ratio to the book's typical text block that makes a block suspicious.
    static let reviewOversizeRatio = 1.08
    /// A box this close to the top of the scan (inches) swallowed the scan's edge.
    static let reviewScanEdgeInches = 0.05

    /// Pages that most likely need a person's (or an agent's) eye: boxes far larger than the book's typical text
    /// block (gutter shadow, scan-edge ink), boxes that overflow the canvas or touch the scan's top edge, and headers
    /// registration could not use. Pages that already have a manual content box are
    /// not flagged for their box.
    ///
    /// Automatic detection only has to handle most pages; this list is the hand-off for the rest.
    public static func reviewFindings(_ manifest: BookProcessingManifest) -> [PageReviewFinding] {
        let dpi = Double(max(1, manifest.processingDPI))
        func median(_ values: [Double]) -> Double? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func inches(_ px: Int) -> Double { Double(px) / dpi }
        func f(_ v: Double) -> String { String(format: "%.2f", v) }

        let ordinary = manifest.pages.filter {
            $0.dimension?.pdfPageSizePoints == nil && $0.layoutPlan.tier != .standaloneFloating
                && ($0.layoutPlan.sourceContentBox.map { !$0.isEmpty } ?? false)
        }
        let typicalWidth = median(ordinary.compactMap { $0.layoutPlan.sourceContentBox.map { inches($0.width) } })
        let typicalHeight = median(ordinary.compactMap { $0.layoutPlan.sourceContentBox.map { inches($0.height) } })
        let bookHasHeaders = (manifest.verticalRegistration?.headerPageCount ?? 0) >= 3

        var findings: [PageReviewFinding] = []
        for record in manifest.pages {
            let plan = record.layoutPlan
            var reasons: [String] = []
            var suggestion: String? = nil
            let scan = manifest.scanReference(of: record)
            let hasManualBox = record.manualOverride?.overrideContentBox != nil

            if let box = plan.sourceContentBox, !box.isEmpty, !hasManualBox {
                let w = inches(box.width), h = inches(box.height)
                var boxProblem = false
                if let typicalWidth, w > reviewOversizeRatio * typicalWidth {
                    reasons.append("box \(f(w)) in wide (typical \(f(typicalWidth)))")
                    boxProblem = true
                }
                if let typicalHeight, h > reviewOversizeRatio * typicalHeight {
                    reasons.append("box \(f(h)) in tall (typical \(f(typicalHeight)))")
                    boxProblem = true
                }
                if inches(box.minY) < reviewScanEdgeInches {
                    reasons.append("box touches the top edge of the scan")
                    boxProblem = true
                }
                let bottom = inches(plan.canvasSize.height - plan.destinationOrigin.y - box.height)
                let right = inches(plan.canvasSize.width - plan.destinationOrigin.x - box.width)
                if bottom < -0.01 || right < -0.01 {
                    reasons.append("box overflows the canvas")
                    boxProblem = true
                }
                if boxProblem {
                    suggestion = "\"\(scan)\": { \"contentBox\": { \"rect\": [\"\(f(inches(box.minX)))in\", \"\(f(inches(box.minY)))in\", "
                        + "\"\(f(inches(box.maxX)))in\", \"\(f(inches(box.maxY)))in\"] } }  (current box; tighten it to the text)"
                }
            }
            if bookHasHeaders, let registration = record.registration,
               registration.method == .boxTop || registration.method == .preserved {
                // Floating, bottom-anchored, title-like and outlier pages are placed on purpose.
                let problems: Set<String> = ["registration:ambiguousTop", "registration:lowConfidence", "registration:shiftTooLarge", "registration:sinkage"]
                let flags = registration.flags.filter { problems.contains($0) }
                if !flags.isEmpty { reasons.append("registration: " + flags.map { $0.replacingOccurrences(of: "registration:", with: "") }.joined(separator: ", ")) }
            } else if bookHasHeaders, let registration = record.registration, registration.flags.contains("registration:clamped") {
                reasons.append("header could not be moved into line (clamped)")
            }

            if !reasons.isEmpty {
                findings.append(PageReviewFinding(page: record.outputPageIndex + 1, scan: scan, reasons: reasons, suggestion: suggestion))
            }
        }
        return findings
    }

    /// The "Pages to check" section of the inspect table and of the end-of-run summary.
    public static func formatReview(_ findings: [PageReviewFinding]) -> String {
        guard !findings.isEmpty else { return "Pages to check: none" }
        var lines = ["Pages to check (\(findings.count)); look at their diagnostic images, then edit the adjustments file:"]
        for finding in findings {
            lines.append("  page \(finding.page) (\(finding.scan)): " + finding.reasons.joined(separator: "; "))
            if let suggestion = finding.suggestion { lines.append("      \(suggestion)") }
        }
        return lines.joined(separator: "\n")
    }
}
