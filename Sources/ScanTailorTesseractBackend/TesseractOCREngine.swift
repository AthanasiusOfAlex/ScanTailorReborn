import CTesseract
import Foundation
import ScanTailorContracts

/// High-precision OCR engine backed by `libtesseract` and `libleptonica`.
///
/// `TesseractOCREngine` implements ``OCREngine`` and supports both 1-bit monochrome
/// ``BinaryBitmap`` and 8-bit ``GrayscaleBuffer`` (`GrayscaleImage`) inputs.
/// It provides first-class support for scholarly and classical languages including
/// Polytonic Ancient Greek (`grc`), German Fraktur (`deu_frak`), Latin (`lat`),
/// and English (`eng`).
///
/// ### Concurrency & Resource Management
/// `TesseractOCREngine` is `Sendable` under Swift 6 strict concurrency. Each OCR
/// operation acquires an isolated `TessBaseAPI` handle from an internal lock-protected
/// pool (or initializes a new handle when running concurrently) so that parallel
/// pages never share a mutable C `TessBaseAPI` state.
public struct TesseractOCREngine: OCREngine, Sendable {

    /// Tesseract OCR engine mode (`TessOcrEngineMode`).
    public enum EngineMode: Int32, Sendable, Equatable {
        case tesseractOnly = 0
        case lstmOnly = 1
        case tesseractAndLSTM = 2
        case `default` = 3

        var cValue: TessOcrEngineMode {
            TessOcrEngineMode(rawValue: UInt32(rawValue))
        }
    }

    /// Page layout segmentation mode (`TessPageSegMode`).
    public enum PageSegmentationMode: Int32, Sendable, Equatable {
        case osdOnly = 0
        case autoOSD = 1
        case autoOnly = 2
        case auto = 3
        case singleColumn = 4
        case singleBlockVertText = 5
        case singleBlock = 6
        case singleLine = 7
        case singleWord = 8
        case circleWord = 9
        case singleChar = 10
        case sparseText = 11
        case sparseTextOSD = 12
        case rawLine = 13

        var cValue: TessPageSegMode {
            TessPageSegMode(rawValue: UInt32(rawValue))
        }
    }

    /// Recognition result iterator granularity (`TessPageIteratorLevel`).
    public enum Granularity: Int32, Sendable, Equatable {
        case block = 0
        case paragraph = 1
        case textLine = 2
        case word = 3
        case symbol = 4

        var cValue: TessPageIteratorLevel {
            TessPageIteratorLevel(rawValue: UInt32(rawValue))
        }
    }

    /// Output bounding box coordinate space.
    public enum CoordinateSpace: Sendable, Equatable {
        /// Normalized `[0, 1] x [0, 1]` coordinates with top-left `(0, 0)` origin.
        /// Matches `AppleVisionOCREngine` and `ApplePDFDocumentWriter` expectations.
        case normalizedTopLeft
        /// Unnormalized pixel coordinates `[0, width] x [0, height]` with top-left `(0, 0)` origin.
        case pixelTopLeft
        /// PDF points (`72.0 / dpi` points per pixel) with top-left `(0, 0)` origin.
        case pdfPointsTopLeft
    }

    /// Configuration options for `TesseractOCREngine`.
    public struct Configuration: Sendable, Equatable {
        /// Optional explicit path to the `tessdata` directory containing `.traineddata` files.
        /// When `nil`, `TesseractOCREngine` searches `TESSDATA_PREFIX` and standard system paths.
        public var tessdataPath: String?

        /// Default language codes when the caller passes an empty `languages` array.
        public var defaultLanguages: [String]

        /// OCR engine mode. Defaults to `.lstmOnly` (`OEM_LSTM_ONLY`).
        public var engineMode: EngineMode

        /// Page segmentation mode. Defaults to `.auto` (`PSM_AUTO`).
        public var pageSegmentationMode: PageSegmentationMode

        /// Observation extraction granularity. Defaults to `.textLine` (`RIL_TEXTLINE`).
        public var granularity: Granularity

        /// Output bounding box coordinate space. Defaults to `.normalizedTopLeft`.
        public var coordinateSpace: CoordinateSpace

        /// Minimum confidence in `[0.0, 1.0]` required to retain an observation.
        public var minimumConfidence: Float

        /// Optional custom Tesseract configuration variables (`TessBaseAPISetVariable`).
        public var variables: [String: String]

        /// Creates a new `TesseractOCREngine` configuration.
        public init(
            tessdataPath: String? = nil,
            defaultLanguages: [String] = ["eng"],
            engineMode: EngineMode = .lstmOnly,
            pageSegmentationMode: PageSegmentationMode = .auto,
            granularity: Granularity = .textLine,
            coordinateSpace: CoordinateSpace = .normalizedTopLeft,
            minimumConfidence: Float = 0.0,
            variables: [String: String] = [:]
        ) {
            self.tessdataPath = tessdataPath
            self.defaultLanguages = defaultLanguages
            self.engineMode = engineMode
            self.pageSegmentationMode = pageSegmentationMode
            self.granularity = granularity
            self.coordinateSpace = coordinateSpace
            self.minimumConfidence = minimumConfidence
            self.variables = variables
        }
    }

    /// The engine's active configuration.
    public let configuration: Configuration

    /// Internal thread-safe pool of initialized `TessBaseAPI` handles.
    private let handlePool: HandlePool

    /// Creates a new `TesseractOCREngine` with the specified configuration.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.handlePool = HandlePool()
    }

    // MARK: - Version & Environment Discovery

    /// Returns the runtime `libtesseract` version string (e.g., `"5.5.3"`).
    public static var tesseractVersion: String {
        String(cString: TessVersion())
    }

    /// Returns the runtime `libleptonica` version string (e.g., `"leptonica-1.87.0"`).
    public static var leptonicaVersion: String {
        guard let ptr = getLeptonicaVersion() else { return "unknown" }
        defer { lept_free(ptr) }
        return String(cString: ptr)
    }

    /// Standard search locations for `tessdata` when not explicitly configured.
    public static let defaultTessdataSearchPaths: [String] = [
        "/opt/homebrew/share/tessdata",
        "/usr/local/share/tessdata",
        "/usr/share/tesseract-ocr/5/tessdata",
        "/usr/share/tesseract-ocr/4.00/tessdata",
        "/usr/share/tessdata",
    ]

    /// Resolves the `tessdata` directory path from an explicit override, `TESSDATA_PREFIX`,
    /// or standard system locations.
    public static func resolveTessdataPath(explicitPath: String? = nil) -> String? {
        let fm = FileManager.default
        if let explicitPath, !explicitPath.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: explicitPath, isDirectory: &isDir), isDir.boolValue {
                return explicitPath
            }
        }

        if let envPath = ProcessInfo.processInfo.environment["TESSDATA_PREFIX"], !envPath.isEmpty {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: envPath, isDirectory: &isDir), isDir.boolValue {
                return envPath
            }
        }

        for candidate in defaultTessdataSearchPaths {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }

        return nil
    }

    /// Returns the list of installed language codes (`.traineddata` files) in the resolved `tessdata` directory.
    ///
    /// Note: Tesseract 4/5 `tessdata_fast` distributions ship German Fraktur as `frk.traineddata`,
    /// whereas `tessdata_best` and legacy distributions ship `deu_frak.traineddata`. When either
    /// is installed, both `deu_frak` and `frk` are reported as available and resolved transparently.
    public func availableLanguages() -> [String] {
        guard let dirPath = Self.resolveTessdataPath(explicitPath: configuration.tessdataPath),
            let entries = try? FileManager.default.contentsOfDirectory(atPath: dirPath)
        else {
            return []
        }
        var codes = Set(
            entries
                .filter { $0.hasSuffix(".traineddata") }
                .map { String($0.dropLast(".traineddata".count)) }
                .filter { $0 != "osd" }
        )
        if codes.contains("frk") {
            codes.insert("deu_frak")
        } else if codes.contains("deu_frak") {
            codes.insert("frk")
        }
        return codes.sorted()
    }

    // MARK: - Language Normalization

    /// Maps a BCP-47 tag or ISO 639 code to its corresponding Tesseract language code.
    ///
    /// Supports direct Tesseract codes (`grc`, `deu_frak`, `lat`, `eng`, `deu`, `fra`, `ita`, `spa`)
    /// as well as BCP-47 locale identifiers (`en-US` -> `eng`, `de-DE` -> `deu`, `el-GR` -> `ell`,
    /// `la` -> `lat`).
    public static func normalizeLanguageCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Preserve compound "+" strings if caller passed e.g. "grc+lat+eng"
        if trimmed.contains("+") {
            return trimmed
                .split(separator: "+")
                .map { normalizeLanguageCode(String($0)) }
                .filter { !$0.isEmpty }
                .joined(separator: "+")
        }

        let lower = trimmed.lowercased()
        switch lower {
        case "grc", "grc-grek", "ancient-greek", "polytonic-greek":
            return "grc"
        case "deu_frak", "de-frak", "de-latf", "deu-latf", "fraktur":
            return "deu_frak"
        case "lat", "la", "la-latn", "latin":
            return "lat"
        case "eng", "en", "en-us", "en-gb", "en_us", "en_gb":
            return "eng"
        case "deu", "ger", "de", "de-de", "de-at", "de-ch", "de_de":
            return "deu"
        case "fra", "fre", "fr", "fr-fr", "fr-ca", "fr_fr":
            return "fra"
        case "ita", "it", "it-it", "it_it":
            return "ita"
        case "spa", "es", "es-es", "es_es":
            return "spa"
        case "ell", "gre", "el", "el-gr", "el_gr":
            return "ell"
        case "rus", "ru", "ru-ru", "ru_ru":
            return "rus"
        case "heb", "he", "he-il":
            return "heb"
        case "ara", "ar":
            return "ara"
        default:
            return trimmed
        }
    }

    /// Builds a `+`-delimited Tesseract language initialization string (e.g., `"grc+lat+eng"`),
    /// deduplicating codes while preserving priority order.
    public static func buildLanguageString(from languages: [String], fallback: [String]) -> String {
        let source = languages.isEmpty ? fallback : languages
        var seen = Set<String>()
        var ordered: [String] = []

        for entry in source {
            let normalized = normalizeLanguageCode(entry)
            for part in normalized.split(separator: "+").map(String.init) where !part.isEmpty {
                if seen.insert(part).inserted {
                    ordered.append(part)
                }
            }
        }

        if ordered.isEmpty {
            return "eng"
        }
        return ordered.joined(separator: "+")
    }

    // MARK: - Coordinate Space Transformations

    /// Inverts a bounding box from bottom-left `(0, 0)` origin (such as PDF user space or `.box` format)
    /// into top-left `(0, 0)` origin within an image of `imageHeight`.
    @inlinable
    public static func invertBottomLeftToTopLeft(
        box: Rect2D,
        imageHeight: Double
    ) -> Rect2D {
        Rect2D(
            x: box.x,
            y: imageHeight - (box.y + box.height),
            width: box.width,
            height: box.height
        )
    }

    /// Converts an unnormalized pixel bounding box `(left, top, right, bottom)` (with top-left `(0, 0)` origin)
    /// into 72 DPI PDF points `(x, y, width, height)` with top-left `(0, 0)` origin.
    @inlinable
    public static func pixelBoxToPDFPoints(
        left: Int32,
        top: Int32,
        right: Int32,
        bottom: Int32,
        dpi: Int
    ) -> Rect2D {
        let effectiveDPI = Double(max(1, dpi))
        let scale = 72.0 / effectiveDPI
        let x = Double(left) * scale
        let y = Double(top) * scale
        let width = Double(max(0, right - left)) * scale
        let height = Double(max(0, bottom - top)) * scale
        return Rect2D(x: x, y: y, width: width, height: height)
    }

    /// Converts a raw `TessPageIteratorBoundingBox` pixel rectangle `(left, top, right, bottom)`
    /// into the configured ``CoordinateSpace``.
    public static func convertPixelBox(
        left: Int32,
        top: Int32,
        right: Int32,
        bottom: Int32,
        imageWidth: Int,
        imageHeight: Int,
        dpi: Int,
        coordinateSpace: CoordinateSpace
    ) -> Rect2D {
        let clampedLeft = max(0, min(Int(left), imageWidth))
        let clampedTop = max(0, min(Int(top), imageHeight))
        let clampedRight = max(clampedLeft, min(Int(right), imageWidth))
        let clampedBottom = max(clampedTop, min(Int(bottom), imageHeight))

        let pixelX = Double(clampedLeft)
        let pixelY = Double(clampedTop)
        let pixelW = Double(clampedRight - clampedLeft)
        let pixelH = Double(clampedBottom - clampedTop)

        switch coordinateSpace {
        case .normalizedTopLeft:
            let w = Double(max(1, imageWidth))
            let h = Double(max(1, imageHeight))
            return Rect2D(
                x: pixelX / w,
                y: pixelY / h,
                width: pixelW / w,
                height: pixelH / h
            )
        case .pixelTopLeft:
            return Rect2D(
                x: pixelX,
                y: pixelY,
                width: pixelW,
                height: pixelH
            )
        case .pdfPointsTopLeft:
            return pixelBoxToPDFPoints(
                left: Int32(clampedLeft),
                top: Int32(clampedTop),
                right: Int32(clampedRight),
                bottom: Int32(clampedBottom),
                dpi: dpi
            )
        }
    }

    // MARK: - OCREngine Conformance & Recognition

    /// Recognizes text inside a 1-bit monochrome ``BinaryBitmap``.
    public func recognizeText(
        in bitmap: borrowing BinaryBitmap,
        dpi: Int,
        languages: [String]
    ) async throws(OCRError) -> [RecognizedTextObservation] {
        if Task.isCancelled {
            throw .cancelled
        }

        let pix = try LeptonicaPix(bitmap: bitmap, dpi: dpi)

        return try recognizePix(
            pix,
            imageWidth: bitmap.width,
            imageHeight: bitmap.height,
            dpi: dpi,
            languages: languages
        )
    }

    /// Recognizes text inside an 8-bit ``GrayscaleBuffer`` (`GrayscaleImage`).
    public func recognizeText(
        in image: borrowing GrayscaleBuffer,
        dpi: Int? = nil,
        languages: [String] = []
    ) async throws(OCRError) -> [RecognizedTextObservation] {
        if Task.isCancelled {
            throw .cancelled
        }

        let effectiveDPI = dpi ?? image.dpi
        let pix = try LeptonicaPix(grayscale: image, dpi: effectiveDPI)

        return try recognizePix(
            pix,
            imageWidth: image.width,
            imageHeight: image.height,
            dpi: effectiveDPI,
            languages: languages
        )
    }

    // MARK: - Core Recognition Pipeline

    private func recognizePix(
        _ pix: borrowing LeptonicaPix,
        imageWidth: Int,
        imageHeight: Int,
        dpi: Int,
        languages: [String]
    ) throws(OCRError) -> [RecognizedTextObservation] {
        if Task.isCancelled {
            throw .cancelled
        }

        let requestedLanguageString = Self.buildLanguageString(
            from: languages,
            fallback: configuration.defaultLanguages
        )
        guard let tessdataPath = Self.resolveTessdataPath(explicitPath: configuration.tessdataPath) else {
            throw .engineUnavailable(
                reason: "Could not locate a valid tessdata directory. Set TESSDATA_PREFIX or Configuration.tessdataPath."
            )
        }

        // Validate that requested language traineddata files exist (resolving deu_frak <-> frk aliases).
        let fm = FileManager.default
        var resolvedLangs: [String] = []
        for lang in requestedLanguageString.split(separator: "+").map(String.init) {
            let directFile = (tessdataPath as NSString).appendingPathComponent("\(lang).traineddata")
            if fm.fileExists(atPath: directFile) {
                resolvedLangs.append(lang)
            } else if lang == "deu_frak" {
                let frkFile = (tessdataPath as NSString).appendingPathComponent("frk.traineddata")
                if fm.fileExists(atPath: frkFile) {
                    resolvedLangs.append("frk")
                } else {
                    throw .engineUnavailable(
                        reason: "Missing traineddata dictionary 'deu_frak.traineddata' (or 'frk.traineddata') in '\(tessdataPath)'."
                    )
                }
            } else if lang == "frk" {
                let deuFrakFile = (tessdataPath as NSString).appendingPathComponent("deu_frak.traineddata")
                if fm.fileExists(atPath: deuFrakFile) {
                    resolvedLangs.append("deu_frak")
                } else {
                    throw .engineUnavailable(
                        reason: "Missing traineddata dictionary 'frk.traineddata' (or 'deu_frak.traineddata') in '\(tessdataPath)'."
                    )
                }
            } else {
                throw .engineUnavailable(
                    reason: "Missing traineddata dictionary '\(lang).traineddata' in '\(tessdataPath)'."
                )
            }
        }
        let languageString = resolvedLangs.joined(separator: "+")

        let handleKey = HandleKey(
            datapath: tessdataPath,
            language: languageString,
            engineMode: configuration.engineMode
        )

        let rawHandle = try handlePool.acquire(key: handleKey)
        defer {
            TessBaseAPIClear(rawHandle)
            handlePool.release(rawHandle, key: handleKey)
        }

        // Apply page segmentation mode and custom variables.
        TessBaseAPISetPageSegMode(rawHandle, configuration.pageSegmentationMode.cValue)
        for (name, value) in configuration.variables {
            _ = name.withCString { namePtr in
                value.withCString { valuePtr in
                    TessBaseAPISetVariable(rawHandle, namePtr, valuePtr)
                }
            }
        }

        let effectiveDPI = Int32(max(70, dpi))
        TessBaseAPISetImage2(rawHandle, pix.pointer)
        TessBaseAPISetSourceResolution(rawHandle, effectiveDPI)

        if Task.isCancelled {
            throw .cancelled
        }

        let recognizeStatus = TessBaseAPIRecognize(rawHandle, nil)
        guard recognizeStatus == 0 else {
            throw .recognitionFailed(
                reason: "TessBaseAPIRecognize failed with status code \(recognizeStatus)."
            )
        }

        if Task.isCancelled {
            throw .cancelled
        }

        guard let resultIterator = TessBaseAPIGetIterator(rawHandle) else {
            return []
        }
        defer {
            TessResultIteratorDelete(resultIterator)
        }

        guard let pageIterator = TessResultIteratorGetPageIterator(resultIterator) else {
            return []
        }

        let level = configuration.granularity.cValue
        let minConfidence = configuration.minimumConfidence
        var observations: [RecognizedTextObservation] = []

        repeat {
            if Task.isCancelled {
                throw .cancelled
            }

            guard let utf8Ptr = TessResultIteratorGetUTF8Text(resultIterator, level) else {
                continue
            }
            let rawText = String(cString: utf8Ptr)
            TessDeleteText(utf8Ptr)

            let cleanedText = Self.normalizeRecognizedText(rawText)
            guard !cleanedText.isEmpty else {
                continue
            }

            // Tesseract confidence is in [0.0, 100.0]; normalize to [0.0, 1.0].
            let rawConfidence = TessResultIteratorConfidence(resultIterator, level)
            let normalizedConfidence = min(1.0, max(0.0, rawConfidence / 100.0))
            guard normalizedConfidence >= minConfidence else {
                continue
            }

            var left: Int32 = 0
            var top: Int32 = 0
            var right: Int32 = 0
            var bottom: Int32 = 0
            let hasBox = TessPageIteratorBoundingBox(
                pageIterator,
                level,
                &left,
                &top,
                &right,
                &bottom
            )
            guard hasBox != 0, right > left, bottom > top else {
                continue
            }

            let boundingBox = Self.convertPixelBox(
                left: left,
                top: top,
                right: right,
                bottom: bottom,
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                dpi: Int(effectiveDPI),
                coordinateSpace: configuration.coordinateSpace
            )

            observations.append(
                RecognizedTextObservation(
                    text: cleanedText,
                    confidence: normalizedConfidence,
                    boundingBox: boundingBox
                )
            )
        } while TessResultIteratorNext(resultIterator, level) != 0

        return observations
    }

    /// Normalizes line breaks and trims leading/trailing whitespace from a Tesseract UTF-8 fragment.
    private static func normalizeRecognizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Thread-Safe TessBaseAPI Handle Pool

private struct HandleKey: Hashable, Sendable {
    let datapath: String
    let language: String
    let engineMode: TesseractOCREngine.EngineMode
}

/// Thread-safe pool of initialized `TessBaseAPI` pointers keyed by `(datapath, language, engineMode)`.
///
/// Avoids reloading multi-megabyte `.traineddata` dictionaries on sequential calls while allowing
/// concurrent tasks to allocate independent `TessBaseAPI` instances without contention.
private final class HandlePool: @unchecked Sendable {
    private let lock = NSLock()
    private var idleHandles: [HandleKey: [OpaquePointer]] = [:]

    init() {}

    deinit {
        lock.lock()
        let allBuckets = idleHandles.values
        idleHandles.removeAll()
        lock.unlock()

        for bucket in allBuckets {
            for handle in bucket {
                TessBaseAPIEnd(handle)
                TessBaseAPIDelete(handle)
            }
        }
    }

    func acquire(key: HandleKey) throws(OCRError) -> OpaquePointer {
        lock.lock()
        if var bucket = idleHandles[key], let existing = bucket.popLast() {
            idleHandles[key] = bucket
            lock.unlock()
            return existing
        }
        lock.unlock()

        guard let handle = TessBaseAPICreate() else {
            throw .engineUnavailable(reason: "TessBaseAPICreate returned NULL.")
        }

        let initResult = key.datapath.withCString { datapathPtr in
            key.language.withCString { langPtr in
                TessBaseAPIInit2(
                    handle,
                    datapathPtr,
                    langPtr,
                    key.engineMode.cValue
                )
            }
        }

        guard initResult == 0 else {
            TessBaseAPIDelete(handle)
            throw .engineUnavailable(
                reason: "TessBaseAPIInit2 failed for languages '\(key.language)' at '\(key.datapath)' (code \(initResult))."
            )
        }

        return handle
    }

    func release(_ handle: OpaquePointer, key: HandleKey) {
        lock.lock()
        defer { lock.unlock() }
        var bucket = idleHandles[key] ?? []
        if bucket.count < 8 {
            bucket.append(handle)
            idleHandles[key] = bucket
        } else {
            TessBaseAPIEnd(handle)
            TessBaseAPIDelete(handle)
        }
    }
}
