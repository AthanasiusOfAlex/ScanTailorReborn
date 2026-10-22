import Foundation
import ScanTailorContracts

/// Word-parallel $2 \times 2$ area-thresholded binary downsampler for 600 DPI $\rightarrow$ 300 DPI conversion
/// and multi-scale pyramid construction.
public enum BinaryDownsampler {

    /// Downsamples a `BinaryBitmap` by a factor of $2 \times 2$ using word-parallel bit compaction.
    ///
    /// For dimensions $\ge 2$, the output size is `(bitmap.width / 2, bitmap.height / 2)`.
    /// Each output pixel `(x, y)` is set to black (`1`) if at least `minBlackSubpixels` (in `1...4`)
    /// of the $2 \times 2$ block `{(2x, 2y), (2x+1, 2y), (2x, 2y+1), (2x+1, 2y+1)}` are black.
    ///
    /// - Parameters:
    ///   - bitmap: Source binary bitmap (e.g., at 600 DPI).
    ///   - minBlackSubpixels: Minimum count of black pixels in each $2 \times 2$ block required to produce
    ///     a black output pixel (clamped to `1...4`). Default is `2`, which preserves 2-pixel (0.085 mm) serifs
    ///     while suppressing single-pixel edge quantization noise.
    /// - Returns: Half-resolution `BinaryBitmap` (e.g., at 300 DPI).
    public static func downsample2x(
        _ bitmap: borrowing BinaryBitmap,
        minBlackSubpixels: Int = 2
    ) -> BinaryBitmap {
        let threshold = max(1, min(4, minBlackSubpixels))

        if bitmap.width < 2 || bitmap.height < 2 {
            let outW = max(1, bitmap.width / 2)
            let outH = max(1, bitmap.height / 2)
            var fallback = BinaryBitmap(width: outW, height: outH, initialBlack: false)
            fallback[0, 0] = bitmap[0, 0]
            return fallback
        }

        let outWidth = bitmap.width / 2
        let outHeight = bitmap.height / 2
        var result = BinaryBitmap(width: outWidth, height: outHeight, initialBlack: false)

        let srcWordsPerRow = bitmap.wordsPerRow
        let dstWordsPerRow = result.wordsPerRow
        let trailingMask = result.trailingWordMask

        bitmap.withUnsafeWords { srcWords in
            result.withUnsafeMutableWords { dstWords in
                for dstY in 0..<outHeight {
                    let srcRow0 = (dstY * 2) * srcWordsPerRow
                    let srcRow1 = (dstY * 2 + 1) * srcWordsPerRow
                    let dstRowBase = dstY * dstWordsPerRow

                    for dstCol in 0..<dstWordsPerRow {
                        let srcCol0 = dstCol * 2
                        let srcCol1 = srcCol0 + 1

                        let w0 = srcWords[srcRow0 + srcCol0]
                        let w1 = srcWords[srcRow1 + srcCol0]
                        let comb0 = combine2x2Word(row0: w0, row1: w1, threshold: threshold)
                        let high32 = UInt64(compactEvenBits(comb0))

                        let low32: UInt64
                        if srcCol1 < srcWordsPerRow {
                            let w2 = srcWords[srcRow0 + srcCol1]
                            let w3 = srcWords[srcRow1 + srcCol1]
                            let comb1 = combine2x2Word(row0: w2, row1: w3, threshold: threshold)
                            low32 = UInt64(compactEvenBits(comb1))
                        } else {
                            low32 = 0
                        }

                        var outWord = (high32 << 32) | low32
                        if dstCol == dstWordsPerRow - 1 {
                            outWord &= trailingMask
                        }
                        dstWords[dstRowBase + dstCol] = outWord
                    }
                }
            }
        }

        return result
    }

    /// Evaluates the $2 \times 2$ threshold predicate across 32 pairs in a 64-bit word simultaneously,
    /// placing the 32 boolean results at bit positions `63, 61, 59, ..., 1`.
    @inline(__always)
    private static func combine2x2Word(row0: UInt64, row1: UInt64, threshold: Int) -> UInt64 {
        let a = row0
        let b = row0 << 1
        let c = row1
        let d = row1 << 1

        let raw: UInt64
        switch threshold {
        case 1:
            raw = a | b | c | d
        case 2:
            raw = (a & b) | (c & d) | ((a | b) & (c | d))
        case 3:
            raw = (a & b & (c | d)) | (c & d & (a | b))
        default:
            raw = a & b & c & d
        }
        return raw & 0xAAAA_AAAA_AAAA_AAAA
    }

    /// Compacts the 32 bits at odd shifts (`63, 61, 59, ..., 1`) into a contiguous 32-bit word (`31...0`).
    @inline(__always)
    private static func compactEvenBits(_ x: UInt64) -> UInt32 {
        var v = (x >> 1) & 0x5555_5555_5555_5555
        v = (v | (v >> 1)) & 0x3333_3333_3333_3333
        v = (v | (v >> 2)) & 0x0F0F_0F0F_0F0F_0F0F
        v = (v | (v >> 4)) & 0x00FF_00FF_00FF_00FF
        v = (v | (v >> 8)) & 0x0000_FFFF_0000_FFFF
        v = (v | (v >> 16)) & 0x0000_0000_FFFF_FFFF
        return UInt32(truncatingIfNeeded: v)
    }
}
