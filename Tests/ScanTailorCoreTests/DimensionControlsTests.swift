import Foundation
import Testing
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

@Suite("CLI & Manifest Physical Dimension Controls Tests")
struct DimensionControlsTests {

    @Test("PhysicalSizeSpec parses named book/ISO/ANSI presets, explicit <w>x<h> units, and JSON object/string Codable forms")
    func testPhysicalSizeSpecPresetsUnitsAndCodable() throws {
        // 1. Standard bibliographic & ISO/ANSI presets + case/separator aliases
        let octavo = try #require(PhysicalSizeSpec.parse("octavo"))
        #expect(octavo.preset == .octavo)
        #expect(octavo.sizeInInches == Size2D(width: 6.0, height: 9.0))
        #expect(octavo.sizeInPixels(atDPI: 600) == Size2I(width: 3600, height: 5400))
        #expect(PhysicalSizeSpec.parse("Standard Octavo") == octavo)
        #expect(PhysicalSizeSpec.parse("8vo") == octavo)

        let trade = try #require(PhysicalSizeSpec.parse("trade_paperback"))
        #expect(trade.preset == .tradePaperback)
        #expect(trade.sizeInInches == Size2D(width: 5.5, height: 8.5))
        #expect(PhysicalSizeSpec.parse("digest") == trade)

        let a5 = try #require(PhysicalSizeSpec.parse("A5"))
        #expect(a5.preset == .a5)
        #expect(a5.unit == .millimeters && a5.width == 148.0 && a5.height == 210.0)
        #expect(abs(a5.sizeInInches.width - (148.0 / 25.4)) < 1e-9)
        #expect(abs(a5.sizeInInches.height - (210.0 / 25.4)) < 1e-9)

        let royal = try #require(PhysicalSizeSpec.parse("royal-octavo"))
        #expect(royal.preset == .royalOctavo)
        #expect(royal.sizeInMillimeters.width == 156.0 && royal.sizeInMillimeters.height == 234.0)

        // Presets containing 'x' ("executive", "sexto") must match presets cleanly before splitting on 'x'
        let exec = try #require(PhysicalSizeSpec.parse("executive"))
        #expect(exec.preset == .executive)
        #expect(exec.sizeInInches == Size2D(width: 7.25, height: 10.5))

        let sexto = try #require(PhysicalSizeSpec.parse("sexto"))
        #expect(sexto.preset == .massMarket)
        #expect(sexto.sizeInInches == Size2D(width: 4.25, height: 6.875))

        // 2. Explicit <w>x<h> across in, mm, cm, pt, px, Unicode '×', quotes, and bare numbers
        let sixByNine = try #require(PhysicalSizeSpec.parse("6x9in"))
        #expect(sixByNine.preset == nil)
        #expect(sixByNine.sizeInInches == Size2D(width: 6.0, height: 9.0))

        let fiveFive = try #require(PhysicalSizeSpec.parse("5.5x8.5in"))
        #expect(fiveFive.sizeInInches == Size2D(width: 5.5, height: 8.5))

        let metricMM = try #require(PhysicalSizeSpec.parse("148x210mm"))
        #expect(metricMM.unit == .millimeters)
        #expect(abs(metricMM.sizeInInches.width - (148.0 / 25.4)) < 1e-9)

        let metricCM = try #require(PhysicalSizeSpec.parse("15.24x22.86cm"))
        #expect(abs(metricCM.sizeInInches.width - 6.0) < 1e-6)
        #expect(abs(metricCM.sizeInInches.height - 9.0) < 1e-6)

        let pointsSpec = try #require(PhysicalSizeSpec.parse("432x648pt"))
        #expect(pointsSpec.sizeInInches == Size2D(width: 6.0, height: 9.0))
        #expect(pointsSpec.sizeInPoints == Size2D(width: 432.0, height: 648.0))

        // 'px' tokens contain 'x' — verify all pixel separator combinations parse unambiguously
        let px1 = try #require(PhysicalSizeSpec.parse("2400x3600px"))
        let px2 = try #require(PhysicalSizeSpec.parse("2400pxx3600px"))
        let px3 = try #require(PhysicalSizeSpec.parse("2400pixels x 3600pixels"))
        #expect(px1 == px2 && px2 == px3)
        #expect(px1.sizeInInches == Size2D(width: 4.0, height: 6.0))
        #expect(px1.sizeInPixels(atDPI: 300) == Size2I(width: 1200, height: 1800))

        let unicodeMul = try #require(PhysicalSizeSpec.parse("6\" × 9\""))
        #expect(unicodeMul.sizeInInches == Size2D(width: 6.0, height: 9.0))

        let bare = try #require(PhysicalSizeSpec.parse("4.5x7.5"))
        #expect(bare.unit == .inches && bare.sizeInInches == Size2D(width: 4.5, height: 7.5))

        let mixed = try #require(PhysicalSizeSpec.parse("6in x 228.6mm"))
        #expect(abs(mixed.sizeInInches.width - 6.0) < 1e-6)
        #expect(abs(mixed.sizeInInches.height - 9.0) < 1e-6)

        // 3. Invalid strings return nil
        for bad in ["", "   ", "unknown-preset", "0x9in", "-6x9in", "6x0in", "6x9foo", "6x9x12", "x9in", "6x"] {
            #expect(PhysicalSizeSpec.parse(bad) == nil)
        }

        // 4. Codable round-trip (keyed JSON object AND compact string shorthand for agentic manifest edits)
        let encodedOctavo = try JSONEncoder().encode(octavo)
        let decodedOctavo = try JSONDecoder().decode(PhysicalSizeSpec.self, from: encodedOctavo)
        #expect(decodedOctavo == octavo)

        let compactPresetJSON = Data("\"a5\"".utf8)
        let decodedCompactPreset = try JSONDecoder().decode(PhysicalSizeSpec.self, from: compactPresetJSON)
        #expect(decodedCompactPreset == a5)

        let compactDimJSON = Data("\"4.5x7.5in\"".utf8)
        let decodedCompactDim = try JSONDecoder().decode(PhysicalSizeSpec.self, from: compactDimJSON)
        #expect(decodedCompactDim.sizeInInches == Size2D(width: 4.5, height: 7.5))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(PhysicalSizeSpec.self, from: Data("\"not-a-valid-size\"".utf8))
        }
    }

    @Test("ScanTailorCLI parses --page-size, --content-box-size, and --input-dpi and rejects malformed values")
    func testCLIOptionParsingForDimensionControls() throws {
        let opts = try ScanTailorCLI.parseProcessOptions([
            "input.pdf", "-o", "output.pdf",
            "--page-size", "octavo",
            "--content-box-size", "4.5x7.5in",
            "--input-dpi", "300",
            "--margins", "1.27cm"
        ])

        #expect(opts.pageSize == .preset(.octavo))
        #expect(opts.contentBoxSize == PhysicalSizeSpec.parse("4.5x7.5in"))
        #expect(opts.inputDPI == 300)
        #expect(opts.margins.verticalMargins(dpi: 600).top == 300)

        // Verify aliases (--trim-size, --content-size, --source-dpi)
        let aliasOpts = try ScanTailorCLI.parseProcessOptions([
            "in.pdf", "-o", "out.pdf",
            "--trim-size", "a5",
            "--content-size", "110x170mm",
            "--source-dpi", "400"
        ])
        #expect(aliasOpts.pageSize == .preset(.a5))
        #expect(aliasOpts.contentBoxSize?.unit == .millimeters)
        #expect(aliasOpts.inputDPI == 400)

        // Verify invalid values and missing arguments throw CLIError
        for badArgs in [
            ["in.pdf", "-o", "out.pdf", "--page-size"],
            ["in.pdf", "-o", "out.pdf", "--page-size", "bogus"],
            ["in.pdf", "-o", "out.pdf", "--content-box-size", "0x8in"],
            ["in.pdf", "-o", "out.pdf", "--input-dpi"],
            ["in.pdf", "-o", "out.pdf", "--input-dpi", "0"],
            ["in.pdf", "-o", "out.pdf", "--input-dpi", "-300"],
            ["in.pdf", "-o", "out.pdf", "--input-dpi", "10000"],
            ["in.pdf", "-o", "out.pdf", "--input-dpi", "abc"]
        ] {
            #expect(throws: ScanTailorCLI.CLIError.self) {
                _ = try ScanTailorCLI.parseProcessOptions(badArgs)
            }
        }
    }

    @Test("MarginHarmonizer enforces explicit --page-size with proportional asymmetric margins and --content-box-size smudge trimming")
    func testMarginHarmonizerExplicitPageAndContentBoxSizes() throws {
        // Source scans have oversized flatbed padding (3900 x 5700 px = 6.5" x 9.5" at 600 DPI),
        // while body text is 2700 x 4500 px (4.5" x 7.5" at 600 DPI).
        let flatbedPageSize = Size2I(width: 3900, height: 5700)
        let bodyRect = Rect2I(x: 600, y: 600, width: 2700, height: 4500)

        func makeDet(clusters: [ContentBoxDetector.Cluster]) -> ContentBoxDetector.DetectionResult {
            var unionBox = clusters[0].exactBounds
            for c in clusters.dropFirst() {
                unionBox = unionBox.union(c.exactBounds)
            }
            return ContentBoxDetector.DetectionResult(
                contentBox: unionBox,
                mainBodyBox: unionBox,
                retainedClusters: clusters,
                rejectedBoxes: [],
                confidence: 0.99
            )
        }

        let p0 = MarginHarmonizer.PageInput(
            pageIndex: 0,
            side: .recto,
            pageSize: flatbedPageSize,
            dpi: 600,
            detection: makeDet(clusters: [.init(exactBounds: bodyRect, foregroundPixels: 250_000)])
        )
        let p1 = MarginHarmonizer.PageInput(
            pageIndex: 1,
            side: .verso,
            pageSize: flatbedPageSize,
            dpi: 600,
            detection: makeDet(clusters: [.init(exactBounds: bodyRect, foregroundPixels: 248_000)])
        )

        // 1. Explicit `--page-size octavo` (6.0" x 9.0" = 3600 x 5400 px) with asymmetric 2:1 inner/outer & 1:2 top/bottom margins:
        //    Remaining W = 3600 - 2700 = 900 px -> inner = 600 px (1.0"), outer = 300 px (0.5").
        //    Remaining H = 5400 - 4500 = 900 px -> top = 300 px (0.5"), bottom = 600 px (1.0").
        let asymmetricMargins = try #require(PublicationMargins.parse("inner=1.0in,outer=0.5in,top=0.5in,bottom=1.0in"))
        let octavoHarmonizer = MarginHarmonizer(
            configuration: MarginHarmonizer.Configuration(
                margins: asymmetricMargins,
                targetPageSize: .preset(.octavo)
            )
        )
        let octavoLayout = octavoHarmonizer.harmonizeBook(pages: [p0, p1])
        #expect(octavoLayout.canvasSize == Size2I(width: 3600, height: 5400))
        #expect(octavoLayout.rectoCanonicalFrame == Rect2I(x: 600, y: 300, width: 2700, height: 4500))
        #expect(octavoLayout.versoCanonicalFrame == Rect2I(x: 300, y: 300, width: 2700, height: 4500))
        #expect(octavoLayout.pagePlans[0].tier == .fullBody)
        #expect(octavoLayout.pagePlans[1].tier == .fullBody)

        // 2. Explicit `--content-box-size 4.5x7.5in` (without `--page-size`) + default margins (0.5" L/R, 0.25" T/B):
        //    Must trim a stray margin smudge on p2 exceeding 4.5" and size canvas to exact 5.5" x 8.0" (3300 x 4800 px),
        //    ignoring the 6.5" x 9.5" flatbed glass dimensions!
        let p2Smudged = MarginHarmonizer.PageInput(
            pageIndex: 2,
            side: .recto,
            pageSize: flatbedPageSize,
            dpi: 600,
            detection: makeDet(clusters: [
                .init(exactBounds: bodyRect, foregroundPixels: 250_000),
                .init(exactBounds: Rect2I(x: 3650, y: 1200, width: 45, height: 45), foregroundPixels: 900)
            ])
        )
        let contentBoxHarmonizer = MarginHarmonizer(
            configuration: MarginHarmonizer.Configuration(
                margins: .publicationDefault,
                targetContentBoxSize: PhysicalSizeSpec.parse("4.5x7.5in")
            )
        )
        let boxLayout = contentBoxHarmonizer.harmonizeBook(pages: [p0, p1, p2Smudged])
        #expect(boxLayout.canvasSize == Size2I(width: 3300, height: 4800))
        #expect(boxLayout.rectoCanonicalFrame == Rect2I(x: 300, y: 150, width: 2700, height: 4500))
        #expect(boxLayout.pagePlans[2].wasOutlierTrimmed == true)
        #expect(boxLayout.pagePlans[2].sourceContentBox == bodyRect)
    }

    @Test("BookPipelineCoordinator enforces override precedence (--input-dpi > --page-size > auto heuristic) and persists/reapplies manifest overrides")
    func testPipelinePrecedenceAndManifestPersistence() async throws {
        // Synthesize a 6.0" x 9.0" single-page large-print (~16 pt body text) scan at 200 optical DPI
        // (1200 x 1800 px) mis-tagged as `dpi: 72` (16.67" x 25.0" declared wrapper).
        // Because the font is 16 pt (1.6x larger than standard 10 pt prose), automatic `FontScaleAnalyzer`
        // (assuming 10 pt) would infer ~320 DPI and shrink the page to ~3.75" x 5.63".
        // Explicit `--input-dpi 200` or `--page-size octavo` MUST override `FontScaleAnalyzer`!
        let largePrintMisTagged = makeLargePrintSinglePageBuffer(width: 1200, height: 1800, declaredDPI: 72)
        let accelerator = PortableComputeAccelerator()

        // 1. Priority 1: Explicit `inputDPI = 200` (with `processingDPI = 200, outputDPI = 100`)
        let inputDPIConfig = BookPipelineCoordinator.Configuration(
            processingDPI: 200,
            outputDPI: 100,
            inputDPI: 200,
            splitMode: .singlePage,
            enableDewarp: false
        )
        let outInputDPI = try await BookPipelineCoordinator(configuration: inputDPIConfig).processGrayscalePages(
            [largePrintMisTagged],
            writer: NoOpPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )
        #expect(outInputDPI.manifest.inputDPI == 200)
        #expect(outInputDPI.manifest.fontScaleEstimate?.inferredSourceOpticalDPI == 200.0)
        #expect(abs((outInputDPI.manifest.fontScaleEstimate?.appliedScaleCorrectionFactor ?? 0.0) - (72.0 / 200.0)) < 1e-6)
        // Output at 100 DPI should preserve >= 6.0" x 9.0" (600 x 900 px), NOT shrink to ~375 x 563 px!
        #expect(outInputDPI.outputBitmapsAtOutputDPI[0].width >= 590)
        #expect(outInputDPI.outputBitmapsAtOutputDPI[0].height >= 890)

        let summaryText = ScanTailorCLI.formatManifestSummary(outInputDPI.manifest)
        #expect(summaryText.contains("Dimension Overrides: inputDPI=200"))

        // 2. Priority 2: Explicit `targetPageSize = .preset(.octavo)` (6.0" x 9.0") without `inputDPI`
        let pageSizeConfig = BookPipelineCoordinator.Configuration(
            processingDPI: 200,
            outputDPI: 100,
            targetPageSize: .preset(.octavo),
            splitMode: .singlePage,
            enableDewarp: false
        )
        let outPageSize = try await BookPipelineCoordinator(configuration: pageSizeConfig).processGrayscalePages(
            [largePrintMisTagged],
            writer: NoOpPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )
        #expect(outPageSize.manifest.pageSize == .preset(.octavo))
        #expect(outPageSize.manifest.canonicalCanvasSizeAtProcessingDPI == Size2I(width: 1200, height: 1800))
        #expect(outPageSize.outputBitmapsAtOutputDPI[0].width == 600)
        #expect(outPageSize.outputBitmapsAtOutputDPI[0].height == 900)

        // 3. Agentic Manifest Re-run: Decode JSON manifest, edit `pageSize` to `trade-paperback` (5.5" x 8.5"),
        //    and run a coordinator with NO CLI overrides — it must inherit `existingManifest.pageSize`!
        let jsonData = try JSONEncoder().encode(outPageSize.manifest)
        var agentEditedManifest = try JSONDecoder().decode(BookProcessingManifest.self, from: jsonData)
        #expect(agentEditedManifest == outPageSize.manifest)
        agentEditedManifest.pageSize = .preset(.tradePaperback)

        let defaultCoordinator = BookPipelineCoordinator(
            configuration: BookPipelineCoordinator.Configuration(
                processingDPI: 200,
                outputDPI: 100,
                splitMode: .singlePage,
                enableDewarp: false
            )
        )
        let outFromManifest = try await defaultCoordinator.processGrayscalePages(
            [largePrintMisTagged],
            writer: NoOpPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil,
            existingManifest: agentEditedManifest
        )
        // 5.5" x 8.5" at 200 DPI = 1100 x 1700 px -> 550 x 850 px at 100 DPI!
        #expect(outFromManifest.manifest.pageSize == .preset(.tradePaperback))
        #expect(outFromManifest.manifest.canonicalCanvasSizeAtProcessingDPI == Size2I(width: 1100, height: 1700))
        #expect(outFromManifest.outputBitmapsAtOutputDPI[0].width == 550)
        #expect(outFromManifest.outputBitmapsAtOutputDPI[0].height == 850)
    }

    // MARK: - Synthetic Fixture Helpers

    private func makeLargePrintSinglePageBuffer(width: Int, height: Int, declaredDPI: Int) -> GrayscaleBuffer {
        var buf = GrayscaleBuffer(width: width, height: height, dpi: declaredDPI, initialValue: 245)
        // 16 pt body text at 200 DPI -> em ≈ 44.4 px, xHeight = 22 px, capHeight = 32 px, leading = 56 px
        var lineIdx = 0
        for baselineY in stride(from: 220, through: height - 220, by: 56) {
            var cursorX = 160
            var glyphIdx = 0
            while cursorX + 20 <= width - 160 {
                let isCap = (glyphIdx == 0) || ((glyphIdx + lineIdx) % 6 == 0)
                let h = isCap ? 32 : 22
                let w = isCap ? 18 : 15
                let topY = baselineY - h
                for y in max(0, topY)..<min(height, baselineY) {
                    for dx in 0..<4 {
                        buf[cursorX + dx, y] = 20
                        buf[cursorX + w - 4 + dx, y] = 20
                    }
                }
                let barY = isCap ? (topY + h / 2) : topY
                for y in max(0, barY)..<min(height, barY + 4) {
                    for x in cursorX..<(cursorX + w) {
                        buf[x, y] = 20
                    }
                }
                cursorX += w + 7 + ((glyphIdx % 5 == 4) ? 12 : 0)
                glyphIdx += 1
            }
            lineIdx += 1
        }
        return buf
    }
}

private struct NoOpPDFWriter: PDFDocumentWriter, ~Copyable {
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap,
        dpi: Int,
        pageBoxPoints: Rect2D,
        ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {}

    consuming func finalize() throws(PDFWriteError) {}
}
