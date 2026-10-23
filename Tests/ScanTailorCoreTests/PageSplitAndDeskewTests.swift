import Foundation
import Testing
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPortableBackend

@Suite("Page Splitting and Multi-Scale Deskew Tests")
struct PageSplitAndDeskewTests {

    // MARK: - Synthetic Document Helpers

    /// Renders a synthetic text-like document with multiple horizontal rows of word-like glyph blocks,
    /// rotated by `angleDegrees` clockwise around the image center.
    private static func makeSyntheticTextPage(
        width: Int = 900,
        height: Int = 1200,
        dpi: Int = 300,
        angleDegrees: Double = 0.0,
        includeVerticalGutterLineAtX: Int? = nil
    ) -> GrayscaleBuffer {
        var buffer = GrayscaleBuffer(width: width, height: height, dpi: dpi, initialValue: 250)
        let cx = Double(width) * 0.5
        let cy = Double(height) * 0.5
        let rad = angleDegrees * .pi / 180.0
        let cosA = cos(rad)
        let sinA = sin(rad)

        // Draw 22 lines of discrete word-like character blocks using inverse rotation mapping
        // so rotated strokes have zero forward-splatting holes.
        let marginX = 110
        let startY = 140
        let lineSpacing = 42
        let lineHeight = 12
        let maxLineY = startY + 22 * lineSpacing

        for y in 0..<height {
            let dy = Double(y) - cy
            for x in 0..<width {
                let dx = Double(x) - cx
                // Inverse rotation by -angleDegrees around (cx, cy):
                let ux = Int((cx + dx * cosA + dy * sinA).rounded())
                let uy = Int((cy - dx * sinA + dy * cosA).rounded())

                guard ux >= marginX && ux < width - marginX && uy >= startY && uy < maxLineY else {
                    continue
                }
                let relY = uy - startY
                let lineIdx = relY / lineSpacing
                let inLineY = relY % lineSpacing
                guard lineIdx < 22 && inLineY < lineHeight else { continue }

                let lineOffset = (lineIdx * 17) % 23
                let relX = ux - (marginX + lineOffset)
                guard relX >= 0 else { continue }
                let wordPeriod = 46 + (lineIdx % 3) * 6
                let inWordX = relX % wordPeriod
                let wordWidth = wordPeriod - 14
                if inWordX < wordWidth && (inWordX % 9 != 7) {
                    buffer[x, y] = 20
                }
            }
        }

        if let gutterX = includeVerticalGutterLineAtX {
            for y in 20..<(height - 20) {
                for x in max(0, gutterX - 2)...min(width - 1, gutterX + 2) {
                    buffer[x, y] = 15
                }
            }
        }

        return buffer
    }

    /// Renders a synthetic dual-page spread with left and right text columns separated by a gutter at `gutterX`
    /// tilted by `tiltDegrees` clockwise from the vertical axis, optionally with a dark spine shadow.
    private static func makeSyntheticSpread(
        width: Int = 1600,
        height: Int = 1100,
        dpi: Int = 300,
        gutterCenterX: Double = 800.0,
        tiltDegrees: Double = 0.0,
        darkSpineShadow: Bool = false
    ) -> GrayscaleBuffer {
        var buffer = GrayscaleBuffer(width: width, height: height, dpi: dpi, initialValue: 248)
        let halfH = Double(height) * 0.5
        let tanTilt = tan(tiltDegrees * .pi / 180.0)

        // Draw left page text blocks and right page text blocks aligned with the tilted frame
        for lineIdx in 0..<20 {
            let yStart = 110 + lineIdx * 44
            for dy in 0..<11 {
                let y = yStart + dy
                guard y < height else { continue }
                let splitX = Int((gutterCenterX - (Double(y) - halfH) * tanTilt).rounded())

                // Left page text lines: [100 .. splitX - 55]
                let leftStart = 100
                let leftEnd = max(leftStart, splitX - 55)
                var x = leftStart
                while x < leftEnd {
                    if (x - leftStart) % 34 < 25 {
                        buffer[x, y] = 25
                    }
                    x += 1
                }

                // Right page text lines: [splitX + 55 .. width - 100]
                let rightStart = min(width - 1, splitX + 55)
                let rightEnd = width - 100
                x = rightStart
                while x < rightEnd {
                    if (x - rightStart) % 34 < 25 {
                        buffer[x, y] = 25
                    }
                    x += 1
                }
            }
        }

        // Optional dark spine crease along the gutter line
        if darkSpineShadow {
            for y in 0..<height {
                let gx = gutterCenterX - (Double(y) - halfH) * tanTilt
                let centerInt = Int(gx.rounded())
                for offset in -8...8 {
                    let x = centerInt + offset
                    guard x >= 0 && x < width else { continue }
                    let dist = Double(abs(offset)) / 8.0
                    let shade = UInt8(clamping: Int(30.0 + dist * 160.0))
                    buffer[x, y] = min(buffer[x, y], shade)
                }
            }
        }

        return buffer
    }

    // MARK: - SkewEstimator Tests

    @Test("SkewEstimator recovers positive, negative, and zero skew angles within ±0.05 degrees")
    func skewEstimatorAngleAccuracy() {
        let testAngles: [Double] = [0.0, 2.75, -4.25]
        for targetAngle in testAngles {
            let page = Self.makeSyntheticTextPage(
                width: 900,
                height: 1200,
                dpi: 300,
                angleDegrees: targetAngle,
                includeVerticalGutterLineAtX: 40 // Verify immunity to tall vertical border/gutter lines
            )
            let estimate = SkewEstimator.estimateSkew(in: page)
            let error = abs(estimate.angleDegrees - targetAngle)
            #expect(
                error <= 0.05,
                "Expected angle \(targetAngle)° ± 0.05°, got \(estimate.angleDegrees)° (error: \(error)°)"
            )
            #expect(estimate.confidence > 0.3)
            #expect(estimate.retainedComponentCount > 50)
        }
    }

    @Test("SkewEstimator.deskew rectifies rotated page to near 0 degrees using PortableComputeAccelerator")
    func deskewRectifiesPage() {
        let initialAngle = 3.20
        let skewedPage = Self.makeSyntheticTextPage(
            width: 800,
            height: 1000,
            dpi: 300,
            angleDegrees: initialAngle
        )
        let initialEstimate = SkewEstimator.estimateSkew(in: skewedPage)
        #expect(abs(initialEstimate.angleDegrees - initialAngle) <= 0.05)

        let accelerator = PortableComputeAccelerator()
        let deskewedPage = SkewEstimator.deskew(
            skewedPage,
            by: initialEstimate.angleDegrees,
            accelerator: accelerator
        )
        let residualEstimate = SkewEstimator.estimateSkew(in: deskewedPage)
        #expect(abs(residualEstimate.angleDegrees) <= 0.05)
    }

    // MARK: - PageSplitEstimator Tests

    @Test("PageSplitEstimator distinguishes single portrait page from two-page spread")
    func singlePageVsTwoPageClassification() {
        let portraitPage = Self.makeSyntheticTextPage(width: 800, height: 1150, dpi: 300, angleDegrees: 0.0)
        let portraitDecision = PageSplitEstimator.estimateSplit(in: portraitPage, mode: .automatic)
        #expect(portraitDecision.layoutType == .singlePage)
        #expect(portraitDecision.splitLine == nil)

        let slices = PageSplitEstimator.split(portraitPage, using: portraitDecision)
        #expect(slices.count == 1)
        #expect(slices[0].side == .single)
        #expect(slices[0].buffer.width == portraitPage.width)
    }

    @Test("PageSplitEstimator locates clean and dark-spine gutters within ±2 mm at 300 DPI")
    func gutterLocalizationAccuracy() throws {
        // At 300 DPI, 2 mm = 2.0 / 25.4 * 300 ≈ 23.6 pixels
        let twoMillimetersInPixels = 2.0 * 300.0 / 25.4

        for (targetCenterX, darkShadow) in [(800.0, false), (745.0, true)] {
            let spread = Self.makeSyntheticSpread(
                width: 1600,
                height: 1100,
                dpi: 300,
                gutterCenterX: targetCenterX,
                tiltDegrees: 0.0,
                darkSpineShadow: darkShadow
            )
            let decision = PageSplitEstimator.estimateSplit(in: spread, mode: .automatic)
            #expect(decision.layoutType == .twoPageSpread)
            let splitLine = try #require(decision.splitLine)
            #expect(splitLine.isDarkCrease == darkShadow)
            if darkShadow {
                #expect(decision.confidence >= 0.80)
            }
            let errorPx = abs(splitLine.centerX - targetCenterX)
            #expect(
                errorPx <= twoMillimetersInPixels,
                "Expected gutter center within \(twoMillimetersInPixels) px (±2 mm) of \(targetCenterX), got \(splitLine.centerX) (error: \(errorPx) px)"
            )
        }
    }

    @Test("PageSplitEstimator tracks wide halftoned dark spine crease midline without rolling onto margin flanks")
    func wideStippledDarkCreaseCenterlineTracking() throws {
        let width = 1600
        let height = 1100
        let targetCenterX = 816.0
        let targetTilt = -0.75
        let halfH = Double(height) * 0.5
        let tanPhi = tan(targetTilt * .pi / 180.0)

        var buffer = GrayscaleBuffer(width: width, height: height, dpi: 300, initialValue: 244)

        // Asymmetric text margins around the crease (wider right white margin than left white margin)
        // so that a White Valley optimizer would roll off to the right flank (+25..+40 px),
        // whereas Dark Crease Mode must lock onto the crease centroid within ±6 px.
        var y = 110
        while y < height - 110 {
            let lineThickness = 6
            let gx = Int((targetCenterX - (Double(y) - halfH) * tanPhi).rounded())
            for dy in 0..<lineThickness where (y + dy) < height {
                let leftStart = 120
                let leftEnd = max(leftStart + 20, gx - 55)
                for x in leftStart..<leftEnd where (x % 9) != 0 {
                    buffer[x, y + dy] = 28
                }
                let rightStart = min(width - 140, gx + 95)
                let rightEnd = width - 120
                for x in rightStart..<rightEnd where (x % 9) != 0 {
                    buffer[x, y + dy] = 28
                }
            }
            y += 22
        }

        // Draw a 36 px wide stippled/halftoned dark spine shadow centered on gx(y).
        let creaseHalfWidth = 18
        for row in 0..<height {
            let gx = targetCenterX - (Double(row) - halfH) * tanPhi
            let minX = max(0, Int(gx.rounded()) - creaseHalfWidth)
            let maxX = min(width - 1, Int(gx.rounded()) + creaseHalfWidth)
            for x in minX...maxX {
                let dist = abs(Double(x) - gx) / Double(creaseHalfWidth)
                // Dense dark core with 1-bit stipple pattern toward edges
                let isStippleDark = ((x + row) % 2 == 0) || dist < 0.45
                if isStippleDark {
                    let shade = UInt8(clamping: Int(30.0 + 150.0 * dist * dist))
                    buffer[x, row] = min(buffer[x, row], shade)
                }
            }
        }

        let decision = PageSplitEstimator.estimateSplit(in: buffer, mode: .automatic)
        #expect(decision.layoutType == .twoPageSpread)
        #expect(decision.confidence >= 0.80)
        let splitLine = try #require(decision.splitLine)
        #expect(splitLine.isDarkCrease == true)
        #expect(abs(splitLine.centerX - targetCenterX) <= 6.0)
        #expect(abs(splitLine.tiltDegrees - targetTilt) <= 0.6)
    }

    @Test("PageSplitEstimator handles tilted spread and masks cross-gutter bleed during split")
    func tiltedSpreadSplitAndMasking() throws {
        let targetCenterX = 810.0
        let targetTilt = 2.5
        let spread = Self.makeSyntheticSpread(
            width: 1600,
            height: 1100,
            dpi: 300,
            gutterCenterX: targetCenterX,
            tiltDegrees: targetTilt,
            darkSpineShadow: true
        )
        let decision = PageSplitEstimator.estimateSplit(in: spread, mode: .twoPageSpread)
        #expect(decision.layoutType == .twoPageSpread)
        let splitLine = try #require(decision.splitLine)

        let twoMillimetersInPixels = 2.0 * 300.0 / 25.4
        #expect(abs(splitLine.centerX - targetCenterX) <= twoMillimetersInPixels)

        let slices = PageSplitEstimator.split(spread, using: decision, backgroundFill: 255)
        #expect(slices.count == 2)
        #expect(slices[0].side == .leftVerso)
        #expect(slices[1].side == .rightRecto)

        // Verify slanted masking: on the left slice at y = height - 1, where splitX < topX,
        // pixels to the right of splitX(y) within leftSlice's bounding box must be masked to 255.
        let leftSlice = slices[0]
        let bottomY = spread.height - 1
        let splitAtBottom = Int(splitLine.x(atY: Double(bottomY), height: spread.height).rounded())
        if splitAtBottom + 2 < leftSlice.buffer.width {
            #expect(leftSlice.buffer[leftSlice.buffer.width - 1, bottomY] == 255)
        }
    }
}
