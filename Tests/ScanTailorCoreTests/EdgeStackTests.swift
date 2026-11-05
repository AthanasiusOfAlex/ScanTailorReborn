import Testing
import ScanTailorContracts
import ScanTailorCore

/// Page-edge stacks (the edges of the following leaves, seen past a camera-photographed page) and the second look
/// at pages whose only fault is an oversized text block (Long 2015, Substep 7.1.2).
@Suite("Page-edge stacks and content-overflow trimming")
struct EdgeStackTests {
    private let width = 2400
    private let height = 3600

    @Test("A page-edge stack in the outer margin is not content, even joined to a rule at the foot of the page")
    func edgeStackBesideTextIsErased() throws {
        var text = BinaryBitmap(width: width, height: height, initialBlack: false)
        drawText(&text)
        let clean = try #require(ContentBoxDetector().detect(in: text, dpi: 600, splitSide: .leftVerso).contentBox)

        var page = text
        drawEdgeStack(&page)
        let result = ContentBoxDetector().detect(in: page, dpi: 600, splitSide: .leftVerso)
        #expect(result.contentBox == clean)
    }

    @Test("A verso that shows only the page-edge stack is blank")
    func edgeStackAloneIsBlank() {
        var page = BinaryBitmap(width: width, height: height, initialBlack: false)
        drawEdgeStack(&page)
        #expect(ContentBoxDetector().detect(in: page, dpi: 600, splitSide: .leftVerso).contentBox == nil)
    }

    @Test("A single rule beside the text and a ruled table in the outer third are kept")
    func rulesAndTablesAreNotStacks() throws {
        var ruled = BinaryBitmap(width: width, height: height, initialBlack: false)
        drawText(&ruled)
        fill(&ruled, Rect2I(x: 700, y: 280, width: 3, height: 2740))
        let ruledBox = try #require(ContentBoxDetector().detect(in: ruled, dpi: 600, splitSide: .leftVerso).contentBox)
        #expect(ruledBox.minX <= 700)

        // Three full-height rules with text between them: more text than rule in the band.
        var table = BinaryBitmap(width: width, height: height, initialBlack: false)
        drawText(&table)
        for x in [300, 500, 700] { fill(&table, Rect2I(x: x, y: 280, width: 3, height: 2740)) }
        for y in stride(from: 300, through: 2980, by: 42) {
            for cellX in [320, 520] { drawLine(&table, Rect2I(x: cellX, y: y, width: 160, height: 24)) }
        }
        let tableBox = try #require(ContentBoxDetector().detect(in: table, dpi: 600, splitSide: .leftVerso).contentBox)
        #expect(tableBox.minX <= 300)
    }

    @Test("A page too wide only because of a smudge beside the text is trimmed and judged again as canonical")
    func contentOverflowPageIsTrimmedAndRejudged() throws {
        let size = Size2I(width: width, height: height)
        func detection(smudge: Bool) -> ContentBoxDetector.DetectionResult {
            var clusters = [ContentBoxDetector.Cluster(exactBounds: Rect2I(x: 400, y: 300, width: 1500, height: 2700), foregroundPixels: 900_000)]
            if smudge { clusters.append(ContentBoxDetector.Cluster(exactBounds: Rect2I(x: 2150, y: 1200, width: 40, height: 60), foregroundPixels: 1_500)) }
            let box = clusters.dropFirst().reduce(clusters[0].exactBounds) { $0.union($1.exactBounds) }
            return ContentBoxDetector.DetectionResult(contentBox: box, mainBodyBox: box, retainedClusters: clusters, rejectedBoxes: [], confidence: 1)
        }
        let detections = (0..<10).map { detection(smudge: $0 == 5) }
        var inputs = detections.indices.map { DimensionConsensus.PageInput(pageIndex: $0, pageSize: size, contentBox: detections[$0].contentBox) }
        let consensus = DimensionConsensus()
        #expect(consensus.classify(pages: inputs).records[5].kinds == [.contentOverflow])

        let harmonizer = MarginHarmonizer()
        let canonical = detections.indices.filter { $0 != 5 }.map {
            MarginHarmonizer.PageInput(pageIndex: $0, side: .recto, pageSize: size, detection: detections[$0])
        }
        let prior = harmonizer.canonicalWidthPrior(canonical)
        #expect(prior == 1500)
        let trimmed = ContentBoxDetector().refineWithCanonicalWidthPrior(
            detections[5], canonicalWidth: prior, maxWidthExcessFraction: harmonizer.configuration.pass2OutlierWidthExcessFraction)
        inputs[5].contentBox = trimmed.contentBox
        #expect(consensus.classify(pages: inputs).records[5].dimensionClass == .canonical)
    }

    // MARK: - Drawing

    /// Body text of a verso: 64 lines of 12-pixel glyphs, 1.2 in from the outer edge.
    private func drawText(_ bitmap: inout BinaryBitmap) {
        for y in stride(from: 300, through: 2980, by: 42) { drawLine(&bitmap, Rect2I(x: 720, y: y, width: 1500, height: 24)) }
    }

    /// Fourteen leaf edges near the left edge, converging slightly downward and meeting a rule at the foot.
    private func drawEdgeStack(_ bitmap: inout BinaryBitmap) {
        for k in 0..<14 {
            let top = 90 + 14 * k
            for y in 60..<3480 {
                let x = top + (y * 2) / 3480
                fill(&bitmap, Rect2I(x: x, y: y, width: 3, height: 1))
            }
        }
        fill(&bitmap, Rect2I(x: 90, y: 3480, width: 1400, height: 3))
    }

    private func drawLine(_ bitmap: inout BinaryBitmap, _ rect: Rect2I) {
        for x in stride(from: rect.minX, to: rect.maxX, by: 18) {
            fill(&bitmap, Rect2I(x: x, y: rect.minY, width: min(12, rect.maxX - x), height: rect.height))
        }
    }

    private func fill(_ bitmap: inout BinaryBitmap, _ rect: Rect2I) {
        for y in max(0, rect.minY)..<min(bitmap.height, rect.maxY) {
            for x in max(0, rect.minX)..<min(bitmap.width, rect.maxX) { bitmap.setPixel(x: x, y: y, isBlack: true) }
        }
    }
}
