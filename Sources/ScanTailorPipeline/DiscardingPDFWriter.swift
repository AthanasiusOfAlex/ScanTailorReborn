import ScanTailorContracts

/// A ``PDFDocumentWriter`` that keeps nothing.
///
/// Used by runs that stop before output (`--stop-after layout`), which need a writer to satisfy the pipeline
/// but must not create or overwrite a PDF.
public struct DiscardingPDFWriter: PDFDocumentWriter {
    public init() {}

    public mutating func appendPage(
        bitmap: borrowing BinaryBitmap,
        dpi: Int,
        pageBoxPoints: Rect2D,
        ocrLayer: [RecognizedTextObservation]
    ) throws(PDFWriteError) {}

    public consuming func finalize() throws(PDFWriteError) {}
}
