import Foundation
import Testing
import ScanTailorContracts
@testable import ScanTailorCore
@testable import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorCLI

@Suite("Substep 5.2.1 — Pre-Binarization Table Surface Masking Tests")
struct DeskMaskingTests {
    typealias Fixtures = DocumentQuadDetectorTests
    typealias Perspective = PerspectiveRectificationTests

    static func pipeline(mask: Bool = true) -> BookPipelineCoordinator {
        BookPipelineCoordinator(configuration: .init(
            processingDPI: 300,
            outputDPI: 150,
            splitMode: .singlePage,
            enableDewarp: false,
            enableAutomaticFontScaleCalibration: false,
            enablePerspectiveRectification: false,
            enableDeskMasking: mask
        ))
    }

    // MARK: - Tests

    @Test("Unrectified wood desk: the mask closely matches the true desk region")
    func woodDeskMaskAccuracy() {
        let (scene, truth) = Fixtures.woodScene()
        let image = Fixtures.render(scene)
        let (output, result) = PaperRegionMasker.mask(image)
        #expect(result.mode == .full, "flags: \(result.flags)")

        let trueCoverage = Fixtures.polygonCoverage(truth, width: image.width, height: image.height)
        var truePositive = 0 // masked, and truly desk
        var falsePositive = 0 // masked, but truly paper
        var falseNegative = 0 // not masked, but truly desk
        for i in 0..<(image.width * image.height) {
            let maskedHere = output.pixels[i] != image.pixels[i]
            let isPaperTrue = trueCoverage[i] >= 0.5
            if maskedHere {
                if isPaperTrue { falsePositive += 1 } else { truePositive += 1 }
            } else if !isPaperTrue {
                falseNegative += 1
            }
        }
        let iou = Double(truePositive) / Double(max(1, truePositive + falsePositive + falseNegative))
        #expect(iou >= 0.98, "IoU \(iou) (fp \(falsePositive), fn \(falseNegative))")
        // The full-resolution boundary refinement regrows a thin (~2 px) band wherever it is darker
        // than the paper/desk midpoint, so a sliver of blurred paper right at the true edge can be
        // claimed; this stays a small fraction of the frame.
        let falsePositiveFraction = Double(falsePositive) / Double(image.width * image.height)
        #expect(falsePositiveFraction < 0.005, "masked \(falsePositiveFraction) of the frame outside the true page")
    }

    @Test("Desk masking keeps the border band free of ink after binarization; without it, the desk pollutes binarization")
    func deskMaskingPreventsBorderInk() {
        let (scene, _) = Fixtures.woodScene()
        let image = Fixtures.render(scene)
        let accelerator = PortableComputeAccelerator()
        let binarizer = AdaptiveBinarizer(configuration: .init(backgroundNormalization: BackgroundNormalizer.Configuration()))

        let (masked, result) = PaperRegionMasker.mask(image)
        #expect(result.mode == .full)
        // Raw binarization, deliberately without BorderAndSpeckleCleaner's own edge-strip removal
        // (Substep 5.2.2's territory), so this isolates what masking alone contributes.
        let maskedBinary = binarizer.binarize(masked, accelerator: accelerator)
        let unmaskedBinary = binarizer.binarize(image, accelerator: accelerator)

        // A strip along the top edge that, for this fixture, lies entirely on the desk (the
        // nearest page corner is at y = 170).
        let strip = Rect2I(x: 0, y: 0, width: image.width, height: 60)
        let maskedDensity = Double(maskedBinary.cropped(to: strip).countBlackPixels()) / Double(strip.width * strip.height)
        let unmaskedDensity = Double(unmaskedBinary.cropped(to: strip).countBlackPixels()) / Double(strip.width * strip.height)
        #expect(maskedDensity < 0.01, "masked density \(maskedDensity)")
        #expect(unmaskedDensity > 0.05, "expected the unmasked desk to pollute binarization (density \(unmaskedDensity))")
    }

    @Test("Bent open-book spread: gutter wedges inside the rectified frame are masked")
    func bentSpreadGutterWedgesMasked() throws {
        let tl = Point2D(x: 150, y: 190)
        let tr = Point2D(x: 1650, y: 170)
        let br = Point2D(x: 1680, y: 1180)
        let bl = Point2D(x: 120, y: 1200)
        let spineTop = (tl + tr) * 0.5 + Point2D(x: 0, y: 34)
        let spineBottom = (br + bl) * 0.5 - Point2D(x: 0, y: 30)
        let scene = Fixtures.Scene(
            width: 1800,
            height: 1350,
            outline: [tl, spineTop, tr, br, spineBottom, bl],
            textQuad: [tl, tr, br, bl],
            textColumns: [0.06...0.46, 0.54...0.94],
            gutterU: 0.5,
            desk: Fixtures.woodDesk,
            lighting: Fixtures.vignette
        )
        let image = Fixtures.render(scene)
        let detection = DocumentQuadDetector().detect(in: image)
        #expect(detection.outcome == .detected, "flags: \(detection.flags)")
        let plan = try #require(PerspectiveRectifier.plan(for: detection, sourceSize: Size2I(width: image.width, height: image.height)))
        let rectified = PerspectiveRectifier.rectify(image, plan: plan)

        let (masked, result) = PaperRegionMasker.mask(rectified)
        #expect(result.mode == .residual, "mode \(result.mode) fraction \(result.maskedFraction) flags \(result.flags)")
        #expect(result.maskedFraction > 0)
        #expect(!result.flags.contains("capped:coverage"))

        // Find the darkest point near the top-middle (inside the gutter wedge, before masking).
        let wedgeX = rectified.width / 2
        var worstY = 2
        var worstValue = 255
        for y in 2..<min(40, rectified.height) {
            let v = Int(rectified[wedgeX, y])
            if v < worstValue { worstValue = v; worstY = y }
        }
        #expect(worstValue < 170, "expected desk tone in the wedge before masking, got \(worstValue)")
        let filled = Int(masked[wedgeX, worstY])
        #expect(filled >= 165, "expected paper-toned fill after masking, got \(filled)")
        #expect(filled - worstValue >= 40, "expected a substantial brightening, got \(worstValue) -> \(filled)")
    }

    @Test("Text close to the paper edge on a wood desk survives masking")
    func textNearEdgeSurvives() {
        let margin = 36.0
        let corners = [
            Point2D(x: margin, y: margin), Point2D(x: 1800 - margin, y: margin),
            Point2D(x: 1800 - margin, y: 1350 - margin), Point2D(x: margin, y: 1350 - margin),
        ]
        let scene = Fixtures.Scene(
            width: 1800, height: 1350, outline: corners, textQuad: corners,
            textColumns: [0.03...0.97], desk: Fixtures.woodDesk, lighting: Fixtures.vignette
        )
        let image = Fixtures.render(scene)
        let (masked, _) = PaperRegionMasker.mask(image)

        // Ink pixels in a band just inside the top edge of the page, closest to the desk. Text
        // only renders for v >= 0.07 (the fixture's typesetting margin), so the band starts there.
        let bandTop = Int(margin) + 95
        let bandBottom = Int(margin) + 230
        let left = Int(margin) + 8
        let right = 1800 - Int(margin) - 8
        var inkBefore = 0
        var inkSurvived = 0
        for y in bandTop..<bandBottom {
            for x in left..<right {
                if image[x, y] < 190 {
                    inkBefore += 1
                    if masked[x, y] < 190 { inkSurvived += 1 }
                }
            }
        }
        #expect(inkBefore > 200, "scene produced too little ink near the edge to test (\(inkBefore))")
        let survivalRate = Double(inkSurvived) / Double(inkBefore)
        #expect(survivalRate >= 0.99, "survival rate \(survivalRate)")
    }

    @Test("Flatbed scan passes desk masking through unchanged")
    func flatbedPassthrough() async throws {
        let flatbed = Perspective.flatbedImage()
        let (masked, result) = PaperRegionMasker.mask(flatbed)
        #expect(result.mode == .skipped, "flags: \(result.flags)")
        #expect(masked == flatbed)

        let enabled = try await Self.pipeline(mask: true).processGrayscalePages(
            [flatbed], writer: NullWriter(), accelerator: PortableComputeAccelerator()
        )
        let disabled = try await Self.pipeline(mask: false).processGrayscalePages(
            [flatbed], writer: NullWriter(), accelerator: PortableComputeAccelerator()
        )
        #expect(enabled.outputBitmapsAtOutputDPI == disabled.outputBitmapsAtOutputDPI)
        #expect(enabled.manifest.sourcePageGeometry.first?.deskMask?.mode == .skipped)
        #expect(disabled.manifest.sourcePageGeometry.first?.deskMask == nil)
    }

    @Test("Low-contrast laminate desk is still masked; wood-only and plain-grey images never crash or erase content")
    func lowContrastAndDegenerateInputs() {
        let corners = [
            Point2D(x: 300, y: 140), Point2D(x: 1500, y: 190), Point2D(x: 1560, y: 1240), Point2D(x: 240, y: 1200),
        ]
        let laminateScene = Fixtures.Scene(
            width: 1800,
            height: 1350,
            outline: corners,
            textQuad: corners,
            desk: Fixtures.laminateDesk,
            lighting: { x, _ in 1.0 + 0.04 * (2.0 * x - 1.0) }
        )
        let laminateImage = Fixtures.render(laminateScene)
        let (laminateMasked, laminateResult) = PaperRegionMasker.mask(laminateImage)
        #expect(laminateResult.mode != .skipped, "flags: \(laminateResult.flags)")
        #expect(laminateMasked.pixels != laminateImage.pixels)

        // Images with no document at all (bare wood grain filling the frame) must never be
        // mistaken for a page with a desk border: the "paper" class texture-splits the grain into
        // a region spanning nearly the whole frame, which the convex-hull-without-a-clean-border
        // check (mirroring DocumentQuadDetector's own frame-filling check) rejects.
        let woodOnly = Fixtures.render(Fixtures.Scene(width: 1200, height: 900, outline: [], desk: Fixtures.woodDesk, lighting: Fixtures.vignette))
        let (woodOnlyOutput, woodOnlyResult) = PaperRegionMasker.mask(woodOnly)
        #expect(woodOnlyResult.mode == .skipped, "flags: \(woodOnlyResult.flags), fraction \(woodOnlyResult.maskedFraction)")
        #expect(woodOnlyOutput == woodOnly)

        let grey = Fixtures.render(Fixtures.Scene(width: 800, height: 600, outline: [], desk: { _, _ in 128 }))
        let (greyOutput, greyResult) = PaperRegionMasker.mask(grey)
        #expect(greyResult.mode == .skipped)
        #expect(greyOutput == grey)

        // Degenerate sizes never crash.
        let tiny = GrayscaleBuffer(width: 4, height: 4, dpi: 300, initialValue: 200)
        let (tinyOutput, tinyResult) = PaperRegionMasker.mask(tiny)
        #expect(tinyResult.mode == .skipped)
        #expect(tinyOutput == tiny)
    }

    @Test("Pipeline integration: manifest telemetry, disableDeskMask override, legacy decoding, CLI flag, summary")
    func pipelineIntegrationAndOverrides() async throws {
        let (scene, _) = Fixtures.woodScene()
        let image = Fixtures.render(scene)
        let accelerator = PortableComputeAccelerator()
        let first = try await Self.pipeline().processGrayscalePages([image], writer: NullWriter(), accelerator: accelerator)

        let record = try #require(first.manifest.sourcePageGeometry.first)
        let maskResult = try #require(record.deskMask)
        #expect(maskResult.mode == .full)
        #expect(maskResult.maskedFraction > 0)
        #expect(ScanTailorCLI.formatManifestSummary(first.manifest).contains("Desk Masking: 1 masked"))

        // disableDeskMask passes the page through and is carried forward.
        var manifest = first.manifest
        manifest.sourcePageGeometry[0].manualOverride = SourcePageGeometryOverride(disableDeskMask: true)
        let disabled = try await Self.pipeline().processGrayscalePages(
            [image], writer: NullWriter(), accelerator: accelerator, existingManifest: manifest
        )
        let disabledRecord = try #require(disabled.manifest.sourcePageGeometry.first)
        #expect(disabledRecord.deskMask == nil)
        #expect(disabledRecord.manualOverride?.disableDeskMask == true)

        // JSON round trip, and manifests from before 5.2.1 decode with no desk-mask telemetry.
        let data = try JSONEncoder().encode(first.manifest)
        #expect(try JSONDecoder().decode(BookProcessingManifest.self, from: data) == first.manifest)
        var legacy = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if var records = legacy["sourcePageGeometry"] as? [[String: Any]] {
            for i in records.indices { records[i].removeValue(forKey: "deskMask") }
            legacy["sourcePageGeometry"] = records
        }
        let legacyManifest = try JSONDecoder().decode(
            BookProcessingManifest.self, from: try JSONSerialization.data(withJSONObject: legacy)
        )
        #expect(legacyManifest.sourcePageGeometry.first?.deskMask == nil)

        // CLI flag.
        #expect(try ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf"]).enableDeskMasking)
        #expect(try !ScanTailorCLI.parseProcessOptions(["in.pdf", "-o", "out.pdf", "--no-desk-mask"]).enableDeskMasking)
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
