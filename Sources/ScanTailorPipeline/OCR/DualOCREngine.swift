import Foundation
import ScanTailorContracts

/// Synthesizes optical character recognition observations from two independent OCR engines.
///
/// Designed to coordinate modern neural OCR (such as `AppleVisionOCREngine` on macOS) with
/// scholarly/classical OCR (such as `TesseractOCREngine` with `grc`, `lat`, or `deu_frak`).
///
/// In `.mergeAndDeduplicate` mode:
/// - Executes both engines in parallel.
/// - Spatially matches overlapping bounding boxes.
/// - Prioritizes classical script characters (e.g. Polytonic Greek accents or Fraktur ligatures)
///   over Latin character misrecognitions.
/// - Retains non-overlapping text blocks detected by either engine.
/// - Gracefully falls back to the surviving engine if one fails.
public struct DualOCREngine: OCREngine, Sendable {

    /// Synthesis strategy when combining OCR results.
    public enum SynthesisStrategy: Sendable, Equatable {
        /// Runs both engines concurrently, aligning overlapping bounding boxes, selecting higher-confidence
        /// or classical script candidates, retaining unique detections, and sorting in reading order.
        case mergeAndDeduplicate
        /// Attempts the primary engine first; if primary produces zero observations or fails, runs the secondary engine.
        case preferPrimaryWithFallback
    }

    /// Primary OCR engine (typically Apple Vision on macOS).
    public let primary: any OCREngine

    /// Secondary OCR engine (typically Tesseract OCR).
    public let secondary: any OCREngine

    /// Synthesis strategy to apply.
    public let strategy: SynthesisStrategy

    /// Creates a new dual OCR engine synthesizer.
    /// - Parameters:
    ///   - primary: Primary OCR engine.
    ///   - secondary: Secondary OCR engine.
    ///   - strategy: Synthesis strategy (default: `.mergeAndDeduplicate`).
    public init(
        primary: any OCREngine,
        secondary: any OCREngine,
        strategy: SynthesisStrategy = .mergeAndDeduplicate
    ) {
        self.primary = primary
        self.secondary = secondary
        self.strategy = strategy
    }

    /// Both engines' identities and the synthesis strategy.
    public var cacheIdentity: String {
        "DualOCREngine(\(strategy); \(primary.cacheIdentity); \(secondary.cacheIdentity))"
    }

    /// Recognizes text lines within a binary bitmap using dual-engine coordination.
    /// - Parameters:
    ///   - bitmap: 1-bit monochrome page image.
    ///   - dpi: Image resolution in DPI.
    ///   - languages: Requested language codes (e.g. `["en-US", "grc"]` or `["deu_frak"]`).
    /// - Returns: Synthesized recognized text observations ordered in natural reading order.
    /// - Throws: `OCRError` if recognition fails and neither engine can recover.
    public func recognizeText(
        in bitmap: borrowing BinaryBitmap,
        dpi: Int,
        languages: [String]
    ) async throws(OCRError) -> [RecognizedTextObservation] {
        if Task.isCancelled {
            throw .cancelled
        }

        // Fast-path: empty bitmap has no characters
        guard !bitmap.isEmpty else {
            return []
        }

        switch strategy {
        case .preferPrimaryWithFallback:
            let visionLangs = Self.filterAppleVisionLanguages(languages)
            do {
                let primaryObs = try await primary.recognizeText(in: bitmap, dpi: dpi, languages: visionLangs)
                if !primaryObs.isEmpty {
                    return primaryObs
                }
            } catch {
                // Primary failed, proceed to secondary fallback
            }
            return try await secondary.recognizeText(in: bitmap, dpi: dpi, languages: languages)

        case .mergeAndDeduplicate:
            let visionLangs = Self.filterAppleVisionLanguages(languages)

            let pResult: Result<[RecognizedTextObservation], OCRError>
            do {
                let obs = try await primary.recognizeText(in: bitmap, dpi: dpi, languages: visionLangs)
                pResult = .success(obs)
            } catch {
                pResult = .failure(error)
            }

            let sResult: Result<[RecognizedTextObservation], OCRError>
            do {
                let obs = try await secondary.recognizeText(in: bitmap, dpi: dpi, languages: languages)
                sResult = .success(obs)
            } catch {
                sResult = .failure(error)
            }

            switch (pResult, sResult) {
            case (.success(let pObs), .success(let sObs)):
                return Self.mergeObservations(primary: pObs, secondary: sObs)
            case (.success(let pObs), .failure):
                return pObs
            case (.failure, .success(let sObs)):
                return sObs
            case (.failure(let pError), .failure):
                throw pError
            }
        }
    }

    // MARK: - Synthesis & Merging Logic

    /// Merges observations from primary and secondary engines with spatial deduplication,
    /// classical script prioritization, and reading-order sorting.
    public static func mergeObservations(
        primary: [RecognizedTextObservation],
        secondary: [RecognizedTextObservation]
    ) -> [RecognizedTextObservation] {
        if primary.isEmpty { return secondary }
        if secondary.isEmpty { return primary }

        var matchedSecondaryIndices = Set<Int>()
        var merged: [RecognizedTextObservation] = []
        merged.reserveCapacity(primary.count + secondary.count)

        for pObs in primary {
            // Find overlapping secondary observations
            var bestSecondaryIndex: Int? = nil
            var bestOverlapScore: Double = 0.0

            for (sIdx, sObs) in secondary.enumerated() {
                let score = computeOverlapScore(pObs.boundingBox, sObs.boundingBox)
                if score > 0.35 && score > bestOverlapScore {
                    bestOverlapScore = score
                    bestSecondaryIndex = sIdx
                }
            }

            if let sIdx = bestSecondaryIndex {
                matchedSecondaryIndices.insert(sIdx)
                let sObs = secondary[sIdx]
                let chosen = selectBestObservation(primary: pObs, secondary: sObs)
                merged.append(chosen)
            } else {
                merged.append(pObs)
            }
        }

        // Add any non-overlapping secondary observations (e.g. polytonic blockquotes missed by primary)
        for (sIdx, sObs) in secondary.enumerated() {
            if !matchedSecondaryIndices.contains(sIdx) {
                merged.append(sObs)
            }
        }

        // Sort into natural reading order
        return sortReadingOrder(merged)
    }

    /// Selects the best candidate between two overlapping text observations.
    public static func selectBestObservation(
        primary: RecognizedTextObservation,
        secondary: RecognizedTextObservation
    ) -> RecognizedTextObservation {
        let pHasClassical = containsClassicalScript(primary.text)
        let sHasClassical = containsClassicalScript(secondary.text)

        // 1. Classical script priority (Polytonic Greek or Fraktur characters)
        if sHasClassical && !pHasClassical {
            return secondary
        }
        if pHasClassical && !sHasClassical {
            return primary
        }

        // 2. Significant confidence differential (> 0.15)
        let confDiff = Double(secondary.confidence) - Double(primary.confidence)
        if confDiff > 0.15 {
            return secondary
        }
        if confDiff < -0.15 {
            return primary
        }

        // 3. Information richness (length of non-whitespace characters)
        let pLen = primary.text.filter { !$0.isWhitespace }.count
        let sLen = secondary.text.filter { !$0.isWhitespace }.count
        if sLen > pLen + 4 {
            return secondary
        }

        // Default to primary engine (e.g. Apple Vision)
        return primary
    }

    /// Calculates a normalized overlap score between two bounding boxes in `[0, 1]`.
    public static func computeOverlapScore(_ a: Rect2D, _ b: Rect2D) -> Double {
        let yOverlap = max(0.0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
        let minHeight = min(a.height, b.height)
        guard minHeight > 0 else { return 0.0 }
        let vRatio = yOverlap / minHeight
        guard vRatio > 0.40 else { return 0.0 }

        let xOverlap = max(0.0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
        let minWidth = min(a.width, b.width)
        guard minWidth > 0 else { return 0.0 }
        let hRatio = xOverlap / minWidth

        return (vRatio * 0.6) + (hRatio * 0.4)
    }

    /// Checks if a text string contains characters from classical or scholarly scripts
    /// (Greek & Coptic, Greek Extended / Polytonic, or Fraktur long s).
    public static func containsClassicalScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let val = scalar.value
            // Greek and Coptic: U+0370...U+03FF
            // Greek Extended (Polytonic accents & breathings): U+1F00...U+1FFF
            // Latin Long s: U+017F (common in Fraktur)
            if (val >= 0x0370 && val <= 0x03FF) || (val >= 0x1F00 && val <= 0x1FFF) || val == 0x017F {
                return true
            }
        }
        return false
    }

    /// Filters language codes for Apple Vision, removing classical/scholarly codes
    /// that are known to be unsupported by Vision (`VNRecognizeTextRequest`).
    public static func filterAppleVisionLanguages(_ languages: [String]) -> [String] {
        let unsupportedPrefixes = ["grc", "deu_frak", "frk", "lat", "la", "el-polyton"]
        return languages.filter { lang in
            let lower = lang.lowercased()
            for prefix in unsupportedPrefixes {
                if lower == prefix || lower.hasPrefix("\(prefix)_") || lower.hasPrefix("\(prefix)-") {
                    return false
                }
            }
            return true
        }
    }

    /// Sorts observations in standard reading order (top-to-bottom, left-to-right).
    public static func sortReadingOrder(_ observations: [RecognizedTextObservation]) -> [RecognizedTextObservation] {
        guard observations.count > 1 else { return observations }

        // Determine if bounding boxes are in normalized [0, 1] space or point space
        let isNormalized = observations.allSatisfy { $0.boundingBox.maxY <= 1.05 }
        let lineTolerance = isNormalized ? 0.015 : 10.0

        return observations.sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) < lineTolerance {
                return a.boundingBox.minX < b.boundingBox.minX
            }
            return a.boundingBox.minY < b.boundingBox.minY
        }
    }
}
