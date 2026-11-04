import Foundation
import ScanTailorAppleBackend
import ScanTailorContracts
import ScanTailorCore
import Testing

/// Opt-in check of ``CameraGutterLocator`` on phone photos of an open dictionary (Substep 7.1.1b).
///
/// The gutters were read by eye on each photo (fraction of the width, at the fold). Every photo shows a
/// cluttered desk: mugs, a keyboard, bottles, a shoe, thumb-index tabs.
///
/// ```
/// SCANTAILOR_CORPUS_DIR="$HOME/Library/CloudStorage/OneDrive-MRC/PDFs-in-the-making" \
///   swift test --filter CameraGutterCorpusTests
/// ```
private let corpusDirectory: String? = {
    guard let value = ProcessInfo.processInfo.environment["SCANTAILOR_CORPUS_DIR"], !value.isEmpty else { return nil }
    return value
}()

@Suite("Camera gutters on Simpson 1968 photos (opt-in: SCANTAILOR_CORPUS_DIR)", .enabled(if: corpusDirectory != nil))
struct CameraGutterCorpusTests {
    /// (file, photo index, gutter read by eye)
    static let photos: [(String, Int, Double)] = [
        ("simpson.1968.280-281.pdf", 0, 0.506), ("simpson.1968.292-293.pdf", 0, 0.513),
        ("simpson.1968.318-319.pdf", 0, 0.528), ("simpson.1968.400-403.pdf", 0, 0.535),
        ("simpson.1968.400-403.pdf", 1, 0.506), ("simpson.1968.598-599.pdf", 0, 0.480),
        ("simpson.1968.646-649.pdf", 0, 0.530), ("simpson.1968.646-649.pdf", 1, 0.528),
    ]

    @Test("Each cut lands within 1% of the width of the fold", arguments: photos.indices)
    func gutter(_ index: Int) async throws {
        let (file, page, expected) = Self.photos[index]
        let root = try #require(corpusDirectory)
        let url = URL(fileURLWithPath: root).appendingPathComponent("simpson.1968/\(file)")
        try #require(FileManager.default.fileExists(atPath: url.path), "missing corpus file \(url.path)")
        // 150 DPI gives the same working raster as the pipeline's 600 DPI (both halve down to ~860 px).
        let photo = try await ApplePDFSourceReader(url: url).rasterizePage(at: page, targetDPI: 150)
        let estimate = try #require(CameraGutterLocator.locate(in: photo), "\(file) #\(page): no gutter")
        #expect(abs(estimate.normalizedCenterX - expected) <= 0.01, "\(file) #\(page): \(estimate.normalizedCenterX) vs \(expected)")
    }
}
