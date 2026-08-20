import AVFoundation
import SwiftUI
import UIKit

/// Hosts an `AVCaptureVideoPreviewLayer`.
///
/// The layer uses `.resizeAspectFill`; ``FaceOverlayView`` reproduces exactly that
/// mapping so the drawn boxes line up with what the user sees.
struct CameraPreviewView: UIViewRepresentable {

    let session: AVCaptureSession?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        view.attach(session)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.attach(session)
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // Safe: `layerClass` guarantees the type.
            layer as! AVCaptureVideoPreviewLayer
        }

        /// Attaches the session and gives the preview connection the *same* orientation
        /// and mirroring as the video data output, so the overlay lines up with what is
        /// on screen.
        func attach(_ session: AVCaptureSession?) {
            videoPreviewLayer.session = session
            if let connection = videoPreviewLayer.connection {
                CaptureGeometry.apply(to: connection)
            }
        }
    }
}

/// Maps image-pixel coordinates onto a view laid out with `.resizeAspectFill`.
///
/// The capture connection already applies orientation and mirroring, so this is just a
/// uniform scale plus a centring offset — the same transform the preview layer uses,
/// which is what keeps the overlay glued to the face.
struct AspectFillMapping {

    let scale: Double
    let offsetX: Double
    let offsetY: Double

    init(imageSize: CGSize, viewSize: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0 else {
            scale = 1; offsetX = 0; offsetY = 0
            return
        }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        self.scale = scale
        offsetX = (viewSize.width - imageSize.width * scale) / 2
        offsetY = (viewSize.height - imageSize.height * scale) / 2
    }

    func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x * scale + offsetX, y: y * scale + offsetY)
    }
}
