import Foundation
import ScanTailorContracts
import ScanTailorCore
import Testing

/// The publication layout rules (Substep 7.1.1a): the canvas hugs the text block plus 1/4 in top and bottom and
/// 1/2 in left and right; every page is centered left to right; header pages hang from the top; chapter openings
/// sit on the bottom; floating pages keep their offset from the scan's text block.
@Suite("Publication layout: hugging canvas, centering, and vertical anchoring")
struct PublicationLayoutTests {
    // At 600 DPI: 1/2 in = 300 px, 1/4 in = 150 px.
    static let side = 300
    static let topBottom = 150
    static let scan = Size2I(width: 1500, height: 2200)
    /// Where the text block sits on the scans: verso and recto are shifted differently, as from a binding offset.
    static let versoX = 200
    static let rectoX = 400
    static let blockTop = 300
    static let blockWidth = 960
    static let blockHeight = 1560

    static func detection(_ box: Rect2I) -> ContentBoxDetector.DetectionResult {
        ContentBoxDetector.DetectionResult(
            contentBox: box,
            mainBodyBox: box,
            retainedClusters: [.init(exactBounds: box, foregroundPixels: 100_000)],
            rejectedBoxes: [],
            confidence: 0.99
        )
    }

    static func page(_ index: Int, _ box: Rect2I, header: Bool = false) -> MarginHarmonizer.PageInput {
        MarginHarmonizer.PageInput(
            pageIndex: index,
            side: index.isMultiple(of: 2) ? .recto : .verso,
            pageSize: scan,
            dpi: 600,
            detection: detection(box),
            hasRunningHeader: header
        )
    }

    /// Six full body pages (one a little narrower and shorter), alternating recto (even) and verso (odd).
    static func bodyPages() -> [MarginHarmonizer.PageInput] {
        (0..<6).map { i in
            let x = i.isMultiple(of: 2) ? rectoX : versoX
            let narrower = (i == 2) ? 20 : 0
            return page(i, Rect2I(x: x + narrower / 2, y: blockTop, width: blockWidth - narrower, height: blockHeight - narrower), header: true)
        }
    }

    static func margins(_ plan: MarginHarmonizer.PageLayoutPlan) -> (l: Int, r: Int, t: Int, b: Int) {
        let box = plan.sourceContentBox!
        return (
            plan.destinationOrigin.x,
            plan.canvasSize.width - plan.destinationOrigin.x - box.width,
            plan.destinationOrigin.y,
            plan.canvasSize.height - plan.destinationOrigin.y - box.height
        )
    }

    @Test("The canvas is the largest text block plus the margins, not the scanned paper size")
    func canvasHugsTextBlock() {
        let model = MarginHarmonizer().harmonizeBook(pages: Self.bodyPages())
        #expect(model.canvasSize == Size2I(width: Self.blockWidth + 2 * Self.side, height: Self.blockHeight + 2 * Self.topBottom))
        #expect(model.versoCanonicalFrame == model.rectoCanonicalFrame)
        #expect(model.rectoCanonicalFrame == Rect2I(x: Self.side, y: Self.topBottom, width: Self.blockWidth, height: Self.blockHeight))
        let widest = Self.margins(model.pagePlans[0])
        #expect(widest == (Self.side, Self.side, Self.topBottom, Self.topBottom))
    }

    @Test("The frame takes the largest size of the main cluster, so boxes swollen by gutter or edge noise do not inflate it")
    func frameIgnoresNoisyBoxes() {
        // Measured Vermeersch 1934 widths: nine clean pages near 2150 px, the rest swollen by gutter shadows.
        let widths = [2143, 2145, 2147, 2153, 2154, 2156, 2156, 2157, 2157, 2205, 2243, 2258, 2268, 2417, 2439, 2541, 2547, 2556]
        #expect(MarginHarmonizer.largestInMainCluster(widths, windowFraction: 0.02) == 2157)
        #expect(MarginHarmonizer.largestInMainCluster([3319, 6499], windowFraction: 0.02) == 6499)
        #expect(MarginHarmonizer.largestInMainCluster([], windowFraction: 0.02) == nil)

        // A page whose box runs 300 px down into the scan's lower edge does not move the canvas.
        let noisy = Self.page(6, Rect2I(x: Self.rectoX, y: Self.blockTop, width: Self.blockWidth, height: Self.blockHeight + 300), header: true)
        let model = MarginHarmonizer().harmonizeBook(pages: Self.bodyPages() + [noisy])
        #expect(model.canvasSize.height == Self.blockHeight + 2 * Self.topBottom)
    }

    @Test("Every full page is centered left to right, whatever its side or offset on the scan")
    func pagesAreCentered() {
        let model = MarginHarmonizer().harmonizeBook(pages: Self.bodyPages())
        for plan in model.pagePlans {
            #expect(plan.tier == .fullBody)
            let m = Self.margins(plan)
            #expect(abs(m.l - m.r) <= 1, "page \(plan.pageIndex): left \(m.l), right \(m.r)")
            #expect(m.t == Self.topBottom)
        }
        // The narrower page is centered, not pinned to the left edge of the frame.
        #expect(Self.margins(model.pagePlans[2]).l == Self.side + 10)
    }

    @Test("A short page with a running header hangs from the top and is centered, even when narrow and off to one side")
    func headerPageHangsFromTop() {
        // Verso: header and a few short lines, narrow and at the left of the scan's text block.
        let box = Rect2I(x: Self.versoX, y: Self.blockTop, width: 500, height: 400)
        let withHeader = MarginHarmonizer().harmonizeBook(pages: Self.bodyPages() + [Self.page(7, box, header: true)])
        let plan = withHeader.pagePlans[6]
        #expect(plan.tier == .edgeAnchoredPartial)
        #expect(plan.verticalAnchorEdge == .top)
        #expect(plan.destinationOrigin == Point2I(x: Self.side + (Self.blockWidth - 500) / 2, y: Self.topBottom))

        // Without a header the same block is floating text off to the left, and keeps that offset.
        let withoutHeader = MarginHarmonizer().harmonizeBook(pages: Self.bodyPages() + [Self.page(7, box)])
        let floating = withoutHeader.pagePlans[6]
        #expect(floating.tier == .standaloneFloating)
        #expect(floating.destinationOrigin == Point2I(x: Self.side, y: Self.topBottom))
    }

    @Test("A chapter opening without a header sits on the frame bottom; a chapter ending hangs from the top")
    func chapterOpeningSitsOnBottom() {
        let blockBottom = Self.blockTop + Self.blockHeight
        let opening = Rect2I(x: Self.rectoX, y: blockBottom - 960, width: Self.blockWidth, height: 960)
        let ending = Rect2I(x: Self.versoX, y: Self.blockTop, width: Self.blockWidth, height: 700)
        let model = MarginHarmonizer().harmonizeBook(pages: Self.bodyPages() + [Self.page(6, opening), Self.page(7, ending)])

        let openingPlan = model.pagePlans[6]
        #expect(openingPlan.tier == .edgeAnchoredPartial)
        #expect(openingPlan.verticalAnchorEdge == .bottom)
        #expect(Self.margins(openingPlan) == (Self.side, Self.side, Self.topBottom + Self.blockHeight - 960, Self.topBottom))

        let endingPlan = model.pagePlans[7]
        #expect(endingPlan.verticalAnchorEdge == .top)
        #expect(endingPlan.destinationOrigin == Point2I(x: Self.side, y: Self.topBottom))
    }

    @Test("A floating page keeps its offset from the text block: centered text stays centered, side text stays to the side")
    func floatingPagesKeepTheirOffset() {
        // Recto title, centered on the scan's text block, 400 px below its top.
        let title = Rect2I(x: Self.rectoX + (Self.blockWidth - 400) / 2, y: Self.blockTop + 400, width: 400, height: 200)
        // Verso dedication flush with the right edge of the text block, 600 px below its top.
        let dedication = Rect2I(x: Self.versoX + Self.blockWidth - 300, y: Self.blockTop + 600, width: 300, height: 100)
        let model = MarginHarmonizer().harmonizeBook(pages: Self.bodyPages() + [Self.page(6, title), Self.page(7, dedication)])

        let titlePlan = model.pagePlans[6]
        #expect(titlePlan.tier == .standaloneFloating)
        #expect(titlePlan.destinationOrigin == Point2I(x: Self.side + (Self.blockWidth - 400) / 2, y: Self.topBottom + 400))

        let dedicationPlan = model.pagePlans[7]
        #expect(dedicationPlan.tier == .standaloneFloating)
        #expect(dedicationPlan.destinationOrigin == Point2I(x: Self.side + Self.blockWidth - 300, y: Self.topBottom + 600))
        #expect(Self.margins(dedicationPlan).r == Self.side)
    }

    @Test("PageInput decodes inputs written before the running-header flag")
    func pageInputDecodesWithoutHeaderFlag() throws {
        let input = Self.page(0, Rect2I(x: 0, y: 0, width: 10, height: 10), header: true)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        #expect(json["hasRunningHeader"] as? Bool == true)
        json.removeValue(forKey: "hasRunningHeader")
        let decoded = try JSONDecoder().decode(MarginHarmonizer.PageInput.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.hasRunningHeader == false)
        #expect(decoded.detection == input.detection)
    }
}
