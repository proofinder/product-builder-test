import XCTest
@testable import RPPGCore

/// Stage 2 verification for the piece the tracker is built on.
///
/// The tracker replaces the reference's KLT + `estgeotform2d` with landmarks + this
/// estimator, so it has to do the same job: recover scale, rotation and translation
/// exactly when the correspondence is clean, reject gross outliers the way
/// `MaxDistance` does, and — the reason it exists at all — average landmark noise down
/// so the tracked corners glide instead of twitching.
final class SimilarityTransformTests: XCTestCase {

    /// A fixed, reproducible landmark-like constellation.
    private func makePoints(count: Int = 40, seed: UInt64 = 0x5111_A17F) -> [Point2D] {
        var generator = SplitMix(seed: seed)
        return (0..<count).map { _ in
            Point2D(x: generator.uniform(-100, 100), y: generator.uniform(-120, 120))
        }
    }

    // MARK: - Exact recovery

    func testRecoversAKnownTransformExactly() {
        let source = makePoints()
        let cases: [(scale: Double, rotation: Double, translation: Point2D)] = [
            (1.0, 0.0, Point2D(x: 0, y: 0)),
            (1.35, 0.42, Point2D(x: 37, y: -19)),
            (0.6, -1.1, Point2D(x: -200, y: 80)),
            (2.5, 3.0, Point2D(x: 5, y: 5))
        ]

        for expected in cases {
            let transform = SimilarityTransform2D(
                scale: expected.scale,
                rotation: expected.rotation,
                translation: expected.translation
            )
            let target = transform.apply(to: source)

            let result = SimilarityTransformEstimator.fit(from: source, to: target)
            XCTAssertNotNil(result)
            XCTAssertEqual(result!.transform.scale, expected.scale, accuracy: 1e-10)
            XCTAssertEqual(result!.transform.rotation, expected.rotation, accuracy: 1e-10)
            XCTAssertEqual(result!.transform.translation.x, expected.translation.x, accuracy: 1e-8)
            XCTAssertEqual(result!.transform.translation.y, expected.translation.y, accuracy: 1e-8)
            XCTAssertEqual(result!.rmsResidual, 0, accuracy: 1e-8)
            XCTAssertEqual(result!.inlierCount, source.count)
        }
    }

    func testApplyingToAQuadKeepsItRectangular() {
        // A similarity preserves angles, so the ROI sampler and the respiration signal
        // keep working on the transformed quad.
        let quad = FaceQuad(center: Point2D(x: 300, y: 400), width: 220, height: 280, roll: 0.15)
        let transform = SimilarityTransform2D(
            scale: 1.4, rotation: -0.35, translation: Point2D(x: 60, y: -25)
        )
        let moved = transform.apply(to: quad)

        XCTAssertEqual(moved.width, quad.width * 1.4, accuracy: 1e-9)
        XCTAssertEqual(moved.height, quad.height * 1.4, accuracy: 1e-9)
        XCTAssertEqual(moved.roll, quad.roll - 0.35, accuracy: 1e-9)

        // Opposite edges still equal, diagonals still equal: it is still a rectangle.
        let topEdge = distance(moved.corners[0], moved.corners[1])
        let bottomEdge = distance(moved.corners[3], moved.corners[2])
        XCTAssertEqual(topEdge, bottomEdge, accuracy: 1e-9)
        XCTAssertEqual(
            distance(moved.corners[0], moved.corners[2]),
            distance(moved.corners[1], moved.corners[3]),
            accuracy: 1e-9
        )
    }

    func testInverseUndoesTheTransform() {
        let transform = SimilarityTransform2D(
            scale: 0.73, rotation: 1.9, translation: Point2D(x: -14, y: 220)
        )
        let point = Point2D(x: 123, y: -45)
        let roundTripped = transform.inverse.apply(to: transform.apply(to: point))
        XCTAssertEqual(roundTripped.x, point.x, accuracy: 1e-9)
        XCTAssertEqual(roundTripped.y, point.y, accuracy: 1e-9)
    }

    // MARK: - Outlier rejection

    func testRejectsGrossOutliers() {
        let source = makePoints()
        let transform = SimilarityTransform2D(
            scale: 1.2, rotation: 0.25, translation: Point2D(x: 5, y: 5)
        )
        var target = transform.apply(to: source)
        // Three landmarks land somewhere else entirely — a blink, a hand across the
        // face, a mis-regressed point.
        for index in [3, 11, 27] {
            target[index] = Point2D(x: target[index].x + 90, y: target[index].y - 70)
        }

        let result = SimilarityTransformEstimator.fit(from: source, to: target)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.inlierCount, source.count - 3)
        XCTAssertEqual(result!.transform.scale, 1.2, accuracy: 1e-8)
        XCTAssertEqual(result!.transform.rotation, 0.25, accuracy: 1e-8)
    }

    func testPruningDoesNotCollapseWhenTheFirstFitIsDragged() {
        // A fixed 4 px threshold applied to the first, outlier-dragged fit rejects
        // *every* point and leaves nothing to fit. The median-scaled threshold must
        // keep the bulk of the set.
        let source = makePoints()
        let transform = SimilarityTransform2D(
            scale: 1.0, rotation: 0.0, translation: Point2D(x: 0, y: 0)
        )
        var target = transform.apply(to: source)
        for index in [0, 1, 2, 3, 4] {
            target[index] = Point2D(x: target[index].x + 300, y: target[index].y + 300)
        }

        let result = SimilarityTransformEstimator.fit(from: source, to: target)
        XCTAssertNotNil(result, "the estimator must not prune itself to nothing")
        XCTAssertGreaterThanOrEqual(result!.inlierCount, source.count - 5)
    }

    // MARK: - Why it exists: noise averaging

    func testFittingManyPointsAveragesLandmarkNoiseDown() {
        // Each landmark is noisy, but the corner position derived from a fit over all
        // of them is much less so. That reduction is what makes the mean corner y a
        // usable respiration signal instead of tracker hash.
        let source = makePoints(count: 40)
        let truth = SimilarityTransform2D(
            scale: 1.0, rotation: 0.30, translation: Point2D(x: 10, y: -5)
        )
        let corner = Point2D(x: 80, y: -110)
        let trueCorner = truth.apply(to: corner)

        var generator = SplitMix(seed: 0xC0FFEE)
        let sigma = 1.5
        var fittedError = 0.0
        var singlePointError = 0.0
        let trials = 200

        for _ in 0..<trials {
            let target = truth.apply(to: source).map { point in
                Point2D(x: point.x + generator.gaussian(sigma), y: point.y + generator.gaussian(sigma))
            }
            guard let result = SimilarityTransformEstimator.fit(
                from: source, to: target, maxDistance: 12
            ) else {
                XCTFail("fit failed on noisy input")
                return
            }
            fittedError += distance(result.transform.apply(to: corner), trueCorner)
            singlePointError += distance(target[0], truth.apply(to: source[0]))
        }
        fittedError /= Double(trials)
        singlePointError /= Double(trials)

        XCTAssertLessThan(
            fittedError, singlePointError * 0.6,
            "fitted corner error \(fittedError) px vs single landmark \(singlePointError) px"
        )
    }

    // MARK: - Degenerate input

    func testRefusesDegenerateInput() {
        let point = Point2D(x: 5, y: 5)
        // Too few points.
        XCTAssertNil(SimilarityTransformEstimator.fit(from: [point, point], to: [point, point]))
        // Mismatched counts.
        XCTAssertNil(SimilarityTransformEstimator.fit(
            from: [point, point, point], to: [point, point]
        ))
        // All source points coincident: scale and rotation are undefined.
        XCTAssertNil(SimilarityTransformEstimator.fit(
            from: Array(repeating: point, count: 10),
            to: makePoints(count: 10)
        ))
    }

    private func distance(_ a: Point2D, _ b: Point2D) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// SplitMix64 — reproducible across platforms, unlike `Double.random`.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in `[0, 1)`.
    mutating func unit() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9007199254740992.0)
    }

    mutating func uniform(_ low: Double, _ high: Double) -> Double {
        low + (high - low) * unit()
    }

    /// Box–Muller.
    mutating func gaussian(_ sigma: Double) -> Double {
        let u1 = Swift.max(unit(), 1e-12)
        let u2 = unit()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
