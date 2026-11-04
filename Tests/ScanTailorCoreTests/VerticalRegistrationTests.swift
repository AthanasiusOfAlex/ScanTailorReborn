import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

@Suite("Substep 6.1.2 — Vertical Registration Tests")
struct VerticalRegistrationTests {
    static let canvas = Size2I(width: 1000, height: 1400)
    static let frame = Rect2I(x: 100, y: 150, width: 800, height: 1100)
    static let pitch = 40.0
    /// Distance from a header baseline to the first body baseline.
    static let gap = 100

    /// A Tier 1 page whose content box starts at source `top`, placed by the harmonizer at the frame top.
    static func plan(
        _ index: Int,
        tier: MarginHarmonizer.PlacementTier = .fullBody,
        edge: MarginHarmonizer.VerticalAnchorEdge? = nil,
        top: Int = 200,
        height: Int = 1100,
        destY: Int = 150
    ) -> MarginHarmonizer.PageLayoutPlan {
        let box = Rect2I(x: 100, y: top, width: 800, height: height)
        return MarginHarmonizer.PageLayoutPlan(
            pageIndex: index,
            side: index % 2 == 0 ? .recto : .verso,
            tier: tier,
            wasOutlierTrimmed: false,
            sourceContentBox: box,
            retainedClusterBoxes: [box],
            rejectedClusterBoxes: [],
            destinationOrigin: Point2I(x: 100, y: destY),
            canvasSize: canvas,
            verticalAnchorEdge: edge
        )
    }

    /// A header anchor whose baseline is `offset` below the page's content-box top.
    static func header(_ plan: MarginHarmonizer.PageLayoutPlan, offset: Int, confidence: Double = 0.9, flags: [String] = []) -> PageTopAnchor {
        let top = plan.sourceContentBox!.minY
        return PageTopAnchor(
            kind: .runningHeader,
            anchorY: top + offset,
            headerBaselineY: top + offset,
            firstBodyBaselineY: top + offset + gap,
            confidence: confidence,
            flags: flags
        )
    }

    static func body(_ plan: MarginHarmonizer.PageLayoutPlan, offset: Int, confidence: Double = 0.9, flags: [String] = [], pitch: Double? = nil) -> PageTopAnchor {
        let top = plan.sourceContentBox!.minY
        return PageTopAnchor(
            kind: .bodyBaseline,
            anchorY: top + offset,
            firstBodyLineTopY: top + offset - 20,
            firstBodyBaselineY: top + offset,
            confidence: confidence,
            flags: flags,
            bodyLinePitch: pitch
        )
    }

    static func register(
        _ inputs: [VerticalRegistration.PageInput],
        configuration: VerticalRegistration.Configuration = .init()
    ) -> VerticalRegistration.Result {
        VerticalRegistration(configuration: configuration).register(
            pages: inputs, versoFrame: frame, rectoFrame: frame, bodyLinePitch: pitch
        )
    }

    /// Eight full-body header pages whose header baseline sits 40–52 px below the content top.
    static func headerBook() -> [VerticalRegistration.PageInput] {
        let offsets = [40, 44, 52, 46, 50, 48, 42, 46]
        return offsets.enumerated().map { i, off in
            let p = plan(i, top: 200 + (i * 7) % 20)
            return .init(plan: p, anchor: header(p, offset: off))
        }
    }

    // MARK: - Header registration

    @Test("Header pages land on one shared header line; the typical page does not move")
    func headerLine() throws {
        let inputs = Self.headerBook()
        let result = Self.register(inputs)

        // Median offset of [40,44,52,46,50,48,42,46] is 46.
        let headerLine = Self.frame.minY + 46
        #expect(result.summary.headerLineY == headerLine)
        #expect(result.summary.bodyLineY == headerLine + Self.gap)
        #expect(result.summary.headerPageCount == 8)
        #expect(result.summary.mode == .automatic)

        for (i, record) in result.records.enumerated() {
            #expect(record.method == .header)
            #expect(record.anchorCanvasY == headerLine, "page \(i)")
            let box = try #require(result.plans[i].sourceContentBox)
            let anchorY = try #require(inputs[i].anchor?.anchorY)
            #expect(result.plans[i].destinationOrigin.y + (anchorY - box.minY) == headerLine)
            #expect(result.plans[i].destinationOrigin.x == 100, "x is never touched")
        }
        #expect(result.records[3].shiftPixels == 0 && result.records[7].shiftPixels == 0, "median pages stay put")
        #expect(result.records[2].shiftPixels == -6 && result.records[0].shiftPixels == 6)
        #expect(result.summary.maxShiftPixels == 6)
        #expect(result.summary.headerSpreadBeforePixels == 12)
        #expect(result.summary.headerSpreadAfterPixels == 0)
        // Header-to-body distance is constant here, so the body baselines line up too.
        #expect(result.summary.bodySpreadAfterPixels == 0)
        #expect(try #require(result.summary.bodySpreadBeforePixels) > 0)
    }

    @Test("A headerless page aligns its first body baseline on the body line, not the header line")
    func headerlessPage() throws {
        var inputs = Self.headerBook()
        let p = Self.plan(8, top: 205)
        inputs.append(.init(plan: p, anchor: Self.body(p, offset: 30)))
        let result = Self.register(inputs)

        let record = result.records[8]
        #expect(record.method == .bodyBaseline)
        let bodyLine = try #require(result.summary.bodyLineY)
        #expect(record.anchorCanvasY == bodyLine)
        #expect(record.shiftPixels == bodyLine - (150 + 30))
        #expect(result.summary.bodyPageCount == 1)
        #expect(result.summary.headerPageCount == 8, "headerless page does not disturb the header line")
    }

    @Test("A book without running headers aligns on the first body baseline")
    func headerlessBook() throws {
        let offsets = [28, 33, 30, 26, 31, 30]
        let inputs = offsets.enumerated().map { i, off -> VerticalRegistration.PageInput in
            let p = Self.plan(i, top: 200 + i * 3)
            return .init(plan: p, anchor: Self.body(p, offset: off))
        }
        let result = Self.register(inputs)
        #expect(result.summary.headerLineY == nil)
        #expect(result.summary.bodyLineY == 150 + 30)
        #expect(result.records.allSatisfy { $0.method == .bodyBaseline && $0.anchorCanvasY == 180 })
        #expect(result.summary.bodySpreadBeforePixels == 7)
        #expect(result.summary.bodySpreadAfterPixels == 0)
    }

    // MARK: - Eligibility

    @Test("Sinkage, floating and bottom-anchored pages keep their placement; weak anchors fall back to box-top")
    func eligibility() throws {
        var inputs = Self.headerBook()
        func add(_ plan: MarginHarmonizer.PageLayoutPlan, _ anchor: PageTopAnchor?, policy: VerticalRegistrationPolicy? = nil) {
            inputs.append(.init(plan: plan, anchor: anchor, policy: policy))
        }
        let tier3 = Self.plan(8, tier: .standaloneFloating, top: 500, height: 400, destY: 520)
        add(tier3, Self.header(tier3, offset: 60))
        let opener = Self.plan(9, tier: .edgeAnchoredPartial, edge: .bottom, top: 500, height: 700, destY: 550)
        add(opener, Self.body(opener, offset: 30))
        let natural = Self.plan(10, tier: .edgeAnchoredPartial, edge: .natural, top: 400, height: 700, destY: 400)
        add(natural, Self.body(natural, offset: 30))
        let ending = Self.plan(11, tier: .edgeAnchoredPartial, edge: .top, top: 300, height: 700, destY: 150)
        add(ending, Self.header(ending, offset: 52))
        let title = Self.plan(12)
        add(title, Self.body(title, offset: 30, flags: ["titleLike"]))
        let sunk = Self.plan(13)
        add(sunk, Self.body(sunk, offset: 30, flags: ["sinkage"]))
        let weak = Self.plan(14)
        add(weak, Self.header(weak, offset: 50, confidence: 0.4))
        let ambiguous = Self.plan(15)
        add(ambiguous, Self.body(ambiguous, offset: 30, flags: ["header:outOfCluster"]))
        let sized = Self.plan(16)
        add(sized, Self.body(sized, offset: 30, flags: ["header:sizeMismatch"]))
        let noAnchor = Self.plan(17)
        add(noAnchor, nil)
        let blank = Self.plan(18)
        add(blank, PageTopAnchor(kind: .none, confidence: 1, flags: ["noText"]))
        let outside = Self.plan(19)
        add(outside, PageTopAnchor(kind: .bodyBaseline, anchorY: 5000, confidence: 0.9))
        var empty = Self.plan(20)
        empty.sourceContentBox = nil
        add(empty, nil)

        let result = Self.register(inputs)
        func record(_ i: Int) -> PageVerticalRegistration { result.records[i] }

        #expect(record(8).method == .preserved && record(8).flags == ["registration:floating"])
        #expect(record(9).method == .preserved && record(9).flags == ["registration:bottomAnchored"])
        #expect(record(10).method == .preserved && record(10).flags == ["registration:naturalPosition"])
        #expect(record(11).method == .header, "a chapter ending anchored by its top edge is registered")
        #expect(record(12).method == .preserved && record(12).flags == ["registration:titleLike"])
        #expect(record(13).method == .preserved && record(13).flags == ["registration:sinkage"])
        #expect(record(14).method == .boxTop && record(14).flags == ["registration:lowConfidence"])
        #expect(record(15).method == .boxTop && record(15).flags == ["registration:ambiguousTop"])
        #expect(record(16).method == .boxTop && record(16).flags == ["registration:ambiguousTop"])
        #expect(record(17).method == .boxTop && record(17).flags == ["registration:noAnchor"])
        #expect(record(18).method == .boxTop && record(18).flags == ["registration:noAnchor"])
        #expect(record(19).method == .boxTop && record(19).flags == ["registration:anchorOutsideBox"])
        #expect(record(20).method == .preserved && record(20).flags == ["registration:noContent"])

        for i in [8, 9, 10, 12, 13, 14, 15, 16, 17, 18, 19, 20] {
            #expect(result.plans[i] == inputs[i].plan, "page \(i) is unchanged")
            #expect(record(i).shiftPixels == 0)
        }
        // The eligible chapter ending joined the header line; the weak and ambiguous pages did not skew it.
        #expect(result.summary.headerLineY == 150 + 46 || result.summary.headerLineY == 150 + 48)
        #expect(result.plans[11].destinationOrigin.y != 150)
        #expect(result.summary.preservedPageCount == 6)
        #expect(result.summary.boxTopPageCount == 6)
    }

    @Test("A page on a side where no header was found, in a book with headers, is not trusted as headerless")
    func sideWithoutHeaders() throws {
        // Recto pages (even indices) have no detected header; verso pages (odd) do.
        var inputs: [VerticalRegistration.PageInput] = []
        for i in 0..<8 {
            let p = Self.plan(i, top: 200 + i)
            inputs.append(.init(plan: p, anchor: i % 2 == 1 ? Self.header(p, offset: 46) : Self.body(p, offset: 46)))
        }
        let result = Self.register(inputs)
        for i in stride(from: 0, to: 8, by: 2) {
            #expect(result.records[i].method == .boxTop && result.records[i].flags == ["registration:headersUndetectedOnSide"])
            #expect(result.plans[i] == inputs[i].plan)
        }
        #expect(result.summary.headerPageCount == 4)

        // In a book with no headers at all, body pages register normally.
        let headerless = (0..<6).map { i -> VerticalRegistration.PageInput in
            let p = Self.plan(i, top: 200 + i)
            return .init(plan: p, anchor: Self.body(p, offset: 30 + i))
        }
        #expect(Self.register(headerless).records.allSatisfy { $0.method == .bodyBaseline })
    }

    @Test("A page whose line pitch differs from the book's is left on the box-top placement")
    func atypicalPitch() throws {
        var inputs = Self.headerBook()
        for i in inputs.indices {
            inputs[i].anchor?.bodyLinePitch = 40
        }
        let odd = Self.plan(8)
        inputs.append(.init(plan: odd, anchor: Self.header(odd, offset: 46)))
        inputs[8].anchor?.bodyLinePitch = 12   // fragments of a title block or a table
        let result = Self.register(inputs)
        #expect(result.records[8].method == .boxTop && result.records[8].flags == ["registration:atypicalLines"])
        #expect(result.plans[8] == odd)
        #expect(result.records[0].method == .header, "pages that match the book's pitch still register")

        // A page forced with `.anchor` ignores the pitch check.
        inputs[8] = .init(plan: odd, anchor: inputs[8].anchor, policy: .anchor)
        #expect(Self.register(inputs).records[8].method == .header)
    }

    // MARK: - Guards

    @Test("A shift beyond the pitch or frame limit falls back to box-top; a shift off the canvas is clamped")
    func guards() throws {
        var inputs = Self.headerBook()
        // 3 pitches = 120 px. This page's header is 200 px below the content top: a 154 px move.
        let far = Self.plan(8)
        inputs.append(.init(plan: far, anchor: Self.header(far, offset: 200)))
        // Near the bottom of the canvas the wanted move is clamped; the page itself is short enough to move.
        let low = Self.plan(9, top: 200, height: 1000, destY: 395)
        inputs.append(.init(plan: low, anchor: Self.header(low, offset: 20)))
        let result = Self.register(inputs)

        #expect(result.records[8].method == .boxTop)
        #expect(result.records[8].flags == ["registration:shiftTooLarge"])
        #expect(result.plans[8] == far)

        // Wanted y = (150 + 46) - 20 = 176; legacy was 395, a 219 px move: too large for a normal page.
        #expect(result.records[9].flags == ["registration:shiftTooLarge"])

        // A limit of 10 pitches lets the move through; the canvas leaves room, so no clamp is needed.
        let relaxed = Self.register(inputs, configuration: .init(maxShiftPitches: 10, maxShiftFrameFraction: 0.5))
        #expect(relaxed.records[9].method == .header)
        #expect(relaxed.records[9].shiftPixels == 176 - 395)

        // A tall box on a short canvas cannot move up or down past the edges.
        var tall = Self.plan(10, top: 200, height: 1300, destY: 90)
        tall.sourceContentBox = Rect2I(x: 100, y: 200, width: 800, height: 1300)
        var clampInputs = Self.headerBook()
        clampInputs.append(.init(plan: tall, anchor: Self.header(tall, offset: 20)))
        let clamped = Self.register(clampInputs, configuration: .init(maxShiftPitches: 10, maxShiftFrameFraction: 0.5))
        // Wanted y = 196 - 20 = 176 but only 100 px of room exists (1400 - 1300).
        #expect(clamped.plans[8].destinationOrigin.y == 100)
        #expect(clamped.records[8].flags == ["registration:clamped"])
    }

    // MARK: - Overrides and mode

    @Test("Manual origin wins; boxTop policy keeps box-top; anchor policy forces registration; box-top mode changes nothing")
    func overridesAndMode() throws {
        var inputs = Self.headerBook()
        let manual = Self.plan(8, destY: 222)
        inputs.append(.init(plan: manual, anchor: Self.header(manual, offset: 60), hasManualOrigin: true))
        let pinned = Self.plan(9)
        inputs.append(.init(plan: pinned, anchor: Self.header(pinned, offset: 60), policy: .boxTop))
        let forcedFloat = Self.plan(10, tier: .standaloneFloating, top: 500, height: 400, destY: 520)
        inputs.append(.init(plan: forcedFloat, anchor: Self.header(forcedFloat, offset: 60), policy: .anchor))
        let forcedWeak = Self.plan(11)
        inputs.append(.init(plan: forcedWeak, anchor: Self.header(forcedWeak, offset: 60, confidence: 0.1, flags: ["titleLike"]), policy: .anchor))

        let result = Self.register(inputs)
        #expect(result.records[8].method == .manual && result.plans[8].destinationOrigin.y == 222)
        #expect(result.records[9].method == .boxTop && result.records[9].flags == ["override:boxTop"])
        #expect(result.plans[9] == pinned)
        #expect(result.records[10].method == .header && result.records[10].flags == ["override:anchor"])
        #expect(result.records[10].anchorCanvasY == result.summary.headerLineY, "forced pages ignore tier and shift guards")
        #expect(result.records[11].method == .header)
        #expect(result.summary.headerLineY == 150 + 46, "forced and manual pages are not used as reference")
        #expect(result.summary.manualPageCount == 1)

        let off = Self.register(inputs, configuration: .init(mode: .boxTop))
        #expect(off.plans == inputs.map(\.plan), "box-top mode reproduces the harmonizer placement")
        #expect(off.records.filter { $0.method == .manual }.count == 1)
        #expect(off.records.filter { $0.method == .boxTop }.count == inputs.count - 1)
        #expect(off.summary.mode == .boxTop && off.summary.headerPageCount == 0)
    }

    @Test("Configuration clamps; summary and records round-trip as JSON")
    func configurationAndCoding() throws {
        let config = VerticalRegistration.Configuration(minConfidence: 4, maxShiftPitches: 0, maxShiftFrameFraction: 9)
        #expect(config.minConfidence == 1 && config.maxShiftPitches == 0.5 && config.maxShiftFrameFraction == 0.5)

        let result = Self.register(Self.headerBook())
        let data = try JSONEncoder().encode(result.summary)
        #expect(try JSONDecoder().decode(VerticalRegistrationSummary.self, from: data) == result.summary)
        let recordData = try JSONEncoder().encode(result.records)
        #expect(try JSONDecoder().decode([PageVerticalRegistration].self, from: recordData) == result.records)

        // Plans written before 6.1.2 have no anchor edge.
        let planData = try JSONEncoder().encode(Self.plan(0, tier: .edgeAnchoredPartial, edge: .top))
        var json = try #require(try JSONSerialization.jsonObject(with: planData) as? [String: Any])
        #expect(json["verticalAnchorEdge"] as? String == "top")
        json.removeValue(forKey: "verticalAnchorEdge")
        let legacy = try JSONDecoder().decode(
            MarginHarmonizer.PageLayoutPlan.self, from: try JSONSerialization.data(withJSONObject: json)
        )
        #expect(legacy.verticalAnchorEdge == nil)
    }

    @Test("The harmonizer records which edge pins a Tier 2 page")
    func harmonizerEdges() throws {
        let harmonizer = MarginHarmonizer(configuration: .init(canonicalHorizontalMarginAt600DPI: 100, canonicalVerticalMarginAt600DPI: 150))
        func input(_ i: Int, box: Rect2I) -> MarginHarmonizer.PageInput {
            let cluster = ContentBoxDetector.Cluster(exactBounds: box, foregroundPixels: 5000)
            return .init(
                pageIndex: i, side: i % 2 == 0 ? .recto : .verso, pageSize: Size2I(width: 1000, height: 1400),
                detection: .init(contentBox: box, mainBodyBox: box, retainedClusters: [cluster], rejectedBoxes: [], confidence: 1)
            )
        }
        let full = Rect2I(x: 100, y: 150, width: 800, height: 1100)
        var pages = (0..<6).map { input($0, box: full) }
        pages.append(input(6, box: Rect2I(x: 100, y: 150, width: 800, height: 600)))   // ends early: top-anchored
        pages.append(input(7, box: Rect2I(x: 100, y: 650, width: 800, height: 600)))   // sinks: bottom-anchored
        pages.append(input(8, box: Rect2I(x: 100, y: 400, width: 800, height: 600)))   // floats
        let layout = harmonizer.harmonizeBook(pages: pages)

        #expect(layout.pagePlans[0].tier == .fullBody && layout.pagePlans[0].verticalAnchorEdge == nil)
        #expect(layout.pagePlans[6].tier == .edgeAnchoredPartial && layout.pagePlans[6].verticalAnchorEdge == .top)
        #expect(layout.pagePlans[7].tier == .edgeAnchoredPartial && layout.pagePlans[7].verticalAnchorEdge == .bottom)
        #expect(layout.pagePlans[8].tier == .edgeAnchoredPartial && layout.pagePlans[8].verticalAnchorEdge == .natural)
    }

    // MARK: - CLI

    @Test("CLI: --vertical-anchor parses; the inspect summary reports registration")
    func cli() throws {
        #expect(try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf"]).verticalRegistrationMode == .automatic)
        #expect(try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf", "--vertical-anchor", "box-top"]).verticalRegistrationMode == .boxTop)
        #expect(try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf", "--vertical-anchor", "auto"]).verticalRegistrationMode == .automatic)
        #expect(try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf", "--no-running-headers"]).enableRunningHeaderDetection == false)
        #expect(throws: ScanTailorCLI.CLIError.invalidOptionValue(flag: "--vertical-anchor", value: "sideways")) {
            try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf", "--vertical-anchor", "sideways"])
        }
        #expect(throws: ScanTailorCLI.CLIError.missingValue(flag: "--vertical-anchor")) {
            try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf", "--vertical-anchor"])
        }
    }

    // MARK: - Pipeline

    /// A small page with a header (and a tall mark that lifts the content-box top by `lift` pixels) and body lines.
    static func page(dy: Int, lift: Int, side: MarginHarmonizer.PageSide) -> GrayscaleBuffer {
        var gray = GrayscaleBuffer(width: 600, height: 750, dpi: 300, initialValue: 235)
        let headerBaseline = 110 + dy
        var rects: [Rect2I] = []
        rects += RunningHeaderDetectionTests.lineRects(baseline: headerBaseline, x0: 200, x1: 400, core: 9)
        let folioX = side == .verso ? 100 : 473
        rects += RunningHeaderDetectionTests.lineRects(baseline: headerBaseline, x0: folioX, x1: folioX + 28, core: 14, capitals: true)
        if lift > 0 {
            rects.append(Rect2I(minX: folioX, minY: headerBaseline - 14 - lift, maxX: folioX + 2, maxY: headerBaseline - 14))
        }
        for i in 0..<24 {
            rects += RunningHeaderDetectionTests.lineRects(baseline: headerBaseline + 50 + i * 20, x0: 100, x1: 500, core: 10)
        }
        for r in rects {
            for y in max(0, r.minY)..<min(gray.height, r.maxY) {
                for x in max(0, r.minX)..<min(gray.width, r.maxX) { gray.pixels[y * gray.width + x] = 30 }
            }
        }
        return gray
    }

    static func pipeline(mode: VerticalRegistrationMode) -> BookPipelineCoordinator {
        BookPipelineCoordinator(configuration: .init(
            processingDPI: 300,
            outputDPI: 150,
            splitMode: .singlePage,
            enableDewarp: false,
            enableAutomaticFontScaleCalibration: false,
            enablePerspectiveRectification: false,
            enableDeskMasking: false,
            verticalRegistrationConfiguration: .init(mode: mode)
        ))
    }

    /// Output-page baseline of the topmost line, found by re-profiling the rendered bitmap.
    static func outputHeaderBaselines(_ output: BookPipelineCoordinator.PipelineOutput) -> [Int] {
        let detector = RunningHeaderDetector()
        return output.outputBitmapsAtOutputDPI.enumerated().map { i, bitmap in
            let profile = detector.profilePage(bitmap, region: bitmap.contentBoundingBox(), pageIndex: i, side: .recto)
            return profile.lines[0].baselineY
        }
    }

    @Test("Pipeline: header baselines line up within one pixel on the rendered pages; box-top mode keeps the jitter")
    func pipelineAlignsRenderedHeaders() async throws {
        let lifts = [0, 7, 3, 11, 5, 0, 9, 2]
        let dys = [0, 5, -5, 3, -3, 6, -6, 2]
        let pages = (0..<8).map { i in
            Self.page(dy: dys[i], lift: lifts[i], side: i % 2 == 0 ? .recto : .verso)
        }
        let accelerator = PortableComputeAccelerator()

        let legacy = try await Self.pipeline(mode: .boxTop).processGrayscalePages(pages, writer: NullWriter(), accelerator: accelerator)
        let aligned = try await Self.pipeline(mode: .automatic).processGrayscalePages(pages, writer: NullWriter(), accelerator: accelerator)

        let legacyBaselines = Self.outputHeaderBaselines(legacy)
        let alignedBaselines = Self.outputHeaderBaselines(aligned)
        let legacySpread = (legacyBaselines.max() ?? 0) - (legacyBaselines.min() ?? 0)
        let alignedSpread = (alignedBaselines.max() ?? 0) - (alignedBaselines.min() ?? 0)
        #expect(legacySpread >= 4, "box-top alignment inherits the lift jitter: \(legacyBaselines)")
        #expect(alignedSpread <= 1, "registered header baselines: \(alignedBaselines)")

        // The body lines follow the header, since the header-to-body distance is constant.
        let model = try #require(aligned.manifest.verticalRegistration)
        #expect(model.mode == .automatic)
        #expect(model.headerPageCount == 8, "\(aligned.manifest.pages.map { $0.registration?.flags ?? [] })")
        #expect(try #require(model.headerSpreadBeforePixels) >= 7)
        #expect(model.headerSpreadAfterPixels == 0)

        // Box-top mode records itself on every page.
        #expect(legacy.manifest.verticalRegistration?.mode == .boxTop)
        #expect(legacy.manifest.pages.allSatisfy { $0.registration?.method == .boxTop })

        // Manifest summary, JSON round trip and pre-6.1.2 manifests.
        let summary = ScanTailorCLI.formatManifestSummary(aligned.manifest)
        #expect(summary.contains("Vertical Registration: 8 header · 0 body · 0 preserved · 0 box-top"), "\(summary)")
        #expect(ScanTailorCLI.formatManifestSummary(legacy.manifest).contains("Vertical Registration: box-top (registration disabled)"))

        let data = try JSONEncoder().encode(aligned.manifest)
        #expect(try JSONDecoder().decode(BookProcessingManifest.self, from: data) == aligned.manifest)
        var old = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "verticalRegistration")
        if var records = old["pages"] as? [[String: Any]] {
            for i in records.indices {
                records[i].removeValue(forKey: "registration")
                if var plan = records[i]["layoutPlan"] as? [String: Any] {
                    plan.removeValue(forKey: "verticalAnchorEdge")
                    records[i]["layoutPlan"] = plan
                }
            }
            old["pages"] = records
        }
        let decoded = try JSONDecoder().decode(BookProcessingManifest.self, from: try JSONSerialization.data(withJSONObject: old))
        #expect(decoded.verticalRegistration == nil)
        #expect(decoded.pages.allSatisfy { $0.registration == nil })

        // A manual `boxTop` policy on one page re-run keeps that page unregistered.
        var manifest = aligned.manifest
        manifest.pages[3].manualOverride = PageManualOverride(verticalRegistration: .boxTop)
        let rerun = try await Self.pipeline(mode: .automatic).processGrayscalePages(
            pages, writer: NullWriter(), accelerator: accelerator, existingManifest: manifest
        )
        #expect(rerun.manifest.pages[3].registration?.method == .boxTop)
        #expect(rerun.manifest.pages[4].registration?.method == .header)
        #expect(rerun.outputBitmapsAtOutputDPI[3] == legacy.outputBitmapsAtOutputDPI[3])
    }
}

private struct NullWriter: PDFDocumentWriter, ~Copyable {
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap,
        dpi: Int,
        pageBoxPoints: Rect2D,
        ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {}

    consuming func finalize() throws(PDFWriteError) {}
}
