import Foundation
import ScanTailorCLI
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import ScanTailorPortableBackend
import Testing

@Suite("Anti-Billboard Canvas Normalization & Agent Escalation Tests")
struct AntiBillboardTests {

    @Test("Oversized illustration-only and sparse 1-line cover wrappers clamp to non-billboard dimensions and flag physicalScaleAmbiguous")
    func testAmbiguousOversizedIllustrationAndSparseCoverPagesClampAndEscalate() async throws {
        let accelerator = PortableComputeAccelerator()
        let config = BookPipelineCoordinator.Configuration(
            processingDPI: 150,
            outputDPI: 75,
            splitMode: .singlePage,
            enableDewarp: false
        )
        let coordinator = BookPipelineCoordinator(configuration: config)

        // 1. Illustration-only camera wrapper: 1200 x 1800 px tagged at 36 DPI -> 33.33" x 50.0" billboard with 0 prose lines
        let illustrationPage = makeIllustrationBuffer(width: 1200, height: 1800, declaredDPI: 36)
        let outIllustration = try await coordinator.processGrayscalePages(
            [illustrationPage],
            writer: RecordingPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )

        #expect(outIllustration.manifest.physicalScaleAmbiguous == true)
        let estA = try #require(outIllustration.manifest.fontScaleEstimate)
        #expect(estA.wasAutoRescaled == true)
        #expect(estA.wasAntiBillboardClamped == true)
        #expect(estA.sampledPageCount == 0)

        let outHeightInchesA = Double(outIllustration.outputBitmapsAtOutputDPI[0].height) / 75.0
        let outWidthInchesA = Double(outIllustration.outputBitmapsAtOutputDPI[0].width) / 75.0
        #expect(outHeightInchesA >= 10.5 && outHeightInchesA <= 11.6)
        #expect(outWidthInchesA >= 7.0 && outWidthInchesA <= 8.6)

        let summaryText = ScanTailorCLI.formatManifestSummary(outIllustration.manifest)
        #expect(summaryText.contains("Physical Scale Status: AMBIGUOUS (physicalScaleAmbiguous=true)"))
        #expect(summaryText.contains("anti-billboard clamped"))

        // 2. Book cover with 1 sparse display-type title line (6 giant 64-px capitals -> low confidence < 0.55):
        // Must NOT mistake giant cover display type for 10-pt body prose (which would crush the page to ~3"),
        // and must clamp cleanly while escalating `physicalScaleAmbiguous = true`.
        let sparseCoverPage = makeSparseDisplayCoverBuffer(width: 1200, height: 1800, declaredDPI: 36)
        let outCover = try await coordinator.processGrayscalePages(
            [sparseCoverPage],
            writer: RecordingPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )

        #expect(outCover.manifest.physicalScaleAmbiguous == true)
        let estB = try #require(outCover.manifest.fontScaleEstimate)
        #expect(estB.wasAntiBillboardClamped == true)
        let coverHeightInches = Double(outCover.outputBitmapsAtOutputDPI[0].height) / 75.0
        #expect(coverHeightInches >= 10.5 && coverHeightInches <= 11.6)
    }

    @Test("Calibrated standard and Legal illustration pages remain at exact 1.0x physical scale with physicalScaleAmbiguous == false")
    func testCalibratedIllustrationAndLegalPagesRemainUnambiguousAndUnclamped() async throws {
        let accelerator = PortableComputeAccelerator()
        let config = BookPipelineCoordinator.Configuration(
            processingDPI: 150,
            outputDPI: 75,
            splitMode: .singlePage,
            enableDewarp: false
        )
        let coordinator = BookPipelineCoordinator(configuration: config)

        // 1. Calibrated 6.0" x 9.0" Octavo illustration scan (900 x 1350 px at 150 DPI)
        let octavoIllustration = makeIllustrationBuffer(width: 900, height: 1350, declaredDPI: 150)
        let outOctavo = try await coordinator.processGrayscalePages(
            [octavoIllustration],
            writer: RecordingPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )
        #expect(outOctavo.manifest.physicalScaleAmbiguous == false)
        #expect(outOctavo.manifest.canonicalCanvasSizeAtProcessingDPI == Size2I(width: 900, height: 1350))
        #expect(outOctavo.outputBitmapsAtOutputDPI[0].width == 450)
        #expect(outOctavo.outputBitmapsAtOutputDPI[0].height == 675)

        // 2. Calibrated 8.5" x 14.0" US Legal illustration scan (1275 x 2100 px at 150 DPI, right on the 14.0" boundary)
        let legalIllustration = makeIllustrationBuffer(width: 1275, height: 2100, declaredDPI: 150)
        let outLegal = try await coordinator.processGrayscalePages(
            [legalIllustration],
            writer: RecordingPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )
        #expect(outLegal.manifest.physicalScaleAmbiguous == false)
        #expect(outLegal.manifest.canonicalCanvasSizeAtProcessingDPI == Size2I(width: 1275, height: 2100))
        #expect(outLegal.outputBitmapsAtOutputDPI[0].height == 1050) // 14.0" at 75 DPI
    }

    @Test("Anti-billboard clamping prevents >14-inch PDF pages even when automatic font-scale calibration is disabled or margins inflate canvas")
    func testDisabledAutoFontScaleAndPass3CanvasBillboardGuard() async throws {
        let accelerator = PortableComputeAccelerator()

        // 1. Oversized 20" x 30" wrapper (1000 x 1500 px at 50 DPI) with `enableAutomaticFontScaleCalibration = false`
        let disabledCalibConfig = BookPipelineCoordinator.Configuration(
            processingDPI: 150,
            outputDPI: 75,
            splitMode: .singlePage,
            enableDewarp: false,
            enableAutomaticFontScaleCalibration: false
        )
        let billboardInput = makeIllustrationBuffer(width: 1000, height: 1500, declaredDPI: 50)
        let outDisabled = try await BookPipelineCoordinator(configuration: disabledCalibConfig).processGrayscalePages(
            [billboardInput],
            writer: RecordingPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )
        #expect(outDisabled.manifest.physicalScaleAmbiguous == true)
        let clampedHeightInches = Double(outDisabled.outputBitmapsAtOutputDPI[0].height) / 75.0
        #expect(clampedHeightInches <= 14.0)

        // 2. Pass 3 PDF MediaBox safety guard when extreme custom margins (e.g. 5.5" top/bottom) inflate an automatic canvas > 18"
        let hugeMargins = try #require(PublicationMargins.parse("top=5.5in,bottom=5.5in,left=0.5in,right=0.5in"))
        let inflatedCanvasConfig = BookPipelineCoordinator.Configuration(
            processingDPI: 150,
            outputDPI: 75,
            splitMode: .singlePage,
            enableDewarp: false,
            harmonizerConfiguration: MarginHarmonizer.Configuration(margins: hugeMargins)
        )
        let boxRecorder = BoxCapturingPDFWriter()
        let calibratedPage = makeIllustrationBuffer(width: 900, height: 1350, declaredDPI: 150)
        let outInflated = try await BookPipelineCoordinator(configuration: inflatedCanvasConfig).processGrayscalePages(
            [calibratedPage],
            writer: boxRecorder.makeWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )
        let recordedBox = try #require(boxRecorder.boxes.first)
        #expect(recordedBox.height / 72.0 <= 14.001)
        #expect(outInflated.manifest.physicalScaleAmbiguous == true)
    }

    @Test("BookProcessingManifest decodes legacy JSON without physicalScaleAmbiguous, preserves ambiguity across non-scale reruns, and clears on explicit folio override")
    func testLegacyManifestBackwardCompatibilityAndAgentResolutionRerun() async throws {
        let accelerator = PortableComputeAccelerator()
        let baseConfig = BookPipelineCoordinator.Configuration(
            processingDPI: 150,
            outputDPI: 75,
            splitMode: .singlePage,
            enableDewarp: false
        )
        let coordinator = BookPipelineCoordinator(configuration: baseConfig)
        let illustrationPage = makeIllustrationBuffer(width: 1200, height: 1800, declaredDPI: 36)

        // 1. Initial ambiguous run -> `physicalScaleAmbiguous == true`
        let initialOut = try await coordinator.processGrayscalePages(
            [illustrationPage],
            writer: RecordingPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil
        )
        #expect(initialOut.manifest.physicalScaleAmbiguous == true)

        // 2. Legacy backward-compatible JSON decode (omit `"physicalScaleAmbiguous"` key) -> defaults to `false`
        let encodedData = try JSONEncoder().encode(initialOut.manifest)
        var jsonObject = try #require(JSONSerialization.jsonObject(with: encodedData) as? [String: Any])
        #expect(jsonObject["physicalScaleAmbiguous"] as? Bool == true)
        jsonObject.removeValue(forKey: "physicalScaleAmbiguous")
        let legacyData = try JSONSerialization.data(withJSONObject: jsonObject)
        let legacyDecoded = try JSONDecoder().decode(BookProcessingManifest.self, from: legacyData)
        #expect(legacyDecoded.physicalScaleAmbiguous == false)

        // 3. Re-running with `initialOut.manifest` and only a per-page manual skew override (still no `pageSize` / `inputDPI`)
        //    must deterministically preserve `physicalScaleAmbiguous == true`!
        var skewEditedManifest = initialOut.manifest
        skewEditedManifest.pages[0].manualOverride = PageManualOverride(overrideSkewDegrees: 0.25)
        let rerunStillAmbiguous = try await coordinator.processGrayscalePages(
            [illustrationPage],
            writer: RecordingPDFWriter(),
            accelerator: accelerator,
            ocrEngine: nil,
            existingManifest: skewEditedManifest
        )
        #expect(rerunStillAmbiguous.manifest.physicalScaleAmbiguous == true)
        #expect(rerunStillAmbiguous.manifest.canonicalCanvasSizeAtProcessingDPI == initialOut.manifest.canonicalCanvasSizeAtProcessingDPI)

        // 4. Agent escalates to user; user selects large-format `folio` (`12" x 15"`, height 15" > 14") in manifest:
        //    Explicit `pageSize` override clears `physicalScaleAmbiguous == false` and honors exact 12" x 15" without clamping!
        var resolvedManifest = initialOut.manifest
        resolvedManifest.pageSize = .preset(.folio)
        let boxRecorder = BoxCapturingPDFWriter()
        let resolvedOut = try await coordinator.processGrayscalePages(
            [illustrationPage],
            writer: boxRecorder.makeWriter(),
            accelerator: accelerator,
            ocrEngine: nil,
            existingManifest: resolvedManifest
        )
        #expect(resolvedOut.manifest.physicalScaleAmbiguous == false)
        #expect(resolvedOut.manifest.pageSize == .preset(.folio))
        #expect(resolvedOut.manifest.canonicalCanvasSizeAtProcessingDPI == Size2I(width: 1800, height: 2250)) // 12" x 15" at 150 DPI
        let folioBox = try #require(boxRecorder.boxes.first)
        #expect(abs(folioBox.width / 72.0 - 12.0) <= 0.05)
        #expect(abs(folioBox.height / 72.0 - 15.0) <= 0.05)
    }

    // MARK: - Synthetic Fixture Helpers

    private func makeIllustrationBuffer(width: Int, height: Int, declaredDPI: Int) -> GrayscaleBuffer {
        var buf = GrayscaleBuffer(width: width, height: height, dpi: declaredDPI, initialValue: 246)
        let insetX = width / 6
        let insetY = height / 6
        let rightX = width - insetX
        let bottomY = height - insetY
        let borderThickness = max(8, width / 90)

        // Heavy ornamental rectangular plate border + interior crosshatching (single large connected component, 0 glyph chains)
        for y in insetY..<bottomY {
            for x in insetX..<rightX {
                let onOuterFrame = (x - insetX < borderThickness)
                    || (rightX - 1 - x < borderThickness)
                    || (y - insetY < borderThickness)
                    || (bottomY - 1 - y < borderThickness)
                let onCross = abs((x - insetX) * (bottomY - insetY) - (y - insetY) * (rightX - insetX)) < borderThickness * (bottomY - insetY)
                    || abs((rightX - 1 - x) * (bottomY - insetY) - (y - insetY) * (rightX - insetX)) < borderThickness * (bottomY - insetY)
                if onOuterFrame || onCross {
                    buf[x, y] = 24
                }
            }
        }
        return buf
    }

    private func makeSparseDisplayCoverBuffer(width: Int, height: Int, declaredDPI: Int) -> GrayscaleBuffer {
        var buf = makeIllustrationBuffer(width: width, height: height, declaredDPI: declaredDPI)
        // Add 1 short horizontal display-title line of 6 giant 64-px block capitals ("ATLAS!") -> chainedLineCount == 1, low confidence
        let baseY = height / 3
        let capH = 64
        let capW = 42
        let stroke = 8
        var cursorX = width / 4
        for idx in 0..<6 {
            let topY = baseY - capH
            for y in topY..<baseY {
                for dx in 0..<stroke {
                    buf[cursorX + dx, y] = 18
                    buf[cursorX + capW - stroke + dx, y] = 18
                }
            }
            let barY = (idx % 2 == 0) ? topY : (topY + capH / 2)
            for y in barY..<(barY + stroke) {
                for x in cursorX..<(cursorX + capW) {
                    buf[x, y] = 18
                }
            }
            cursorX += capW + 16
        }
        return buf
    }
}

private struct RecordingPDFWriter: PDFDocumentWriter, ~Copyable {
    mutating func appendPage(
        bitmap: borrowing BinaryBitmap,
        dpi: Int,
        pageBoxPoints: Rect2D,
        ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {}

    consuming func finalize() throws(PDFWriteError) {}
}

private final class BoxCapturingPDFWriter: @unchecked Sendable {
    var boxes: [Rect2D] = []

    struct Writer: PDFDocumentWriter, ~Copyable {
        let owner: BoxCapturingPDFWriter

        mutating func appendPage(
            bitmap: borrowing BinaryBitmap,
            dpi: Int,
            pageBoxPoints: Rect2D,
            ocrLayer: [RecognizedTextObservation]
        ) throws(PDFWriteError) {
            owner.boxes.append(pageBoxPoints)
        }

        consuming func finalize() throws(PDFWriteError) {}
    }

    func makeWriter() -> Writer {
        Writer(owner: self)
    }
}
