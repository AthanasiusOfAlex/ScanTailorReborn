import Foundation
import ScanTailorContracts

/// Pixel connectivity mode for morphological reconstruction and connected-component labeling.
public enum Connectivity: Sendable, Equatable, Codable {
    /// Orthogonal 4-neighbor connectivity (north, south, east, west).
    case four
    /// Orthogonal and diagonal 8-neighbor connectivity.
    case eight
}

/// Word-parallel morphological reconstruction (geodesic dilation / flood-fill) on 1-bit `BinaryBitmap` rasters.
///
/// Adapted from ScanTailor-Advanced `imageproc::seedFill`, operating directly on 64-bit packed words
/// so that 64 columns propagate simultaneously across rows.
public enum SeedFill {

    /// Reconstructs (flood-fills) black foreground regions of `mask` that are connected to black pixels in `seed`.
    /// - Parameters:
    ///   - seed: Starting marker bitmap (`1` = seed point). Must match `mask` dimensions.
    ///   - mask: Constraining mask bitmap (`1` = allowed foreground region).
    ///   - connectivity: Neighbor connectivity (`.four` or `.eight`). Default is `.eight`.
    /// - Returns: A `BinaryBitmap` containing all connected components of `mask` that overlap at least one black pixel of `seed`.
    public static func reconstruct(
        seed: borrowing BinaryBitmap,
        mask: borrowing BinaryBitmap,
        connectivity: Connectivity = .eight
    ) -> BinaryBitmap {
        precondition(
            seed.width == mask.width && seed.height == mask.height,
            "Seed (\(seed.width)x\(seed.height)) and mask (\(mask.width)x\(mask.height)) dimensions must match"
        )

        var result = seed.bitwiseAnd(mask)
        let height = mask.height
        let wordsPerRow = mask.wordsPerRow
        let totalWords = height * wordsPerRow

        var queue = ContiguousArray<Int>()
        queue.reserveCapacity(min(totalWords, 1024))
        var inQueue = ContiguousArray<Bool>(repeating: false, count: totalWords)

        result.withUnsafeMutableWords { resultWords in
            mask.withUnsafeWords { maskWords in
                for idx in 0..<totalWords {
                    if resultWords[idx] != 0 {
                        inQueue[idx] = true
                        queue.append(idx)
                    }
                }

                var head = 0
                while head < queue.count {
                    let idx = queue[head]
                    head += 1
                    inQueue[idx] = false

                    let m = maskWords[idx]
                    var w = resultWords[idx] & m
                    if w == 0 { continue }

                    // Expand horizontally within the current 64-bit word until convergence
                    while true {
                        let expanded = (w | (w << 1) | (w >> 1)) & m
                        if expanded == w { break }
                        w = expanded
                    }
                    resultWords[idx] = w

                    let y = idx / wordsPerRow
                    let col = idx % wordsPerRow

                    @inline(__always)
                    func propagate(to neighborIdx: Int, incoming: UInt64) {
                        let allowed = incoming & maskWords[neighborIdx]
                        if allowed == 0 { return }
                        let oldVal = resultWords[neighborIdx]
                        let newVal = oldVal | allowed
                        if newVal != oldVal {
                            resultWords[neighborIdx] = newVal
                            if !inQueue[neighborIdx] {
                                inQueue[neighborIdx] = true
                                queue.append(neighborIdx)
                            }
                        }
                    }

                    let hasLeftmostBit = (w & (UInt64(1) << 63)) != 0
                    let hasRightmostBit = (w & 1) != 0

                    // Horizontal neighbor words on the same row
                    if col > 0 && hasLeftmostBit {
                        propagate(to: idx - 1, incoming: 1)
                    }
                    if col + 1 < wordsPerRow && hasRightmostBit {
                        propagate(to: idx + 1, incoming: UInt64(1) << 63)
                    }

                    // Vertical neighbor words on row y - 1 and row y + 1
                    switch connectivity {
                    case .four:
                        if y > 0 {
                            propagate(to: idx - wordsPerRow, incoming: w)
                        }
                        if y + 1 < height {
                            propagate(to: idx + wordsPerRow, incoming: w)
                        }

                    case .eight:
                        let midReach = w | (w << 1) | (w >> 1)
                        if y > 0 {
                            let upIdx = idx - wordsPerRow
                            propagate(to: upIdx, incoming: midReach)
                            if col > 0 && hasLeftmostBit {
                                propagate(to: upIdx - 1, incoming: 1)
                            }
                            if col + 1 < wordsPerRow && hasRightmostBit {
                                propagate(to: upIdx + 1, incoming: UInt64(1) << 63)
                            }
                        }
                        if y + 1 < height {
                            let downIdx = idx + wordsPerRow
                            propagate(to: downIdx, incoming: midReach)
                            if col > 0 && hasLeftmostBit {
                                propagate(to: downIdx - 1, incoming: 1)
                            }
                            if col + 1 < wordsPerRow && hasRightmostBit {
                                propagate(to: downIdx + 1, incoming: UInt64(1) << 63)
                            }
                        }
                    }
                }
            }
        }

        return result
    }

    /// Creates a border seed along the 1-pixel outer perimeter of `bitmap` and extracts all black foreground
    /// regions connected to the image edges.
    /// - Parameters:
    ///   - bitmap: Source binary bitmap.
    ///   - connectivity: Neighbor connectivity (default: `.eight`).
    /// - Returns: A `BinaryBitmap` containing only the border-connected foreground components.
    public static func extractBorderConnected(
        from bitmap: borrowing BinaryBitmap,
        connectivity: Connectivity = .eight
    ) -> BinaryBitmap {
        let width = bitmap.width
        let height = bitmap.height
        let wordsPerRow = bitmap.wordsPerRow

        var borderSeed = BinaryBitmap(width: width, height: height, initialBlack: false)
        bitmap.withUnsafeWords { srcWords in
            borderSeed.withUnsafeMutableWords { seedWords in
                // Top row (y = 0) and bottom row (y = height - 1)
                for c in 0..<wordsPerRow {
                    seedWords[c] = srcWords[c]
                    if height > 1 {
                        let bottomIdx = (height - 1) * wordsPerRow + c
                        seedWords[bottomIdx] = srcWords[bottomIdx]
                    }
                }

                // Leftmost column (x = 0) and rightmost column (x = width - 1)
                let leftMask = UInt64(1) << 63
                let rightCol = (width - 1) >> 6
                let rightMask = UInt64(1) << (63 - ((width - 1) & 63))

                if height > 2 {
                    for y in 1..<(height - 1) {
                        let rowBase = y * wordsPerRow
                        seedWords[rowBase] |= (srcWords[rowBase] & leftMask)
                        seedWords[rowBase + rightCol] |= (srcWords[rowBase + rightCol] & rightMask)
                    }
                }
            }
        }

        return reconstruct(seed: borderSeed, mask: bitmap, connectivity: connectivity)
    }

    /// Removes dark photocopier borders, edge shadows, or margin artifacts touching the outer boundary of `bitmap`.
    /// - Parameters:
    ///   - bitmap: Source binary bitmap.
    ///   - connectivity: Neighbor connectivity (default: `.eight`).
    /// - Returns: A copy of `bitmap` with all border-connected black components erased to white (`0`).
    public static func removeBorderConnected(
        from bitmap: borrowing BinaryBitmap,
        connectivity: Connectivity = .eight
    ) -> BinaryBitmap {
        let borderComponents = extractBorderConnected(from: bitmap, connectivity: connectivity)
        return bitmap.subtracting(borderComponents)
    }

    /// Fills enclosed white background holes inside black foreground objects.
    /// - Parameters:
    ///   - bitmap: Source binary bitmap.
    ///   - connectivity: Background connectivity (default: `.four`, standard for dual to 8-connected foreground).
    /// - Returns: A `BinaryBitmap` with all interior white holes filled with black (`1`).
    public static func fillHoles(
        in bitmap: borrowing BinaryBitmap,
        connectivity: Connectivity = .four
    ) -> BinaryBitmap {
        let inverted = bitmap.inverted()
        let exteriorBackground = extractBorderConnected(from: inverted, connectivity: connectivity)
        return exteriorBackground.inverted()
    }
}
