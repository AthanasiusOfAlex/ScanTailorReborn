import Foundation
import ScanTailorContracts
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Where and how a run reuses the results of earlier runs (Substep 6.3.2).
///
/// Two expensive results are stored on disk, each under a key that hashes everything it depends on:
/// - **scans**: the cleaned 600 DPI pages of a scan and everything pass 1 decided about it (split, skew,
///   dewarp, border fallback, content box detection, blank check);
/// - **OCR**: the recognized text of a rendered output page, keyed by the page's pixels.
///
/// A key includes ``codeVersion``, so a rebuilt program never reuses results of an older one. Entries that
/// cannot be read are recomputed, so deleting the directory at any time is safe.
public struct PipelineCacheOptions: Sendable, Equatable {
    /// The cache directory (created on first use).
    public var directory: URL
    /// Identifies the code that produced an entry, for example the executable's build UUID.
    public var codeVersion: String
    /// Identifies the source document's contents (for example a SHA-256 of the PDF file). Scans read from a
    /// ``PDFSourceReader`` are cached only when it is set; scans passed as pixel buffers are identified by
    /// their pixels.
    public var sourceFingerprint: String?

    public init(directory: URL, codeVersion: String, sourceFingerprint: String? = nil) {
        self.directory = directory
        self.codeVersion = codeVersion
        self.sourceFingerprint = sourceFingerprint
    }

    /// `~/Library/Caches/ScanTailorReborn`, or the system temporary directory when there is no caches folder.
    public static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("ScanTailorReborn", isDirectory: true)
    }

    /// A SHA-256 of a file's contents, read in chunks, as lowercase hex (`nil` if the file cannot be read).
    public static func fingerprint(ofFileAt url: URL) -> String? {
        #if canImport(CryptoKit)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // `nil` (or empty data) is the end of the file; a thrown error is a failed read.
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 8 << 20)
            } catch {
                return nil
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return nil
        #endif
    }
}

/// Reads and writes cache entries. Every failure is a miss: the caller recomputes.
struct PipelineCache: Sendable {
    let options: PipelineCacheOptions

    /// Whether this platform can hash keys (no hashing, no cache).
    static var isSupported: Bool {
        #if canImport(CryptoKit)
        return true
        #else
        return false
        #endif
    }

    init?(_ options: PipelineCacheOptions?) {
        guard let options, Self.isSupported else { return nil }
        self.options = options
    }

    /// Builds a key from labelled parts; the parts are hashed together with ``PipelineCacheOptions/codeVersion``.
    func key(_ kind: String, _ parts: [String]) -> String {
        var hasher = KeyHasher()
        hasher.add("scantailor-cache-v1")
        hasher.add(options.codeVersion)
        hasher.add(kind)
        for part in parts { hasher.add(part) }
        return hasher.hex
    }

    private func url(kind: String, key: String) -> URL {
        options.directory
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent(String(key.prefix(2)), isDirectory: true)
            .appendingPathComponent(key + ".bin")
    }

    /// The decoded entry, or `nil` when it is missing or unreadable.
    func load<T: Decodable>(_ type: T.Type, kind: String, key: String) -> T? {
        guard let compressed = try? Data(contentsOf: url(kind: kind, key: key)),
              let data = Self.decompress(compressed)
        else { return nil }
        return try? PropertyListDecoder().decode(T.self, from: data)
    }

    /// Stores an entry. Writes go to a temporary file that is then renamed, so concurrent readers never see
    /// half an entry. Failures are ignored (the cache is an optimisation).
    func store<T: Encodable>(_ value: T, kind: String, key: String) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(value), let compressed = Self.compress(data) else { return }
        let destination = url(kind: kind, key: key)
        let folder = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let temporary = folder.appendingPathComponent(".\(key).\(UUID().uuidString).tmp")
            try compressed.write(to: temporary)
            if rename(temporary.path, destination.path) != 0 {
                try? FileManager.default.removeItem(at: temporary)
            }
        } catch {
            return
        }
    }

    private static func compress(_ data: Data) -> Data? {
        #if canImport(Darwin)
        return try? (data as NSData).compressed(using: .lzfse) as Data
        #else
        return data
        #endif
    }

    private static func decompress(_ data: Data) -> Data? {
        #if canImport(Darwin)
        return try? (data as NSData).decompressed(using: .lzfse) as Data
        #else
        return data
        #endif
    }
}

/// SHA-256 over length-prefixed parts, so `["ab", "c"]` and `["a", "bc"]` differ.
struct KeyHasher {
    #if canImport(CryptoKit)
    private var sha = SHA256()
    #endif

    mutating func add(_ string: String) {
        add(Data(string.utf8))
    }

    mutating func add(_ data: Data) {
        #if canImport(CryptoKit)
        var length = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &length) { sha.update(bufferPointer: $0) }
        sha.update(data: data)
        #endif
    }

    mutating func add(_ bitmap: borrowing BinaryBitmap) {
        add("\(bitmap.width)x\(bitmap.height)")
        #if canImport(CryptoKit)
        bitmap.words.withUnsafeBytes { sha.update(bufferPointer: $0) }
        #endif
    }

    mutating func add(_ buffer: borrowing GrayscaleBuffer) {
        add("\(buffer.width)x\(buffer.height)@\(buffer.dpi)")
        #if canImport(CryptoKit)
        buffer.pixels.withUnsafeBytes { sha.update(bufferPointer: $0) }
        #endif
    }

    var hex: String {
        #if canImport(CryptoKit)
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        return ""
        #endif
    }
}

/// A ``BinaryBitmap`` stored as its packed words.
struct CachedBitmap: Codable {
    var width: Int
    var height: Int
    var words: Data

    init(_ bitmap: BinaryBitmap) {
        width = bitmap.width
        height = bitmap.height
        words = bitmap.words.withUnsafeBytes { Data($0) }
    }

    /// The bitmap, or `nil` when the stored words do not match the size.
    var bitmap: BinaryBitmap? {
        guard width > 0, height > 0 else { return nil }
        let count = ((width + 63) / 64) * height
        guard words.count == count * MemoryLayout<UInt64>.size else { return nil }
        var array = ContiguousArray<UInt64>(repeating: 0, count: count)
        array.withUnsafeMutableBytes { destination in
            words.withUnsafeBytes { source in destination.copyMemory(from: source) }
        }
        return BinaryBitmap(width: width, height: height, words: array)
    }
}

/// OCR through the cache: the text of a page is reused when the engine, languages, resolution and every pixel
/// are the same.
struct CachedOCR: Sendable {
    let engine: any OCREngine
    let cache: PipelineCache?

    /// Recognizes `bitmap`, reusing a stored result when possible.
    /// - Returns: The observations, and whether they came from the cache.
    func recognize(
        _ bitmap: borrowing BinaryBitmap,
        dpi: Int,
        languages: [String]
    ) async throws(OCRError) -> (observations: [RecognizedTextObservation], reused: Bool) {
        guard let cache else {
            return (try await engine.recognizeText(in: bitmap, dpi: dpi, languages: languages), false)
        }
        var hasher = KeyHasher()
        hasher.add(engine.cacheIdentity)
        hasher.add(languages.joined(separator: ","))
        hasher.add("\(dpi)")
        hasher.add(bitmap)
        let key = cache.key("ocr", [hasher.hex])
        if let stored = cache.load([RecognizedTextObservation].self, kind: "ocr", key: key) {
            return (stored, true)
        }
        let observations = try await engine.recognizeText(in: bitmap, dpi: dpi, languages: languages)
        cache.store(observations, kind: "ocr", key: key)
        return (observations, false)
    }
}
