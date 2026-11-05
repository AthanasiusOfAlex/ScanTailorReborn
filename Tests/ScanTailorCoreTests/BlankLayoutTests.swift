import Testing
import ScanTailorContracts
import ScanTailorCore

/// Blank pages kept inside a book are laid out blank when the detector found only specks on them
/// (Substep 7.1.2, fix 3).
@Suite("Blank-page layout")
struct BlankLayoutTests {
    private func detection(heights: [Int]) -> ContentBoxDetector.DetectionResult {
        let clusters = heights.enumerated().map { i, h in
            ContentBoxDetector.Cluster(exactBounds: Rect2I(x: 300 + 200 * i, y: 500, width: 120, height: h), foregroundPixels: 40 * h)
        }
        let box = clusters.dropFirst().reduce(clusters.first?.exactBounds) { $0?.union($1.exactBounds) }
        return ContentBoxDetector.DetectionResult(
            contentBox: box, mainBodyBox: box, retainedClusters: clusters, rejectedBoxes: [], confidence: 0.5)
    }

    @Test("Fibres and dust are specks; a page number or a line of type is not")
    func speckGuard() {
        #expect(detection(heights: [16, 43, 9]).holdsOnlySpecks(dpi: 600))
        #expect(detection(heights: []).holdsOnlySpecks(dpi: 600))
        // A 9-point folio: digits about 0.1 in tall at 600 dpi.
        #expect(!detection(heights: [12, 62]).holdsOnlySpecks(dpi: 600))
        #expect(!detection(heights: [30]).holdsOnlySpecks(dpi: 300, maxHeightInches: 0.09))
    }

    @Test("A blanked detection retains nothing and keeps the specks for the overlays")
    func blankedDetection() {
        let blank = detection(heights: [16, 43]).blanked
        #expect(blank.contentBox == nil && blank.mainBodyBox == nil && blank.retainedClusters.isEmpty)
        #expect(blank.rejectedBoxes.count == 2)
        #expect(blank.confidence == 1)
    }

    @Test("A blank page from a landscape scan takes the book's canvas; one with content keeps its own")
    func blankPageIsNeverASizeOutlier() {
        let portrait = Size2I(width: 4000, height: 5600)
        let landscape = Size2I(width: 6900, height: 5100)
        let text = Rect2I(x: 400, y: 500, width: 3000, height: 4500)
        func pages(landscapeBox: Rect2I?) -> [DimensionConsensus.PageInput] {
            (0..<12).map { i in
                i == 6
                    ? DimensionConsensus.PageInput(pageIndex: i, pageSize: landscape, contentBox: landscapeBox)
                    : DimensionConsensus.PageInput(pageIndex: i, pageSize: portrait, contentBox: text)
            }
        }
        #expect(DimensionConsensus().classify(pages: pages(landscapeBox: nil)).records[6].dimensionClass == .canonical)
        #expect(DimensionConsensus().classify(pages: pages(landscapeBox: text)).records[6].dimensionClass == .outlier)
    }
}
