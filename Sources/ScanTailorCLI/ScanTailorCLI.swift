import Foundation
import ScanTailorAppleBackend
import ScanTailorContracts
import ScanTailorCore
import ScanTailorPipeline
import ScanTailorPortableBackend

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

    public struct ProcessOptions: Sendable, Equatable {
        public var inputPDFPath: String
        public var outputPDFPath: String
        public var manifestPath: String?
        public var diagnosticsDirPath: String?
        public var splitMode: PageSplitMode = .automatic
        public var gutterTrimWidth: Int = 24
        public var enableDewarp: Bool = true
        public var enableOCR: Bool = true
        public var binarizationMethod: AdaptiveBinarizer.Method = .wolfJolion
        public var usePortableBackend: Bool = false
        public var renderAllDiagnostics: Bool = false

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
        var enableDewarp = true
        var enableOCR = true
        var binarizeMethod: AdaptiveBinarizer.Method = .wolfJolion
        var usePortable = false
        var allDiagnostics = false

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
        opts.enableDewarp = enableDewarp
        opts.enableOCR = enableOCR
        opts.binarizationMethod = binarizeMethod
        opts.usePortableBackend = usePortable
        opts.renderAllDiagnostics = allDiagnostics
        return opts
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
        let ocrEngine: (any OCREngine)? = options.enableOCR ? AppleVisionOCREngine() : nil

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
        let pipeConfig = BookPipelineCoordinator.Configuration(
            processingDPI: 600,
            outputDPI: 300,
            splitMode: options.splitMode,
            gutterTrimWidth: options.gutterTrimWidth,
            enableDewarp: options.enableDewarp,
            binarizerConfiguration: binConfig
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

    public static func formatManifestSummary(_ manifest: BookProcessingManifest) -> String {
        var lines: [String] = []
        lines.append("=== ScanTailorReborn Manifest Summary ===")
        lines.append("Processing DPI: \(manifest.processingDPI) | Output DPI: \(manifest.outputDPI)")
        lines.append("Canonical 600 DPI Canvas: \(manifest.canonicalCanvasSizeAtProcessingDPI.width) x \(manifest.canonicalCanvasSizeAtProcessingDPI.height) px")
        lines.append("Verso Canonical Text Frame: \(manifest.versoCanonicalFrame.width) x \(manifest.versoCanonicalFrame.height) at (\(manifest.versoCanonicalFrame.minX), \(manifest.versoCanonicalFrame.minY))")
        lines.append("Recto Canonical Text Frame: \(manifest.rectoCanonicalFrame.width) x \(manifest.rectoCanonicalFrame.height) at (\(manifest.rectoCanonicalFrame.minX), \(manifest.rectoCanonicalFrame.minY))")
        lines.append("Total Output Pages: \(manifest.pages.count) (from \(manifest.sourcePageSplits.count) source scan(s))")
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
      --binarize <method>          Adaptive thresholding: wolf (default) or sauvola
      --no-dewarp                  Disable 3D cubic-sheet curvature dewarping
      --no-ocr                     Disable Vision OCR searchable text layer
      --portable-backend           Use pure-Swift portable compute accelerator instead of Metal GPU
    """
}
