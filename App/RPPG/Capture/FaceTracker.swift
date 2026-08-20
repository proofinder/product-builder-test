import CoreVideo
import Foundation
import RPPGCore
import Vision
import os

/// Detection + tracking of a single face, including in-plane rotation.
///
/// Runs at the **tracking rate** (4 Hz by default), not the frame rate. Each tick:
///
/// 1. the live `VNTrackObjectRequest` is advanced on the current frame, keeping it
///    warm and giving a fallback box;
/// 2. `VNDetectFaceRectanglesRequest` runs and, when it finds a face, wins — its
///    observation carries `roll`, which the object tracker cannot provide, and it
///    re-seeds the tracker so drift never accumulates;
/// 3. if detection finds nothing (blink of occlusion, fast head turn) the tracker's
///    box is used with the last known roll, for up to `maxTrackedTicks` ticks before
///    the face is declared lost.
///
/// Everything is expressed in **image pixel coordinates with y pointing down**, which
/// is what ``FaceQuad`` and the ROI sampler expect.
/// `@unchecked Sendable`: all state is confined to the caller's Vision queue.
final class FaceTracker: @unchecked Sendable {

    struct Output: Sendable {
        /// The tracked face region. Its four corners are the respiration signal source.
        let faceQuad: FaceQuad
        /// In-plane rotation, radians, positive clockwise on screen.
        let roll: Double
        let confidence: Double
        let source: Source
        let imageSize: CGSize
    }

    enum Source {
        case detection
        case tracking
    }

    struct Configuration {
        /// How many consecutive ticks the object tracker may carry the face on its own
        /// before it is declared lost.
        var maxTrackedTicks: Int = 8
        /// Below this, a `VNDetectedObjectObservation` is not trusted.
        var minimumTrackingConfidence: Float = 0.35
        /// Below this, a `VNFaceObservation` is ignored.
        var minimumDetectionConfidence: Float = 0.4
        /// EWMA time constant for the roll angle, in *tracking ticks*, to keep the ROI
        /// from twitching on noisy per-frame roll estimates.
        var rollSmoothingTicks: Double = 2.0
    }

    private let configuration: Configuration
    private let sequenceHandler = VNSequenceRequestHandler()
    private var trackingRequest: VNTrackObjectRequest?
    private var ticksSinceDetection = 0
    private var rollFilter: EWMA
    private var lastRoll: Double = 0
    private let logger = Logger(subsystem: "com.rppg.tablet", category: "FaceTracker")

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        // The roll filter ticks once per tracking update, so its "sample rate" is 1.
        rollFilter = EWMA(timeConstant: configuration.rollSmoothingTicks, sampleRate: 1)
    }

    /// One tracking tick. Call from a dedicated Vision queue — it is CPU/ANE bound and
    /// must not sit on the frame-rate path.
    ///
    /// - Returns: `nil` when the face is lost.
    func track(pixelBuffer: CVPixelBuffer) -> Output? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: width, height: height)

        // 1. Advance the existing tracker, if any.
        var trackedObservation: VNDetectedObjectObservation?
        if let request = trackingRequest {
            do {
                // `.up` is correct because the capture connection already rotated and
                // mirrored the buffer into display orientation.
                try sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
                if let result = request.results?.first as? VNDetectedObjectObservation,
                   result.confidence >= configuration.minimumTrackingConfidence {
                    trackedObservation = result
                    request.inputObservation = result
                } else {
                    trackingRequest = nil
                }
            } catch {
                logger.debug("object tracking failed: \(error.localizedDescription, privacy: .public)")
                trackingRequest = nil
            }
        }

        // 2. Detection, which owns the roll angle.
        if let face = detectFace(in: pixelBuffer) {
            ticksSinceDetection = 0
            let request = VNTrackObjectRequest(detectedObjectObservation:
                VNDetectedObjectObservation(boundingBox: face.boundingBox))
            request.trackingLevel = .accurate
            trackingRequest = request

            let roll = rollFilter.update(imageRoll(of: face))
            lastRoll = roll
            return Output(
                faceQuad: quad(from: face.boundingBox, roll: roll, imageSize: imageSize),
                roll: roll,
                confidence: Double(face.confidence),
                source: .detection,
                imageSize: imageSize
            )
        }

        // 3. Fall back to the tracker.
        ticksSinceDetection += 1
        guard let trackedObservation, ticksSinceDetection <= configuration.maxTrackedTicks else {
            reset()
            return nil
        }
        return Output(
            faceQuad: quad(from: trackedObservation.boundingBox, roll: lastRoll, imageSize: imageSize),
            roll: lastRoll,
            confidence: Double(trackedObservation.confidence),
            source: .tracking,
            imageSize: imageSize
        )
    }

    func reset() {
        trackingRequest = nil
        ticksSinceDetection = 0
        rollFilter.reset()
        lastRoll = 0
    }

    // MARK: - Vision plumbing

    private func detectFace(in pixelBuffer: CVPixelBuffer) -> VNFaceObservation? {
        let request = VNDetectFaceRectanglesRequest()
        // Revision 3 is the one that reports roll / yaw / pitch.
        if VNDetectFaceRectanglesRequest.supportedRevisions.contains(VNDetectFaceRectanglesRequestRevision3) {
            request.revision = VNDetectFaceRectanglesRequestRevision3
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            logger.debug("face detection failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let faces = request.results, !faces.isEmpty else { return nil }
        // The subject is whoever fills the most of the frame.
        return faces
            .filter { $0.confidence >= configuration.minimumDetectionConfidence }
            .max { a, b in
                a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
            }
    }

    /// Vision reports roll counter-clockwise in its own y-up normalised space; the ROI
    /// sampler works in y-down pixel space, where the same rotation has the opposite
    /// sign.
    private func imageRoll(of face: VNFaceObservation) -> Double {
        guard let roll = face.roll else { return lastRoll }
        return -roll.doubleValue
    }

    /// Converts a Vision bounding box (normalised, origin bottom-left) into a rolled
    /// ``FaceQuad`` in pixel coordinates with the origin top-left.
    private func quad(from boundingBox: CGRect, roll: Double, imageSize: CGSize) -> FaceQuad {
        let width = boundingBox.width * imageSize.width
        let height = boundingBox.height * imageSize.height
        let centerX = boundingBox.midX * imageSize.width
        let centerY = (1 - boundingBox.midY) * imageSize.height
        return FaceQuad(
            center: Point2D(x: centerX, y: centerY),
            width: width,
            height: height,
            roll: roll
        )
    }
}
