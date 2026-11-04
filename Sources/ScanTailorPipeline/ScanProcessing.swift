import Foundation
import ScanTailorContracts
import ScanTailorCore

/// The pass-1 edits that change a page's pixels. A cached page is reused only when they match, and a page
/// whose final edits differ from the ones it was processed with is processed again.
struct HeavyPageEdits: Sendable, Equatable, Codable {
    var skewDegrees: Double?
    var disableDewarp: Bool
    var borderFallback: BorderFallbackPolicy

    init(_ override: PageManualOverride?) {
        skewDegrees = override?.overrideSkewDegrees
        disableDewarp = override?.disableDewarp ?? false
        borderFallback = override?.borderFallback ?? .automatic
    }

    var cacheDescription: String {
        "skew=\(skewDegrees.map { "\($0)" } ?? "auto");dewarp=\(!disableDewarp);fallback=\(borderFallback.rawValue)"
    }
}

/// Where pass 1 gets its scans: loaded one at a time, so a book never has to fit in memory as raw rasters.
struct ScanSource: Sendable {
    /// Number of scans.
    let count: Int
    /// Size of each raster in pixels, known without loading it (used for the landscape split veto).
    let sizes: [Size2I]
    /// Loads one scan, stamped at the processing DPI.
    let load: @Sendable (Int) async throws(BookPipelineCoordinator.PipelineError) -> GrayscaleBuffer
    /// What identifies the scan's pixels for the cache (`nil` disables caching of that scan).
    let identity: @Sendable (Int) -> String?
}

/// What pass 1 is asked to do with one scan.
struct ScanJob: Sendable {
    let index: Int
    /// Stored geometry record, with any rectification or desk-mask edits merged in.
    let priorGeometry: SourcePageGeometryRecord?
    /// Split mode after the landscape veto and any `split` edit.
    let splitMode: PageSplitMode
    /// An exact cut position from the adjustments file.
    let splitX: AdjustmentLength?
    /// The pixel-changing edits for each half the scan may produce.
    var edits: [PageSide: HeavyPageEdits]

    func edits(for side: PageSide) -> HeavyPageEdits { edits[side] ?? HeavyPageEdits(nil) }

    /// Everything scan-level that the result depends on, for the cache key.
    var cacheDescription: String {
        var parts = ["scan=\(index)", "split=\(splitMode)", "splitX=\(splitX?.description ?? "-")"]
        if let prior = priorGeometry, let override = prior.manualOverride {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let json = (try? encoder.encode(override)).map { String(decoding: $0, as: UTF8.self) } ?? "?"
            parts.append("geometry=\(json)@\(prior.rasterSize.width)x\(prior.rasterSize.height)")
        }
        return parts.joined(separator: ";")
    }
}

/// The scan-level part of a pass-1 result.
struct ScanHeader: Sendable, Codable {
    var geometry: SourcePageGeometryRecord
    var split: PageSplitDecision
    var sides: [PageSide]
}

/// One cleaned page (half of a spread, or a whole scan) as pass 1 leaves it, before any content-box edit.
struct SliceOutcome: Sendable, Codable {
    let side: PageSide
    /// The edits it was processed with.
    let edits: HeavyPageEdits
    let skewEstimate: SkewEstimate
    let appliedSkewDegrees: Double
    let dewarpApplied: Bool
    let dewarpVerticalSagPixels: Double
    let dewarpResidualRMSPixels: Double
    let tracedLines: [PolyLine2D]
    let cleaned: BinaryBitmap
    let borderFallback: MacroBorderResult?
    /// Automatic content-box detection.
    let detection: ContentBoxDetector.DetectionResult
    let inkDensity: Double
    /// Whether the blank check found the page empty (`nil` when it was not checked: enough ink, or pruning off).
    let isBlank: Bool?

    private enum CodingKeys: String, CodingKey {
        case side, edits, skewEstimate, appliedSkewDegrees, dewarpApplied, dewarpVerticalSagPixels
        case dewarpResidualRMSPixels, tracedLines, cleaned, borderFallback, detection, inkDensity, isBlank
    }

    init(
        side: PageSide, edits: HeavyPageEdits, skewEstimate: SkewEstimate, appliedSkewDegrees: Double,
        dewarpApplied: Bool, dewarpVerticalSagPixels: Double, dewarpResidualRMSPixels: Double,
        tracedLines: [PolyLine2D], cleaned: BinaryBitmap, borderFallback: MacroBorderResult?,
        detection: ContentBoxDetector.DetectionResult, inkDensity: Double, isBlank: Bool?
    ) {
        self.side = side
        self.edits = edits
        self.skewEstimate = skewEstimate
        self.appliedSkewDegrees = appliedSkewDegrees
        self.dewarpApplied = dewarpApplied
        self.dewarpVerticalSagPixels = dewarpVerticalSagPixels
        self.dewarpResidualRMSPixels = dewarpResidualRMSPixels
        self.tracedLines = tracedLines
        self.cleaned = cleaned
        self.borderFallback = borderFallback
        self.detection = detection
        self.inkDensity = inkDensity
        self.isBlank = isBlank
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        side = try c.decode(PageSide.self, forKey: .side)
        edits = try c.decode(HeavyPageEdits.self, forKey: .edits)
        skewEstimate = try c.decode(SkewEstimate.self, forKey: .skewEstimate)
        appliedSkewDegrees = try c.decode(Double.self, forKey: .appliedSkewDegrees)
        dewarpApplied = try c.decode(Bool.self, forKey: .dewarpApplied)
        dewarpVerticalSagPixels = try c.decode(Double.self, forKey: .dewarpVerticalSagPixels)
        dewarpResidualRMSPixels = try c.decode(Double.self, forKey: .dewarpResidualRMSPixels)
        tracedLines = try c.decode([PolyLine2D].self, forKey: .tracedLines)
        guard let bitmap = try c.decode(CachedBitmap.self, forKey: .cleaned).bitmap else {
            throw DecodingError.dataCorruptedError(forKey: .cleaned, in: c, debugDescription: "bitmap size mismatch")
        }
        cleaned = bitmap
        borderFallback = try c.decodeIfPresent(MacroBorderResult.self, forKey: .borderFallback)
        detection = try c.decode(ContentBoxDetector.DetectionResult.self, forKey: .detection)
        inkDensity = try c.decode(Double.self, forKey: .inkDensity)
        isBlank = try c.decodeIfPresent(Bool.self, forKey: .isBlank)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(side, forKey: .side)
        try c.encode(edits, forKey: .edits)
        try c.encode(skewEstimate, forKey: .skewEstimate)
        try c.encode(appliedSkewDegrees, forKey: .appliedSkewDegrees)
        try c.encode(dewarpApplied, forKey: .dewarpApplied)
        try c.encode(dewarpVerticalSagPixels, forKey: .dewarpVerticalSagPixels)
        try c.encode(dewarpResidualRMSPixels, forKey: .dewarpResidualRMSPixels)
        try c.encode(tracedLines, forKey: .tracedLines)
        try c.encode(CachedBitmap(cleaned), forKey: .cleaned)
        try c.encodeIfPresent(borderFallback, forKey: .borderFallback)
        try c.encode(detection, forKey: .detection)
        try c.encode(inkDensity, forKey: .inkDensity)
        try c.encodeIfPresent(isBlank, forKey: .isBlank)
    }
}

/// Pass 1 of one scan.
struct ScanResult: Sendable {
    var header: ScanHeader
    var slices: [SliceOutcome]
    /// Whether every part came from the cache.
    var reused: Bool
    var clock: StageClock
}

/// A kept page of pass 1 with its output number (assigned in scan order after the parallel jobs).
struct NumberedPage {
    let sourceIndex: Int
    let sliceIndex: Int
    let outputIndex: Int
    let bookSide: MarginHarmonizer.PageSide
    let manualOverride: PageManualOverride?
}

/// One page of pass 3 after rendering and recognition.
struct RenderedPage: Sendable {
    var bitmap: BinaryBitmap? = nil
    var observations: [RecognizedTextObservation] = []
    var ocrReused = false
    var glyphMetrics: FontScaleAnalyzer.PageGlyphMetrics? = nil
    var clock = StageClock()
}

/// The tools and settings shared by every pass-1 job of a run.
struct Pass1Context: Sendable {
    let binarizer: AdaptiveBinarizer
    let cleaner: BorderAndSpeckleCleaner
    let tracer: TextLineTracer
    let dewarpSolver: CylindricalDewarpSolver
    let contentDetector: ContentBoxDetector
    let fontScaleAnalyzer: FontScaleAnalyzer
    let accelerator: any ComputeAccelerator
    let ocrEngine: (any OCREngine)?
    let cache: PipelineCache?
    /// Hash of every setting pass 1 depends on (see ``BookPipelineCoordinator/pass1Fingerprint(effectivePageSize:accelerator:ocrEngine:)``).
    let fingerprint: String
    let effectivePageSize: PhysicalSizeSpec?
    let minSagPixels: Double
    let gutterTrimWidth: Int
}

extension BookPipelineCoordinator {
    /// Every setting the cleaned pages of pass 1 depend on, as one hashed string.
    func pass1Fingerprint(
        effectivePageSize: PhysicalSizeSpec?,
        accelerator: any ComputeAccelerator,
        ocrEngine: (any OCREngine)?
    ) -> String {
        let c = configuration
        var hasher = KeyHasher()
        for part in [
            "dpi=\(c.processingDPI);out=\(c.outputDPI);gutter=\(c.gutterTrimWidth)",
            "prune=\(c.autoPruneBlankPages);blank=\(c.blankPageInkDensityThreshold)",
            "dewarp=\(c.enableDewarp);sag=\(c.minDewarpSagPixelsAt600DPI)",
            String(reflecting: c.binarizerConfiguration),
            String(reflecting: c.cleanerConfiguration),
            String(reflecting: c.contentDetectorConfiguration),
            String(reflecting: c.fontScaleConfiguration),
            "rectify=\(c.enablePerspectiveRectification)",
            String(reflecting: c.quadDetectorConfiguration),
            String(reflecting: c.rectifierConfiguration),
            "deskMask=\(c.enableDeskMasking)",
            String(reflecting: c.deskMaskerConfiguration),
            "fallback=\(c.enableBorderFallback);marginal=\(c.borderFallbackMarginalConfidence)",
            "pageSize=\(String(reflecting: effectivePageSize))",
            "accelerator=\(String(reflecting: type(of: accelerator)))",
            "ocr=\(ocrEngine?.cacheIdentity ?? "none");languages=\(c.ocrLanguages)",
        ] {
            hasher.add(part)
        }
        return hasher.hex
    }

    /// Runs pass 1 on one scan, reusing cached results where the cache has them.
    func processScan(_ job: ScanJob, source: ScanSource, context: Pass1Context) async throws(PipelineError) -> ScanResult {
        var clock = StageClock()
        let cache = context.cache
        let scanKey: String? = cache.flatMap { cache in
            source.identity(job.index).map { cache.key("scan", [context.fingerprint, $0, job.cacheDescription]) }
        }
        func sliceKey(_ side: PageSide) -> String? {
            scanKey.flatMap { key in cache?.key("slice", [key, side.rawValue, job.edits(for: side).cacheDescription]) }
        }

        // Everything from the cache: the scan is not even loaded.
        if let cache, let scanKey, let header = clock.measure("pass1.cacheRead", { cache.load(ScanHeader.self, kind: "scan", key: scanKey) }) {
            var slices: [SliceOutcome] = []
            for side in header.sides {
                guard let key = sliceKey(side),
                      let slice = clock.measure("pass1.cacheRead", { cache.load(SliceOutcome.self, kind: "slice", key: key) }),
                      slice.side == side, slice.edits == job.edits(for: side)
                else { break }
                slices.append(slice)
            }
            if slices.count == header.sides.count {
                return ScanResult(header: header, slices: slices, reused: true, clock: clock)
            }
        }

        let start = ContinuousClock.now
        let unrectified = try await source.load(job.index)
        clock.add("pass1.rasterize", ContinuousClock.now - start)

        // 0a. Document quadrangle detection & perspective rectification (desk excision).
        let (rectified, rectificationRecord) = clock.measure("pass1.rectify") {
            rectifySourcePage(unrectified, sourcePageIndex: job.index, priorRecord: job.priorGeometry, targetPageSize: context.effectivePageSize)
        }
        // 0b. Residual desk/background masking.
        var (rawScan, geometry) = clock.measure("pass1.deskMask") { maskDeskOfSourcePage(rectified, record: rectificationRecord) }
        // 0b'. A camera photo: crop to the paper outline, traced on the photo before masking painted the desk over.
        let cameraOutline = geometry.looksLikeCameraPhoto
            ? clock.measure("pass1.cameraOutline") { CameraGutterLocator.Outline(photo: rectified) }
            : nil
        if let cameraOutline, let (cropped, result) = clock.measure("pass1.cameraOutline", { CameraPaperMasker.mask(rawScan, outline: cameraOutline) }) {
            rawScan = cropped
            geometry.cameraPaperMask = result
        }

        // 0c. Spread split.
        let (splitDecision, slices) = clock.measure("pass1.split") { () -> (PageSplitDecision, [SplitPageSlice]) in
            let decision: PageSplitDecision
            if let splitX = job.splitX {
                // An exact cut from the adjustments file: a straight vertical line at the requested position.
                let centerX = AdjustmentResolver.splitCenter(splitX, width: rawScan.width, dpi: configuration.processingDPI)
                decision = PageSplitDecision(
                    layoutType: .twoPageSpread,
                    splitLine: GutterSplitLine(centerX: centerX, normalizedCenterX: centerX / Double(max(1, rawScan.width))),
                    confidence: 1.0
                )
            } else if let cameraOutline,
                      let camera = PageSplitEstimator.estimateCameraSplit(outline: cameraOutline, mode: job.splitMode) {
                // A camera photo: cut at the fold of the paper outline.
                decision = camera
            } else {
                decision = PageSplitEstimator.estimateSplit(in: rawScan, mode: job.splitMode)
            }
            return (decision, PageSplitEstimator.split(rawScan, using: decision, gutterTrimWidth: context.gutterTrimWidth))
        }
        let header = ScanHeader(geometry: geometry, split: splitDecision, sides: slices.map(\.side))
        if let cache, let scanKey { clock.measure("pass1.cacheWrite") { cache.store(header, kind: "scan", key: scanKey) } }

        var outcomes: [SliceOutcome] = []
        outcomes.reserveCapacity(slices.count)
        for slice in slices {
            let key = sliceKey(slice.side)
            if let cache, let key,
               let stored = clock.measure("pass1.cacheRead", { cache.load(SliceOutcome.self, kind: "slice", key: key) }),
               stored.side == slice.side, stored.edits == job.edits(for: slice.side) {
                outcomes.append(stored)
                continue
            }
            let outcome = try await processSlice(
                slice.buffer,
                side: slice.side,
                edits: job.edits(for: slice.side),
                geometry: geometry,
                context: context,
                clock: &clock
            )
            if let cache, let key { clock.measure("pass1.cacheWrite") { cache.store(outcome, kind: "slice", key: key) } }
            outcomes.append(outcome)
        }
        return ScanResult(header: header, slices: outcomes, reused: false, clock: clock)
    }

    /// Deskews, binarizes, cleans, dewarps and measures one page, and checks whether it is blank.
    private func processSlice(
        _ buffer: GrayscaleBuffer,
        side: PageSide,
        edits: HeavyPageEdits,
        geometry: SourcePageGeometryRecord,
        context: Pass1Context,
        clock: inout StageClock
    ) async throws(PipelineError) -> SliceOutcome {
        let accelerator = context.accelerator

        // 1a. Multi-scale deskew.
        let skewEstimate = clock.measure("pass1.deskew") { SkewEstimator.estimateSkew(in: buffer) }
        let appliedSkew = edits.skewDegrees ?? skewEstimate.angleDegrees
        let deskewedGray = clock.measure("pass1.deskew") { SkewEstimator.deskew(buffer, by: appliedSkew, accelerator: accelerator) }

        // 1b. Binarize for text-line tracing and possible 3D cubic-sheet dewarping.
        let initialBinary = clock.measure("pass1.binarize") { context.binarizer.binarize(deskewedGray, accelerator: accelerator) }
        let fallbackContext = configuration.enableBorderFallback
            ? geometry.borderFallbackContext(
                splitSide: side,
                policy: edits.borderFallback,
                marginalConfidence: configuration.borderFallbackMarginalConfidence
            )
            : nil
        let (initialCleaned, initialFallback) = clock.measure("pass1.clean") { context.cleaner.clean(initialBinary, fallback: fallbackContext) }
        var borderFallbackResult = initialFallback

        let tracedLines = clock.measure("pass1.trace") { context.tracer.traceLines(in: initialCleaned) }
        let pageSize = Size2I(width: deskewedGray.width, height: deskewedGray.height)

        var finalCleaned = initialCleaned
        var dewarpApplied = false
        var verticalSagPixels = 0.0
        var residualRMS = 0.0

        if configuration.enableDewarp && !edits.disableDewarp {
            let solution = clock.measure("pass1.dewarp") { context.dewarpSolver.solve(pageSize: pageSize, lines: tracedLines) }
            if let model = solution.model {
                residualRMS = model.residualRMSPixels
                // Peak vertical excursion across u in [-0.85, 0.85].
                var minZ = 0.0
                var maxZ = 0.0
                for step in -17...17 {
                    let z = model.depthProfile(u: Double(step) * 0.05)
                    if z < minZ { minZ = z }
                    if z > maxZ { maxZ = z }
                }
                verticalSagPixels = (maxZ - minZ) * model.halfHeight

                if verticalSagPixels >= context.minSagPixels {
                    let dewarpedGray = clock.measure("pass1.dewarp") {
                        accelerator.meshWarp(deskewedGray, displacementGrid: solution.grid, outputSize: pageSize)
                    }
                    let glyphScale = context.fontScaleAnalyzer.analyzePage(
                        in: initialCleaned,
                        declaredDPI: deskewedGray.dpi,
                        ocrObservations: []
                    ).map { BackgroundNormalizer.GlyphScale(metrics: $0) }
                    let dewarpedBinary = clock.measure("pass1.binarize") {
                        context.binarizer.binarize(dewarpedGray, accelerator: accelerator, glyphScale: glyphScale)
                    }
                    let (dewarpedCleaned, dewarpedFallback) = clock.measure("pass1.clean") {
                        context.cleaner.clean(dewarpedBinary, fallback: fallbackContext)
                    }
                    finalCleaned = dewarpedCleaned
                    borderFallbackResult = dewarpedFallback
                    dewarpApplied = true
                }
            }
        }

        // 1c. Automatic content box detection (edits from the adjustments file are applied later).
        let detection = clock.measure("pass1.contentBox") { () -> ContentBoxDetector.DetectionResult in
            var detector = context.contentDetector
            if geometry.looksLikeCameraPhoto {
                // Desk residue survives in a photo's margins: keep only the body and headers set tight against it.
                var strict = detector.configuration
                strict.strictMargins = true
                detector = ContentBoxDetector(configuration: strict)
            }
            return detector.detect(in: finalCleaned, dpi: configuration.processingDPI, splitSide: side)
        }

        // 1d. Blank check: run on every low-ink page; whether it prunes depends on the page's edits.
        let totalPixels = finalCleaned.width * finalCleaned.height
        let inkDensity = totalPixels > 0 ? Double(finalCleaned.countBlackPixels()) / Double(totalPixels) : 0.0
        var isBlank: Bool? = nil
        if configuration.autoPruneBlankPages && inkDensity < configuration.blankPageInkDensityThreshold {
            let noContent = detection.contentBox == nil || detection.retainedClusters.isEmpty
            if let ocrEngine = context.ocrEngine {
                let checkBitmap = configuration.processingDPI >= configuration.outputDPI * 2
                    ? accelerator.downsampleBinaryTo300DPI(finalCleaned)
                    : finalCleaned
                let start = ContinuousClock.now
                do {
                    let observations = try await ocrEngine.recognizeText(
                        in: checkBitmap,
                        dpi: configuration.outputDPI,
                        languages: configuration.ocrLanguages
                    )
                    // At least one substantive word with letters and confidence >= 0.60, so scanner-glass dust,
                    // specks or punctuation noise (e.g. "2%" at 0.5) cannot keep an empty flatbed or cover slice.
                    isBlank = !observations.contains { $0.confidence >= 0.60 && $0.text.contains { $0.isLetter } }
                } catch {
                    isBlank = noContent
                }
                clock.add("pass1.blankCheck", ContinuousClock.now - start)
            } else {
                isBlank = noContent
            }
        }

        return SliceOutcome(
            side: side,
            edits: edits,
            skewEstimate: skewEstimate,
            appliedSkewDegrees: appliedSkew,
            dewarpApplied: dewarpApplied,
            dewarpVerticalSagPixels: verticalSagPixels,
            dewarpResidualRMSPixels: residualRMS,
            tracedLines: tracedLines,
            cleaned: finalCleaned,
            borderFallback: borderFallbackResult,
            detection: detection,
            inkDensity: inkDensity,
            isBlank: isBlank
        )
    }
}
