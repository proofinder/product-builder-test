import CoreVideo
import Foundation
import RPPGCore

/// Spatial average of the skin ROI for one frame.
///
/// Step 2 of the spec: the ROI is the **central 80% of the detected face**, which is
/// applied by the caller via `FaceQuad.scaled(0.8)`. This type turns that quad — which
/// is rolled with the head, so it stays on skin when the subject tilts — into a single
/// ``RGBSample``.
///
/// The walk is over the quad's axis-aligned bounds with a stride, testing each
/// candidate against the rolled quad. For a 300 px face at stride 2 that is roughly
/// 14 000 tests per frame, which is nothing next to the cost of the capture itself,
/// and it avoids the rectangular-crop-plus-rotation dance entirely.
struct ROISampler: Sendable {

    /// Pixel step in both axes. 1 samples everything; 2 quarters the work with no
    /// measurable effect on the spatial mean.
    var pixelStride: Int = 2

    /// Channel value at or above which a pixel counts as clipped.
    var clippingThreshold: Double = 250

    /// Optional YCbCr skin gate. Off by default because the spec defines the ROI
    /// purely geometrically; switch it on when glasses, hair or a beard intrude on the
    /// central 80%.
    var skinGateEnabled: Bool = false

    /// Averages the pixels of `roi` in a 32BGRA pixel buffer.
    ///
    /// - Returns: an ``RGBSample``; `pixelCount == 0` means the ROI fell outside the
    ///   frame, and the pipelines will treat the sample as unusable.
    func sample(roi: FaceQuad, pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> RGBSample {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return RGBSample(red: 0, green: 0, blue: 0, timestamp: timestamp, pixelCount: 0)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return RGBSample(red: 0, green: 0, blue: 0, timestamp: timestamp, pixelCount: 0)
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        let bounds = roi.bounds.clipped(toWidth: Double(width), height: Double(height))
        guard bounds.width > 0, bounds.height > 0 else {
            return RGBSample(red: 0, green: 0, blue: 0, timestamp: timestamp, pixelCount: 0)
        }

        let step = Swift.max(1, pixelStride)
        let minX = Int(bounds.minX.rounded(.down)), maxX = Int(bounds.maxX.rounded(.up))
        let minY = Int(bounds.minY.rounded(.down)), maxY = Int(bounds.maxY.rounded(.up))

        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var count = 0
        var clipped = 0

        var y = Swift.max(0, minY)
        while y < Swift.min(height, maxY) {
            let row = pointer.advanced(by: y * bytesPerRow)
            var x = Swift.max(0, minX)
            while x < Swift.min(width, maxX) {
                defer { x += step }
                // Pixel centre, so the test matches what a rasteriser would decide.
                guard roi.contains(Point2D(x: Double(x) + 0.5, y: Double(y) + 0.5)) else { continue }

                let offset = x * 4                       // BGRA
                let blue = Double(row[offset])
                let green = Double(row[offset + 1])
                let red = Double(row[offset + 2])

                if skinGateEnabled, !ROISampler.isSkin(red: red, green: green, blue: blue) { continue }

                sumR += red; sumG += green; sumB += blue
                count += 1
                if red >= clippingThreshold || green >= clippingThreshold || blue >= clippingThreshold {
                    clipped += 1
                }
            }
            y += step
        }

        guard count > 0 else {
            return RGBSample(red: 0, green: 0, blue: 0, timestamp: timestamp, pixelCount: 0)
        }
        let n = Double(count)
        return RGBSample(
            red: sumR / n,
            green: sumG / n,
            blue: sumB / n,
            timestamp: timestamp,
            pixelCount: count,
            clippedFraction: Double(clipped) / n
        )
    }

    /// Classic YCbCr skin rule (Chai & Ngan). Cheap, illumination tolerant, and good
    /// enough to reject hair, glasses frames and background showing through the ROI.
    static func isSkin(red: Double, green: Double, blue: Double) -> Bool {
        let cb = 128 - 0.168736 * red - 0.331264 * green + 0.5 * blue
        let cr = 128 + 0.5 * red - 0.418688 * green - 0.081312 * blue
        return cb >= 77 && cb <= 127 && cr >= 133 && cr <= 173
    }
}
