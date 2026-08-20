import RPPGCore
import SwiftUI

/// Draws the tracked face quad, its four numbered corners, the roll axis and — when
/// asked — the ROI.
///
/// This is the primary Stage 2 check. Three things are visible at a glance:
///
/// * **rotation sign** — the top edge and the roll axis must stay parallel to the eye
///   line as the subject tilts. If they counter-rotate, the sign in
///   `FaceTracker.visionRoll(of:)` is inverted.
/// * **corner ordering** — 1 is top-left *in the face's frame*, so the numbers rotate
///   with the head. If they jump between ticks, the correspondence is broken.
/// * **smoothness** — corners driven by a similarity fit glide; corners driven by a
///   raw bounding box twitch.
struct FaceOverlayView: View {

    let faceQuad: FaceQuad?
    let roiQuad: FaceQuad?
    let imageSize: CGSize
    let showsROI: Bool
    var showsCorners: Bool = true

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard imageSize.width > 0, imageSize.height > 0 else { return }
                let mapping = AspectFillMapping(imageSize: imageSize, viewSize: size)

                if let faceQuad {
                    context.stroke(
                        path(for: faceQuad, mapping: mapping),
                        with: .color(.yellow.opacity(0.9)),
                        style: StrokeStyle(lineWidth: 2.5)
                    )
                    drawRollAxis(faceQuad, in: &context, mapping: mapping)
                    if showsCorners {
                        drawCorners(faceQuad, in: &context, mapping: mapping)
                    }
                    drawCentroid(faceQuad, in: &context, mapping: mapping)
                }

                if showsROI, let roiQuad {
                    let roiPath = path(for: roiQuad, mapping: mapping)
                    context.fill(roiPath, with: .color(.green.opacity(0.12)))
                    context.stroke(roiPath, with: .color(.green), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private func path(for quad: FaceQuad, mapping: AspectFillMapping) -> Path {
        var path = Path()
        let points = quad.corners.map { mapping.point($0.x, $0.y) }
        path.move(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    /// The face's own x axis: from the midpoint of the left edge to the midpoint of the
    /// right edge. Parallel to the eye line when roll is tracked correctly.
    private func drawRollAxis(
        _ quad: FaceQuad,
        in context: inout GraphicsContext,
        mapping: AspectFillMapping
    ) {
        let left = midpoint(quad.corners[0], quad.corners[3])
        let right = midpoint(quad.corners[1], quad.corners[2])
        var path = Path()
        path.move(to: mapping.point(left.x, left.y))
        path.addLine(to: mapping.point(right.x, right.y))
        context.stroke(
            path,
            with: .color(.yellow.opacity(0.5)),
            style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
        )
    }

    private func drawCorners(
        _ quad: FaceQuad,
        in context: inout GraphicsContext,
        mapping: AspectFillMapping
    ) {
        for (index, corner) in quad.corners.enumerated() {
            let point = mapping.point(corner.x, corner.y)
            let dot = Path(ellipseIn: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
            context.fill(dot, with: .color(.yellow))
            context.draw(
                Text("\(index + 1)")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black),
                at: point
            )
        }
    }

    /// The centroid — its `y` is the respiration signal.
    private func drawCentroid(
        _ quad: FaceQuad,
        in context: inout GraphicsContext,
        mapping: AspectFillMapping
    ) {
        let centre = quad.center
        let point = mapping.point(centre.x, centre.y)
        var cross = Path()
        cross.move(to: CGPoint(x: point.x - 8, y: point.y))
        cross.addLine(to: CGPoint(x: point.x + 8, y: point.y))
        cross.move(to: CGPoint(x: point.x, y: point.y - 8))
        cross.addLine(to: CGPoint(x: point.x, y: point.y + 8))
        context.stroke(cross, with: .color(.orange), lineWidth: 2)
    }

    private func midpoint(_ a: Point2D, _ b: Point2D) -> Point2D {
        Point2D(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
