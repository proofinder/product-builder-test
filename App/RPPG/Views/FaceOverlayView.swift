import RPPGCore
import SwiftUI

/// Draws the tracked face quad and the central-80% ROI on top of the preview.
///
/// Both are rolled with the head, so the overlay is also the fastest way to see
/// whether rotation tracking is behaving: the ROI edges should stay parallel to the
/// eye line as the subject tilts.
struct FaceOverlayView: View {

    let faceQuad: FaceQuad?
    let roiQuad: FaceQuad?
    let imageSize: CGSize
    let showsROI: Bool

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard imageSize.width > 0, imageSize.height > 0 else { return }
                let mapping = AspectFillMapping(imageSize: imageSize, viewSize: size)

                if let faceQuad {
                    context.stroke(
                        path(for: faceQuad, mapping: mapping),
                        with: .color(.white.opacity(0.55)),
                        style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                    )
                }
                if showsROI, let roiQuad {
                    let roiPath = path(for: roiQuad, mapping: mapping)
                    context.fill(roiPath, with: .color(.green.opacity(0.12)))
                    context.stroke(roiPath, with: .color(.green), lineWidth: 2.5)
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
}
