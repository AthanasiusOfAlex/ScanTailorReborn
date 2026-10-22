import Testing
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPortableBackend

@Suite("Text-Line Tracing & 3D Cubic-Sheet Dewarp Tests")
struct DewarpTests {

    @Test("TextLineTracer extracts curved text baselines from synthetic binary page")
    func testTextLineTracerCurvedBaselines() {
        let width = 800
        let height = 1000
        var bitmap = BinaryBitmap(width: width, height: height)

        let centerX = Double(width) * 0.5
        let halfWidth = Double(width) * 0.5
        let centerY = Double(height) * 0.5
        let halfHeight = Double(height) * 0.5

        // Ground-truth normalized cubic profile: Z(u) = 0.03 * u^3 - 0.06 * u^2 + 0.01 * u
        let trueAlpha1 = 0.03
        let trueAlpha2 = -0.06
        let trueAlpha3 = 0.01

        let lineBaseYs = stride(from: 180, through: 820, by: 80).map(Double.init)

        // Render synthetic word/character blocks along each curved baseline
        for baseY in lineBaseYs {
            let v0 = (baseY - centerY) / halfHeight
            var x = 100
            while x <= 700 {
                let charW = 14
                let charH = 18
                for dx in 0..<charW {
                    let px = x + dx
                    guard px < width else { continue }
                    let u = (Double(px) - centerX) / halfWidth
                    let z = ((trueAlpha1 * u + trueAlpha2) * u + trueAlpha3) * u
                    let vSrc = v0 + z
                    let yCurve = Int((centerY + vSrc * halfHeight).rounded())
                    for dy in (-charH / 2)...(charH / 2) {
                        let py = yCurve + dy
                        if py >= 0 && py < height {
                            bitmap.setPixel(x: px, y: py, isBlack: true)
                        }
                    }
                }
                x += 22 // character spacing
            }
        }

        let tracer = TextLineTracer()
        let tracedLines = tracer.traceLines(in: bitmap)

        #expect(tracedLines.count == lineBaseYs.count)

        // Check that each traced polyline closely tracks the synthetic curve
        for (lineIdx, poly) in tracedLines.enumerated() {
            #expect(poly.count >= 8)
            let v0 = (lineBaseYs[lineIdx] - centerY) / halfHeight
            for pt in poly.points {
                let u = (pt.x - centerX) / halfWidth
                let z = ((trueAlpha1 * u + trueAlpha2) * u + trueAlpha3) * u
                let expectedY = centerY + (v0 + z) * halfHeight
                #expect(abs(pt.y - expectedY) < 4.5)
            }
        }
    }

    @Test("CylindricalDewarpSolver recovers 3D cubic-sheet parameters and straightens curved lines")
    func testCylindricalDewarpSolverEndToEndRectification() {
        let width = 800
        let height = 1000
        let pageSize = Size2I(width: width, height: height)

        let centerX = Double(width) * 0.5
        let halfWidth = Double(width) * 0.5
        let centerY = Double(height) * 0.5
        let halfHeight = Double(height) * 0.5

        // Ground-truth 3D cubic-sheet surface with vertical perspective coupling:
        let trueAlpha1 = 0.035
        let trueAlpha2 = -0.075
        let trueAlpha3 = 0.015
        let trueBeta = 0.12

        var syntheticLines: [PolyLine2D] = []
        let vBaselines = stride(from: -0.7, through: 0.7, by: 0.2).map { $0 }

        for v0 in vBaselines {
            var pts: [Point2D] = []
            for step in 0...24 {
                let u = -0.8 + 1.6 * (Double(step) / 24.0)
                let z = ((trueAlpha1 * u + trueAlpha2) * u + trueAlpha3) * u
                let vSrc = v0 + (1.0 + trueBeta * v0) * z
                let x = centerX + u * halfWidth
                let y = centerY + vSrc * halfHeight
                pts.append(Point2D(x: x, y: y))
            }
            syntheticLines.append(PolyLine2D(points: pts))
        }

        let solver = CylindricalDewarpSolver()
        let solution = solver.solve(pageSize: pageSize, lines: syntheticLines)

        let model = try! #require(solution.model)
        #expect(model.fittedLineCount == syntheticLines.count)
        #expect(model.residualRMSPixels < 0.75)
        #expect(abs(model.alpha1 - trueAlpha1) < 0.008)
        #expect(abs(model.alpha2 - trueAlpha2) < 0.008)
        #expect(abs(model.alpha3 - trueAlpha3) < 0.008)
        #expect(abs(model.beta - trueBeta) < 0.05)

        // Render curved horizontal bands into a grayscale image using the forward surface model
        // (including inverse arc-length foreshortening from the solved grid), then warp with
        // PortableComputeAccelerator and verify that the rectified lines are flat (< 1.5 px deviation).
        var curvedGray = GrayscaleBuffer(width: width, height: height, initialValue: 255)
        let targetRectifiedYs: [Double] = [200.0, 350.0, 500.0, 650.0, 800.0]

        for yRect in targetRectifiedYs {
            for xRect in 80..<(width - 80) {
                let srcPt = solution.grid.sampleSource(outputX: Double(xRect), outputY: yRect)
                let sx = Int(srcPt.x.rounded())
                let sy = Int(srcPt.y.rounded())
                for dy in -3...3 {
                    let py = sy + dy
                    if sx >= 0 && sx < width && py >= 0 && py < height {
                        curvedGray[sx, py] = 0
                    }
                }
            }
        }

        let accelerator = PortableComputeAccelerator()
        let rectifiedGray = accelerator.meshWarp(
            curvedGray,
            displacementGrid: solution.grid,
            outputSize: pageSize
        )

        // Measure the vertical centroid of each dark band across columns in the rectified image
        for expectedY in targetRectifiedYs {
            let searchMinY = Int(expectedY) - 15
            let searchMaxY = Int(expectedY) + 15
            var maxDeviation = 0.0
            var measuredColumns = 0

            for x in stride(from: 100, through: width - 100, by: 20) {
                var weightedSumY = 0.0
                var weightTotal = 0.0
                for y in searchMinY...searchMaxY {
                    let darkness = Double(255 - Int(rectifiedGray[x, y]))
                    if darkness > 30 {
                        weightedSumY += Double(y) * darkness
                        weightTotal += darkness
                    }
                }
                if weightTotal > 0 {
                    let centroidY = weightedSumY / weightTotal
                    maxDeviation = max(maxDeviation, abs(centroidY - expectedY))
                    measuredColumns += 1
                }
            }

            #expect(measuredColumns > 20)
            #expect(maxDeviation < 1.5)
        }
    }

    @Test("CylindricalDewarpSolver falls back to identity grid when insufficient lines are traced")
    func testIdentityFallbackWithTooFewLines() {
        let pageSize = Size2I(width: 400, height: 600)
        let singleLine = PolyLine2D(points: [
            Point2D(x: 50, y: 200),
            Point2D(x: 150, y: 205),
            Point2D(x: 250, y: 205),
            Point2D(x: 350, y: 200)
        ])

        let solver = CylindricalDewarpSolver()
        let solution = solver.solve(pageSize: pageSize, lines: [singleLine])

        #expect(solution.model == nil)
        let midSample = solution.grid.sampleSource(outputX: 123.5, outputY: 456.25)
        #expect(abs(midSample.x - 123.5) < 1e-6)
        #expect(abs(midSample.y - 456.25) < 1e-6)
    }
}
