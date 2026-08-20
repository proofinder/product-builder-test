import Foundation

/// Platform-independent 2D point, in image pixel coordinates
/// (origin top-left, `y` increasing downwards).
public struct Point2D: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static func + (a: Point2D, b: Point2D) -> Point2D { Point2D(x: a.x + b.x, y: a.y + b.y) }
    public static func - (a: Point2D, b: Point2D) -> Point2D { Point2D(x: a.x - b.x, y: a.y - b.y) }
    public static func * (p: Point2D, s: Double) -> Point2D { Point2D(x: p.x * s, y: p.y * s) }
}

/// Axis-aligned rectangle, used for the pixel bounds a sampler needs to walk.
public struct Bounds2D: Sendable, Equatable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX; self.minY = minY; self.maxX = maxX; self.maxY = maxY
    }

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }

    public func clipped(toWidth width: Double, height: Double) -> Bounds2D {
        Bounds2D(
            minX: Swift.max(0, minX),
            minY: Swift.max(0, minY),
            maxX: Swift.min(width, maxX),
            maxY: Swift.min(height, maxY)
        )
    }
}

/// The tracked face region: a convex quadrilateral in image coordinates.
///
/// Corners are stored explicitly and in order — `[topLeft, topRight, bottomRight,
/// bottomLeft]` **in the face's own frame**, so they follow the head as it rolls. Two
/// things in the spec depend on that ordering:
///
/// * the ROI is the central 80% of this quad, which stays on skin under rotation;
/// * the respiration signal is the mean `y` of the four corners.
public struct FaceQuad: Sendable, Equatable {

    /// Exactly four points, ordered top-left, top-right, bottom-right, bottom-left.
    public let corners: [Point2D]

    public init(corners: [Point2D]) {
        precondition(corners.count == 4, "a face quad needs exactly four corners")
        self.corners = corners
    }

    /// Builds an upright rectangle rotated by `roll` about its centre.
    ///
    /// - Parameter roll: in-plane rotation in radians, positive clockwise in image
    ///   coordinates (`y` down), matching how the head tilts on screen.
    public init(center: Point2D, width: Double, height: Double, roll: Double) {
        let halfWidth = width / 2
        let halfHeight = height / 2
        let cosR = cos(roll), sinR = sin(roll)
        let local = [
            Point2D(x: -halfWidth, y: -halfHeight),
            Point2D(x:  halfWidth, y: -halfHeight),
            Point2D(x:  halfWidth, y:  halfHeight),
            Point2D(x: -halfWidth, y:  halfHeight)
        ]
        self.init(corners: local.map { point in
            Point2D(
                x: center.x + point.x * cosR - point.y * sinR,
                y: center.y + point.x * sinR + point.y * cosR
            )
        })
    }

    /// Centroid of the four corners.
    public var center: Point2D {
        let sum = corners.reduce(Point2D(x: 0, y: 0), +)
        return sum * 0.25
    }

    /// **The respiration signal**: the mean `y` of the four tracked corners.
    ///
    /// The head bobs vertically with the breathing cycle, so this single scalar,
    /// sampled at the tracking rate, carries the respiratory waveform. For a perfectly
    /// symmetric quad this equals `center.y`; it is computed from the corners directly
    /// because a landmark-derived quad is not always symmetric.
    public var meanCornerY: Double {
        corners.reduce(0) { $0 + $1.y } / 4
    }

    /// Length of the top edge.
    public var width: Double {
        distance(corners[0], corners[1])
    }

    /// Length of the left edge.
    public var height: Double {
        distance(corners[0], corners[3])
    }

    /// In-plane rotation recovered from the top edge, in radians.
    public var roll: Double {
        let edge = corners[1] - corners[0]
        return atan2(edge.y, edge.x)
    }

    /// Scales the quad about its centroid — `scaled(0.8)` is the central-80% ROI
    /// required by step 2 of the spec.
    public func scaled(_ factor: Double) -> FaceQuad {
        let c = center
        return FaceQuad(corners: corners.map { c + ($0 - c) * factor })
    }

    /// Independent horizontal / vertical scaling about the centroid, in the quad's own
    /// frame. Useful for a wider-than-tall forehead-and-cheeks ROI.
    public func scaled(horizontal: Double, vertical: Double) -> FaceQuad {
        let c = center
        let cosR = cos(roll), sinR = sin(roll)
        return FaceQuad(corners: corners.map { corner in
            let d = corner - c
            // Rotate into the face frame, scale, rotate back.
            let localX = d.x * cosR + d.y * sinR
            let localY = -d.x * sinR + d.y * cosR
            let sx = localX * horizontal
            let sy = localY * vertical
            return Point2D(
                x: c.x + sx * cosR - sy * sinR,
                y: c.y + sx * sinR + sy * cosR
            )
        })
    }

    /// Smallest axis-aligned box containing the quad.
    public var bounds: Bounds2D {
        var minX = corners[0].x, maxX = corners[0].x
        var minY = corners[0].y, maxY = corners[0].y
        for corner in corners.dropFirst() {
            minX = Swift.min(minX, corner.x); maxX = Swift.max(maxX, corner.x)
            minY = Swift.min(minY, corner.y); maxY = Swift.max(maxY, corner.y)
        }
        return Bounds2D(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }

    /// Convex point-in-quad test: the point is inside when it lies on the same side of
    /// every directed edge. Works for any winding, including rolled quads.
    public func contains(_ point: Point2D) -> Bool {
        var sawPositive = false
        var sawNegative = false
        for i in 0..<4 {
            let a = corners[i]
            let b = corners[(i + 1) % 4]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if cross > 0 { sawPositive = true }
            if cross < 0 { sawNegative = true }
            if sawPositive && sawNegative { return false }
        }
        return true
    }

    /// Corner-wise linear interpolation, `t = 0` giving `self`.
    public func interpolated(to other: FaceQuad, t: Double) -> FaceQuad {
        let clamped = Swift.min(Swift.max(t, 0), 1)
        return FaceQuad(corners: (0..<4).map { index in
            corners[index] + (other.corners[index] - corners[index]) * clamped
        })
    }

    private func distance(_ a: Point2D, _ b: Point2D) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Per-frame corner smoothing that bridges the gap between tracking updates.
///
/// The tracker only produces a new quad at the tracking rate (4 Hz by default) while
/// the ROI is sampled at the full frame rate. Snapping the ROI to a new position four
/// times a second would inject a 4 Hz staircase straight into the pulse band, so every
/// corner coordinate is run through an ``EWMA`` at frame rate and the ROI follows a
/// continuous path instead.
public final class QuadSmoother {

    /// Eight independent EWMAs: x and y of each corner.
    private var filters: [EWMA]
    private var target: FaceQuad?

    /// EWMA time constant in seconds.
    public let timeConstant: Double
    /// Frame rate the smoother is advanced at, in Hz.
    public let sampleRate: Double

    /// - Parameters:
    ///   - timeConstant: EWMA time constant in seconds. Around 0.2–0.3 s keeps the ROI
    ///     locked to the face without visibly lagging normal head motion.
    ///   - sampleRate: the *frame* rate, since smoothing runs once per frame.
    public init(timeConstant: Double = 0.25, sampleRate: Double) {
        self.timeConstant = timeConstant
        self.sampleRate = sampleRate
        filters = (0..<8).map { _ in EWMA(timeConstant: timeConstant, sampleRate: sampleRate) }
    }

    /// Installs the newest tracker output. Call at the tracking rate.
    public func setTarget(_ quad: FaceQuad) {
        target = quad
    }

    /// Advances the smoother by one frame and returns the ROI-carrying quad.
    /// Returns `nil` until a target has been set.
    public func advance() -> FaceQuad? {
        guard let target else { return nil }
        var corners: [Point2D] = []
        corners.reserveCapacity(4)
        for index in 0..<4 {
            let x = filters[index * 2].update(target.corners[index].x)
            let y = filters[index * 2 + 1].update(target.corners[index].y)
            corners.append(Point2D(x: x, y: y))
        }
        return FaceQuad(corners: corners)
    }

    public func reset() {
        target = nil
        for index in filters.indices {
            filters[index].reset()
        }
    }
}
