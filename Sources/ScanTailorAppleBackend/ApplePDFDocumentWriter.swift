import CoreGraphics
import CoreText
import Foundation
import ScanTailorContracts

/// Apple CoreGraphics / CoreText implementation of `PDFDocumentWriter` (`~Copyable`).
///
/// Writes 1-bit monochrome (`BitsPerComponent = 1`, `DeviceGray`) page rasters at 300 DPI
/// along with an invisible, selectable, searchable OCR text layer (`CGTextDrawingMode.invisible`)
/// positioned accurately over the page glyphs.
public struct ApplePDFDocumentWriter: PDFDocumentWriter, ~Copyable {

    /// Output file URL where the PDF is written.
    public let destinationURL: URL

    /// Number of pages appended so far.
    public private(set) var pageCount: Int = 0

    private let pdfContext: CGContext
    private let baseOCRFont: CTFont
    private var isFinalized: Bool = false

    /// Creates a new PDF document writer targeting `destinationURL`.
    /// - Parameters:
    ///   - destinationURL: File URL for the output PDF document.
    ///   - title: Optional PDF document title metadata.
    ///   - author: Optional PDF document author metadata.
    ///   - creator: Creator application string (default: `"ScanTailorReborn"`).
    /// - Throws: `PDFWriteError.destinationInitializationFailed` if the PDF stream cannot be opened.
    public init(
        destinationURL: URL,
        title: String? = nil,
        author: String? = nil,
        creator: String = "ScanTailorReborn"
    ) throws(PDFWriteError) {
        let parentDir = destinationURL.deletingLastPathComponent()
        if !parentDir.path.isEmpty && !FileManager.default.fileExists(atPath: parentDir.path) {
            do {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            } catch {
                throw .destinationInitializationFailed(url: destinationURL)
            }
        }

        var auxInfo: [CFString: Any] = [
            kCGPDFContextCreator: creator
        ]
        if let title {
            auxInfo[kCGPDFContextTitle] = title
        }
        if let author {
            auxInfo[kCGPDFContextAuthor] = author
        }

        guard let consumer = CGDataConsumer(url: destinationURL as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, auxInfo as CFDictionary)
        else {
            throw .destinationInitializationFailed(url: destinationURL)
        }

        self.destinationURL = destinationURL
        self.pdfContext = context
        self.baseOCRFont = CTFontCreateWithName("Helvetica" as CFString, 12.0, nil)
    }

    /// Appends a 1-bit monochrome page with an invisible searchable OCR text layer.
    /// - Parameters:
    ///   - bitmap: The 1-bit monochrome page image (typically 300 DPI).
    ///   - dpi: Image resolution in dots per inch (typically 300).
    ///   - pageBoxPoints: PDF page boundaries in 72 DPI points (e.g., `Rect2D(x: 0, y: 0, width: 432, height: 648)`).
    ///   - ocrLayer: Recognized text observations to embed as an invisible searchable text layer.
    /// - Throws: `PDFWriteError` if page encoding or addition fails.
    public mutating func appendPage(
        bitmap: borrowing BinaryBitmap,
        dpi: Int,
        pageBoxPoints: Rect2D,
        ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {
        guard !isFinalized else {
            throw .pageAdditionFailed(pageIndex: pageCount, reason: "Cannot append page after PDF writer has been finalized")
        }

        guard pageBoxPoints.width > 0 && pageBoxPoints.height > 0 else {
            throw .pageAdditionFailed(
                pageIndex: pageCount,
                reason: "Invalid pageBoxPoints dimensions: \(pageBoxPoints.width)x\(pageBoxPoints.height)"
            )
        }

        guard dpi > 0 else {
            throw .pageAdditionFailed(pageIndex: pageCount, reason: "Invalid DPI: \(dpi)")
        }

        guard let cgImage = BinaryBitmapCGImageBridge.make1BitCGImage(from: bitmap) else {
            throw .encodingFailed(reason: "Failed to create 1-bit CGImage from BinaryBitmap (\(bitmap.width)x\(bitmap.height))")
        }

        var mediaBox = CGRect(
            x: pageBoxPoints.minX,
            y: pageBoxPoints.minY,
            width: pageBoxPoints.width,
            height: pageBoxPoints.height
        )
        let pageInfo: [CFString: Any] = [
            kCGPDFContextMediaBox: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
        ]

        pdfContext.beginPDFPage(pageInfo as CFDictionary)

        // 1. Draw the 1-bit monochrome page raster crisply without interpolation blurring.
        pdfContext.saveGState()
        pdfContext.interpolationQuality = .none
        pdfContext.setShouldAntialias(false)
        pdfContext.draw(cgImage, in: mediaBox)
        pdfContext.restoreGState()

        // 2. Draw the invisible searchable OCR text layer aligned with the visible glyphs.
        if !ocrLayer.isEmpty {
            drawInvisibleOCRLayer(ocrLayer, in: pageBoxPoints)
        }

        pdfContext.endPDFPage()
        pageCount += 1
    }

    /// Finalizes the PDF document, closes streams, and writes the trailer dictionary.
    /// Consumes `self` so no further operations can occur on this document writer.
    /// - Throws: `PDFWriteError` if final disk write fails.
    public consuming func finalize() throws(PDFWriteError) {
        guard !isFinalized else { return }
        pdfContext.closePDF()
        isFinalized = true

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw .finalizationFailed(reason: "Output PDF file was not written to \(destinationURL.path)")
        }
    }

    deinit {
        if !isFinalized {
            pdfContext.closePDF()
        }
    }

    // MARK: - Private Helpers

    private func drawInvisibleOCRLayer(
        _ observations: [RecognizedTextObservation],
        in pageBox: Rect2D
    ) {
        pdfContext.saveGState()
        pdfContext.setTextDrawingMode(.invisible)

        for obs in observations {
            let trimmed = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let box = obs.boundingBox
            guard box.width > 0 && box.height > 0 else { continue }

            // Determine whether observation boundingBox is in normalized [0, 1] top-left space
            // (as returned by AppleVisionOCREngine) or already in top-left PDF point coordinates.
            let isNormalized = (box.maxX <= 1.001 && box.maxY <= 1.001)

            let pdfX: Double
            let pdfY: Double
            let pdfWidth: Double
            let pdfHeight: Double

            if isNormalized {
                pdfX = pageBox.minX + box.minX * pageBox.width
                pdfY = pageBox.minY + (1.0 - box.maxY) * pageBox.height
                pdfWidth = box.width * pageBox.width
                pdfHeight = box.height * pageBox.height
            } else {
                pdfX = pageBox.minX + box.minX
                pdfY = pageBox.minY + (pageBox.height - box.maxY)
                pdfWidth = box.width
                pdfHeight = box.height
            }

            guard pdfWidth > 0.5 && pdfHeight > 0.5 else { continue }

            // Deduplicate font objects in the generated PDF: use a single base CTFont (12 pt Helvetica)
            // and apply vertical (font size) & horizontal (bounding box fitting) scaling via CGAffineTransform textMatrix.
            let attributes: [CFString: Any] = [
                kCTFontAttributeName: baseOCRFont
            ]
            guard let attributedString = CFAttributedStringCreate(
                kCFAllocatorDefault,
                trimmed as CFString,
                attributes as CFDictionary
            ) else {
                continue
            }

            let line = CTLineCreateWithAttributedString(attributedString)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let naturalWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))

            let targetHeight = CGFloat(pdfHeight) * 0.85
            let verticalScale = max(0.1, targetHeight / 12.0)
            let scaledNaturalWidth = naturalWidth * verticalScale

            let horizontalScale: CGFloat
            if scaledNaturalWidth > 0.1 {
                horizontalScale = (CGFloat(pdfWidth) / scaledNaturalWidth) * verticalScale
            } else {
                horizontalScale = verticalScale
            }

            let baselineY = CGFloat(pdfY) + max(0, descent * verticalScale)
            pdfContext.textMatrix = CGAffineTransform(
                a: horizontalScale,
                b: 0,
                c: 0,
                d: verticalScale,
                tx: CGFloat(pdfX),
                ty: baselineY
            )
            CTLineDraw(line, pdfContext)
        }

        pdfContext.restoreGState()
    }
}
