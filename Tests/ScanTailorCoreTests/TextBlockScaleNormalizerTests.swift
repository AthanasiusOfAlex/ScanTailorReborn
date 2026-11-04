import Testing
import ScanTailorContracts
@testable import ScanTailorCore

/// Per-page text-block scaling of camera photos (Substep 7.1.1b-i).
@Suite("Text-block scale normalization of camera pages")
struct TextBlockScaleNormalizerTests {
    typealias Input = TextBlockScaleNormalizer.PageInput

    static func box(_ width: Int, _ height: Int) -> Rect2I { Rect2I(x: 100, y: 200, width: width, height: height) }

    @Test("Full pages are brought to the median block, each axis on its own")
    func fullPages() throws {
        let scales = TextBlockScaleNormalizer.scales(for: [
            Input(group: 0, contentBox: Self.box(900, 1500), isEligible: true),    // perspective: narrow
            Input(group: 0, contentBox: Self.box(1000, 1450), isEligible: true),
            Input(group: 1, contentBox: Self.box(1000, 1500), isEligible: true),   // already typical
            Input(group: 1, contentBox: Self.box(1050, 1600), isEligible: true),
        ])
        // Medians: width 1000, height 1500.
        let narrow = try #require(scales[0])
        #expect(abs(narrow.width - 1000.0 / 900) < 1e-9)
        #expect(scales[0]?.height == 1)
        #expect(abs((scales[1]?.height ?? 0) - 1500.0 / 1450) < 1e-9)
        #expect(scales[2] == nil)
        #expect(abs((scales[3]?.width ?? 0) - 1000.0 / 1050) < 1e-9)
    }

    @Test("A short full-width page keeps the book's aspect; an empty one borrows from its photo; others stay")
    func partialAndBorrowedPages() throws {
        let scales = TextBlockScaleNormalizer.scales(for: [
            Input(group: 0, contentBox: Self.box(1000, 1500), isEligible: true),
            Input(group: 0, contentBox: Self.box(1000, 1500), isEligible: true),
            Input(group: 1, contentBox: Self.box(800, 1500), isEligible: true),    // clamped to 1.25
            Input(group: 2, contentBox: Self.box(900, 600), isEligible: true),     // chapter ending
            Input(group: 2, contentBox: Self.box(300, 200), isEligible: true),     // ornament: borrows
            Input(group: 3, contentBox: Self.box(900, 1500), isEligible: false),   // flatbed or manual box
            Input(group: 4, contentBox: nil, isEligible: true),                    // blank, alone in its photo
        ])
        #expect(scales[2]?.width == 1.25)
        let ending = try #require(scales[3])
        #expect(abs(ending.width - 1000.0 / 900) < 1e-9)
        #expect(abs(ending.height - ending.width) < 1e-9)   // full pages scale equally on both axes here
        #expect(scales[4] == scales[3])
        #expect(scales[5] == nil)
        #expect(scales[6] == nil)
    }

    @Test("With fewer than two full pages nothing is scaled")
    func tooFewPages() {
        let scales = TextBlockScaleNormalizer.scales(for: [
            Input(group: 0, contentBox: Self.box(1000, 1500), isEligible: true),
            Input(group: 0, contentBox: Self.box(400, 300), isEligible: true),
            Input(group: 1, contentBox: Self.box(1000, 1500), isEligible: false),
        ])
        #expect(scales.allSatisfy { $0 == nil })
    }

    @Test("Resampling scales strokes and boxes together and keeps their weight")
    func resampleBitmap() {
        var bitmap = BinaryBitmap(width: 300, height: 200, initialBlack: false)
        for y in 50..<60 { for x in 40..<240 { bitmap.setPixel(x: x, y: y, isBlack: true) } }     // a rule
        for y in 80..<180 { for x in 100..<108 { bitmap.setPixel(x: x, y: y, isBlack: true) } }   // a stem
        let scale = Size2D(width: 1.1, height: 0.9)
        let out = TextBlockScaleNormalizer.resample(bitmap, by: scale)
        #expect(out.width == 330 && out.height == 180)

        let rule = TextBlockScaleNormalizer.scaled(Rect2I(x: 40, y: 50, width: 200, height: 10), by: scale, within: Size2I(width: 330, height: 180))
        #expect(rule == Rect2I(minX: 44, minY: 45, maxX: 264, maxY: 54))
        #expect(out[150, 49] && out[46, 50] && out[262, 52])
        #expect(!out[150, 43] && !out[150, 56] && !out[41, 50] && !out[267, 50])
        let expectedInk = Double(bitmap.countBlackPixels()) * 1.1 * 0.9
        #expect(abs(Double(out.countBlackPixels()) - expectedInk) / expectedInk < 0.05)
    }

    @Test("Detections scale with the page and stay inside it")
    func scaledDetection() {
        let detection = ContentBoxDetector.DetectionResult(
            contentBox: Rect2I(x: 10, y: 20, width: 280, height: 170),
            mainBodyBox: Rect2I(x: 10, y: 20, width: 280, height: 170),
            retainedClusters: [ContentBoxDetector.Cluster(exactBounds: Rect2I(x: 10, y: 20, width: 280, height: 170), foregroundPixels: 1000)],
            rejectedBoxes: [Rect2I(x: 290, y: 0, width: 10, height: 200)],
            confidence: 0.8
        )
        let bounds = Size2I(width: 360, height: 180)
        let scaled = TextBlockScaleNormalizer.scaled(detection, by: Size2D(width: 1.2, height: 0.9), within: bounds)
        #expect(scaled.contentBox == Rect2I(minX: 12, minY: 18, maxX: 348, maxY: 171))
        #expect(scaled.retainedClusters.first?.foregroundPixels == 1080)
        #expect(scaled.rejectedBoxes.first == Rect2I(minX: 348, minY: 0, maxX: 360, maxY: 180))
        #expect(scaled.confidence == 0.8)
    }
}
