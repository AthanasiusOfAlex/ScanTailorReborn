import ScanTailorContracts

/// Per-page policy for vertical registration, stored in the manifest's manual overrides.
public enum VerticalRegistrationPolicy: String, Sendable, Equatable, Codable, CaseIterable {
    /// Register the page when the automatic eligibility rules allow it.
    case automatic
    /// Force registration on the page's detected anchor, even when it would normally be preserved.
    case anchor
    /// Keep the harmonizer's placement (content-box top on the frame top).
    case boxTop
}

/// Book-wide vertical registration mode (the CLI's `--vertical-anchor`).
public enum VerticalRegistrationMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Align eligible pages on their running header or first body baseline.
    case automatic
    /// Leave every page where the harmonizer placed it (legacy behavior).
    case boxTop
}

/// How one page was (or was not) vertically registered.
public struct PageVerticalRegistration: Sendable, Equatable, Codable {
    /// Outcome category.
    public enum Method: String, Sendable, Equatable, Codable {
        /// Aligned so its running-header baseline sits on the book's header line.
        case header
        /// Aligned so its first body baseline sits on the book's body line.
        case bodyBaseline
        /// Intentionally left alone (title page, sinkage, bottom-anchored or floating page).
        case preserved
        /// Left on the box-top placement because registration was disabled or not possible.
        case boxTop
        /// A manual destination origin was applied.
        case manual
    }

    /// Outcome category.
    public var method: Method
    /// Vertical movement relative to the harmonizer's placement, in processing-DPI pixels.
    public var shiftPixels: Int
    /// Canvas Y of the page's anchor baseline after registration (`nil` when none was used).
    public var anchorCanvasY: Int?
    /// Diagnostic flags such as `registration:shiftTooLarge`, `registration:clamped`,
    /// `registration:lowConfidence`, `registration:titleLike`, or `override:boxTop`.
    public var flags: [String]

    public init(method: Method, shiftPixels: Int = 0, anchorCanvasY: Int? = nil, flags: [String] = []) {
        self.method = method
        self.shiftPixels = shiftPixels
        self.anchorCanvasY = anchorCanvasY
        self.flags = flags
    }
}

/// Book-wide vertical registration telemetry.
public struct VerticalRegistrationSummary: Sendable, Equatable, Codable {
    /// Mode the registration ran in.
    public var mode: VerticalRegistrationMode
    /// Canvas Y of the book's running-header baseline line (`nil` when no header pages were registered).
    public var headerLineY: Int?
    /// Canvas Y of the book's first-body-baseline line (`nil` when no page could be aligned).
    public var bodyLineY: Int?
    /// Pages registered on a running header.
    public var headerPageCount: Int
    /// Pages registered on a first body baseline.
    public var bodyPageCount: Int
    /// Pages deliberately left alone.
    public var preservedPageCount: Int
    /// Pages left on the box-top placement.
    public var boxTopPageCount: Int
    /// Pages with a manual destination origin.
    public var manualPageCount: Int
    /// Largest absolute shift applied, in pixels.
    public var maxShiftPixels: Int
    /// Spread (max - min) of header baselines across registered header pages before registration.
    public var headerSpreadBeforePixels: Int?
    /// Spread of header baselines after registration.
    public var headerSpreadAfterPixels: Int?
    /// Spread of first-body baselines across registered pages before registration.
    public var bodySpreadBeforePixels: Int?
    /// Spread of first-body baselines after registration.
    public var bodySpreadAfterPixels: Int?

    public init(
        mode: VerticalRegistrationMode,
        headerLineY: Int? = nil,
        bodyLineY: Int? = nil,
        headerPageCount: Int = 0,
        bodyPageCount: Int = 0,
        preservedPageCount: Int = 0,
        boxTopPageCount: Int = 0,
        manualPageCount: Int = 0,
        maxShiftPixels: Int = 0,
        headerSpreadBeforePixels: Int? = nil,
        headerSpreadAfterPixels: Int? = nil,
        bodySpreadBeforePixels: Int? = nil,
        bodySpreadAfterPixels: Int? = nil
    ) {
        self.mode = mode
        self.headerLineY = headerLineY
        self.bodyLineY = bodyLineY
        self.headerPageCount = headerPageCount
        self.bodyPageCount = bodyPageCount
        self.preservedPageCount = preservedPageCount
        self.boxTopPageCount = boxTopPageCount
        self.manualPageCount = manualPageCount
        self.maxShiftPixels = maxShiftPixels
        self.headerSpreadBeforePixels = headerSpreadBeforePixels
        self.headerSpreadAfterPixels = headerSpreadAfterPixels
        self.bodySpreadBeforePixels = bodySpreadBeforePixels
        self.bodySpreadAfterPixels = bodySpreadAfterPixels
    }
}

/// Aligns the vertical position of full-body pages on one shared header line and one shared body line.
///
/// The harmonizer places every Tier 1 page with its content-box top on the canonical frame top, so any
/// difference in how far the first inked row sits above the running header (or first body line) shows up
/// as jitter when pages are flipped. This step instead pins the page's *anchor baseline* — the running
/// header baseline when the page has one, otherwise the first body baseline (Substep 6.1.1) — to a book-wide
/// reference line:
///
/// - **Header line:** frame top + the median distance from content top to header baseline.
/// - **Body line:** header line + the median header-to-first-body distance. In a book without running
///   headers: frame top + the median distance from content top to first body baseline.
///
/// Because the lines are medians of the pages themselves, the typical page does not move.
///
/// Pages that are *meant* to sit elsewhere keep their placement: Tier 3 pages, Tier 2 pages anchored by
/// their bottom edge (chapter openers with sinkage) or at a natural position, and pages flagged as title-like
/// or with top sinkage. Pages whose anchor is ambiguous or weak stay on the box-top placement.
public struct VerticalRegistration: Sendable {
    /// Tuning parameters.
    public struct Configuration: Sendable, Equatable {
        /// Registration mode.
        public var mode: VerticalRegistrationMode
        /// Minimum anchor confidence for a page to be registered automatically.
        public var minConfidence: Double
        /// Maximum shift, in body line pitches, before a page falls back to the box-top placement.
        public var maxShiftPitches: Double
        /// Maximum shift as a fraction of the canonical frame height (caps the pitch-based limit when the pitch is unreliable).
        public var maxShiftFrameFraction: Double
        /// Maximum relative difference between a page's own line pitch and the book's before the page
        /// is treated as atypical (a title block, a table, or a mis-measured page) and left alone.
        public var maxPitchDeviation: Double

        public init(
            mode: VerticalRegistrationMode = .automatic,
            minConfidence: Double = 0.5,
            maxShiftPitches: Double = 3.0,
            maxShiftFrameFraction: Double = 0.12,
            maxPitchDeviation: Double = 0.30
        ) {
            self.maxPitchDeviation = min(max(0.05, maxPitchDeviation), 2.0)
            self.mode = mode
            self.minConfidence = min(max(0.0, minConfidence), 1.0)
            self.maxShiftPitches = min(max(0.5, maxShiftPitches), 20.0)
            self.maxShiftFrameFraction = min(max(0.005, maxShiftFrameFraction), 0.5)
        }
    }

    /// One page entering registration.
    public struct PageInput: Sendable {
        /// Harmonizer plan with manual content-box overrides already applied.
        public var plan: MarginHarmonizer.PageLayoutPlan
        /// Detected anchor (`nil` when running-header detection was disabled).
        public var anchor: PageTopAnchor?
        /// Per-page policy (`nil` is `.automatic`).
        public var policy: VerticalRegistrationPolicy?
        /// Whether a manual destination origin has been applied to `plan`.
        public var hasManualOrigin: Bool

        public init(
            plan: MarginHarmonizer.PageLayoutPlan,
            anchor: PageTopAnchor?,
            policy: VerticalRegistrationPolicy? = nil,
            hasManualOrigin: Bool = false
        ) {
            self.plan = plan
            self.anchor = anchor
            self.policy = policy
            self.hasManualOrigin = hasManualOrigin
        }
    }

    /// Registration output, one entry per input page (input order).
    public struct Result: Sendable, Equatable {
        /// Plans with the vertical destination origin adjusted.
        public var plans: [MarginHarmonizer.PageLayoutPlan]
        /// Per-page registration records.
        public var records: [PageVerticalRegistration]
        /// Book-wide summary.
        public var summary: VerticalRegistrationSummary
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Registration

    /// Registers the pages of one book.
    ///
    /// - Parameters:
    ///   - pages: Pages in output order.
    ///   - versoFrame: Canonical frame for verso pages.
    ///   - rectoFrame: Canonical frame for recto and single pages.
    ///   - bodyLinePitch: Typical body line pitch in pixels (`nil` if unknown); bounds the shift guard.
    /// - Returns: Adjusted plans, per-page records and a summary.
    public func register(
        pages: [PageInput],
        versoFrame: Rect2I,
        rectoFrame: Rect2I,
        bodyLinePitch: Double?
    ) -> Result {
        var plans = pages.map(\.plan)
        var records = [PageVerticalRegistration](repeating: PageVerticalRegistration(method: .boxTop), count: pages.count)
        func frame(_ i: Int) -> Rect2I { pages[i].plan.side == .verso ? versoFrame : rectoFrame }

        // Sides on which running headers were detected. A page on a side with none, in a book that has
        // headers elsewhere, may simply be a page whose header was missed, so its first line is not
        // trusted as a body baseline.
        let sidesWithHeaders = Set(pages.filter { $0.anchor?.kind == .runningHeader }.map(\.plan.side))

        // 1. Classify each page: decided now, or a candidate for registration.
        enum Kind { case header, body }
        struct Candidate { var kind: Kind; var forced: Bool }
        var candidates: [Int: Candidate] = [:]

        for (i, page) in pages.enumerated() {
            if page.hasManualOrigin {
                records[i] = PageVerticalRegistration(method: .manual)
                continue
            }
            if configuration.mode == .boxTop {
                records[i] = PageVerticalRegistration(method: .boxTop, flags: ["registration:disabled"])
                continue
            }
            let policy = page.policy ?? .automatic
            if policy == .boxTop {
                records[i] = PageVerticalRegistration(method: .boxTop, flags: ["override:boxTop"])
                continue
            }
            guard let box = page.plan.sourceContentBox, !box.isEmpty else {
                records[i] = PageVerticalRegistration(method: .preserved, flags: ["registration:noContent"])
                continue
            }
            let forced = policy == .anchor

            if !forced {
                switch page.plan.tier {
                case .standaloneFloating:
                    records[i] = PageVerticalRegistration(method: .preserved, flags: ["registration:floating"])
                    continue
                case .edgeAnchoredPartial where page.plan.verticalAnchorEdge != .top:
                    let flag = page.plan.verticalAnchorEdge == .bottom ? "registration:bottomAnchored" : "registration:naturalPosition"
                    records[i] = PageVerticalRegistration(method: .preserved, flags: [flag])
                    continue
                default:
                    break
                }
            }

            guard let anchor = page.anchor, anchor.kind != .none, let anchorY = anchor.anchorY else {
                records[i] = PageVerticalRegistration(method: .boxTop, flags: ["registration:noAnchor"])
                continue
            }
            if !forced {
                if anchor.flags.contains("titleLike") {
                    records[i] = PageVerticalRegistration(method: .preserved, flags: ["registration:titleLike"])
                    continue
                }
                if anchor.flags.contains("sinkage") {
                    records[i] = PageVerticalRegistration(method: .preserved, flags: ["registration:sinkage"])
                    continue
                }
                if anchor.flags.contains("header:outOfCluster") || anchor.flags.contains("header:sizeMismatch") {
                    records[i] = PageVerticalRegistration(method: .boxTop, flags: ["registration:ambiguousTop"])
                    continue
                }
                if anchor.confidence < configuration.minConfidence {
                    records[i] = PageVerticalRegistration(method: .boxTop, flags: ["registration:lowConfidence"])
                    continue
                }
            }
            if !forced, let own = anchor.bodyLinePitch, let typical = bodyLinePitch, typical > 0,
               abs(own - typical) > configuration.maxPitchDeviation * typical {
                records[i] = PageVerticalRegistration(method: .boxTop, flags: ["registration:atypicalLines"])
                continue
            }
            if !forced, anchor.kind == .bodyBaseline, !sidesWithHeaders.isEmpty, !sidesWithHeaders.contains(page.plan.side) {
                records[i] = PageVerticalRegistration(method: .boxTop, flags: ["registration:headersUndetectedOnSide"])
                continue
            }
            guard anchorY >= box.minY, anchorY < box.maxY else {
                records[i] = PageVerticalRegistration(method: .boxTop, flags: ["registration:anchorOutsideBox"])
                continue
            }
            candidates[i] = Candidate(kind: anchor.kind == .runningHeader ? .header : .body, forced: forced)
        }

        // 2. Reference offsets from automatically eligible pages (medians, relative to the frame top).
        var headerOffsets: [Double] = []
        var bodyAfterHeader: [Double] = []
        var bodyOffsets: [Double] = []
        for (i, candidate) in candidates where !candidate.forced {
            guard let box = pages[i].plan.sourceContentBox, let anchor = pages[i].anchor, let anchorY = anchor.anchorY else { continue }
            switch candidate.kind {
            case .header:
                headerOffsets.append(Double(anchorY - box.minY))
                if let body = anchor.firstBodyBaselineY, let header = anchor.headerBaselineY, body > header {
                    bodyAfterHeader.append(Double(body - header))
                }
            case .body:
                bodyOffsets.append(Double(anchorY - box.minY))
            }
        }
        let headerOffset = RunningHeaderDetector.median(headerOffsets).map { Int($0.rounded()) }
        let bodyOffset: Int? = {
            if let headerOffset, let gap = RunningHeaderDetector.median(bodyAfterHeader) {
                return headerOffset + Int(gap.rounded())
            }
            return RunningHeaderDetector.median(bodyOffsets).map { Int($0.rounded()) }
        }()

        // 3. Place the candidates.
        var maxShift = 0
        for (i, candidate) in candidates.sorted(by: { $0.key < $1.key }) {
            guard let box = pages[i].plan.sourceContentBox, let anchorY = pages[i].anchor?.anchorY else { continue }
            let pageFrame = frame(i)
            let reference = candidate.kind == .header ? headerOffset : bodyOffset
            guard let reference else {
                records[i] = PageVerticalRegistration(method: .boxTop, flags: ["registration:noReference"])
                continue
            }
            let targetY = pageFrame.minY + reference
            let wantedY = targetY - (anchorY - box.minY)
            let currentY = pages[i].plan.destinationOrigin.y
            let canvasH = pages[i].plan.canvasSize.height

            var flags: [String] = candidate.forced ? ["override:anchor"] : []
            if !candidate.forced {
                var limit = Double(pageFrame.height) * configuration.maxShiftFrameFraction
                if let bodyLinePitch, bodyLinePitch > 0 {
                    limit = min(limit, configuration.maxShiftPitches * bodyLinePitch)
                }
                if Double(abs(wantedY - currentY)) > limit {
                    records[i] = PageVerticalRegistration(method: .boxTop, flags: ["registration:shiftTooLarge"])
                    continue
                }
            }
            var newY = wantedY
            if canvasH > box.height {
                newY = min(max(0, wantedY), canvasH - box.height)
            } else {
                newY = 0
            }
            if newY != wantedY { flags.append("registration:clamped") }

            plans[i].destinationOrigin = Point2I(x: plans[i].destinationOrigin.x, y: newY)
            let shift = newY - currentY
            maxShift = max(maxShift, abs(shift))
            records[i] = PageVerticalRegistration(
                method: candidate.kind == .header ? .header : .bodyBaseline,
                shiftPixels: shift,
                anchorCanvasY: newY + (anchorY - box.minY),
                flags: flags
            )
        }

        // 4. Telemetry.
        func canvasY(_ baseline: Int?, _ index: Int, _ plan: MarginHarmonizer.PageLayoutPlan) -> Int? {
            guard let baseline, let box = plan.sourceContentBox else { return nil }
            return plan.destinationOrigin.y + (baseline - box.minY)
        }
        var headerBefore: [Int] = [], headerAfter: [Int] = [], bodyBefore: [Int] = [], bodyAfter: [Int] = []
        for (i, record) in records.enumerated() where record.method == .header || record.method == .bodyBaseline {
            let anchor = pages[i].anchor
            if record.method == .header {
                if let y = canvasY(anchor?.headerBaselineY, i, pages[i].plan) { headerBefore.append(y) }
                if let y = canvasY(anchor?.headerBaselineY, i, plans[i]) { headerAfter.append(y) }
            }
            if let y = canvasY(anchor?.firstBodyBaselineY, i, pages[i].plan) { bodyBefore.append(y) }
            if let y = canvasY(anchor?.firstBodyBaselineY, i, plans[i]) { bodyAfter.append(y) }
        }
        func spread(_ values: [Int]) -> Int? {
            guard let lo = values.min(), let hi = values.max() else { return nil }
            return hi - lo
        }

        let reportFrame = rectoFrame
        let summary = VerticalRegistrationSummary(
            mode: configuration.mode,
            headerLineY: headerOffset.map { reportFrame.minY + $0 },
            bodyLineY: bodyOffset.map { reportFrame.minY + $0 },
            headerPageCount: records.filter { $0.method == .header }.count,
            bodyPageCount: records.filter { $0.method == .bodyBaseline }.count,
            preservedPageCount: records.filter { $0.method == .preserved }.count,
            boxTopPageCount: records.filter { $0.method == .boxTop }.count,
            manualPageCount: records.filter { $0.method == .manual }.count,
            maxShiftPixels: maxShift,
            headerSpreadBeforePixels: spread(headerBefore),
            headerSpreadAfterPixels: spread(headerAfter),
            bodySpreadBeforePixels: spread(bodyBefore),
            bodySpreadAfterPixels: spread(bodyAfter)
        )
        return Result(plans: plans, records: records, summary: summary)
    }

    /// Typical body line pitch of a book: the median of the per-side pitches that look plausible.
    public static func typicalPitch(of model: RunningHeaderModel?) -> Double? {
        guard let model else { return nil }
        return RunningHeaderDetector.median(model.sides.compactMap(\.bodyLinePitchPixels).filter { $0 > 0 })
    }
}
