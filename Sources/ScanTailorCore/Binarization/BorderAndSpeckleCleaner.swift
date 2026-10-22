import Foundation
import ScanTailorContracts

/// Cleans binarized document pages by removing dark scanner/photocopier borders,
/// deskew wedge artifacts, and isolated salt-and-pepper noise speckles while
/// preserving punctuation and diacritics (`i`/`j` dots, periods, commas, accents).
///
/// Combines boundary-seeded morphological analysis (`SeedFill`) with context-aware
/// connected-component filtering (`ConnectedComponentAnalyzer`), inspired by
/// ScanTailor-Advanced `Despeckle` and edge cleanup filters.
public struct BorderAndSpeckleCleaner: Sendable, Equatable {

    /// Configuration parameters for border removal and context-aware despeckling.
    public struct Configuration: Sendable, Equatable, Codable {
        /// Whether to remove dark scanner borders and deskew edge wedges.
        public var removeBorders: Bool

        /// Distance in pixels from the outer image edges within which a component is
        /// considered proximate to the page border. Default is `16`.
        public var borderProximityMargin: Int

        /// Maximum thickness (as a fraction of page width or height) for an edge-hugging
        /// margin strip to be unconditionally classified as a border artifact. Default is `0.14`.
        public var maxBorderStripThicknessRatio: Double

        /// Minimum span (as a fraction of page width or height) along a page edge for a
        /// boundary-proximate component to be classified as a scan border or wedge. Default is `0.20`.
        public var minBorderSpanRatio: Double

        /// Minimum pixel count for a component confined strictly inside the outer border strip
        /// to be removed even if its span is shorter than `minBorderSpanRatio`. Default is `32`.
        public var minBorderEdgePixelThreshold: Int

        /// Whether to run context-aware connected-component despeckling.
        public var despeckle: Bool

        /// Maximum foreground pixel count for a connected component to be considered a
        /// candidate noise speckle. Components with `pixelCount > maxSpecklePixels` are
        /// classified as anchored text/graphics bodies. Default is `24` (for 600 DPI).
        public var maxSpecklePixels: Int

        /// Minimum foreground pixel count for a small component near a valid text body to be
        /// protected as a diacritic (`i`/`j` dot, accent) or punctuation mark.
        /// Ultra-tiny speckles strictly smaller than `minDiacriticPixels` (e.g., 1-pixel shots)
        /// are removed even near text. Default is `2`.
        public var minDiacriticPixels: Int

        /// Radius in pixels around anchored text body bounding boxes within which candidate
        /// diacritic/punctuation components (`minDiacriticPixels ... maxSpecklePixels`) are preserved.
        /// Default is `20`.
        public var diacriticProtectionRadius: Int

        /// Neighbor connectivity used for connected-component extraction. Default is `.eight`.
        public var connectivity: Connectivity

        public init(
            removeBorders: Bool = true,
            borderProximityMargin: Int = 16,
            maxBorderStripThicknessRatio: Double = 0.14,
            minBorderSpanRatio: Double = 0.20,
            minBorderEdgePixelThreshold: Int = 32,
            despeckle: Bool = true,
            maxSpecklePixels: Int = 24,
            minDiacriticPixels: Int = 2,
            diacriticProtectionRadius: Int = 20,
            connectivity: Connectivity = .eight
        ) {
            self.removeBorders = removeBorders
            self.borderProximityMargin = max(1, borderProximityMargin)
            self.maxBorderStripThicknessRatio = min(0.45, max(0.02, maxBorderStripThicknessRatio))
            self.minBorderSpanRatio = min(0.95, max(0.05, minBorderSpanRatio))
            self.minBorderEdgePixelThreshold = max(1, minBorderEdgePixelThreshold)
            self.despeckle = despeckle
            self.maxSpecklePixels = max(0, maxSpecklePixels)
            self.minDiacriticPixels = max(1, minDiacriticPixels)
            self.diacriticProtectionRadius = max(0, diacriticProtectionRadius)
            self.connectivity = connectivity
        }
    }

    /// Active cleaner configuration.
    public let configuration: Configuration

    /// Creates a border and speckle cleaner with the given configuration.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Runs the full cleanup pipeline (scan border removal followed by context-aware despeckling).
    /// - Parameter bitmap: Source 1-bit monochrome bitmap (`1` = black ink, `0` = white paper).
    /// - Returns: Cleaned 1-bit monochrome bitmap.
    public func clean(_ bitmap: borrowing BinaryBitmap) -> BinaryBitmap {
        var current = copy bitmap
        if configuration.removeBorders {
            current = removeScanBorders(from: current)
        }
        if configuration.despeckle && configuration.maxSpecklePixels > 0 {
            current = despecklePreservingDiacritics(current)
        }
        return current
    }

    /// Removes dark scanner borders, gutter shadow bars, and deskew wedge artifacts touching or
    /// hugging the outer page edges while preserving legitimate text that approaches a margin.
    /// - Parameter bitmap: Source 1-bit monochrome bitmap.
    /// - Returns: Bitmap with scan border components erased to white (`0`).
    public func removeScanBorders(from bitmap: borrowing BinaryBitmap) -> BinaryBitmap {
        let width = bitmap.width
        let height = bitmap.height
        guard width > 4 && height > 4 else { return copy bitmap }

        let margin = min(configuration.borderProximityMargin, min(width, height) / 4)
        let maxHorizontalStrip = max(margin, Int((Double(width) * configuration.maxBorderStripThicknessRatio).rounded()))
        let maxVerticalStrip = max(margin, Int((Double(height) * configuration.maxBorderStripThicknessRatio).rounded()))
        let minWidthSpan = max(4, Int((Double(width) * configuration.minBorderSpanRatio).rounded()))
        let minHeightSpan = max(4, Int((Double(height) * configuration.minBorderSpanRatio).rounded()))

        return ConnectedComponentAnalyzer.filterComponents(
            in: bitmap,
            connectivity: configuration.connectivity
        ) { comp in
            let bbox = comp.boundingBox

            let touchesOuterLeft = bbox.minX <= 1
            let touchesOuterRight = bbox.maxX >= width - 1
            let touchesOuterTop = bbox.minY <= 1
            let touchesOuterBottom = bbox.maxY >= height - 1
            let touchesAnyOuterEdge = touchesOuterLeft || touchesOuterRight || touchesOuterTop || touchesOuterBottom

            let nearLeft = bbox.minX < margin
            let nearRight = bbox.maxX > width - margin
            let nearTop = bbox.minY < margin
            let nearBottom = bbox.maxY > height - margin
            let nearAnyEdge = nearLeft || nearRight || nearTop || nearBottom

            // Interior components not near any boundary are always retained by border removal.
            guard nearAnyEdge else { return true }

            // 1. Multi-edge frame component (e.g., L-shaped, U-shaped, or 4-sided border frame)
            let outerEdgeTouchCount =
                (touchesOuterLeft ? 1 : 0) +
                (touchesOuterRight ? 1 : 0) +
                (touchesOuterTop ? 1 : 0) +
                (touchesOuterBottom ? 1 : 0)
            if outerEdgeTouchCount >= 2 {
                return false
            }

            // 2. Confined strictly within one of the outer margin strips
            let confinedToLeftStrip = nearLeft && bbox.maxX <= maxHorizontalStrip
            let confinedToRightStrip = nearRight && bbox.minX >= width - maxHorizontalStrip
            let confinedToTopStrip = nearTop && bbox.maxY <= maxVerticalStrip
            let confinedToBottomStrip = nearBottom && bbox.minY >= height - maxVerticalStrip

            if confinedToLeftStrip || confinedToRightStrip {
                // Erase if it touches the very outer edge, spans a significant fraction of height,
                // or has substantial border mass inside the narrow proximity margin.
                if touchesOuterLeft || touchesOuterRight || bbox.height >= minHeightSpan {
                    return false
                }
                if bbox.maxX <= margin || bbox.minX >= width - margin,
                   comp.pixelCount >= configuration.minBorderEdgePixelThreshold {
                    return false
                }
            }

            if confinedToTopStrip || confinedToBottomStrip {
                if touchesOuterTop || touchesOuterBottom || bbox.width >= minWidthSpan {
                    return false
                }
                if bbox.maxY <= margin || bbox.minY >= height - margin,
                   comp.pixelCount >= configuration.minBorderEdgePixelThreshold {
                    return false
                }
            }

            // 3. Long border bar / wedge touching the outer edge and spanning a large fraction of the page
            if touchesAnyOuterEdge {
                if (touchesOuterTop || touchesOuterBottom) && bbox.width >= minWidthSpan && bbox.height <= maxVerticalStrip * 2 {
                    return false
                }
                if (touchesOuterLeft || touchesOuterRight) && bbox.height >= minHeightSpan && bbox.width <= maxHorizontalStrip * 2 {
                    return false
                }
            }

            return true
        }
    }

    /// Removes isolated noise speckles (`pixelCount <= maxSpecklePixels`) while preserving
    /// small punctuation marks and diacritics (`i`/`j` dots, accents, periods) located within
    /// `diacriticProtectionRadius` of an anchored text/graphics component.
    /// - Parameter bitmap: Source 1-bit monochrome bitmap.
    /// - Returns: Despeckled 1-bit monochrome bitmap.
    public func despecklePreservingDiacritics(_ bitmap: borrowing BinaryBitmap) -> BinaryBitmap {
        let maxSpeckle = configuration.maxSpecklePixels
        guard maxSpeckle > 0 else { return copy bitmap }

        let width = bitmap.width
        let height = bitmap.height
        let radius = configuration.diacriticProtectionRadius
        let minDiacritic = configuration.minDiacriticPixels

        // First pass: extract all connected components and partition into anchored bodies vs candidate speckles.
        let allComponents = ConnectedComponentAnalyzer.extractComponents(
            from: bitmap,
            connectivity: configuration.connectivity
        )
        guard !allComponents.isEmpty else { return copy bitmap }

        // Build a dilated protection mask (or spatial grid) around all anchored text/graphics components
        // (`pixelCount > maxSpecklePixels`). Using a coarse spatial occupancy grid or dilated bounding
        // box table makes lookup O(1) per speckle.
        var protectionMask = BinaryBitmap(width: width, height: height, initialBlack: false)
        var hasAnchoredBodies = false

        for comp in allComponents where comp.pixelCount > maxSpeckle {
            hasAnchoredBodies = true
            guard radius > 0 else { continue }
            let box = comp.boundingBox
            let minX = max(0, box.minX - radius)
            let maxX = min(width, box.maxX + radius)
            let minY = max(0, box.minY - radius)
            let maxY = min(height, box.maxY + radius)

            for y in minY..<maxY {
                for x in minX..<maxX {
                    protectionMask[x, y] = true
                }
            }
        }

        // Second pass: filter components using O(1) protection lookup on the seed point / bounding box.
        return ConnectedComponentAnalyzer.filterComponents(
            in: bitmap,
            connectivity: configuration.connectivity
        ) { comp in
            if comp.pixelCount > maxSpeckle {
                return true
            }
            // Ultra-small single-pixel noise below minDiacriticPixels is always removed.
            if comp.pixelCount < minDiacritic {
                return false
            }
            guard hasAnchoredBodies && radius > 0 else {
                return false
            }
            // Preserve if the component's seed point or center lies within the diacritic protection zone
            let seed = comp.seedPoint
            if protectionMask[seed.x, seed.y] {
                return true
            }
            let centerX = min(width - 1, max(0, comp.boundingBox.minX + comp.boundingBox.width / 2))
            let centerY = min(height - 1, max(0, comp.boundingBox.minY + comp.boundingBox.height / 2))
            return protectionMask[centerX, centerY]
        }
    }
}
