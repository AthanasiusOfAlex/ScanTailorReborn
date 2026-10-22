import Foundation

/// Hardware-accelerated image processing and linear/non-linear resampling primitives.
///
/// Conforming types include `MetalComputeAccelerator` (backed by Apple Silicon Unified Memory GPU shaders
/// and Accelerate/vImage) and `PortableComputeAccelerator` (pure Swift SIMD portable fallback).
public protocol ComputeAccelerator: Sendable {
    /// Generates first-order ($\Sigma I$) and second-order ($\Sigma I^2$) integral images for $O(1)$ window queries.
    /// - Parameter buffer: The source grayscale buffer.
    /// - Returns: A dual integral buffer.
    func integralImage(of buffer: borrowing GrayscaleBuffer) -> IntegralBuffer

    /// Performs 2D Gaussian blur with standard deviation `sigma`.
    /// - Parameters:
    ///   - buffer: Source grayscale buffer.
    ///   - sigma: Standard deviation of the Gaussian kernel.
    /// - Returns: The smoothed grayscale buffer.
    func gaussianBlur(_ buffer: borrowing GrayscaleBuffer, sigma: Double) -> GrayscaleBuffer

    /// Resamples a grayscale buffer according to an affine transformation matrix.
    /// - Parameters:
    ///   - buffer: The source grayscale buffer.
    ///   - transform: The affine transformation to apply.
    ///   - outputSize: Desired output dimensions in pixels.
    /// - Returns: The warped grayscale buffer.
    func affineWarp(_ buffer: borrowing GrayscaleBuffer, transform: AffineTransform2D, outputSize: Size2I) -> GrayscaleBuffer

    /// Resamples a grayscale buffer according to a 2D non-linear displacement mesh.
    /// - Parameters:
    ///   - buffer: The source grayscale buffer.
    ///   - displacementGrid: Sampling grid mapping output pixels to source pixels.
    ///   - outputSize: Desired output dimensions in pixels.
    /// - Returns: The rectified grayscale buffer.
    func meshWarp(_ buffer: borrowing GrayscaleBuffer, displacementGrid: borrowing DewarpGrid, outputSize: Size2I) -> GrayscaleBuffer

    /// Fast 2x2 area-thresholded downsampling from 600 DPI 1-bit to 300 DPI 1-bit.
    /// - Parameter bitmap: Source 600 DPI binary bitmap.
    /// - Returns: Half-resolution 300 DPI binary bitmap.
    func downsampleBinaryTo300DPI(_ bitmap: borrowing BinaryBitmap) -> BinaryBitmap
}
