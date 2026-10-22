import Foundation
import ScanTailorContracts

/// High-performance word-parallel binary morphological operators on 1-bit `BinaryBitmap` rasters.
///
/// Adapted from ScanTailor-Advanced `imageproc::Morphology`, using separable 1D horizontal and
/// vertical passes with in-place logarithmic doubling ($O(\frac{W}{64} \log K)$) so arbitrary
/// structuring element sizes execute at memory-bandwidth speeds without intermediate heap allocations.
public enum BinaryMorphology {

    // MARK: - Public API

    /// Dilates black foreground pixels (`1`) using a rectangular structuring element of size `brickWidth x brickHeight`.
    ///
    /// Outside the image bounds, pixels are assumed to be white (`0`).
    /// - Parameters:
    ///   - bitmap: Source binary bitmap.
    ///   - brickWidth: Width of the rectangular structuring element in pixels ($\ge 1$).
    ///   - brickHeight: Height of the rectangular structuring element in pixels ($\ge 1$).
    /// - Returns: The dilated `BinaryBitmap`.
    public static func dilateBrick(
        _ bitmap: borrowing BinaryBitmap,
        width brickWidth: Int,
        height brickHeight: Int
    ) -> BinaryBitmap {
        precondition(brickWidth >= 1 && brickHeight >= 1, "Brick dimensions must be at least 1x1")
        if brickWidth == 1 && brickHeight == 1 {
            return copy bitmap
        }

        let left = (brickWidth - 1) / 2
        let right = brickWidth - 1 - left
        let top = (brickHeight - 1) / 2
        let bottom = brickHeight - 1 - top

        var result = copy bitmap
        dilateInPlace(&result, left: left, right: right, top: top, bottom: bottom)
        return result
    }

    /// Erodes black foreground pixels (`1`) using a rectangular structuring element of size `brickWidth x brickHeight`.
    ///
    /// Uses De Morgan duality ($\text{Erode}(B) = \neg \text{Dilate}(\neg B)$) with reflected structuring element offsets
    /// so that dilation and erosion form an exact adjoint pair even for even brick dimensions.
    /// - Parameters:
    ///   - bitmap: Source binary bitmap.
    ///   - brickWidth: Width of the rectangular structuring element in pixels ($\ge 1$).
    ///   - brickHeight: Height of the rectangular structuring element in pixels ($\ge 1$).
    ///   - borderFillBlack: If `true` (default), pixels outside the image bounds are treated as black (`1`),
    ///     preventing foreground objects touching the image boundary from eroding inward from the border.
    ///     If `false`, pixels outside the image bounds are treated as white (`0`).
    /// - Returns: The eroded `BinaryBitmap`.
    public static func erodeBrick(
        _ bitmap: borrowing BinaryBitmap,
        width brickWidth: Int,
        height brickHeight: Int,
        borderFillBlack: Bool = true
    ) -> BinaryBitmap {
        precondition(brickWidth >= 1 && brickHeight >= 1, "Brick dimensions must be at least 1x1")
        if brickWidth == 1 && brickHeight == 1 {
            return copy bitmap
        }

        let left = (brickWidth - 1) / 2
        let right = brickWidth - 1 - left
        let top = (brickHeight - 1) / 2
        let bottom = brickHeight - 1 - top

        // Under adjoint reflection, the erosion window for pixel x is [x - right, x + left]
        // and for pixel y is [y - bottom, y + top].
        var result = bitmap.inverted()
        dilateInPlace(&result, left: right, right: left, top: bottom, bottom: top)
        result.invert()

        if !borderFillBlack {
            // When outside is assumed white (0), any pixel whose [x - right, x + left] x [y - bottom, y + top]
            // window extends outside [0, width) x [0, height) must become white (0).
            clearBorders(&result, leftMargin: right, rightMargin: left, topMargin: bottom, bottomMargin: top)
        }

        return result
    }

    /// Performs morphological opening (erosion followed by dilation) with a rectangular structuring element.
    ///
    /// Opening removes small foreground speckles and thin protrusions smaller than the brick while preserving
    /// the size and position of larger structures.
    /// - Parameters:
    ///   - bitmap: Source binary bitmap.
    ///   - brickWidth: Width of the rectangular structuring element ($\ge 1$).
    ///   - brickHeight: Height of the rectangular structuring element ($\ge 1$).
    ///   - borderFillBlack: Border policy during the erosion step.
    /// - Returns: The opened `BinaryBitmap`.
    public static func openBrick(
        _ bitmap: borrowing BinaryBitmap,
        width brickWidth: Int,
        height brickHeight: Int,
        borderFillBlack: Bool = true
    ) -> BinaryBitmap {
        let eroded = erodeBrick(bitmap, width: brickWidth, height: brickHeight, borderFillBlack: borderFillBlack)
        return dilateBrick(eroded, width: brickWidth, height: brickHeight)
    }

    /// Performs morphological closing (dilation followed by erosion) with a rectangular structuring element.
    ///
    /// Closing bridges narrow gaps between characters/words and fills small interior holes.
    /// - Parameters:
    ///   - bitmap: Source binary bitmap.
    ///   - brickWidth: Width of the rectangular structuring element ($\ge 1$).
    ///   - brickHeight: Height of the rectangular structuring element ($\ge 1$).
    ///   - borderFillBlack: Border policy during the erosion step.
    /// - Returns: The closed `BinaryBitmap`.
    public static func closeBrick(
        _ bitmap: borrowing BinaryBitmap,
        width brickWidth: Int,
        height brickHeight: Int,
        borderFillBlack: Bool = true
    ) -> BinaryBitmap {
        let dilated = dilateBrick(bitmap, width: brickWidth, height: brickHeight)
        return erodeBrick(dilated, width: brickWidth, height: brickHeight, borderFillBlack: borderFillBlack)
    }

    // MARK: - Internal In-Place Word-Parallel Engine

    /// Dilates `bitmap` in-place so that output pixel `(x, y)` becomes the OR of input pixels in
    /// `[x - left, x + right] x [y - top, y + bottom]`.
    internal static func dilateInPlace(
        _ bitmap: inout BinaryBitmap,
        left: Int,
        right: Int,
        top: Int,
        bottom: Int
    ) {
        if left > 0 || right > 0 {
            dilateHorizontalInPlace(&bitmap, left: left, right: right)
        }
        if top > 0 || bottom > 0 {
            dilateVerticalInPlace(&bitmap, top: top, bottom: bottom)
        }
    }

    /// Word-parallel horizontal dilation in-place using two-stage logarithmic doubling:
    /// 1. Propagate LEFT by `right` pixels (`row[u] = OR_{d=0..right} row[u + d]`).
    /// 2. Propagate RIGHT by `left` pixels (`row[x] = OR_{e=0..left} row[x - e]`).
    private static func dilateHorizontalInPlace(_ bitmap: inout BinaryBitmap, left: Int, right: Int) {
        let width = bitmap.width
        let height = bitmap.height
        let wordsPerRow = bitmap.wordsPerRow
        let trailingMask = bitmap.trailingWordMask

        let clampedRight = min(right, width - 1)
        let clampedLeft = min(left, width - 1)

        bitmap.withUnsafeMutableWords { words in
            for y in 0..<height {
                let rowBase = y * wordsPerRow

                // Stage 1: Propagate LEFT by `clampedRight` (each bit u gets OR of [u, u + clampedRight])
                if clampedRight > 0 {
                    let targetSpan = clampedRight + 1
                    var k = 1
                    while k * 2 <= targetSpan {
                        orRowShiftedLeft(words: &words, rowBase: rowBase, wordsPerRow: wordsPerRow, shift: k)
                        k *= 2
                    }
                    let remainder = targetSpan - k
                    if remainder > 0 {
                        orRowShiftedLeft(words: &words, rowBase: rowBase, wordsPerRow: wordsPerRow, shift: remainder)
                    }
                }

                // Stage 2: Propagate RIGHT by `clampedLeft` (each bit x gets OR of [x - clampedLeft, x])
                if clampedLeft > 0 {
                    let targetSpan = clampedLeft + 1
                    var k = 1
                    while k * 2 <= targetSpan {
                        orRowShiftedRight(
                            words: &words,
                            rowBase: rowBase,
                            wordsPerRow: wordsPerRow,
                            shift: k,
                            trailingMask: trailingMask
                        )
                        k *= 2
                    }
                    let remainder = targetSpan - k
                    if remainder > 0 {
                        orRowShiftedRight(
                            words: &words,
                            rowBase: rowBase,
                            wordsPerRow: wordsPerRow,
                            shift: remainder,
                            trailingMask: trailingMask
                        )
                    }
                }
            }
        }
    }

    /// Computes `row |= (row << shift)` in-place across a single row of 64-bit MSB-first words.
    @inline(__always)
    private static func orRowShiftedLeft(
        words: inout UnsafeMutableBufferPointer<UInt64>,
        rowBase: Int,
        wordsPerRow: Int,
        shift: Int
    ) {
        let wordShift = shift >> 6
        let bitShift = shift & 63
        guard wordShift < wordsPerRow else { return }

        if bitShift == 0 {
            for c in 0..<(wordsPerRow - wordShift) {
                words[rowBase + c] |= words[rowBase + c + wordShift]
            }
        } else {
            let invShift = 64 - bitShift
            let limit = wordsPerRow - wordShift
            for c in 0..<limit {
                let srcCol = c + wordShift
                let w0 = words[rowBase + srcCol] << bitShift
                let w1: UInt64 = (srcCol + 1 < wordsPerRow) ? (words[rowBase + srcCol + 1] >> invShift) : 0
                words[rowBase + c] |= (w0 | w1)
            }
        }
    }

    /// Computes `row |= (row >> shift)` in-place across a single row of 64-bit MSB-first words.
    @inline(__always)
    private static func orRowShiftedRight(
        words: inout UnsafeMutableBufferPointer<UInt64>,
        rowBase: Int,
        wordsPerRow: Int,
        shift: Int,
        trailingMask: UInt64
    ) {
        let wordShift = shift >> 6
        let bitShift = shift & 63
        guard wordShift < wordsPerRow else { return }

        if bitShift == 0 {
            for c in stride(from: wordsPerRow - 1, through: wordShift, by: -1) {
                var val = words[rowBase + c] | words[rowBase + c - wordShift]
                if c == wordsPerRow - 1 {
                    val &= trailingMask
                }
                words[rowBase + c] = val
            }
        } else {
            let invShift = 64 - bitShift
            for c in stride(from: wordsPerRow - 1, through: wordShift, by: -1) {
                let srcCol = c - wordShift
                let w0 = words[rowBase + srcCol] >> bitShift
                let w1: UInt64 = (srcCol > 0) ? (words[rowBase + srcCol - 1] << invShift) : 0
                var val = words[rowBase + c] | w0 | w1
                if c == wordsPerRow - 1 {
                    val &= trailingMask
                }
                words[rowBase + c] = val
            }
        }
    }

    /// Word-parallel vertical dilation in-place using two-stage logarithmic doubling:
    /// 1. Propagate UP by `bottom` rows (`row[y] = OR_{d=0..bottom} row[y + d]`).
    /// 2. Propagate DOWN by `top` rows (`row[y] = OR_{e=0..top} row[y - e]`).
    private static func dilateVerticalInPlace(_ bitmap: inout BinaryBitmap, top: Int, bottom: Int) {
        let height = bitmap.height
        let wordsPerRow = bitmap.wordsPerRow

        let clampedBottom = min(bottom, height - 1)
        let clampedTop = min(top, height - 1)

        bitmap.withUnsafeMutableWords { words in
            // Stage 1: Propagate UP by `clampedBottom`
            if clampedBottom > 0 {
                let targetSpan = clampedBottom + 1
                var k = 1
                while k * 2 <= targetSpan {
                    orRowsShiftedUp(words: &words, height: height, wordsPerRow: wordsPerRow, shift: k)
                    k *= 2
                }
                let remainder = targetSpan - k
                if remainder > 0 {
                    orRowsShiftedUp(words: &words, height: height, wordsPerRow: wordsPerRow, shift: remainder)
                }
            }

            // Stage 2: Propagate DOWN by `clampedTop`
            if clampedTop > 0 {
                let targetSpan = clampedTop + 1
                var k = 1
                while k * 2 <= targetSpan {
                    orRowsShiftedDown(words: &words, height: height, wordsPerRow: wordsPerRow, shift: k)
                    k *= 2
                }
                let remainder = targetSpan - k
                if remainder > 0 {
                    orRowsShiftedDown(words: &words, height: height, wordsPerRow: wordsPerRow, shift: remainder)
                }
            }
        }
    }

    @inline(__always)
    private static func orRowsShiftedUp(
        words: inout UnsafeMutableBufferPointer<UInt64>,
        height: Int,
        wordsPerRow: Int,
        shift: Int
    ) {
        guard shift < height else { return }
        let rowOffset = shift * wordsPerRow
        let limitIndex = (height - shift) * wordsPerRow
        for idx in 0..<limitIndex {
            words[idx] |= words[idx + rowOffset]
        }
    }

    @inline(__always)
    private static func orRowsShiftedDown(
        words: inout UnsafeMutableBufferPointer<UInt64>,
        height: Int,
        wordsPerRow: Int,
        shift: Int
    ) {
        guard shift < height else { return }
        let rowOffset = shift * wordsPerRow
        let totalWords = height * wordsPerRow
        for idx in stride(from: totalWords - 1, through: rowOffset, by: -1) {
            words[idx] |= words[idx - rowOffset]
        }
    }

    /// Clears border strips when `borderFillBlack == false` during erosion.
    private static func clearBorders(
        _ bitmap: inout BinaryBitmap,
        leftMargin: Int,
        rightMargin: Int,
        topMargin: Int,
        bottomMargin: Int
    ) {
        let width = bitmap.width
        let height = bitmap.height
        let wordsPerRow = bitmap.wordsPerRow

        if leftMargin + rightMargin >= width || topMargin + bottomMargin >= height {
            bitmap = BinaryBitmap(width: width, height: height, initialBlack: false)
            return
        }

        // Clear top rows
        let clampedTop = min(topMargin, height)
        for y in 0..<clampedTop {
            let rowBase = y * wordsPerRow
            for c in 0..<wordsPerRow {
                bitmap.words[rowBase + c] = 0
            }
        }

        // Clear bottom rows
        let bottomStart = max(clampedTop, height - bottomMargin)
        for y in bottomStart..<height {
            let rowBase = y * wordsPerRow
            for c in 0..<wordsPerRow {
                bitmap.words[rowBase + c] = 0
            }
        }

        // Clear left and right columns on remaining interior rows
        if leftMargin > 0 || rightMargin > 0 {
            for y in clampedTop..<bottomStart {
                if leftMargin > 0 {
                    let fullLeftWords = leftMargin >> 6
                    let remLeftBits = leftMargin & 63
                    let rowBase = y * wordsPerRow
                    for c in 0..<min(fullLeftWords, wordsPerRow) {
                        bitmap.words[rowBase + c] = 0
                    }
                    if remLeftBits > 0 && fullLeftWords < wordsPerRow {
                        let mask = ~UInt64(0) >> remLeftBits
                        bitmap.words[rowBase + fullLeftWords] &= mask
                    }
                }
                if rightMargin > 0 {
                    let rightStartX = width - rightMargin
                    let firstRightWord = rightStartX >> 6
                    let firstRightBitInWord = rightStartX & 63
                    let rowBase = y * wordsPerRow
                    if firstRightBitInWord > 0 && firstRightWord < wordsPerRow {
                        let keepMask = ~UInt64(0) << (64 - firstRightBitInWord)
                        bitmap.words[rowBase + firstRightWord] &= keepMask
                    }
                    let clearStartWord = (firstRightBitInWord == 0) ? firstRightWord : (firstRightWord + 1)
                    if clearStartWord < wordsPerRow {
                        for c in clearStartWord..<wordsPerRow {
                            bitmap.words[rowBase + c] = 0
                        }
                    }
                }
            }
        }
    }
}
