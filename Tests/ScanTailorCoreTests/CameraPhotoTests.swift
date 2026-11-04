import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline

/// Camera photos of open books (Substep 7.1.1b): gutter from the paper outline, crop to the paper, strict margins.
@Suite("Camera photos: gutter, paper crop and strict margins")
struct CameraPhotoTests {
    static let fold = 612

    /// A 1200×700 photo: a dark desk, a two-page spread from x = 200 to 1000 whose top edge dips and bottom edge
    /// rises at the fold (x = 612) when `notch` is set, two text columns per page, and text-free gaps at
    /// 400–420 and 800–820 (column gaps) and 580–644 (the gutter). `clutter` adds a white mug above the page and
    /// a keyboard beside it.
    static func spreadPhoto(notch: Bool, clutter: Bool = false) -> GrayscaleBuffer {
        let w = 1200, h = 700
        var px = ContiguousArray<UInt8>(repeating: 70, count: w * h)
        func dip(_ x: Int, _ depth: Double) -> Int { notch ? Int(depth * max(0, 1 - Double(abs(x - fold)) / 60)) : 0 }
        for x in 200..<1000 {
            for y in (60 + dip(x, 40))..<(640 - dip(x, 30)) { px[y * w + x] = 205 }
        }
        for (x0, x1) in [(240, 400), (420, 580), (644, 800), (820, 960)] {
            for line in stride(from: 130, to: 600, by: 12) {
                for y in line..<(line + 6) {
                    for x in x0..<x1 where (x - x0) % 9 < 7 { px[y * w + x] = 40 }
                }
            }
        }
        if clutter {
            for y in 0..<40 { for x in 300..<500 { px[y * w + x] = 235 } }
            for y in 300..<500 {
                for x in 1040..<1180 { px[y * w + x] = (x % 20 < 3 || y % 20 < 3) ? 30 : 210 }
            }
        }
        return GrayscaleBuffer(width: w, height: h, dpi: 600, pixels: px)
    }

    @Test("The gutter is the text-free gap under the notch in the paper outline, not a column gap")
    func gutterFromOutlineNotch() throws {
        let photo = Self.spreadPhoto(notch: true)
        let estimate = try #require(CameraGutterLocator.locate(in: photo))
        #expect(estimate.evidence == .gapAndNotch)
        #expect(abs(estimate.normalizedCenterX - (Double(Self.fold) + 0.5) / 1200) <= 0.003)

        let outline = try #require(CameraGutterLocator.Outline(photo: photo))
        let decision = try #require(PageSplitEstimator.estimateCameraSplit(outline: outline))
        #expect(decision.layoutType == .twoPageSpread)
        #expect(abs((decision.splitLine?.centerX ?? 0) - estimate.centerX) < 1e-9)
        #expect(PageSplitEstimator.estimateCameraSplit(outline: outline, mode: .singlePage) == nil)
    }

    @Test("Without a notch, three equal gaps are ambiguous and the caller falls back")
    func noNotchFallsBack() {
        #expect(CameraGutterLocator.locate(in: Self.spreadPhoto(notch: false)) == nil)
    }

    @Test("Desk, mug and keyboard are painted paper-toned; the page is untouched")
    func paperCropRemovesDesk() throws {
        let photo = Self.spreadPhoto(notch: true, clutter: true)
        let outline = try #require(CameraGutterLocator.Outline(photo: photo))
        let (masked, result) = try #require(CameraPaperMasker.mask(photo, outline: outline))
        func value(_ x: Int, _ y: Int) -> Int { Int(masked.pixels[y * masked.width + x]) }

        #expect(abs(result.paperLeft - 200.0 / 1200) <= 0.02)
        #expect(abs(result.paperRight - 1000.0 / 1200) <= 0.02)
        #expect(result.maskedFraction > 0.2)
        for (x, y) in [(400, 20), (1100, 400), (1110, 310), (100, 350), (300, 690)] {
            #expect(abs(value(x, y) - 205) <= 35, "desk pixel (\(x), \(y)) = \(value(x, y))")
        }
        #expect(value(245, 133) == 40)      // text
        #expect(value(230, 300) == 205)     // paper margin
        #expect(value(Self.fold, 120) == 205)   // paper inside the fold notch
        // Desk left beside the widened edges does not darken the fill.
        #expect(value(600, 690) >= 170)
    }

    @Test("Strict margins keep the body, header and folio, and drop a mug, thumb tabs and the paper's rim")
    func strictMarginsCrop() throws {
        var bitmap = BinaryBitmap(width: 1400, height: 1800, initialBlack: false)
        func text(_ r: Rect2I) {
            var x = r.minX
            while x < r.maxX {
                for py in r.minY..<r.maxY { for px in x..<min(r.maxX, x + 12) { bitmap.setPixel(x: px, y: py, isBlack: true) } }
                x += 18
            }
        }
        func solid(_ r: Rect2I) {
            for py in r.minY..<r.maxY { for px in r.minX..<r.maxX { bitmap.setPixel(x: px, y: py, isBlack: true) } }
        }
        for line in stride(from: 300, through: 1476, by: 42) { text(Rect2I(x: 300, y: line, width: 800, height: 24)) }
        text(Rect2I(x: 600, y: 250, width: 200, height: 22))        // running header, 28 px above the body
        text(Rect2I(x: 680, y: 1530, width: 40, height: 22))        // folio
        solid(Rect2I(x: 350, y: 20, width: 350, height: 140))       // mug rim on the desk, 90 px above the header
        solid(Rect2I(x: 1180, y: 500, width: 50, height: 100))      // thumb tabs
        solid(Rect2I(x: 1180, y: 900, width: 50, height: 100))
        solid(Rect2I(x: 280, y: 240, width: 4, height: 1300))       // rim of the paper, touching the text
        solid(Rect2I(x: 280, y: 285, width: 870, height: 4))

        var configuration = ContentBoxDetector.Configuration(cleanBordersFirst: false)
        let loose = try #require(ContentBoxDetector(configuration: configuration).detect(in: bitmap, dpi: 600).contentBox)
        configuration.strictMargins = true
        let box = try #require(ContentBoxDetector(configuration: configuration).detect(in: bitmap, dpi: 600).contentBox)

        #expect(abs(box.minX - 300) <= 2)
        #expect(abs(box.maxX - 1094) <= 8)
        #expect(abs(box.minY - 250) <= 2)
        #expect(abs(box.maxY - 1552) <= 2)
        #expect(loose.minX < 290 || loose.minY < 240 || loose.maxX > 1150)
    }

    @Test("Only unrectified photos with a desk around the paper count as camera photos")
    func cameraPhotoGate() {
        let quad = DocumentQuad(
            topLeft: Point2D(x: 0, y: 0), topRight: Point2D(x: 100, y: 0),
            bottomRight: Point2D(x: 100, y: 100), bottomLeft: Point2D(x: 0, y: 100)
        )
        func record(
            _ outcome: DocumentQuadDetection.Outcome, area: Double, mask: DeskMaskResult.Mode, flags: [String] = [], rectified: Bool = false
        ) -> SourcePageGeometryRecord {
            SourcePageGeometryRecord(
                sourcePageIndex: 0, rasterSize: Size2I(width: 100, height: 100),
                detection: DocumentQuadDetection(outcome: outcome, quad: quad, confidence: 0, areaFraction: area),
                rectified: rectified, plan: nil, deskMask: DeskMaskResult(mode: mask, maskedFraction: 0, flags: flags)
            )
        }
        #expect(record(.rejected, area: 0.7, mask: .skipped, flags: ["skipped:noPaper"]).looksLikeCameraPhoto)
        #expect(record(.rejected, area: 0.7, mask: .skipped, flags: ["capped:depth", "skipped:coverageCapExceeded"]).looksLikeCameraPhoto)
        #expect(!record(.rejected, area: 0.45, mask: .skipped, flags: ["skipped:noSharpBoundary"]).looksLikeCameraPhoto)  // lighting gradient
        #expect(record(.rejected, area: 0.95, mask: .full).looksLikeCameraPhoto)
        #expect(!record(.rejected, area: 0.95, mask: .residual).looksLikeCameraPhoto)   // flatbed (Vermeersch)
        #expect(!record(.fullFrame, area: 0.7, mask: .skipped).looksLikeCameraPhoto)    // flatbed (Flannery)
        #expect(!record(.rejected, area: 0.7, mask: .full, rectified: true).looksLikeCameraPhoto)
    }
}
