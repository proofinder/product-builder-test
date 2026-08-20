import AVFoundation
import Foundation

/// The one place that decides how video is oriented and mirrored.
///
/// Both the video data output and the preview layer must agree, otherwise the ROI
/// overlay drifts away from the face it is supposed to be drawn on. Because both
/// connections get exactly this transform, a pixel coordinate from Vision reaches the
/// screen through nothing but the uniform scale in ``AspectFillMapping``.
///
/// The app is locked to landscape (see `Info.plist`), so a single fixed orientation is
/// enough; nothing here has to react to device rotation.
enum CaptureGeometry {

    /// Landscape-right, which is `videoRotationAngle == 0` in the iOS 17 API.
    static let videoOrientation: AVCaptureVideoOrientation = .landscapeRight
    static let rotationAngle: CGFloat = 0

    /// Front-camera video is mirrored so the preview behaves like a mirror. Vision then
    /// analyses the same mirrored image the user sees, which keeps the roll angle and
    /// the overlay consistent with each other.
    static let isMirrored = true

    static func apply(to connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(rotationAngle) {
                connection.videoRotationAngle = rotationAngle
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = videoOrientation
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = isMirrored
        }
    }
}
