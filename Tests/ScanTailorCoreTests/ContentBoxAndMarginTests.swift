import Testing
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

@Suite("Content Box Detection, 3-Tier Margin Harmonizer & Book Pipeline Tests")
struct ContentBoxAndMarginTests {

    @Test("ContentBoxDetector retains body text, running headers, and page numbers while rejecting margin noise")
    func testContentBoxDetectorRetainsHeadersAndRejectsMarginNoise() {
        let width = 1200
        let height = 1800
        var bitmap = BinaryBitmap(width: width, height: height, initialBlack: false)

        // 1. Running header at y = 200..222, x = 450..750
        fillTextBlock(&bitmap, rect: Rect2I(x: 450, y: 200, width: 300, height: 22))

        // 2. Main body text block at x = 220..980 (width = 760), y = 280..1480 (height = 1200)
        for lineY in stride(from: 280, through: 1456, by: 42) {
            fillTextBlock(&bitmap, rect: Rect2I(x: 220, y: lineY, width: 760, height: 24))
        }

        // 3. Bottom page number at y = 1540..1562, x = 580..620
        fillTextBlock(&bitmap, rect: Rect2I(x: 580, y: 1540, width: 40, height: 22))

        // 4. Outer right margin smudge at x = 1140..1155, y = 800..820 (far outside body text)
        fillSolidRect(&bitmap, rect: Rect2I(x: 1140, y: 800, width: 15, height: 20))

        // 5. Outer left border artifact line at x = 4..8, y = 100..1600
        fillSolidRect(&bitmap, rect: Rect2I(x: 4, y: 100, width: 4, height: 1500))

        let detector = ContentBoxDetector()
        let result = detector.detect(in: bitmap, dpi: 600)

        let box = try! #require(result.contentBox)
        // Content box should span from x = 220 to 980 (width 760) and y = 200 (header) to 1562 (page number)
        #expect(abs(box.minX - 220) <= 2)
        #expect(abs(box.maxX - 980) <= 2)
        #expect(abs(box.minY - 200) <= 2)
        #expect(abs(box.maxY - 1562) <= 2)
        #expect(!result.rejectedBoxes.isEmpty)
    }

    @Test("Split-edge exclusion zone masks residual spine crease prior to morphological closing on sliced sub-pages")
    func testSplitBoundaryNoiseExclusionZonePreventsCreaseBridging() throws {
        let width = 1200
        let height = 1800
        let detector = ContentBoxDetector(
            configuration: ContentBoxDetector.Configuration(
                cleanBordersFirst: false,
                splitEdgeExclusionFraction: 0.04 // 48 px exclusion strip on cut edge
            )
        )

        // 1. Right Recto slice (inner cut edge on LEFT, x in 0..<48):
        // Place residual spine crease fragments at x = 10..42 (and a thick vertical crease sliver reaching x = 58),
        // with body text starting at x = 90 (only 32..48 px away, well within closeBrick's 64 px horizontal span).
        var rectoBitmap = BinaryBitmap(width: width, height: height, initialBlack: false)
        fillSolidRect(&rectoBitmap, rect: Rect2I(x: 10, y: 120, width: 48, height: 1500))
        for lineY in stride(from: 280, through: 1456, by: 42) {
            fillTextBlock(&rectoBitmap, rect: Rect2I(x: 90, y: lineY, width: 760, height: 24))
        }

        let rectoResult = detector.detect(in: rectoBitmap, dpi: 600, splitSide: .rightRecto)
        let rectoBox = try #require(rectoResult.contentBox)
        #expect(abs(rectoBox.minX - 90) <= 2)
        #expect(abs(rectoBox.maxX - 850) <= 6)
        #expect(!rectoResult.rejectedBoxes.isEmpty)

        // 2. Left Verso slice (inner cut edge on RIGHT, x in 1152..<1200):
        // Place residual spine crease at x = 1142..1190, with body text ending at x = 1110
        // (only 32 px gap from the crease, within closeBrick's 64 px bridging span).
        var versoBitmap = BinaryBitmap(width: width, height: height, initialBlack: false)
        fillSolidRect(&versoBitmap, rect: Rect2I(x: 1142, y: 120, width: 48, height: 1500))
        for lineY in stride(from: 280, through: 1456, by: 42) {
            fillTextBlock(&versoBitmap, rect: Rect2I(x: 350, y: lineY, width: 760, height: 24))
        }

        let versoResult = detector.detect(in: versoBitmap, dpi: 600, splitSide: .leftVerso)
        let versoBox = try #require(versoResult.contentBox)
        #expect(abs(versoBox.minX - 350) <= 2)
        #expect(abs(versoBox.maxX - 1110) <= 6)
        #expect(!versoResult.rejectedBoxes.isEmpty)
    }

    @Test("MarginHarmonizer enforces 3-tier placement (fullBody, edgeAnchoredPartial sinkage, standaloneFloating) and Pass 2 smudge rejection")
    func testMarginHarmonizerThreeTierPlacementAndPass2OutlierTrimming() {
        let pageSize = Size2I(width: 1200, height: 1800)
        let canonicalBodyRect = Rect2I(x: 220, y: 240, width: 760, height: 1320)

        // Helper to build a synthetic DetectionResult from clusters
        func makeDetection(clusters: [ContentBoxDetector.Cluster]) -> ContentBoxDetector.DetectionResult {
            guard let first = clusters.first else {
                return ContentBoxDetector.DetectionResult(
                    contentBox: nil,
                    mainBodyBox: nil,
                    retainedClusters: [],
                    rejectedBoxes: [],
                    confidence: 1.0
                )
            }
            var total = first.exactBounds
            for c in clusters.dropFirst() {
                total = total.union(c.exactBounds)
            }
            return ContentBoxDetector.DetectionResult(
                contentBox: total,
                mainBodyBox: total,
                retainedClusters: clusters,
                rejectedBoxes: [],
                confidence: 0.98
            )
        }

        // Page 0 (Recto): Standard Full Body Page
        let p0 = MarginHarmonizer.PageInput(
            pageIndex: 0,
            side: .recto,
            pageSize: pageSize,
            dpi: 600,
            detection: makeDetection(clusters: [
                .init(exactBounds: canonicalBodyRect, foregroundPixels: 180_000)
            ])
        )

        // Page 1 (Verso): Standard Full Body Page
        let p1 = MarginHarmonizer.PageInput(
            pageIndex: 1,
            side: .verso,
            pageSize: pageSize,
            dpi: 600,
            detection: makeDetection(clusters: [
                .init(exactBounds: canonicalBodyRect, foregroundPixels: 175_000)
            ])
        )

        // Page 2 (Recto): Full Body Page WITH a stray margin smudge at x = 1090..1120 (>10% wider than 760)
        // that slipped through Pass 1 as a separate cluster. Pass 2 must trim it!
        let p2 = MarginHarmonizer.PageInput(
            pageIndex: 2,
            side: .recto,
            pageSize: pageSize,
            dpi: 600,
            detection: makeDetection(clusters: [
                .init(exactBounds: canonicalBodyRect, foregroundPixels: 182_000),
                .init(exactBounds: Rect2I(x: 1090, y: 700, width: 30, height: 35), foregroundPixels: 900)
            ])
        )

        // Page 3 (Verso): Chapter Opening Page with 360 px of top sinkage (starts at y = 600, ends at canonical maxY = 1560)
        let chapterStartRect = Rect2I(x: 220, y: 600, width: 760, height: 960)
        let p3 = MarginHarmonizer.PageInput(
            pageIndex: 3,
            side: .verso,
            pageSize: pageSize,
            dpi: 600,
            detection: makeDetection(clusters: [
                .init(exactBounds: chapterStartRect, foregroundPixels: 120_000)
            ])
        )

        // Page 4 (Recto): Standalone Section Divider / Epigraph sitting at natural position (x = 420, y = 740, width = 360, height = 180)
        let standaloneRect = Rect2I(x: 420, y: 740, width: 360, height: 180)
        let p4 = MarginHarmonizer.PageInput(
            pageIndex: 4,
            side: .recto,
            pageSize: pageSize,
            dpi: 600,
            detection: makeDetection(clusters: [
                .init(exactBounds: standaloneRect, foregroundPixels: 14_000)
            ])
        )

        let harmonizer = MarginHarmonizer(
            configuration: MarginHarmonizer.Configuration(
                canonicalHorizontalMarginAt600DPI: 220,
                canonicalVerticalMarginAt600DPI: 240
            )
        )
        let model = harmonizer.harmonizeBook(pages: [p0, p1, p2, p3, p4])

        #expect(model.pagePlans.count == 5)

        // Verify Tier 1 (fullBody) on pages 0, 1, and 2 (after Pass 2 outlier trim)
        #expect(model.pagePlans[0].tier == .fullBody)
        #expect(model.pagePlans[1].tier == .fullBody)
        #expect(model.pagePlans[2].tier == .fullBody)
        #expect(model.pagePlans[2].wasOutlierTrimmed == true)
        #expect(model.pagePlans[2].sourceContentBox == canonicalBodyRect)

        // Verify Tier 2 (edgeAnchoredPartial) on page 3 (chapter start with top sinkage):
        // Its bottom edge on the output canvas must align with the canonical bottom edge, preserving the 360 px top sinkage!
        let plan3 = model.pagePlans[3]
        #expect(plan3.tier == .edgeAnchoredPartial)
        let placedBottom3 = plan3.destinationOrigin.y + chapterStartRect.height
        #expect(placedBottom3 == model.versoCanonicalFrame.maxY)
        #expect(plan3.destinationOrigin.y == model.versoCanonicalFrame.minY + 360)

        // Verify Tier 3 (standaloneFloating) on page 4 (divider / epigraph):
        // It keeps its offset from the scan's text block (here centered, 500 px below the block top) rather than
        // being pushed to the top margin.
        let plan4 = model.pagePlans[4]
        #expect(plan4.tier == .standaloneFloating)
        let frame = model.rectoCanonicalFrame
        #expect(plan4.destinationOrigin.x == frame.minX + (frame.width - standaloneRect.width) / 2)
        #expect(plan4.destinationOrigin.y == frame.minY + (standaloneRect.minY - canonicalBodyRect.minY))
    }

    @Test("BookPipelineCoordinator runs 3-pass pipeline on multi-page scans and supports manifest overrides")
    func testBookPipelineCoordinatorEndToEnd() async throws {
        // Build 2 synthetic 600 DPI grayscale pages (600 x 800 for fast execution):
        // Scan 0: Single full-body page
        // Scan 1: Standalone title/epigraph page
        let width = 600
        let height = 800
        var page0 = GrayscaleBuffer(width: width, height: height, dpi: 600, initialValue: 245)
        for lineY in stride(from: 120, through: 660, by: 36) {
            for y in lineY..<(lineY + 16) {
                for x in 100..<500 where (x % 14) < 10 {
                    page0[x, y] = 20
                }
            }
        }

        var page1 = GrayscaleBuffer(width: width, height: height, dpi: 600, initialValue: 245)
        for lineY in [340, 380] {
            for y in lineY..<(lineY + 16) {
                for x in 200..<400 where (x % 14) < 10 {
                    page1[x, y] = 20
                }
            }
        }

        let coordinator = BookPipelineCoordinator(
            configuration: BookPipelineCoordinator.Configuration(
                processingDPI: 600,
                outputDPI: 300,
                splitMode: .singlePage,
                enableDewarp: false
            )
        )
        let accelerator = PortableComputeAccelerator()
        let writer = MockPDFDocumentWriter()

        let output = try await coordinator.processGrayscalePages(
            [page0, page1],
            writer: writer,
            accelerator: accelerator,
            ocrEngine: nil
        )

        #expect(output.manifest.pages.count == 2)
        #expect(output.outputBitmapsAtOutputDPI.count == 2)
        #expect(output.manifest.pages[0].layoutPlan.tier == .fullBody)
        #expect(output.manifest.pages[1].layoutPlan.tier == .standaloneFloating)

        // Verify 600 -> 300 DPI downsampling halved the canvas dimensions
        let canvas600 = output.manifest.canonicalCanvasSizeAtProcessingDPI
        #expect(output.outputBitmapsAtOutputDPI[0].width == canvas600.width / 2)
        #expect(output.outputBitmapsAtOutputDPI[0].height == canvas600.height / 2)

        // Test re-running with a manual destinationOrigin override in the manifest
        var modifiedManifest = output.manifest
        let customOrigin = Point2I(x: 77, y: 88)
        modifiedManifest.pages[1].manualOverride = PageManualOverride(
            overrideDestinationOrigin: customOrigin
        )

        let writer2 = MockPDFDocumentWriter()
        let output2 = try await coordinator.processGrayscalePages(
            [page0, page1],
            writer: writer2,
            accelerator: accelerator,
            ocrEngine: nil,
            existingManifest: modifiedManifest
        )
        #expect(output2.manifest.pages[1].layoutPlan.destinationOrigin == customOrigin)
    }

    @Test("MarginHarmonizer IQR and median outlier rejection prevents foldouts and title pages from corrupting canonical dimensions")
    func testMarginHarmonizerIQROutlierRejectionExcludesFoldoutsAndTitlePages() {
        // Direct testing of filterOutliersIQR
        let sampleWidths = [1200, 1995, 2000, 2000, 2005, 4000] // 1200 is title page, 4000 is foldout
        let filteredWidths = MarginHarmonizer.filterOutliersIQR(sampleWidths)
        #expect(filteredWidths == [1995, 2000, 2000, 2005])

        let sampleHeights = [600, 3190, 3200, 3200, 3200, 3210] // 600 is title page
        let filteredHeights = MarginHarmonizer.filterOutliersIQR(sampleHeights)
        #expect(filteredHeights == [3190, 3200, 3200, 3200, 3210])

        // Book-wide harmonization test with 4 standard body pages, 1 oversized foldout, and 1 short title page
        let pageSize = Size2I(width: 1200, height: 1800)
        let bodyRect = Rect2I(x: 220, y: 240, width: 760, height: 1320)
        let foldoutRect = Rect2I(x: 100, y: 240, width: 1800, height: 1320)
        let titleRect = Rect2I(x: 400, y: 700, width: 400, height: 280)

        func makeDet(box: Rect2I) -> ContentBoxDetector.DetectionResult {
            ContentBoxDetector.DetectionResult(
                contentBox: box,
                mainBodyBox: box,
                retainedClusters: [.init(exactBounds: box, foregroundPixels: 100_000)],
                rejectedBoxes: [],
                confidence: 0.99
            )
        }

        let p0 = MarginHarmonizer.PageInput(pageIndex: 0, side: .recto, pageSize: pageSize, dpi: 600, detection: makeDet(box: titleRect))
        let p1 = MarginHarmonizer.PageInput(pageIndex: 1, side: .verso, pageSize: pageSize, dpi: 600, detection: makeDet(box: bodyRect))
        let p2 = MarginHarmonizer.PageInput(pageIndex: 2, side: .recto, pageSize: pageSize, dpi: 600, detection: makeDet(box: bodyRect))
        let p3 = MarginHarmonizer.PageInput(pageIndex: 3, side: .verso, pageSize: pageSize, dpi: 600, detection: makeDet(box: bodyRect))
        let p4 = MarginHarmonizer.PageInput(pageIndex: 4, side: .recto, pageSize: pageSize, dpi: 600, detection: makeDet(box: bodyRect))
        let p5 = MarginHarmonizer.PageInput(pageIndex: 5, side: .verso, pageSize: Size2I(width: 2200, height: 1800), dpi: 600, detection: makeDet(box: foldoutRect))

        let harmonizer = MarginHarmonizer(
            configuration: MarginHarmonizer.Configuration(
                canonicalHorizontalMarginAt600DPI: 220,
                canonicalVerticalMarginAt600DPI: 240
            )
        )
        let model = harmonizer.harmonizeBook(pages: [p0, p1, p2, p3, p4, p5])

        // Verify that canonical width and height are strictly locked to the 760 x 1320 body pages
        #expect(model.rectoCanonicalFrame.width == 760)
        #expect(model.rectoCanonicalFrame.height == 1320)
        #expect(model.versoCanonicalFrame.width == 760)
        #expect(model.versoCanonicalFrame.height == 1320)

        // Verify that the title page and foldout are placed in Tier 3 (standaloneFloating)
        #expect(model.pagePlans[0].tier == .standaloneFloating)
        #expect(model.pagePlans[5].tier == .standaloneFloating)

        // Standard body pages must remain Tier 1 (fullBody)
        #expect(model.pagePlans[1].tier == .fullBody)
        #expect(model.pagePlans[2].tier == .fullBody)
        #expect(model.pagePlans[3].tier == .fullBody)
        #expect(model.pagePlans[4].tier == .fullBody)
    }

    @Test("BookPipelineCoordinator auto-prunes blank sub-page slices and records telemetry in manifest")
    func testBlankSubPageAutoPruningEliminatesPhantomFlyleaf() async throws {
        let width = 1200
        let height = 800

        // Create a 2-page spread where the left half (0..<600) is a blank flyleaf (pure background 245),
        // and the right half (600..<1200) has dense text lines (ink density > 1%).
        var spreadScan = GrayscaleBuffer(width: width, height: height, dpi: 600, initialValue: 245)
        for lineY in stride(from: 140, through: 660, by: 36) {
            for y in lineY..<(lineY + 16) {
                for x in 700..<1100 where (x % 14) < 10 {
                    spreadScan[x, y] = 20
                }
            }
        }

        let accelerator = PortableComputeAccelerator()

        // 1. With autoPruneBlankPages = true (default):
        let coordinatorAuto = BookPipelineCoordinator(
            configuration: BookPipelineCoordinator.Configuration(
                processingDPI: 600,
                outputDPI: 300,
                splitMode: .twoPageSpread,
                autoPruneBlankPages: true,
                enableDewarp: false
            )
        )
        let writer1 = MockPDFDocumentWriter()
        let output1 = try await coordinatorAuto.processGrayscalePages(
            [spreadScan],
            writer: writer1,
            accelerator: accelerator,
            ocrEngine: nil
        )

        // The blank left sub-page should be pruned; only 1 output page remains (the right recto page)
        #expect(output1.manifest.pages.count == 1)
        #expect(output1.outputBitmapsAtOutputDPI.count == 1)
        #expect(output1.manifest.prunedPages.count == 1)
        #expect(output1.manifest.prunedPages[0].splitSide == .leftVerso)
        #expect(output1.manifest.pages[0].splitSide == .rightRecto)
        #expect(output1.manifest.pages[0].bookSide == .recto)
        #expect(output1.manifest.pages[0].outputPageIndex == 0)

        // 2. With autoPruneBlankPages = false:
        let coordinatorNoPrune = BookPipelineCoordinator(
            configuration: BookPipelineCoordinator.Configuration(
                processingDPI: 600,
                outputDPI: 300,
                splitMode: .twoPageSpread,
                autoPruneBlankPages: false,
                enableDewarp: false
            )
        )
        let writer2 = MockPDFDocumentWriter()
        let output2 = try await coordinatorNoPrune.processGrayscalePages(
            [spreadScan],
            writer: writer2,
            accelerator: accelerator,
            ocrEngine: nil
        )

        // Both pages must be retained when pruning is disabled
        #expect(output2.manifest.pages.count == 2)
        #expect(output2.manifest.prunedPages.isEmpty)
    }

    @Test("BookPipelineCoordinator preserves sparse sub-page when OCR detects recognized text")
    func testBlankSubPageAutoPruningPreservesPageWithOCRWords() async throws {
        let width = 600
        let height = 800

        // Create a page with very sparse text (a single small line, ink density < 0.2%)
        var sparseScan = GrayscaleBuffer(width: width, height: height, dpi: 600, initialValue: 245)
        for y in 400..<412 {
            for x in 280..<320 {
                sparseScan[x, y] = 20
            }
        }

        let accelerator = PortableComputeAccelerator()
        let coordinator = BookPipelineCoordinator(
            configuration: BookPipelineCoordinator.Configuration(
                processingDPI: 600,
                outputDPI: 300,
                splitMode: .singlePage,
                autoPruneBlankPages: true,
                blankPageInkDensityThreshold: 0.005,
                enableDewarp: false
            )
        )

        // Mock OCR engine returns 1 recognized word ("FINIS")
        let mockOCR = MockTextOCREngine(wordsToReturn: [
            RecognizedTextObservation(
                text: "FINIS",
                confidence: 0.99,
                boundingBox: Rect2D(x: 0.45, y: 0.50, width: 0.10, height: 0.02)
            )
        ])

        let writer = MockPDFDocumentWriter()
        let output = try await coordinator.processGrayscalePages(
            [sparseScan],
            writer: writer,
            accelerator: accelerator,
            ocrEngine: mockOCR
        )

        // Page must NOT be pruned because OCR confirmed the presence of text
        #expect(output.manifest.pages.count == 1)
        #expect(output.manifest.prunedPages.isEmpty)
    }

    @Test("PublicationMargins parses dimensions across in, pt, mm, px and asymmetric CSS-like strings")
    func testPublicationMarginsParsingAndDPIConversion() throws {
        // 1. Shorthand top/bottom, left/right
        let m1 = try #require(PublicationMargins.parse("0.25in, 0.5in"))
        #expect(m1.top.value == 0.25 && m1.top.unit == .inches)
        #expect(m1.bottom.value == 0.25 && m1.bottom.unit == .inches)
        #expect(m1.left.value == 0.50 && m1.left.unit == .inches)
        #expect(m1.right.value == 0.50 && m1.right.unit == .inches)
        #expect(m1.verticalMargins(dpi: 600) == (150, 150))
        #expect(m1.horizontalMargins(for: .verso, dpi: 600) == (300, 300))

        // 2. Key-value string with units
        let m2 = try #require(PublicationMargins.parse("top=18pt,bottom=18pt,inner=0.75in,outer=0.5in"))
        #expect(m2.top.unit == .points && m2.top.value == 18.0)
        #expect(m2.inner?.unit == .inches && m2.inner?.value == 0.75)
        #expect(m2.outer?.unit == .inches && m2.outer?.value == 0.50)

        // At 600 DPI: 18 pt = (18 / 72) * 600 = 150 px
        let v2 = m2.verticalMargins(dpi: 600)
        #expect(v2.top == 150)
        #expect(v2.bottom == 150)

        // Recto: inner (0.75in = 450 px) is on left, outer (0.5in = 300 px) is on right
        let rectoH = m2.horizontalMargins(for: .recto, dpi: 600)
        #expect(rectoH.left == 450)
        #expect(rectoH.right == 300)

        // Verso: outer (0.5in = 300 px) is on left, inner (0.75in = 450 px) is on right
        let versoH = m2.horizontalMargins(for: .verso, dpi: 600)
        #expect(versoH.left == 300)
        #expect(versoH.right == 450)

        // 3. Millimeters parsing: 25.4mm = 1.0 inch = 600 px at 600 DPI
        let m3 = try #require(PublicationMargins.parse("top=25.4mm,left=12.7mm"))
        #expect(m3.verticalMargins(dpi: 600).top == 600)
        #expect(m3.horizontalMargins(for: .single, dpi: 600).left == 300)
    }

    @Test("CLI option parsing correctly handles publication margins, page ranges, exclusions, and starting side")
    func testCLIParsingOptionsForMarginsAndPageFilters() throws {
        // Valid full CLI arguments
        let args = [
            "process",
            "input.pdf",
            "-o", "output.pdf",
            "--margins", "top=0.25in,bottom=0.25in,left=0.5in,right=0.5in",
            "--page-range", "2-5",
            "--exclude-pages", "1,3,7",
            "--first-page-side", "verso"
        ]
        let opts = try ScanTailorCLI.parseProcessOptions(Array(args.dropFirst()))
        #expect(opts.inputPDFPath == "input.pdf")
        #expect(opts.outputPDFPath == "output.pdf")
        #expect(opts.pageRange == 2...5)
        #expect(opts.excludedPages == [1, 3, 7])
        #expect(opts.firstPageSide == .verso)
        #expect(opts.margins.top.value == 0.25)
        #expect(opts.margins.left.value == 0.50)

        // Invalid margins format throws error
        #expect(throws: ScanTailorCLI.CLIError.self) {
            _ = try ScanTailorCLI.parseProcessOptions(["input.pdf", "-o", "out.pdf", "--margins", "invalid-margin"])
        }

        // Invalid page-range throws error
        #expect(throws: ScanTailorCLI.CLIError.self) {
            _ = try ScanTailorCLI.parseProcessOptions(["input.pdf", "-o", "out.pdf", "--page-range", "abc"])
        }
    }

    // MARK: - Test Helpers

    private func fillTextBlock(_ bitmap: inout BinaryBitmap, rect: Rect2I) {
        var x = rect.minX
        while x < rect.maxX {
            let charW = min(12, rect.maxX - x)
            for py in rect.minY..<rect.maxY {
                for px in x..<(x + charW) {
                    if px >= 0 && px < bitmap.width && py >= 0 && py < bitmap.height {
                        bitmap.setPixel(x: px, y: py, isBlack: true)
                    }
                }
            }
            x += 18
        }
    }

    private func fillSolidRect(_ bitmap: inout BinaryBitmap, rect: Rect2I) {
        for py in max(0, rect.minY)..<min(bitmap.height, rect.maxY) {
            for px in max(0, rect.minX)..<min(bitmap.width, rect.maxX) {
                bitmap.setPixel(x: px, y: py, isBlack: true)
            }
        }
    }
}

private struct MockPDFDocumentWriter: PDFDocumentWriter, ~Copyable {
    var appendedPageCount: Int = 0

    mutating func appendPage(
        bitmap: borrowing BinaryBitmap,
        dpi: Int,
        pageBoxPoints: Rect2D,
        ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {
        appendedPageCount += 1
    }

    consuming func finalize() throws(PDFWriteError) {
        // No-op for in-memory test mock
    }
}

private struct MockTextOCREngine: OCREngine {
    let wordsToReturn: [RecognizedTextObservation]

    func recognizeText(
        in bitmap: borrowing BinaryBitmap,
        dpi: Int,
        languages: [String]
    ) async throws(OCRError) -> [RecognizedTextObservation] {
        wordsToReturn
    }
}
