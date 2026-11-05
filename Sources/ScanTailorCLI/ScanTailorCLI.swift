import Foundation
import MachO
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
        case invalidCombination(String)

        public var showUsage: Bool {
            switch self {
            case .missingCommand, .unknownCommand, .missingValue, .unknownOption, .missingPositional, .invalidOptionValue, .invalidCombination:
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
            case .invalidCombination(let message):
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
        public var coverHandling: CoverHandling = .auto
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
        /// Exact outlier pages, 1-based output pages (`--outlier-pages`); `nil` is automatic, empty is "none".
        public var outlierPages: Set<Int>? = nil
        public var isolateOutlierCanvases: Bool = true
        /// Scan references (`s45L`) in `--outlier-pages`; they join `outlierPages` as the exact outlier list.
        public var outlierScanRefs: [PageReference] = []
        /// Adjustments file (`--apply-manifest`): per-scan and per-page edits, plus a `book` section of options.
        public var applyManifestPath: String? = nil
        /// The adjustments read from `applyManifestPath` (filled in by ``loadAdjustments(into:arguments:)``).
        public var adjustments: PageAdjustments = .empty
        /// A complete earlier manifest given to `--apply-manifest` (read-only; its per-page overrides are applied).
        public var priorManifestPath: String? = nil
        /// Stop early (`--stop-after layout`): no output PDF, OCR or rendering.
        public var stopAfter: PipelineStop? = nil
        /// Write layout contact sheets into the diagnostics directory (`--layout-sheets`; automatic with `--stop-after`).
        public var layoutSheets: Bool = false
        /// Scans and pages processed at the same time (`--jobs`).
        public var jobs: Int = ScanTailorCLI.defaultJobs
        /// Reuse results of earlier runs (`--no-cache` turns it off).
        public var useCache: Bool = true
        /// Cache directory (`--cache-dir`; `nil` is ``PipelineCacheOptions/defaultDirectory``).
        public var cacheDirPath: String? = nil
        /// Print the per-stage timing table (`--timings`).
        public var showTimings: Bool = false

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
            let options = try loadAdjustments(into: try parseProcessOptions(remaining), arguments: remaining)
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
        var coverHandling: CoverHandling = .auto
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
        var outlierPages: Set<Int>? = nil
        var isolateOutlierCanvases = true
        var outlierScanRefs: [PageReference] = []
        var applyManifestPath: String? = nil
        var stopAfter: PipelineStop? = nil
        var layoutSheets = false
        var jobs = defaultJobs
        var useCache = true
        var cacheDirPath: String? = nil
        var showTimings = false

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
            case "--outlier-pages":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                guard let spec = Self.parseOutlierSpec(args[i + 1]) else {
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                outlierPages = (spec.pages.isEmpty && !spec.scans.isEmpty) ? nil : spec.pages
                outlierScanRefs = spec.scans
                i += 2
            case "--apply-manifest", "--adjustments":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                applyManifestPath = args[i + 1]
                i += 2
            case "--stop-after":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                guard let stage = PipelineStop(rawValue: args[i + 1].lowercased()) else {
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                stopAfter = stage
                i += 2
            case "--layout-sheets":
                layoutSheets = true
                i += 1
            case "--jobs", "-j":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                guard let n = Int(args[i + 1]), n >= 1 else { throw .invalidOptionValue(flag: arg, value: args[i + 1]) }
                jobs = n
                i += 2
            case "--cache-dir":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                cacheDirPath = args[i + 1]
                useCache = true
                i += 2
            case "--no-cache":
                useCache = false
                i += 1
            case "--timings":
                showTimings = true
                i += 1
            case "--outlier-canvas":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                switch args[i + 1].lowercased() {
                case "isolated": isolateOutlierCanvases = true
                case "shared": isolateOutlierCanvases = false
                default: throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
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
            case "--cover-handling":
                guard i + 1 < args.count else { throw .missingValue(flag: arg) }
                guard let mode = CoverHandling(rawValue: args[i + 1].lowercased()) else {
                    throw .invalidOptionValue(flag: arg, value: args[i + 1])
                }
                coverHandling = mode
                i += 2
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
        if outputPath == nil, stopAfter != nil {
            // A stopped run writes no PDF; the name only gives the manifest and diagnostics their stem.
            outputPath = ((validInput as NSString).deletingPathExtension) + "-layout.pdf"
        }
        guard let validOutput = outputPath else {
            throw .missingPositional("output-pdf (-o)")
        }
        if stopAfter != nil && manifestPath == nil && diagnosticsDirPath == nil {
            throw .invalidCombination("--stop-after writes no PDF, so it needs --manifest <path.json> or --diagnostics-dir <dir> to keep its results.")
        }
        if layoutSheets && diagnosticsDirPath == nil {
            throw .invalidCombination("--layout-sheets needs --diagnostics-dir <dir> to hold the sheets.")
        }

        var opts = ProcessOptions(inputPDFPath: validInput, outputPDFPath: validOutput)
        opts.manifestPath = manifestPath
        opts.diagnosticsDirPath = diagnosticsDirPath
        opts.splitMode = splitMode
        opts.gutterTrimWidth = gutterTrimWidth
        opts.autoPruneBlankPages = autoPruneBlankPages
        opts.coverHandling = coverHandling
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
        opts.outlierPages = outlierPages
        opts.isolateOutlierCanvases = isolateOutlierCanvases
        opts.outlierScanRefs = outlierScanRefs
        opts.applyManifestPath = applyManifestPath
        opts.stopAfter = stopAfter
        opts.layoutSheets = layoutSheets || (stopAfter != nil && diagnosticsDirPath != nil)
        opts.jobs = jobs
        opts.useCache = useCache
        opts.cacheDirPath = cacheDirPath
        opts.showTimings = showTimings
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
        if let priorPath = options.priorManifestPath {
            // A complete manifest given to --apply-manifest: its per-page overrides are applied (read-only).
            let data = try Data(contentsOf: URL(fileURLWithPath: priorPath))
            existingManifest = try JSONDecoder().decode(BookProcessingManifest.self, from: data)
            print("Applying per-page overrides from manifest \(priorPath)")
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
            coverHandling: options.coverHandling,
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
                toleranceFraction: options.outlierTolerance,
                manualOutlierPages: options.outlierPages.map { Set($0.map { $0 - 1 }) }
            ),
            isolateOutlierCanvases: options.isolateOutlierCanvases,
            adjustments: options.adjustments,
            manualOutlierReferences: options.outlierScanRefs,
            stopAfter: options.stopAfter,
            jobs: options.jobs,
            cache: options.useCache
                ? PipelineCacheOptions(
                    directory: options.cacheDirPath.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? PipelineCacheOptions.defaultDirectory,
                    codeVersion: buildIdentity(),
                    sourceFingerprint: PipelineCacheOptions.fingerprint(ofFileAt: inputURL)
                )
                : nil
        )

        let coordinator = BookPipelineCoordinator(configuration: pipeConfig)
        print("Processing '\(inputURL.lastPathComponent)' (\(reader.pageCount) source page(s))...")

        let result: BookPipelineCoordinator.PipelineOutput
        do {
            if options.stopAfter != nil {
                result = try await coordinator.processBook(
                    reader: reader,
                    writer: DiscardingPDFWriter(),
                    accelerator: accelerator,
                    ocrEngine: ocrEngine,
                    existingManifest: existingManifest
                ) { completed, total in
                    print("  Processed scan \(completed)/\(total)")
                }
            } else {
                let writer: ApplePDFDocumentWriter
                do {
                    writer = try ApplePDFDocumentWriter(destinationURL: outputURL)
                } catch {
                    throw CLIError.executionFailed("Failed to initialize output PDF '\(outputURL.path)': \(error)")
                }
                result = try await coordinator.processBook(
                    reader: reader,
                    writer: writer,
                    accelerator: accelerator,
                    ocrEngine: ocrEngine,
                    existingManifest: existingManifest
                ) { completed, total in
                    print("  Processed scan \(completed)/\(total)")
                }
            }
        } catch let error as CLIError {
            throw error
        } catch {
            throw CLIError.executionFailed("Pipeline failed: \(error)")
        }

        if let report = result.manifest.adjustments {
            print(Self.formatAdjustmentReport(report))
        }
        if let run = result.manifest.run {
            if let line = Self.formatCacheLine(run) { print(line) }
            if options.showTimings { print(Self.formatTimings(run)) }
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

        if options.layoutSheets, let diagDir = options.diagnosticsDirPath {
            let diagDirURL = URL(fileURLWithPath: diagDir)
            try FileManager.default.createDirectory(at: diagDirURL, withIntermediateDirectories: true)
            do {
                let sheets = try LayoutContactSheetRenderer().renderSheets(
                    manifest: result.manifest,
                    cleanedBitmaps: result.cleanedBitmapsAtProcessingDPI
                )
                for (n, data) in sheets.enumerated() {
                    try data.write(to: diagDirURL.appendingPathComponent(String(format: "layout-sheet-%02d.png", n + 1)), options: .atomic)
                }
                print("Wrote \(sheets.count) layout contact sheet(s) to \(diagDirURL.path)")
            } catch {
                throw CLIError.executionFailed("Failed to write layout contact sheets: \(error)")
            }
        }

        let flaggedPages = result.manifest.pages.filter(\.flaggedLowConfidence)
        if options.stopAfter != nil {
            print("Stopped after the layout: \(result.manifest.pages.count) page(s) planned; no PDF was written. Inspect with: scantailor-reborn-cli inspect <manifest.json> --pages")
            if !flaggedPages.isEmpty {
                let indices = flaggedPages.map { String($0.outputPageIndex + 1) }.joined(separator: ", ")
                print("WARNING: \(flaggedPages.count) page(s) had confidence below threshold: [\(indices)]")
            }
            printReviewSummary(result.manifest)
            return
        }
        print("Completed: wrote \(result.manifest.pages.count) page(s) at \(result.manifest.outputDPI) DPI to \(outputURL.path)")
        if !flaggedPages.isEmpty {
            let indices = flaggedPages.map { String($0.outputPageIndex + 1) }.joined(separator: ", ")
            print("WARNING: \(flaggedPages.count) page(s) had confidence below threshold: [\(indices)]")
        }
        printReviewSummary(result.manifest)
    }

    /// One line naming the pages that need a look, with the command that explains why.
    private static func printReviewSummary(_ manifest: BookProcessingManifest) {
        let pages = reviewFindings(manifest).map { String($0.page) }
        guard !pages.isEmpty else { return }
        print("Pages to check (\(pages.count)): [\(pages.joined(separator: ", "))]. Reasons and adjustments-file entries: scantailor-reborn-cli inspect <manifest.json> --pages")
    }

    public static func executeInspect(_ args: [String]) throws {
        guard let manifestPath = args.first, !manifestPath.hasPrefix("-") else {
            throw CLIError.missingPositional("manifest-json")
        }
        var table = false
        var json = false
        for flag in args.dropFirst() {
            switch flag {
            case "--pages": table = true
            case "--json": json = true
            default: throw CLIError.unknownOption(flag)
            }
        }
        let url = URL(fileURLWithPath: manifestPath)
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(BookProcessingManifest.self, from: data)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(pageRows(manifest)), as: UTF8.self))
        } else if table {
            print(formatPageTable(manifest))
        } else {
            print(formatManifestSummary(manifest))
        }
    }

    /// Reads the `--apply-manifest` file, if any, into `options`: its `book` section becomes ordinary options
    /// (the command line still wins), and its `scans` and `pages` sections become the run's adjustments.
    ///
    /// A complete manifest written by an earlier run is also accepted; its per-page overrides are then applied.
    public static func loadAdjustments(into options: ProcessOptions, arguments: [String]) throws -> ProcessOptions {
        guard let path = options.applyManifestPath else { return options }
        let url = URL(fileURLWithPath: path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CLIError.executionFailed("Cannot read the adjustments file '\(url.path)': \(error.localizedDescription)")
        }
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           root["processingDPI"] != nil, root["pages"] is [Any] {
            var updated = options
            updated.priorManifestPath = path
            return updated
        }
        let adjustments: PageAdjustments
        do {
            adjustments = try PageAdjustments.parse(data, source: url.path)
        } catch {
            throw CLIError.executionFailed("\(url.lastPathComponent): \(error)")
        }
        // File options come first so that anything on the command line overrides them.
        var updated = try parseProcessOptions(adjustments.bookArguments + arguments)
        updated.adjustments = adjustments
        return updated
    }

    /// Parses `--outlier-pages`: `none`, or comma-separated 1-based output pages, ranges (`89-91`) and scan
    /// references (`s45`, `s45L`, `s45R`), for example `1,45,89-91,s120L`.
    static func parseOutlierSpec(_ text: String) -> (pages: Set<Int>, scans: [PageReference])? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed == "none" { return ([], []) }
        var pages: Set<Int> = []
        var scans: [PageReference] = []
        for part in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let token = part.trimmingCharacters(in: .whitespaces)
            if token.hasPrefix("s") {
                guard let reference = PageReference(token), case .scan = reference else { return nil }
                scans.append(reference)
                continue
            }
            let bounds = token.split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bounds.count == 1, let n = bounds[0], n >= 1 {
                pages.insert(n)
            } else if bounds.count == 2, let lo = bounds[0], let hi = bounds[1], lo >= 1, lo <= hi, hi - lo < 100_000 {
                pages.formUnion(lo...hi)
            } else {
                return nil
            }
        }
        return (pages.isEmpty && scans.isEmpty) ? nil : (pages, scans)
    }

    /// A short, readable account of what an adjustments file did.
    public static func formatAdjustmentReport(_ report: AdjustmentReport) -> String {
        var lines = ["Adjustments\(report.source.map { " (\($0))" } ?? ""): \(report.applied.count) applied, \(report.ignored.count) ignored"]
        for entry in report.applied.prefix(40) {
            lines.append("  applied  \(entry.reference): \(entry.fields.joined(separator: ", "))")
        }
        if report.applied.count > 40 { lines.append("  … and \(report.applied.count - 40) more applied") }
        for entry in report.ignored.prefix(40) {
            lines.append("  IGNORED  \(entry.reference): \(entry.reason)")
        }
        if report.ignored.count > 40 { lines.append("  … and \(report.ignored.count - 40) more ignored") }
        return lines.joined(separator: "\n")
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
                    let own = d.pdfPageSizePoints.map { String(format: " own %.1f×%.1f in", $0.width / 72, $0.height / 72) } ?? ""
                    return "p\(page.outputPageIndex + 1) \(kinds) \(Self.percent(d.widthDeviation)) W \(Self.percent(d.heightDeviation)) H\(scale)\(own)"
                }
                if !described.isEmpty { text += " (" + described.prefix(6).joined(separator: "; ") + (described.count > 6 ? "; …" : "") + ")" }
                if consensus.note == "manualList" { text += " | manual list" }
                if !consensus.ignoredManualReferences.isEmpty {
                    text += " | ignored (no such page): " + consensus.ignoredManualReferences.joined(separator: ",")
                }
                if !consensus.ignoredManualPages.isEmpty {
                    text += " | ignored (not in book): " + consensus.ignoredManualPages.map(String.init).joined(separator: ",")
                }
                if consensus.ambiguous { text += " | ambiguous: sizes not trusted" }
                if !consensus.splitByConsensusSourcePages.isEmpty {
                    text += " | split like the rest of the book: scans " + consensus.splitByConsensusSourcePages.map { String($0 + 1) }.joined(separator: ",")
                }
                if !consensus.splitVetoedSourcePages.isEmpty {
                    text += " | not split: scans " + consensus.splitVetoedSourcePages.map { String($0 + 1) }.joined(separator: ",")
                }
                lines.append(text)
            }
        }
        if let report = manifest.adjustments {
            lines.append(formatAdjustmentReport(report))
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
            lines.append("Pages left out: \(manifest.prunedPages.count)")
            for pruned in manifest.prunedPages {
                lines.append("  - Source scan #\(manifest.sourceScanNumbers.indices.contains(pruned.sourcePageIndex) ? manifest.sourceScanNumbers[pruned.sourcePageIndex] : pruned.sourcePageIndex + 1) (\(pruned.splitSide.rawValue)): \(pruned.reason)")
            }
        }
        lines.append("-----------------------------------------")
        for page in manifest.pages {
            let skewStr = String(format: "%+.2f°", page.skewAngleDegrees)
            let dewarpStr = page.dewarpApplied ? String(format: "yes (sag %.1fpx)", page.dewarpVerticalSagPixels) : "bypass"
            let confStr = String(format: "%.2f", page.overallConfidence)
            let flagStr = page.flaggedLowConfidence ? " [FLAGGED]" : ""
            lines.append("Page \(page.outputPageIndex + 1) (\(manifest.scanReference(of: page)), \(page.bookSide.rawValue)): tier=\(page.layoutPlan.tier.rawValue), skew=\(skewStr), dewarp=\(dewarpStr), conf=\(confStr)\(flagStr)")
        }
        return lines.joined(separator: "\n")
    }

    /// Default for `--jobs`: four, or fewer on a machine with fewer cores.
    public static let defaultJobs = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount))

    /// Identifies this build of the program, for the cache: the executable's Mach-O `LC_UUID`, which the linker
    /// derives from the binary's contents (falls back to the executable's size and modification date).
    public static func buildIdentity() -> String {
        if let header = _dyld_get_image_header(0), header.pointee.magic == MH_MAGIC_64 {
            var cursor = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
            for _ in 0..<header.pointee.ncmds {
                let command = cursor.loadUnaligned(as: load_command.self)
                if command.cmd == UInt32(LC_UUID) {
                    let uuid = cursor.loadUnaligned(as: uuid_command.self).uuid
                    return "uuid:" + UUID(uuid: uuid).uuidString
                }
                cursor = cursor.advanced(by: Int(command.cmdsize))
            }
        }
        let path = CommandLine.arguments.first ?? ""
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "file:\(size):\(date)"
    }

    /// One line: what the cache reused (`nil` when the cache was off).
    public static func formatCacheLine(_ run: PipelineRunReport) -> String? {
        guard let cache = run.cache else { return nil }
        var line = "Cache: \(cache.scansReused)/\(cache.scans) scans reused"
        if cache.ocrPages > 0 { line += ", OCR of \(cache.ocrReused)/\(cache.ocrPages) pages reused" }
        return line + " (\(cache.directory); --no-cache to recompute)"
    }

    /// The `--timings` table: elapsed time per pass, then work time per stage summed over the parallel jobs.
    public static func formatTimings(_ run: PipelineRunReport) -> String {
        func s(_ v: Double) -> String { String(format: "%.2f s", v) }
        let elapsed = run.timings.filter(\.isElapsed).map { "\($0.stage) \(s($0.seconds))" }.joined(separator: ", ")
        var lines = ["Timings (elapsed, \(run.jobs) job\(run.jobs == 1 ? "" : "s")): \(elapsed)"]
        let work = run.timings.filter { !$0.isElapsed }.sorted { $0.seconds > $1.seconds }
        if !work.isEmpty {
            lines.append("  Work time by stage, summed over jobs:")
            let width = work.map(\.stage.count).max() ?? 0
            for t in work {
                lines.append("    " + t.stage.padding(toLength: width, withPad: " ", startingAt: 0) + "  " + s(t.seconds))
            }
        }
        return lines.joined(separator: "\n")
    }

    public static let usageText = """
    USAGE:
      scantailor-reborn-cli process <input.pdf> -o <output.pdf> [options]
      scantailor-reborn-cli inspect <manifest.json> [--pages] [--json]

    PROCESS OPTIONS:
      -o, --output <path>          Output PDF path (300 DPI, 1-bit, searchable) (required unless --stop-after)
      --apply-manifest <file>      Apply an adjustments file (JSON) of per-scan and per-page edits; its "book" section
                                   holds ordinary options (flags on the command line win). A complete manifest from an
                                   earlier run is also accepted. See "ADJUSTMENTS FILE" below.
      --stop-after layout          Plan the layout but render, recognize and write nothing (needs --manifest or
                                   --diagnostics-dir); writes layout contact sheets into the diagnostics directory
      --layout-sheets              Also write layout contact sheets on a complete run
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
      --no-auto-prune              Keep blank pages at the start and end too (blank pages between pages are always kept)
      --cover-handling <mode>      auto (default): drop JSTOR/Project MUSE/Google Books/Internet Archive cover sheets;
                                   strip: also drop an odd-sized printed cover; keep: drop none
      --no-dewarp                  Disable 3D cubic-sheet curvature dewarping
      --no-perspective             Disable document-quad detection and perspective rectification (alias --no-quad)
      --no-desk-mask               Disable residual desk/background masking before binarization
      --no-border-fallback         Disable the macro-cluster border fallback on marginal-geometry pages
      --vertical-anchor <mode>     Vertical page registration: auto (default; align full-body pages on their running
                                   header or first body baseline) or box-top (legacy; align content-box tops)
      --dimension-consensus <mode> Group pages by size: auto (default; covers, plates and foldouts of a different size
                                   are kept out of the book's page size) or off
      --outlier-pages <list|none>  Exact outlier pages (1-based output pages and scans, e.g. 1,45,89-91,s120L);
                                   overrides automatic detection completely
      --outlier-canvas <mode>      isolated (default: each outlier gets its own page size) or shared
      --outlier-tolerance <frac>   Relative size difference that makes a page an outlier (default 0.08)
      --no-running-headers         Disable running-header detection (and with it, vertical registration)
      --no-ocr                     Disable OCR searchable text layer
      --ocr-engine <engine>        OCR engine: apple (default on macOS), tesseract, dual
      --ocr-languages <langs>      Comma or plus-separated language codes, e.g. "grc+lat", "en-US,de-DE", "frk"
                                   (aliases: --languages, --ocr-lang)
      --tessdata-dir <path>        Custom tessdata directory containing .traineddata files
      --portable-backend           Use pure-Swift portable compute accelerator instead of Metal GPU
      -j, --jobs <n>               Scans and pages processed at the same time (default: 4). Results do not depend on
                                   it; memory grows with it
      --cache-dir <dir>            Where earlier results are reused from (default: ~/Library/Caches/ScanTailorReborn).
                                   Cleaned pages are reused unless their scan or a pass-1 edit (split, splitX, skew,
                                   disableDewarp, borderFallback, rectification, desk mask) or option changed; OCR
                                   text is reused for any page whose pixels are unchanged. Safe to delete at any time
      --no-cache                   Compute everything and store nothing
      --timings                    Print elapsed time per pass and work time per stage

    ITERATING (agent or human):
      1. scantailor-reborn-cli process book.pdf --stop-after layout --diagnostics-dir d/     (fast: no PDF, no OCR)
      2. scantailor-reborn-cli inspect d/book-layout-manifest.json --pages                   (sizes and margins per page)
         and look at d/layout-sheet-01.png ...                                        (red: canonical frame,
                                                                                       green: text block, orange: outlier)
      3. Write adjustments.json, then repeat step 1 with --apply-manifest adjustments.json
         (repeats are fast: unchanged scans come from the cache)
      4. When satisfied, run without --stop-after to write the PDF (OCR is reused for unchanged pages).

    ADJUSTMENTS FILE (--apply-manifest; strict JSON; keys starting with "_" and "note" are ignored):
      {
        "version": 1,
        "book":  { "page-size": "octavo", "margins": "0.75in", "outlier-pages": "1,s45L" },
        "scans": { "s12": { "split": "single" }, "s30": { "splitX": "52%", "disableRectification": true } },
        "pages": { "s45L": { "skew": -0.4, "contentBox": { "nudge": { "top": "-2mm", "bottom": "+0.1in" } } },
                   "77":   { "tier": "standaloneFloating", "keep": true },
                   "s88":  { "contentBox": { "rect": ["1.0in", "1.2in", "4.1in", "6.6in"] }, "offset": { "y": "+1mm" } } }
      }
      Page names: "45" is output page 45 of the run you are looking at; "s12" is scan 12 of the source PDF (counted
      from the start of the PDF, even with --page-range); "s12L" / "s12R" are the left / right half of a split scan.
      Prefer scan names: they survive changes in splitting or pruning. More specific names win ("s12L" over "s12").
      scans: split ("single"|"spread"|"auto"), splitX ("52%" or a length), disableRectification, disableDeskMask.
      pages: skew (degrees), disableDewarp, contentBox.rect [left, top, right, bottom], contentBox.nudge {top,left,
             bottom,right} (positive moves an edge right/down), offset {x,y}, tier (fullBody|edgeAnchoredPartial|
             standaloneFloating), outlier (true|false), pageSize (outlier's own page size, same aspect), keep, drop,
             runningHeader (automatic|present|absent), verticalRegistration (automatic|anchor|boxTop),
             borderFallback (automatic|forced|disabled).
      Lengths need a unit: in, mm, cm, pt, px (px = pixels of the 600 DPI processing raster).
      Mistakes are reported all at once, with suggestions, before any scan is processed. The run prints which
      entries were applied and which were ignored (and why); the manifest records the same.
    """
}
