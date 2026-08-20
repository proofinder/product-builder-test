import XCTest
@testable import RPPGCore

final class FaceGeometryTests: XCTestCase {

    func testUprightQuadCornersAndMetrics() {
        let quad = FaceQuad(center: Point2D(x: 100, y: 200), width: 80, height: 120, roll: 0)
        XCTAssertEqual(quad.corners[0].x, 60, accuracy: 1e-9)
        XCTAssertEqual(quad.corners[0].y, 140, accuracy: 1e-9)
        XCTAssertEqual(quad.corners[2].x, 140, accuracy: 1e-9)
        XCTAssertEqual(quad.corners[2].y, 260, accuracy: 1e-9)
        XCTAssertEqual(quad.width, 80, accuracy: 1e-9)
        XCTAssertEqual(quad.height, 120, accuracy: 1e-9)
        XCTAssertEqual(quad.meanCornerY, 200, accuracy: 1e-9)
    }

    func testRollIsRecoveredFromCorners() {
        for degrees in stride(from: -40.0, through: 40.0, by: 10.0) {
            let roll = degrees * Double.pi / 180
            let quad = FaceQuad(center: Point2D(x: 0, y: 0), width: 100, height: 140, roll: roll)
            XCTAssertEqual(quad.roll, roll, accuracy: 1e-9, "roll \(degrees) deg")
            // Rotation is rigid: edge lengths must be preserved.
            XCTAssertEqual(quad.width, 100, accuracy: 1e-9)
            XCTAssertEqual(quad.height, 140, accuracy: 1e-9)
        }
    }

    func testCentralEightyPercentROI() {
        let quad = FaceQuad(center: Point2D(x: 50, y: 50), width: 100, height: 100, roll: 0.3)
        let roi = quad.scaled(0.8)
        XCTAssertEqual(roi.width, 80, accuracy: 1e-9)
        XCTAssertEqual(roi.height, 80, accuracy: 1e-9)
        XCTAssertEqual(roi.center.x, quad.center.x, accuracy: 1e-9)
        XCTAssertEqual(roi.center.y, quad.center.y, accuracy: 1e-9)
        XCTAssertEqual(roi.roll, quad.roll, accuracy: 1e-9)
        // Every ROI corner has to sit inside the face it was cut from.
        for corner in roi.corners {
            XCTAssertTrue(quad.contains(corner))
        }
    }

    func testAnisotropicScaling() {
        let quad = FaceQuad(center: Point2D(x: 0, y: 0), width: 100, height: 200, roll: 0.5)
        let roi = quad.scaled(horizontal: 0.6, vertical: 0.9)
        XCTAssertEqual(roi.width, 60, accuracy: 1e-9)
        XCTAssertEqual(roi.height, 180, accuracy: 1e-9)
        XCTAssertEqual(roi.roll, quad.roll, accuracy: 1e-9)
    }

    func testContainsHandlesRotatedQuads() {
        let quad = FaceQuad(center: Point2D(x: 0, y: 0), width: 100, height: 100, roll: Double.pi / 4)
        XCTAssertTrue(quad.contains(Point2D(x: 0, y: 0)))
        // A 45-degree square of side 100 reaches ~70.7 along the axes but only ~50 at
        // the corners of the *unrotated* box.
        XCTAssertTrue(quad.contains(Point2D(x: 65, y: 0)))
        XCTAssertFalse(quad.contains(Point2D(x: 45, y: 45)))
    }

    func testBoundsCoverAllCorners() {
        let quad = FaceQuad(center: Point2D(x: 10, y: 20), width: 60, height: 80, roll: -0.7)
        let bounds = quad.bounds
        for corner in quad.corners {
            XCTAssertGreaterThanOrEqual(corner.x, bounds.minX - 1e-9)
            XCTAssertLessThanOrEqual(corner.x, bounds.maxX + 1e-9)
            XCTAssertGreaterThanOrEqual(corner.y, bounds.minY - 1e-9)
            XCTAssertLessThanOrEqual(corner.y, bounds.maxY + 1e-9)
        }
    }

    func testSmootherConvergesToTargetWithoutJumping() {
        let frameRate = 60.0
        let smoother = QuadSmoother(timeConstant: 0.25, sampleRate: frameRate)
        let first = FaceQuad(center: Point2D(x: 0, y: 0), width: 100, height: 100, roll: 0)
        smoother.setTarget(first)
        XCTAssertNotNil(smoother.advance())

        // A tracker update jumps the face 50 px to the right; the ROI must ease over.
        let second = FaceQuad(center: Point2D(x: 50, y: 0), width: 100, height: 100, roll: 0)
        smoother.setTarget(second)
        let firstStep = smoother.advance()!
        XCTAssertLessThan(firstStep.center.x, 10, "must not snap to the new position")

        for _ in 0..<Int(frameRate * 2) { _ = smoother.advance() }
        XCTAssertEqual(smoother.advance()!.center.x, 50, accuracy: 0.5)
    }
}
