import Foundation
import ScanTailorAppleBackend
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import ScanTailorPortableBackend
import ScanTailorTesseractBackend

@main
public struct ScanTailorCLI {
    public static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            try await run(arguments: args)
        } catch let error as CLIError {
            fputs("Error: \(error.description)\n", stderr)
            if error.showUsage {
                fputs(Self.usageText, stderr)
            }
            exit(1)
        } catch {
            fputs("Fatal error: \(error)\n", stderr)
            exit(1)
        }
    }

    public enum CLIError: Error, CustomStringConvertible, Sendable, Equatable {
        case missingCommand
        case unknownCommand(String)
        case missingValue(flag: String)
        case unknownOption(String)
        case missingPositional(String)
        case invalidOptionValue(flag: String, value: String)
        case executionFailed(String)

        public var showUsage: Bool {
            switch self {
            case .missingCommand, .unknownCommand, .missingValue, .unknownOption, .missingPositional, .invalidOptionValue:
                return true
            case .executionFailed:
                return false
            }
        }

        public var description: String {
            switch self {
            case .missingCommand:
                return "No command specified."
            case .unknownCommand(let cmd):
                return "Unknown command '\(cmd)'."
            case .missingValue(let flag):
                return "Missing value for option '\(flag)'."
            case .unknownOption(let opt):
                return "Unknown option '\(opt)'."
            case .missingPositional(let name):
                return "Missing required argument <\(name)>."
            case .invalidOptionValue(let flag, let value):
                return "Invalid value '\(value)' for option '\(flag)'."
            case .executionFailed(let message):
                return message
            }
        }
    }

    /// One page of the `--diagnostics-dir` text-line dump.
    struct LineDumpEntry: Codable {
        var profile: RunningHeaderDetector.PageLineProfile
        var anchor: PageTopAnchor?
        var registration: PageVerticalRegistration?
    }

    public struct ProcessOptions: Sendable, Equatable {
        public var inputPDFPath: String
        public var outputPDFPath: String
        public var manifestPath: String?
        public var diagnosticsDirPath: String?
        public var splitMode: PageSplitMode = .automatic
        public var gutterTrimWidth: Int = 24
        public var autoPruneBlankPages: Bool = true
        public var margins: PublicationMargins = .publicationDefault
        public var pageSize: PhysicalSizeSpec? = nil
        public var contentBoxSize: PhysicalSizeSpec? = nil
        public var inputDPI: Int? = nil
        public var pageRange: ClosedRange<Int>?
        public var excludedPages: Set<Int> = []
        public var firstPageSide: MarginHarmonizer.PageSide = .recto
        public var enableDewarp: Bool = true
        public var enablePerspectiveRectification: Bool = true
        public var enableDeskMasking: Bool = true
        public var enableBorderFallback: Bool = true
        public var enableOCR: Bool = true
        public var ocrEngineType: OCREngineType? = nil
        public var ocrLanguages: [String] = ["en-US"]
        public var tessdataDir: String? = nil
        public var binarizationMethod: AdaptiveBinarizer.Method = .wolfJolion
        public var usePortableBackend: Bool = false
        public var renderAllDiagnostics: Bool = false
        public var verticalRegistrationMode: VerticalRegistrationMode = .automatic
        public var enableRunningHeaderDetection: Bool = true
        public var enableDimensionConsensus: Bool = true
        public var outlierTolerance: Double = 0.08

        public init(inputPDFPath: String, outputPDFPath: String) {
            self.inputPDFPath = inputPDFPath
            self.outputPDFPath = outputPDFPath
        }
    }

    public static func run(arguments: [String]) async throws {
        guard let first = arguments.first else {
            throw CLIError.missingCommand
        }

        if first == "--help" || first == "-h" || first == "help" {
            print(usageText)
            return
        }

        let remaining = Array(arguments.dropFirst())
        switch first {
        case "process":
            let options = try parseProcessOptions(remaining)
            try await executeProcess(options)
        case "inspect":
            try executeInspect(remaining)
        default:
            throw CLIError.unknownCommand(first)
        }
    }

    public static func parseProcessOptions(_ args: [String]) throws(CLIError) -> ProcessOptions {
        var inputPath: String? = nil
        var outputPath: String? = nil
        var manifestPath: String? = nil
        var diagnosticsDirPath: String? = nil
        var splitMode: PageSplitMode = .automatic
        var gutterTrimWidth = 24
        var autoPruneBlankPages = true
        var margins: PublicationMargins = .publicationDefault
        var pageSize: PhysicalSizeSpec? = nil
        var contentBoxSize: PhysicalSizeSpec? = nil
        var inputDPI: Int? = nil
        var pageRange: ClosedRange<Int>? = nil
        var excludedPages: Set<Int> = []
        var firstPageSide: MarginHarmonizer.PageSide = .recto
        var enableDewarp = true
        var enablePerspective = true
        var enableDeskMask = true
        var enableBorderFallback = true
        var enableOCR = true
        var ocrEngineType: OCREngineType? = nil
        var ocrLanguages: [String] = ["en-US"]
        var tessdataDir: String? = nil
        var binarizeMethod: AdaptiveBinarizer.Method = .wolfJolion
        var usePortable = false
        var allDiagnostics = false
        var verticalMode: VerticalRegistrationMode = .automatic
        var enableHeaderDetection = true
        var dimensionConsensus = true
        var outlierTolerance = 0.08

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "-o", "--output":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                outputPath = args[i + 1]
                i += 2
            case "--manifest":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                manifestPath = args[i + 1]
                i += 2
            case "--diagnostics-dir":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                diagnosticsDirPath = args[i + 1]
                i += 2
            case "--split-mode":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                let val = args[i + 1].lowercased()
                switch val {
                case "auto", "automatic":
                    splitMode = .automatic
                case "single", "singlepage":
                    splitMode = .singlePage
                case "spread", "twopage", "twopagespread":
                    splitMode = .twoPageSpread
                default:
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                i += 2
            case "--gutter-trim-width", "--gutter-trim":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                guard let val = Int(args[i + 1]), val >= 0 else {
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                gutterTrimWidth = val
                i += 2
            case "--margins", "--margin":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                guard let parsed = PublicationMargins.parse(args[i + 1]) else {
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                margins = parsed
                i += 2
            case "--page-size", "--trim-size":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                guard let parsed = PhysicalSizeSpec.parse(args[i + 1]) else {
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                pageSize = parsed
                i += 2
            case "--content-box-size", "--content-size", "--text-box-size":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                guard let parsed = PhysicalSizeSpec.parse(args[i + 1]) else {
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                contentBoxSize = parsed
                i += 2
            case "--input-dpi", "--source-dpi":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                guard let val = Int(args[i + 1]), val >= 18, val <= 4800 else {
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                inputDPI = val
                i += 2
            case "--page-range", "--pages":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                let val = args[i + 1]
                let parts = val.components(separatedBy: CharacterSet(charactersIn: "-."))
                    .filter { !$0.isEmpty }
                if parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]), start <= end, start >= 1 {
                    pageRange = start...end
                } else if parts.count == 1, let single = Int(parts[0]), single >= 1 {
                    pageRange = single...single
                } else {
                    throw .invalidOptionValue(flag: arg, value: val)
                }
                i += 2
            case "--exclude-pages", "--exclude-page", "--exclude":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                let val = args[i + 1]
                let pageStrs = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                var parsedSet = Set<Int>()
                for pStr in pageStrs {
                    guard let pNum = Int(pStr), pNum >= 1 else {
                        throw .invalidOptionValue(flag: arg, value: val)
                    }
                    parsedSet.insert(pNum)
                }
                excludedPages = parsedSet
                i += 2
            case "--first-page-side", "--first-side":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                let val = args[i + 1].lowercased()
                switch val {
                case "recto", "right":
                    firstPageSide = .recto
                case "verso", "left":
                    firstPageSide = .verso
                default:
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                i += 2
            case "--ocr-engine", "--engine":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                let val = args[i + 1].lowercased()
                switch val {
                case "apple", "applevision", "vision":
                    ocrEngineType = .apple
                case "tesseract", "tess":
                    ocrEngineType = .tesseract
                case "dual", "hybrid", "both":
                    ocrEngineType = .dual
                default:
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                i += 2
            case "--ocr-languages", "--ocr-lang", "--languages", "--lang":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                let val = args[i + 1]
                let parsed = val.split(whereSeparator: { $0 == "," || $0 == "+" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard !parsed.isEmpty else {
                    throw .invalidOptionValue(flag: arg, value: val)
                }
                ocrLanguages = parsed
                i += 2
            case "--tessdata-dir", "--tessdata":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                tessdataDir = args[i + 1]
                i += 2
            case "--binarize":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                let val = args[i + 1].lowercased()
                switch val {
                case "wolf", "wolf-jolion", "wolfjolion":
                    binarizeMethod = .wolfJolion
                case "sauvola":
                    binarizeMethod = .sauvola
                default:
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                i += 2
            case "--no-dewarp":
                enableDewarp = false
                i += 1
            case "--no-perspective", "--no-quad":
                enablePerspective = false
                i += 1
            case "--no-desk-mask":
                enableDeskMask = false
                i += 1
            case "--vertical-anchor":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                switch args[i + 1].lowercased() {
                case "auto", "automatic":
                    verticalMode = .automatic
                case "box-top", "boxtop", "off":
                    verticalMode = .boxTop
                default:
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                i += 2
            case "--dimension-consensus":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                switch args[i + 1].lowercased() {
                case "auto", "automatic", "on":
                    dimensionConsensus = true
                case "off":
                    dimensionConsensus = false
                default:
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                i += 2
            case "--outlier-tolerance":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                guard let value = Double(args[i + 1]), value >= 0.02, value <= 0.5 else {
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                outlierTolerance = value
                i += 2
            case "--no-running-headers":
                enableHeaderDetection = false
                i += 1
            case "--no-border-fallback":
                enableBorderFallback = false
                i += 1
            case "--no-auto-prune", "--no-blank-pruning":
                autoPruneBlankPages = false
                i += 1
            case "--no-ocr":
                enableOCR = false
                i += 1
            case "--portable-backend":
                usePortable = true
                i += 1
            case "--all-diagnostics":
                allDiagnostics = true
                i += 1
            default:
                if arg.hasPrefix("-") {
                    throw .unknownOption(arg)
                }
                if inputPath == nil {
                    inputPath = arg
                } else if outputPath == nil {
                    outputPath = arg
                } else {
                    throw .unknownOption(arg)
                }
                i += 1
            }
        }

        guard let validInput = inputPath else {
            throw .missingPositional("input-pdf")
        }
        guard let validOutput = outputPath else {
            throw .missingPositional("output-pdf (-o)")
        }

        var opts = ProcessOptions(inputPDFPath: validInput, outputPDFPath: validOutput)
        opts.manifestPath = manifestPath
        opts.diagnosticsDirPath = diagnosticsDirPath
        opts.splitMode = splitMode
        opts.gutterTrimWidth = gutterTrimWidth
        opts.autoPruneBlankPages = autoPruneBlankPages
        opts.margins = margins
        opts.pageSize = pageSize
        opts.contentBoxSize = contentBoxSize
        opts.inputDPI = inputDPI
        opts.pageRange = pageRange
        opts.excludedPages = excludedPages
        opts.firstPageSide = firstPageSide
        opts.enableDewarp = enableDewarp
        opts.enablePerspectiveRectification = enablePerspective
        opts.enableDeskMasking = enableDeskMask
        opts.enableBorderFallback = enableBorderFallback
        opts.enableOCR = enableOCR
        opts.ocrEngineType = ocrEngineType
        opts.ocrLanguages = ocrLanguages
        opts.tessdataDir = tessdataDir
        opts.binarizationMethod = binarizeMethod
        opts.usePortableBackend = usePortable
        opts.renderAllDiagnostics = allDiagnostics
        opts.verticalRegistrationMode = verticalMode
        opts.enableRunningHeaderDetection = enableHeaderDetection
        opts.enableDimensionConsensus = dimensionConsensus
        opts.outlierTolerance = outlierTolerance
        return opts
    }

    /// Resolves the effective OCR engine type based on options and language requirements.
    public static func resolveOCREngineType(options: ProcessOptions) -> OCREngineType {
        if let explicit = options.ocrEngineType {
            return explicit
        }
        if options.usePortableBackend {
            return .tesseract
        }
        let classicalLangs = Set(["grc", "deu_frak", "frk", "lat", "la", "el-polyton"])
        let hasClassical = options.ocrLanguages.contains { lang in
            let lower = lang.lowercased()
            return classicalLangs.contains(lower) || lower.hasPrefix("grc") || lower.hasPrefix("deu_frak") || lower.hasPrefix("frk")
        }
        if hasClassical {
            return .dual
        }
        return .apple
    }

    /// Constructs the appropriate OCR engine based on options.
    public static func makeOCREngine(options: ProcessOptions) -> (any OCREngine)? {
        guard options.enableOCR else { return nil }
        let engineType = resolveOCREngineType(options: options)
        switch engineType {
        case .apple:
            return AppleVisionOCREngine()
        case .tesseract:
            return TesseractOCREngine(tessdataPath: options.tessdataDir)
        case .dual:
            let primary = AppleVisionOCREngine()
            let secondary = TesseractOCREngine(tessdataPath: options.tessdataDir)
            return DualOCREngine(primary: primary, secondary: secondary)
        }
    }

    public static func executeProcess(_ options: ProcessOptions) async throws {
        let inputURL = URL(fileURLWithPath: options.inputPDFPath)
        let outputURL = URL(fileURLWithPath: options.outputPDFPath)

        let reader: ApplePDFSourceReader
        do {
            reader = try ApplePDFSourceReader(url: inputURL)
        } catch {
            throw CLIError.executionFailed("Failed to open input PDF '\(inputURL.path)': \(error)")
        }

        let writer: ApplePDFDocumentWriter
        do {
            writer = try ApplePDFDocumentWriter(destinationURL: outputURL)
        } catch {
            throw CLIError.executionFailed("Failed to initialize output PDF '\(outputURL.path)': \(error)")
        }

        let accelerator: any ComputeAccelerator = options.usePortableBackend
            ? PortableComputeAccelerator()
            : MetalComputeAccelerator()
        let ocrEngine: (any OCREngine)? = makeOCREngine(options: options)

        // Load existing manifest if `--manifest` was specified and exists on disk
        var existingManifest: BookProcessingManifest? = nil
        if let manifestPath = options.manifestPath, FileManager.default.fileExists(atPath: manifestPath) {
            let manifestURL = URL(fileURLWithPath: manifestPath)
            let data = try Data(contentsOf: manifestURL)
            existingManifest = try JSONDecoder().decode(BookProcessingManifest.self, from: data)
            print("Loaded existing manifest from \(manifestURL.path)")
        }

        let binConfig = AdaptiveBinarizer.Configuration(
            method: options.binarizationMethod,
            backgroundNormalization: BackgroundNormalizer.Configuration()
        )
        let harmConfig = MarginHarmonizer.Configuration(
            margins: options.margins,
            targetPageSize: options.pageSize,
            targetContentBoxSize: options.contentBoxSize
        )
        let pipeConfig = BookPipelineCoordinator.Configuration(
            processingDPI: 600,
            outputDPI: 300,
            inputDPI: options.inputDPI,
            splitMode: options.splitMode,
            gutterTrimWidth: options.gutterTrimWidth,
            autoPruneBlankPages: options.autoPruneBlankPages,
            enableDewarp: options.enableDewarp,
            binarizerConfiguration: binConfig,
            harmonizerConfiguration: harmConfig,
            firstPageSide: options.firstPageSide,
            pageRange: options.pageRange,
            excludedPages: options.excludedPages,
            ocrLanguages: options.ocrLanguages,
            enablePerspectiveRectification: options.enablePerspectiveRectification,
            enableDeskMasking: options.enableDeskMasking,
            enableBorderFallback: options.enableBorderFallback,
            enableRunningHeaderDetection: options.enableRunningHeaderDetection,
            verticalRegistrationConfiguration: VerticalRegistration.Configuration(mode: options.verticalRegistrationMode),
            dimensionConsensusConfiguration: DimensionConsensus.Configuration(
                enabled: options.enableDimensionConsensus,
                toleranceFraction: options.outlierTolerance
            )
        )

        let coordinator = BookPipelineCoordinator(configuration: pipeConfig)
        print("Processing '\(inputURL.lastPathComponent)' (\(reader.pageCount) source page(s))...")

        let result: BookPipelineCoordinator.PipelineOutput
        do {
            result = try await coordinator.processBook(
                reader: reader,
                writer: writer,
                accelerator: accelerator,
                ocrEngine: ocrEngine,
                existingManifest: existingManifest
            ) { completed, total in
                print("  Rasterized source page \(completed)/\(total) at 600 DPI")
            }
        } catch {
            throw CLIError.executionFailed("Pipeline failed: \(error)")
        }

        if result.manifest.physicalScaleAmbiguous {
            let pageSizeInches = result.manifest.fontScaleEstimate?.estimatedSinglePageSizeInches
                ?? Size2D(
                    width: Double(result.manifest.canonicalCanvasSizeAtProcessingDPI.width) / Double(max(1, result.manifest.processingDPI)),
                    height: Double(result.manifest.canonicalCanvasSizeAtProcessingDPI.height) / Double(max(1, result.manifest.processingDPI))
                )
            let trimW = String(format: "%.2f", pageSizeInches.width)
            let trimH = String(format: "%.2f", pageSizeInches.height)
            print("WARNING [physicalScaleAmbiguous=true]: Physical page scale could not be determined automatically with high confidence (estimated height > 14\"). Clamped output canvas to \(trimW)\" x \(trimH)\" to prevent billboard pages. Escalate to user and re-run with --page-size (e.g. octavo, trade-paperback, a5, a4, letter, or <w>x<h>) or --input-dpi.")
        } else if let scaleEst = result.manifest.fontScaleEstimate, scaleEst.wasAutoRescaled {
            let scaleStr = String(format: "%.3fx", scaleEst.appliedScaleCorrectionFactor)
            let optDPIStr = String(format: "%.0f", scaleEst.inferredSourceOpticalDPI)
            let trimW = String(format: "%.2f", scaleEst.estimatedSinglePageSizeInches.width)
            let trimH = String(format: "%.2f", scaleEst.estimatedSinglePageSizeInches.height)
            print("Auto-rescaled uncalibrated source (\(scaleStr), inferred ~\(optDPIStr) optical DPI -> \(trimW)\" x \(trimH)\" canonical page)")
        }

        // Determine where to save the JSON manifest
        let targetManifestURL: URL?
        if let explicitManifest = options.manifestPath {
            targetManifestURL = URL(fileURLWithPath: explicitManifest)
        } else if let diagDir = options.diagnosticsDirPath {
            let stem = outputURL.deletingPathExtension().lastPathComponent
            targetManifestURL = URL(fileURLWithPath: diagDir).appendingPathComponent("\(stem)-manifest.json")
        } else {
            targetManifestURL = nil
        }

        if let manifestURL = targetManifestURL {
            let parent = manifestURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let jsonData = try encoder.encode(result.manifest)
            try jsonData.write(to: manifestURL, options: .atomic)
            print("Saved processing manifest to \(manifestURL.path)")
        }

        // Render diagnostic PNG overlays if `--diagnostics-dir` was requested
        if let diagDir = options.diagnosticsDirPath {
            let diagDirURL = URL(fileURLWithPath: diagDir)
            try FileManager.default.createDirectory(at: diagDirURL, withIntermediateDirectories: true)
            let overlayRenderer = DiagnosticOverlayRenderer()
            var renderedCount = 0

            for (idx, record) in result.manifest.pages.enumerated() {
                if options.renderAllDiagnostics || record.flaggedLowConfidence {
                    let filename = String(format: "page-%04d-diag.png", record.outputPageIndex + 1)
                    let fileURL = diagDirURL.appendingPathComponent(filename)
                    try overlayRenderer.writePNGOverlay(
                        bitmap: result.cleanedBitmapsAtProcessingDPI[idx],
                        contentBox: record.layoutPlan.sourceContentBox,
                        retainedClusterBoxes: record.layoutPlan.retainedClusterBoxes,
                        rejectedBoxes: record.layoutPlan.rejectedClusterBoxes,
                        tracedLines: record.tracedLines,
                        to: fileURL
                    )
                    renderedCount += 1
                }
            }
            print("Wrote \(renderedCount) diagnostic overlay PNG(s) to \(diagDirURL.path)")

            // Text-line dump: the lines each page's running-header detection measured, with anchors.
            if !result.lineProfiles.isEmpty {
                let stem = outputURL.deletingPathExtension().lastPathComponent
                let linesURL = diagDirURL.appendingPathComponent("\(stem)-lines.json")
                let dump = zip(result.lineProfiles, result.manifest.pages).map { profile, record in
                    LineDumpEntry(profile: profile, anchor: record.topAnchor, registration: record.registration)
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(dump).write(to: linesURL, options: .atomic)
                print("Wrote text-line dump to \(linesURL.path)")
            }
        }

        let flaggedPages = result.manifest.pages.filter(\.flaggedLowConfidence)
        print("Completed: wrote \(result.manifest.pages.count) page(s) at \(result.manifest.outputDPI) DPI to \(outputURL.path)")
        if !flaggedPages.isEmpty {
            let indices = flaggedPages.map { String($0.outputPageIndex + 1) }.joined(separator: ", ")
            print("WARNING: \(flaggedPages.count) page(s) had confidence below threshold: [\(indices)]")
        }
    }

    public static func executeInspect(_ args: [String]) throws {
        guard let manifestPath = args.first, !manifestPath.hasPrefix("-") else {
            throw CLIError.missingPositional("manifest-json")
        }
        let url = URL(fileURLWithPath: manifestPath)
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(BookProcessingManifest.self, from: data)
        print(formatManifestSummary(manifest))
    }

    private static func percent(_ fraction: Double) -> String {
        let value = Int((fraction * 100).rounded())
        return value >= 0 ? "+\(value)%" : "\(value)%"
    }

    public static func formatManifestSummary(_ manifest: BookProcessingManifest) -> String {
        var lines: [String] = []
        lines.append("=== ScanTailorReborn Manifest Summary ===")
        lines.append("Processing DPI: \(manifest.processingDPI) | Output DPI: \(manifest.outputDPI)")
        lines.append("Canonical 600 DPI Canvas: \(manifest.canonicalCanvasSizeAtProcessingDPI.width) x \(manifest.canonicalCanvasSizeAtProcessingDPI.height) px")
        lines.append("Verso Canonical Text Frame: \(manifest.versoCanonicalFrame.width) x \(manifest.versoCanonicalFrame.height) at (\(manifest.versoCanonicalFrame.minX), \(manifest.versoCanonicalFrame.minY))")
        lines.append("Recto Canonical Text Frame: \(manifest.rectoCanonicalFrame.width) x \(manifest.rectoCanonicalFrame.height) at (\(manifest.rectoCanonicalFrame.minX), \(manifest.rectoCanonicalFrame.minY))")
        if let engine = manifest.ocrEngine {
            let langs = manifest.ocrLanguages?.joined(separator: ", ") ?? "default"
            lines.append("OCR Engine: \(engine) | Languages: [\(langs)]")
        }
        var overrideParts: [String] = []
        if let inputDPI = manifest.inputDPI {
            overrideParts.append("inputDPI=\(inputDPI)")
        }
        if let pageSize = manifest.pageSize {
            overrideParts.append("pageSize=\(pageSize.description)")
        }
        if let contentBoxSize = manifest.contentBoxSize {
            overrideParts.append("contentBoxSize=\(contentBoxSize.description)")
        }
        if !overrideParts.isEmpty {
            lines.append("Dimension Overrides: \(overrideParts.joined(separator: " | "))")
        }
        if !manifest.sourcePageGeometry.isEmpty {
            let rectified = manifest.sourcePageGeometry.filter(\.rectified).count
            let fullFrame = manifest.sourcePageGeometry.filter { $0.detection?.outcome == .fullFrame }.count
            let rejected = manifest.sourcePageGeometry.filter { $0.detection?.outcome == .rejected }.count
            let manual = manifest.sourcePageGeometry.filter { $0.manualOverride != nil }.count
            lines.append("Perspective Rectification: \(rectified) rectified | \(fullFrame) full-frame | \(rejected) rejected | \(manual) manual override(s)")
            let maskRecords = manifest.sourcePageGeometry.compactMap(\.deskMask)
            let masked = maskRecords.filter { $0.mode != .skipped }.count
            let skipped = maskRecords.filter { $0.mode == .skipped }.count
            let capped = maskRecords.filter { $0.flags.contains(where: { $0.hasPrefix("capped:") }) }.count
            let meanMaskedPercent = masked > 0
                ? maskRecords.filter { $0.mode != .skipped }.map(\.maskedFraction).reduce(0, +) / Double(masked) * 100
                : 0
            lines.append("Desk Masking: \(masked) masked (mean \(String(format: "%.1f", meanMaskedPercent))%) | \(skipped) skipped | \(capped) capped")
        }
        let fallbackRecords = manifest.pages.compactMap(\.borderFallback)
        if !fallbackRecords.isEmpty {
            let excised = fallbackRecords.filter(\.didExcise).count
            let rejected = fallbackRecords.filter { !$0.didExcise && !$0.rejectedCandidates.isEmpty }.count
            let idle = fallbackRecords.count - excised - rejected
            lines.append("Border Fallback: \(excised) excised | \(idle) engaged, nothing found | \(rejected) rejected")
        }
        if let headerModel = manifest.runningHeaderModel {
            let anchors = manifest.pages.compactMap(\.topAnchor)
            let sides = headerModel.sides
                .map { "\($0.side.rawValue) \($0.headerPageCount)/\($0.pageCount)" }
                .joined(separator: " · ")
            let bodyAnchored = anchors.filter { $0.kind == .bodyBaseline }.count
            let unanchored = anchors.filter { $0.kind == .none }.count
            lines.append("Running Headers: \(sides.isEmpty ? "no pages" : sides) | \(bodyAnchored) body-anchored | \(unanchored) none")
        }
        if let registration = manifest.verticalRegistration {
            switch registration.mode {
            case .boxTop:
                lines.append("Vertical Registration: box-top (registration disabled)")
            case .automatic:
                var text = "Vertical Registration: \(registration.headerPageCount) header · \(registration.bodyPageCount) body · \(registration.preservedPageCount) preserved · \(registration.boxTopPageCount) box-top"
                if registration.manualPageCount > 0 { text += " · \(registration.manualPageCount) manual" }
                if let before = registration.headerSpreadBeforePixels, let after = registration.headerSpreadAfterPixels {
                    text += " | header spread \(before)→\(after) px"
                }
                if let before = registration.bodySpreadBeforePixels, let after = registration.bodySpreadAfterPixels {
                    text += " | body spread \(before)→\(after) px"
                }
                lines.append(text)
            }
        }
        if let consensus = manifest.dimensionConsensus {
            if !consensus.applied {
                lines.append("Dimension Consensus: not applied (\(consensus.note ?? "off"))")
            } else {
                var text = "Dimension Consensus: \(consensus.canonicalPageCount) canonical · \(consensus.outlierPageCount) outlier"
                let described = manifest.pages.compactMap { page -> String? in
                    guard let d = page.dimension, d.dimensionClass == .outlier else { return nil }
                    let kinds = d.kinds.map(\.rawValue).joined(separator: "/")
                    let scale = d.scaleMismatch ? " scale≠" : ""
                    return "p\(page.outputPageIndex + 1) \(kinds) \(Self.percent(d.widthDeviation)) W \(Self.percent(d.heightDeviation)) H\(scale)"
                }
                if !described.isEmpty { text += " (" + described.prefix(6).joined(separator: "; ") + (described.count > 6 ? "; …" : "") + ")" }
                if consensus.ambiguous { text += " | ambiguous: sizes not trusted" }
                if !consensus.splitVetoedSourcePages.isEmpty {
                    text += " | not split: scans " + consensus.splitVetoedSourcePages.map { String($0 + 1) }.joined(separator: ",")
                }
                lines.append(text)
            }
        }
        if manifest.physicalScaleAmbiguous {
            lines.append("Physical Scale Status: AMBIGUOUS (physicalScaleAmbiguous=true) — escalate to user for --page-size (octavo, trade-paperback, a5, a4, letter) or --input-dpi")
        }
        if let scale = manifest.fontScaleEstimate {
            let modeStr: String
            if scale.wasAntiBillboardClamped {
                modeStr = String(
                    format: "anti-billboard clamped %.3fx",
                    scale.appliedScaleCorrectionFactor
                )
            } else if scale.wasAutoRescaled {
                modeStr = String(
                    format: "auto-rescaled %.3fx (inferred %.0f DPI)",
                    scale.appliedScaleCorrectionFactor,
                    scale.inferredSourceOpticalDPI
                )
            } else {
                modeStr = "calibrated 1.000x"
            }
            let xH = String(format: "%.1f", scale.medianXHeightPixels)
            let capH = String(format: "%.1f", scale.medianCapHeightPixels)
            let strokeW = String(format: "%.1f", scale.medianStrokeWidthPixels)
            let bodyPt = String(format: "%.1f", scale.estimatedBodyPointSize)
            let pageIn = String(
                format: "%.2f\" x %.2f\"",
                scale.estimatedSinglePageSizeInches.width,
                scale.estimatedSinglePageSizeInches.height
            )
            lines.append("Typography & Scale: \(modeStr) | body≈\(bodyPt)pt (x=\(xH)px, cap=\(capH)px, stroke=\(strokeW)px @ \(scale.processingDPI) DPI) | page=\(pageIn)")
        }
        lines.append("Total Output Pages: \(manifest.pages.count) (from \(manifest.sourcePageSplits.count) source scan(s))")
        if !manifest.prunedPages.isEmpty {
            lines.append("Pruned Blank Sub-Pages: \(manifest.prunedPages.count)")
            for pruned in manifest.prunedPages {
                lines.append("  - Source scan #\(pruned.sourcePageIndex + 1) (\(pruned.splitSide.rawValue)): \(pruned.reason)")
            }
        }
        lines.append("-----------------------------------------")
        for page in manifest.pages {
            let skewStr = String(format: "%+.2f°", page.skewAngleDegrees)
            let dewarpStr = page.dewarpApplied ? String(format: "yes (sag %.1fpx)", page.dewarpVerticalSagPixels) : "bypass"
            let confStr = String(format: "%.2f", page.overallConfidence)
            let flagStr = page.flaggedLowConfidence ? " [FLAGGED]" : ""
            lines.append("Page \(page.outputPageIndex + 1) (src #\(page.sourcePageIndex + 1), \(page.bookSide.rawValue)): tier=\(page.layoutPlan.tier.rawValue), skew=\(skewStr), dewarp=\(dewarpStr), conf=\(confStr)\(flagStr)")
        }
        return lines.joined(separator: "\n")
    }

    public static let usageText = """
    USAGE:
      scantailor-cli process <input.pdf> -o <output.pdf> [options]
      scantailor-cli inspect <manifest.json>

    PROCESS OPTIONS:
      -o, --output <path>          Output 300 DPI 1-bit searchable PDF path (required)
      --manifest <path.json>       Read/write JSON processing manifest (supports per-page overrides)
      --diagnostics-dir <dir>      Directory for manifest and PNG diagnostic overlays
      --all-diagnostics            Render PNG diagnostic overlays for all pages (not just low-confidence)
      --split-mode <mode>          Spread split mode: automatic (default), single, spread
      --gutter-trim-width <px>     Central gutter strip trimming width in px at 600 DPI (default: 24)
      --margins <spec>             Publication margins, e.g. "top=0.25in,bottom=0.25in,left=0.5in,right=0.5in"
                                   (supports in, pt, mm, cm, px; inner/gutter, outer)
      --page-size <spec>           Target output page trim size: preset (octavo, trade-paperback, royal-octavo,
                                   crown-octavo, a5, a4, b5, letter) or <w>x<h> (e.g. 6x9in, 5.5x8.5in, 148x210mm)
      --content-box-size <w>x<h>   Explicit canonical text block dimensions (e.g. 4.5x7.5in, 114x190mm)
      --input-dpi <dpi>            Explicit genuine source optical DPI (overrides 72/96-DPI wrapper metadata)
      --page-range <range>         1-based source scan range (e.g. 1-10, 5..20)
      --exclude-pages <list>       Comma-separated 1-based source scan indices to skip (e.g. 1,2,5)
      --first-page-side <side>     Initial logical book side: recto (default) or verso
      --binarize <method>          Adaptive thresholding: wolf (default) or sauvola
      --no-auto-prune              Disable automatic pruning of blank sub-page slices
      --no-dewarp                  Disable 3D cubic-sheet curvature dewarping
      --no-perspective             Disable document-quad detection and perspective rectification (alias --no-quad)
      --no-desk-mask               Disable residual desk/background masking before binarization
      --no-border-fallback         Disable the macro-cluster border fallback on marginal-geometry pages
      --vertical-anchor <mode>     Vertical page registration: auto (default; align full-body pages on their running
                                   header or first body baseline) or box-top (legacy; align content-box tops)
      --dimension-consensus <mode> Group pages by size: auto (default; covers, plates and foldouts of a different size
                                   are kept out of the book's page size) or off
      --outlier-tolerance <frac>   Relative size difference that makes a page an outlier (default 0.08)
      --no-running-headers         Disable running-header detection (and with it, vertical registration)
      --no-ocr                     Disable OCR searchable text layer
      --ocr-engine <engine>        OCR engine: apple (default on macOS), tesseract, dual
      --ocr-languages <langs>      Comma or plus-separated language codes, e.g. "grc+lat", "en-US,de-DE", "frk"
                                   (aliases: --languages, --ocr-lang)
      --tessdata-dir <path>        Custom tessdata directory containing .traineddata files
      --portable-backend           Use pure-Swift portable compute accelerator instead of Metal GPU
    """
}
