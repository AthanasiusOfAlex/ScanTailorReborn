import ScanTailorContracts

/// Fits a 3D cylindrical / cubic-sheet page model to traced text-line curves
/// and generates a rectified `DewarpGrid` that removes both vertical baseline curl
/// and horizontal foreshortening near the spine.
public struct CylindricalDewarpSolver: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// Number of horizontal grid cells in the generated `DewarpGrid`.
        public var gridColumns: Int
        /// Number of vertical grid cells in the generated `DewarpGrid`.
        public var gridRows: Int
        /// Minimum number of traced text lines required to fit a 3D surface model.
        public var minLinesRequired: Int
        /// Maximum number of alternating Gauss-Newton / IRLS iterations.
        public var maxIterations: Int
        /// Huber loss threshold (in normalized vertical coordinates) for outlier robustness.
        public var huberDelta: Double
        /// Tikhonov regularization weight on cubic and quadratic depth terms.
        public var regularizationWeight: Double
        /// Scaling factor coupling vertical baseline slope to horizontal foreshortening arc-length.
        public var foreshorteningCoupling: Double
        /// Maximum allowed absolute normalized depth amplitude to prevent extreme warp blowup.
        public var maxNormalizedCurlAmplitude: Double

        public init(
            gridColumns: Int = 32,
            gridRows: Int = 32,
            minLinesRequired: Int = 3,
            maxIterations: Int = 25,
            huberDelta: Double = 0.015,
            regularizationWeight: Double = 1e-4,
            foreshorteningCoupling: Double = 1.0,
            maxNormalizedCurlAmplitude: Double = 0.25
        ) {
            self.gridColumns = max(4, gridColumns)
            self.gridRows = max(4, gridRows)
            self.minLinesRequired = max(2, minLinesRequired)
            self.maxIterations = max(5, maxIterations)
            self.huberDelta = max(1e-4, huberDelta)
            self.regularizationWeight = max(0.0, regularizationWeight)
            self.foreshorteningCoupling = max(0.0, foreshorteningCoupling)
            self.maxNormalizedCurlAmplitude = max(0.02, maxNormalizedCurlAmplitude)
        }
    }

    /// Fitted parameters of the 3D cubic-sheet page surface over normalized page coordinates
    /// $u \in [-1, 1]$ and $v \in [-1, 1]$.
    ///
    /// A point with rectified normalized coordinates $(\hat{u}, v)$ maps to source normalized
    /// horizontal coordinate $u = s^{-1}(\hat{u})$ via inverse arc-length parameterization, and
    /// vertical source coordinate:
    /// $$v_{\text{src}}(u, v) = v + (1 + \beta v) \cdot (\alpha_1 u^3 + \alpha_2 u^2 + \alpha_3 u)$$
    public struct SurfaceModel: Sendable, Equatable {
        /// Cubic depth coefficient $\alpha_1$ (models S-curve or asymmetric gutter roll-off).
        public let alpha1: Double
        /// Quadratic depth coefficient $\alpha_2$ (models symmetric parabolic page arch).
        public let alpha2: Double
        /// Linear tilt coefficient $\alpha_3$ (models residual baseline skew).
        public let alpha3: Double
        /// Vertical perspective coupling $\beta$ (models top-to-bottom variation in curve amplitude).
        public let beta: Double
        /// Horizontal domain center $x_0$ in pixels.
        public let centerX: Double
        /// Horizontal half-span $R_x$ in pixels ($u = (x - x_0) / R_x$).
        public let halfWidth: Double
        /// Vertical domain center $y_0$ in pixels.
        public let centerY: Double
        /// Vertical half-span $R_y$ in pixels ($v = (y - y_0) / R_y$).
        public let halfHeight: Double
        /// Root-mean-square vertical residual in pixels across all fitted text-line points.
        public let residualRMSPixels: Double
        /// Number of text lines used in the fit.
        public let fittedLineCount: Int

        public init(
            alpha1: Double,
            alpha2: Double,
            alpha3: Double,
            beta: Double,
            centerX: Double,
            halfWidth: Double,
            centerY: Double,
            halfHeight: Double,
            residualRMSPixels: Double,
            fittedLineCount: Int
        ) {
            self.alpha1 = alpha1
            self.alpha2 = alpha2
            self.alpha3 = alpha3
            self.beta = beta
            self.centerX = centerX
            self.halfWidth = halfWidth
            self.centerY = centerY
            self.halfHeight = halfHeight
            self.residualRMSPixels = residualRMSPixels
            self.fittedLineCount = fittedLineCount
        }

        /// Evaluates the normalized depth / baseline profile $Z(u) = \alpha_1 u^3 + \alpha_2 u^2 + \alpha_3 u$.
        @inline(__always)
        public func depthProfile(u: Double) -> Double {
            ((alpha1 * u + alpha2) * u + alpha3) * u
        }

        /// Evaluates the derivative $Z'(u) = 3\alpha_1 u^2 + 2\alpha_2 u + \alpha_3$.
        @inline(__always)
        public func depthDerivative(u: Double) -> Double {
            (3.0 * alpha1 * u + 2.0 * alpha2) * u + alpha3
        }
    }

    /// Complete result of 3D cylindrical / cubic-sheet dewarping.
    public struct Solution: Sendable, Equatable {
        /// The mapping grid from rectified output coordinates to curved source image coordinates.
        public let grid: DewarpGrid
        /// The fitted 3D cubic-sheet surface model, or `nil` if fallback to identity occurred.
        public let model: SurfaceModel?

        public init(grid: DewarpGrid, model: SurfaceModel?) {
            self.grid = grid
            self.model = model
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Traces text lines in `bitmap` using `tracer` and solves for the 3D dewarp grid.
    public func solve(
        in bitmap: borrowing BinaryBitmap,
        tracer: TextLineTracer = TextLineTracer()
    ) -> Solution {
        let lines = tracer.traceLines(in: bitmap)
        return solve(
            pageSize: Size2I(width: bitmap.width, height: bitmap.height),
            lines: lines
        )
    }

    /// Solves for the 3D cubic-sheet surface model and rectified `DewarpGrid` directly from
    /// traced text-line polylines.
    public func solve(
        pageSize: Size2I,
        lines: [PolyLine2D]
    ) -> Solution {
        guard pageSize.width > 1, pageSize.height > 1 else {
            let safeSize = Size2I(width: max(1, pageSize.width), height: max(1, pageSize.height))
            return Solution(
                grid: .identity(
                    outputSize: safeSize,
                    columns: configuration.gridColumns,
                    rows: configuration.gridRows
                ),
                model: nil
            )
        }

        let validLines = lines.filter { $0.points.count >= 4 }
        guard validLines.count >= configuration.minLinesRequired else {
            return Solution(
                grid: .identity(
                    outputSize: pageSize,
                    columns: configuration.gridColumns,
                    rows: configuration.gridRows
                ),
                model: nil
            )
        }

        // Compute normalization domain from the page dimensions (matching DewarpGrid [0, width] x [0, height]).
        let centerX = Double(pageSize.width) * 0.5
        let halfWidth = max(1.0, Double(pageSize.width) * 0.5)
        let centerY = Double(pageSize.height) * 0.5
        let halfHeight = max(1.0, Double(pageSize.height) * 0.5)

        // Convert line samples into normalized coordinates (u, v_obs) in [-1, 1]^2.
        var normalizedLines: [[(u: Double, v: Double)]] = []
        normalizedLines.reserveCapacity(validLines.count)

        for line in validLines {
            let pts = line.points.map { pt in
                (
                    u: (pt.x - centerX) / halfWidth,
                    v: (pt.y - centerY) / halfHeight
                )
            }
            normalizedLines.append(pts)
        }

        // Initialize per-line rectified vertical baseline coordinates v_i as the median or mean v
        // of each line, and global cubic shape parameters (alpha1, alpha2, alpha3, beta) = 0.
        var lineV = [Double](repeating: 0.0, count: normalizedLines.count)
        for i in 0..<normalizedLines.count {
            let sumV = normalizedLines[i].reduce(0.0) { $0 + $1.v }
            lineV[i] = sumV / Double(normalizedLines[i].count)
        }

        var alpha1 = 0.0
        var alpha2 = 0.0
        var alpha3 = 0.0
        var beta = 0.0

        let reg = configuration.regularizationWeight
        let delta = configuration.huberDelta

        // Alternating Robust Gauss-Newton (IRLS) optimization:
        // Step A: Given lineV and beta, solve weighted regularized linear least squares for (alpha1, alpha2, alpha3).
        // Step B: Given (alpha1, alpha2, alpha3), update each lineV[i] and global perspective coupling beta.
        for _ in 0..<configuration.maxIterations {
            // --- Step A: Update (alpha1, alpha2, alpha3) ---
            var ata00 = reg, ata01 = 0.0, ata02 = 0.0
            var ata11 = reg, ata12 = 0.0
            var ata22 = reg * 0.25
            var atb0 = 0.0, atb1 = 0.0, atb2 = 0.0

            for i in 0..<normalizedLines.count {
                let vi = lineV[i]
                let scale = 1.0 + beta * vi
                for sample in normalizedLines[i] {
                    let u = sample.u
                    let u2 = u * u
                    let u3 = u2 * u
                    let z = alpha1 * u3 + alpha2 * u2 + alpha3 * u
                    let pred = vi + scale * z
                    let r = sample.v - pred
                    let absR = abs(r)
                    let w = absR <= delta ? 1.0 : (delta / absR)

                    let j0 = scale * u3
                    let j1 = scale * u2
                    let j2 = scale * u
                    let target = sample.v - vi

                    ata00 += w * j0 * j0
                    ata01 += w * j0 * j1
                    ata02 += w * j0 * j2
                    ata11 += w * j1 * j1
                    ata12 += w * j1 * j2
                    ata22 += w * j2 * j2

                    atb0 += w * j0 * target
                    atb1 += w * j1 * target
                    atb2 += w * j2 * target
                }
            }

            if let solvedAlpha = Self.solveSymmetric3x3(
                a00: ata00, a01: ata01, a02: ata02,
                a11: ata11, a12: ata12,
                a22: ata22,
                b0: atb0, b1: atb1, b2: atb2
            ) {
                alpha1 = solvedAlpha.0
                alpha2 = solvedAlpha.1
                alpha3 = solvedAlpha.2
            }

            // Clamp normalized curl amplitude so malformed lines cannot invert the page.
            let maxAmp = configuration.maxNormalizedCurlAmplitude
            alpha1 = min(max(alpha1, -maxAmp), maxAmp)
            alpha2 = min(max(alpha2, -maxAmp), maxAmp)
            alpha3 = min(max(alpha3, -maxAmp), maxAmp)

            // --- Step B1: Update per-line baseline offsets lineV[i] ---
            // So that Z(u) remains uniquely identifiable relative to v_i when u isn't centered at 0,
            // we anchor v_i assuming beta is fixed: sample.v ≈ v_i * (1 + beta * Z(u)) + Z(u).
            for i in 0..<normalizedLines.count {
                let viOld = lineV[i]
                var num = 0.0
                var den = 0.0
                for sample in normalizedLines[i] {
                    let u = sample.u
                    let z = ((alpha1 * u + alpha2) * u + alpha3) * u
                    let pred = viOld + (1.0 + beta * viOld) * z
                    let absR = abs(sample.v - pred)
                    let w = absR <= delta ? 1.0 : (delta / absR)
                    let dV = 1.0 + beta * z
                    num += w * dV * (sample.v - z)
                    den += w * dV * dV
                }
                if den > 1e-12 {
                    lineV[i] = min(max(num / den, -1.5), 1.5)
                }
            }

            // --- Step B2: Update perspective coupling beta ---
            var betaNum = 0.0
            var betaDen = reg + 1e-3
            for i in 0..<normalizedLines.count {
                let vi = lineV[i]
                for sample in normalizedLines[i] {
                    let u = sample.u
                    let z = ((alpha1 * u + alpha2) * u + alpha3) * u
                    let pred = vi + (1.0 + beta * vi) * z
                    let absR = abs(sample.v - pred)
                    let w = absR <= delta ? 1.0 : (delta / absR)
                    let jBeta = vi * z
                    let residualNoBeta = sample.v - (vi + z)
                    betaNum += w * jBeta * residualNoBeta
                    betaDen += w * jBeta * jBeta
                }
            }
            if betaDen > 1e-12 {
                beta = min(max(betaNum / betaDen, -0.45), 0.45)
            }
        }

        // Compute final RMS vertical residual in pixels.
        var sumSqError = 0.0
        var totalSamples = 0
        for i in 0..<normalizedLines.count {
            let vi = lineV[i]
            let scale = 1.0 + beta * vi
            for sample in normalizedLines[i] {
                let u = sample.u
                let z = ((alpha1 * u + alpha2) * u + alpha3) * u
                let pred = vi + scale * z
                let errPx = (sample.v - pred) * halfHeight
                sumSqError += errPx * errPx
                totalSamples += 1
            }
        }
        let rmsPixels = totalSamples > 0 ? (sumSqError / Double(totalSamples)).squareRoot() : 0.0

        let model = SurfaceModel(
            alpha1: alpha1,
            alpha2: alpha2,
            alpha3: alpha3,
            beta: beta,
            centerX: centerX,
            halfWidth: halfWidth,
            centerY: centerY,
            halfHeight: halfHeight,
            residualRMSPixels: rmsPixels,
            fittedLineCount: normalizedLines.count
        )

        let grid = buildDewarpGrid(pageSize: pageSize, model: model)
        return Solution(grid: grid, model: model)
    }

    /// Builds a rectified `DewarpGrid` from a fitted `SurfaceModel`, incorporating inverse
    /// surface arc-length parameterization along the horizontal axis to undo foreshortening.
    public func buildDewarpGrid(
        pageSize: Size2I,
        model: SurfaceModel
    ) -> DewarpGrid {
        let cols = configuration.gridColumns
        let rows = configuration.gridRows

        // Build a dense arc-length lookup table for u in [-1, 1].
        // Physical slope dz/dx is proportional to (halfHeight / halfWidth) * Z'(u).
        let tableSteps = 512
        var uTable = [Double](repeating: 0.0, count: tableSteps + 1)
        var sTable = [Double](repeating: 0.0, count: tableSteps + 1)

        let aspectFactor = (model.halfHeight / max(1.0, model.halfWidth))
        let coupling = configuration.foreshorteningCoupling * aspectFactor * aspectFactor

        uTable[0] = -1.0
        sTable[0] = 0.0
        let du = 2.0 / Double(tableSteps)

        for k in 1...tableSteps {
            let uPrev = -1.0 + Double(k - 1) * du
            let uCurr = -1.0 + Double(k) * du
            let uMid = 0.5 * (uPrev + uCurr)

            let dPrev = model.depthDerivative(u: uPrev)
            let dMid = model.depthDerivative(u: uMid)
            let dCurr = model.depthDerivative(u: uCurr)

            let fPrev = (1.0 + coupling * dPrev * dPrev).squareRoot()
            let fMid = (1.0 + coupling * dMid * dMid).squareRoot()
            let fCurr = (1.0 + coupling * dCurr * dCurr).squareRoot()

            // Simpson's rule over [uPrev, uCurr]
            let ds = (du / 6.0) * (fPrev + 4.0 * fMid + fCurr)
            uTable[k] = uCurr
            sTable[k] = sTable[k - 1] + ds
        }

        let totalArcLength = max(1e-12, sTable[tableSteps])

        // Precompute source u for each grid column by inverting the normalized arc-length.
        var columnSourceU = [Double](repeating: 0.0, count: cols)
        let denomCols = Double(max(1, cols - 1))
        for col in 0..<cols {
            let targetFraction = Double(col) / denomCols
            let targetS = targetFraction * totalArcLength

            // Binary search in sTable
            var lo = 0
            var hi = tableSteps
            while lo < hi {
                let mid = (lo + hi) >> 1
                if sTable[mid] < targetS {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            if lo == 0 {
                columnSourceU[col] = -1.0
            } else {
                let s0 = sTable[lo - 1]
                let s1 = sTable[lo]
                let t = (s1 > s0) ? ((targetS - s0) / (s1 - s0)) : 0.0
                columnSourceU[col] = uTable[lo - 1] + t * (uTable[lo] - uTable[lo - 1])
            }
        }

        var sourcePoints = ContiguousArray<Point2D>()
        sourcePoints.reserveCapacity(rows * cols)
        let denomRows = Double(max(1, rows - 1))

        for row in 0..<rows {
            let vRect = -1.0 + 2.0 * (Double(row) / denomRows)
            let perspectiveScale = 1.0 + model.beta * vRect

            for col in 0..<cols {
                let uSrc = columnSourceU[col]
                let z = model.depthProfile(u: uSrc)
                let vSrc = vRect + perspectiveScale * z

                let xSrc = model.centerX + uSrc * model.halfWidth
                let ySrc = model.centerY + vSrc * model.halfHeight
                sourcePoints.append(Point2D(x: xSrc, y: ySrc))
            }
        }

        return DewarpGrid(
            outputSize: pageSize,
            columns: cols,
            rows: rows,
            sourcePoints: sourcePoints
        )
    }

    /// Solves a 3x3 symmetric linear system $A x = b$ using explicit Cramer's rule / LDL^T decomposition.
    private static func solveSymmetric3x3(
        a00: Double, a01: Double, a02: Double,
        a11: Double, a12: Double,
        a22: Double,
        b0: Double, b1: Double, b2: Double
    ) -> (Double, Double, Double)? {
        let c00 = a11 * a22 - a12 * a12
        let c01 = -(a01 * a22 - a12 * a02)
        let c02 = a01 * a12 - a11 * a02

        let det = a00 * c00 + a01 * c01 + a02 * c02
        guard abs(det) > 1e-18 else { return nil }

        let c11 = a00 * a22 - a02 * a02
        let c12 = -(a00 * a12 - a01 * a02)
        let c22 = a00 * a11 - a01 * a01

        let invDet = 1.0 / det
        let x0 = (c00 * b0 + c01 * b1 + c02 * b2) * invDet
        let x1 = (c01 * b0 + c11 * b1 + c12 * b2) * invDet
        let x2 = (c02 * b0 + c12 * b1 + c22 * b2) * invDet

        return (x0, x1, x2)
    }
}
