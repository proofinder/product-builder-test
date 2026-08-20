import Foundation

/// A 2D similarity transform: uniform scale, rotation, translation.
///
///     q = s * R(theta) * p + t
///
/// The MATLAB reference tracks the face this way — `estgeotform2d(..., 'similarity')`
/// fitted to tracked feature points, then `transformPointsForward` applied to the four
/// box corners. A similarity preserves angles, so a rectangle stays a rectangle: the
/// transformed quad is still a properly rolled box, which is what the ROI sampler and
/// the respiration signal both assume.
public struct SimilarityTransform2D: Sendable, Equatable {

    public var scale: Double
    /// Radians, positive clockwise in image coordinates (y down).
    public var rotation: Double
    public var translation: Point2D

    public init(scale: Double, rotation: Double, translation: Point2D) {
        self.scale = scale
        self.rotation = rotation
        self.translation = translation
    }

    public static let identity = SimilarityTransform2D(
        scale: 1, rotation: 0, translation: Point2D(x: 0, y: 0)
    )

    public func apply(to point: Point2D) -> Point2D {
        let cosR = cos(rotation), sinR = sin(rotation)
        return Point2D(
            x: scale * (point.x * cosR - point.y * sinR) + translation.x,
            y: scale * (point.x * sinR + point.y * cosR) + translation.y
        )
    }

    public func apply(to points: [Point2D]) -> [Point2D] {
        let cosR = cos(rotation), sinR = sin(rotation)
        return points.map { point in
            Point2D(
                x: scale * (point.x * cosR - point.y * sinR) + translation.x,
                y: scale * (point.x * sinR + point.y * cosR) + translation.y
            )
        }
    }

    public func apply(to quad: FaceQuad) -> FaceQuad {
        FaceQuad(corners: apply(to: quad.corners))
    }

    public var inverse: SimilarityTransform2D {
        let inverseScale = 1 / scale
        let inverseRotation = -rotation
        let cosR = cos(inverseRotation), sinR = sin(inverseRotation)
        let x = -inverseScale * (translation.x * cosR - translation.y * sinR)
        let y = -inverseScale * (translation.x * sinR + translation.y * cosR)
        return SimilarityTransform2D(
            scale: inverseScale,
            rotation: inverseRotation,
            translation: Point2D(x: x, y: y)
        )
    }
}

/// Least-squares similarity fit between two corresponding point sets, with the
/// outlier rejection `estgeotform2d`'s `MaxDistance` provides.
///
/// The closed form minimises `sum |s*R*p' - q'|^2` over centred points:
///
///     Sxx = sum(px'*qx' + py'*qy')          Sxy = sum(px'*qy' - py'*qx')
///     theta = atan2(Sxy, Sxx)
///     s     = hypot(Sxx, Sxy) / sum(|p'|^2)
///     t     = qbar - s*R(theta)*pbar
///
/// Fitting over many points is the whole reason the tracked corners are smooth: the
/// noise on a single landmark is large, but a least-squares fit over ~40 of them
/// averages it down by roughly the square root of the count. That smoothness is what
/// the respiration signal — the mean corner y — is made of.
public enum SimilarityTransformEstimator {

    public struct Result: Sendable, Equatable {
        public let transform: SimilarityTransform2D
        /// Points kept after outlier rejection.
        public let inlierCount: Int
        /// RMS distance, in pixels, between transformed inliers and their targets.
        public let rmsResidual: Double
        /// Largest single inlier residual, in pixels.
        public let maxResidual: Double
    }

    /// - Parameters:
    ///   - source: reference points.
    ///   - target: corresponding observed points; must match `source` in count.
    ///   - maxDistance: residual, in pixels, beyond which a correspondence is dropped
    ///     and the fit repeated. `estgeotform2d`'s default in the reference is 4.
    ///   - refinementPasses: how many times to re-fit after dropping outliers.
    /// - Returns: `nil` when there are too few points, the counts disagree, or the
    ///   source points are degenerate (all coincident).
    public static func fit(
        from source: [Point2D],
        to target: [Point2D],
        maxDistance: Double = 4,
        refinementPasses: Int = 2
    ) -> Result? {
        guard source.count == target.count, source.count >= 3 else { return nil }

        var indices = Array(source.indices)
        var transform = SimilarityTransform2D.identity

        for pass in 0...refinementPasses {
            guard indices.count >= 3, let fitted = solve(source, target, indices) else { return nil }
            transform = fitted

            // The last pass only measures; it does not prune again.
            guard pass < refinementPasses else { break }

            let residuals = indices.map { distance(fitted.apply(to: source[$0]), target[$0]) }

            // A fixed pixel threshold alone collapses: a few gross outliers drag the
            // first fit far enough that *every* residual exceeds it, and pruning takes
            // out the whole set. Scaling by the median residual keeps the threshold
            // above the bulk of the points however badly that first fit was pulled.
            let threshold = Swift.max(maxDistance, 2.5 * median(residuals))

            let kept = zip(indices, residuals).filter { $0.1 <= threshold }.map(\.0)
            // Refuse to prune down to a degenerate set; keep what we had instead.
            guard kept.count >= 3 else { break }
            if kept.count == indices.count { break }
            indices = kept
        }

        var sumSquares = 0.0
        var worst = 0.0
        for index in indices {
            let residual = distance(transform.apply(to: source[index]), target[index])
            sumSquares += residual * residual
            worst = Swift.max(worst, residual)
        }
        let rms = (sumSquares / Double(indices.count)).squareRoot()

        guard transform.scale.isFinite, transform.rotation.isFinite,
              transform.translation.x.isFinite, transform.translation.y.isFinite else { return nil }

        return Result(
            transform: transform,
            inlierCount: indices.count,
            rmsResidual: rms,
            maxResidual: worst
        )
    }

    private static func solve(
        _ source: [Point2D],
        _ target: [Point2D],
        _ indices: [Int]
    ) -> SimilarityTransform2D? {
        let n = Double(indices.count)

        var sourceMeanX = 0.0, sourceMeanY = 0.0
        var targetMeanX = 0.0, targetMeanY = 0.0
        for index in indices {
            sourceMeanX += source[index].x; sourceMeanY += source[index].y
            targetMeanX += target[index].x; targetMeanY += target[index].y
        }
        sourceMeanX /= n; sourceMeanY /= n
        targetMeanX /= n; targetMeanY /= n

        var sxx = 0.0   // sum(px'*qx' + py'*qy')
        var sxy = 0.0   // sum(px'*qy' - py'*qx')
        var sourceEnergy = 0.0
        for index in indices {
            let px = source[index].x - sourceMeanX
            let py = source[index].y - sourceMeanY
            let qx = target[index].x - targetMeanX
            let qy = target[index].y - targetMeanY
            sxx += px * qx + py * qy
            sxy += px * qy - py * qx
            sourceEnergy += px * px + py * py
        }
        guard sourceEnergy > .ulpOfOne else { return nil }

        let rotation = atan2(sxy, sxx)
        let scale = (sxx * sxx + sxy * sxy).squareRoot() / sourceEnergy
        guard scale > .ulpOfOne else { return nil }

        let cosR = cos(rotation), sinR = sin(rotation)
        let translation = Point2D(
            x: targetMeanX - scale * (sourceMeanX * cosR - sourceMeanY * sinR),
            y: targetMeanY - scale * (sourceMeanX * sinR + sourceMeanY * cosR)
        )
        return SimilarityTransform2D(scale: scale, rotation: rotation, translation: translation)
    }

    private static func distance(_ a: Point2D, _ b: Point2D) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2
    }
}
