import AVFoundation
import CoreVideo
import Foundation
import RPPGCore
import os

/// Snapshot handed to the UI. Produced on the processing queue, delivered on main.
struct CaptureSnapshot: Sendable {
    var pulseWaveform: [Double] = []
    var respirationWaveform: [Double] = []
    var heartRate: SpectralEstimate?
    var respirationRate: SpectralEstimate?
    var quality: SignalQuality = .none
    /// Tracked face box in image pixel coordinates, for the overlay.
    var faceQuad: FaceQuad?
    /// The central-80% ROI actually sampled.
    var roiQuad: FaceQuad?
    var imageSize: CGSize = .zero
    /// Frame rate the DSP is configured for.
    var frameRate: Double = 0
    /// Frame rate actually observed from the presentation timestamps.
    var measuredFrameRate: Double = 0
    var trackingRate: Double = 0
    var rollDegrees: Double = 0
}

/// Wires the camera, the tracker, the ROI sampler and the DSP engine together, and
/// owns the **frame rate / tracking rate split** the spec asks for.
///
/// * Every frame (30 or 60 Hz) → glide the ROI forward, average its pixels, push one
///   ``RGBSample`` through POS.
/// * Every tracking tick (4 Hz) → hand the newest frame to Vision on a *separate*
///   queue, and feed the resulting quad's mean corner `y` into the respiration chain.
///
/// Vision never runs on the frame path, so a slow detection delays a tracking tick
/// instead of dropping camera frames. At most one detection is in flight; ticks that
/// come due while one is running are skipped.
///
/// Threading contract: every stored property below is owned by `processingQueue`
/// except `onSnapshot`, which is set once before ``start()``. This class is
/// deliberately *not* an actor — the frame path must stay synchronous and
/// allocation-free.
/// `@unchecked Sendable` is a claim about the threading contract above, not an
/// escape hatch: the processing state is confined to `processingQueue`, the camera
/// handle to the main actor, and the tracker to `visionQueue`.
final class CaptureCoordinator: @unchecked Sendable {

    struct Settings {
        var targetFrameRate: Double = 60
        var trackingRate: Double = 4
        /// Central fraction of the face used as the skin ROI. 0.8 per the spec.
        var roiScale: Double = 0.8
        /// EWMA time constant, in seconds, for gliding the ROI between tracking ticks.
        var roiSmoothingTimeConstant: Double = 0.25
        var skinGateEnabled: Bool = false
        /// Seconds without a tracked face before the accumulated signal is discarded.
        var resetAfterFaceLoss: TimeInterval = 3.0
        /// UI refresh rate, Hz.
        var publishRate: Double = 15
    }

    /// Delivered on the main queue.
    var onSnapshot: (@Sendable (CaptureSnapshot) -> Void)?

    private(set) var settings: Settings

    private let processingQueue = DispatchQueue(label: "rppg.processing", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "rppg.vision", qos: .userInitiated)

    private var camera: CameraSession?
    private let tracker = FaceTracker()
    private let logger = Logger(subsystem: "com.rppg.tablet", category: "CaptureCoordinator")

    // MARK: Processing-queue state
    private var engine: RPPGEngine?
    private var smoother: QuadSmoother?
    private var sampler = ROISampler()
    private var roiScale: Double = 0.8
    private var trackingInterval: TimeInterval = 0.25
    private var faceLossTimeout: TimeInterval = 3.0
    private var publishInterval: TimeInterval = 1.0 / 15.0

    private var latestFaceQuad: FaceQuad?
    private var imageSize: CGSize = .zero
    private var lastTrackTimestamp: TimeInterval = -.infinity
    private var lastFaceSeenTimestamp: TimeInterval = -.infinity
    private var lastPublishTimestamp: TimeInterval = -.infinity
    private var visionBusy = false
    private var frameRateEstimate = EWMA(lambda: 0.95)
    private var previousFrameTimestamp: TimeInterval?

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// The session the SwiftUI preview layer attaches to.
    @MainActor var captureSession: AVCaptureSession? { camera?.session }

    // MARK: - Lifecycle

    /// Starts the camera and builds the DSP chain around the frame rate the device
    /// actually granted.
    /// - Throws: ``CameraSession/StartError``.
    @MainActor
    func start() async throws {
        guard camera == nil else { return }

        let camera = CameraSession(
            configuration: .init(targetFrameRate: settings.targetFrameRate),
            outputQueue: processingQueue
        )
        camera.onFrame = { [weak self] pixelBuffer, timestamp in
            self?.handleFrame(pixelBuffer, timestamp: timestamp)
        }

        do {
            try await camera.start()
        } catch {
            camera.stop()
            throw error
        }
        self.camera = camera

        let frameRate = camera.actualFrameRate
        let settings = self.settings
        processingQueue.sync {
            self.engine = RPPGEngine(
                configuration: .init(frameRate: frameRate, trackingRate: settings.trackingRate)
            )
            self.smoother = QuadSmoother(
                timeConstant: settings.roiSmoothingTimeConstant,
                sampleRate: frameRate
            )
            self.sampler.skinGateEnabled = settings.skinGateEnabled
            self.roiScale = settings.roiScale
            self.trackingInterval = 1.0 / settings.trackingRate
            self.faceLossTimeout = settings.resetAfterFaceLoss
            self.publishInterval = 1.0 / settings.publishRate
            self.clearProcessingState()
        }
        logger.info("capture started at \(frameRate) fps, tracking at \(settings.trackingRate) Hz")
    }

    @MainActor
    func stop() {
        camera?.stop()
        camera = nil
        processingQueue.sync {
            self.engine = nil
            self.smoother = nil
            self.clearProcessingState()
        }
        visionQueue.async { self.tracker.reset() }
    }

    /// Discards the accumulated signal without restarting the camera.
    func resetSignal() {
        processingQueue.async {
            self.engine?.reset()
            self.smoother?.reset()
            self.clearProcessingState()
        }
        visionQueue.async { self.tracker.reset() }
    }

    /// Re-runs auto exposure / white balance and then re-locks them. Worth offering in
    /// the UI: once exposure is locked, a change in room lighting cannot be corrected
    /// any other way.
    @MainActor
    func rebalanceCamera() {
        camera?.relock()
        resetSignal()
    }

    func setSkinGateEnabled(_ enabled: Bool) {
        settings.skinGateEnabled = enabled
        processingQueue.async { self.sampler.skinGateEnabled = enabled }
    }

    private func clearProcessingState() {
        latestFaceQuad = nil
        lastTrackTimestamp = -.infinity
        lastFaceSeenTimestamp = -.infinity
        lastPublishTimestamp = -.infinity
        previousFrameTimestamp = nil
        frameRateEstimate.reset()
    }

    // MARK: - Frame path (frame rate: 30 / 60 Hz)

    private func handleFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        // The camera's output queue *is* the processing queue, so this is already
        // serialised against everything else that touches the state below.
        dispatchPrecondition(condition: .onQueue(processingQueue))
        guard let engine, let smoother else { return }

        if let previous = previousFrameTimestamp, timestamp > previous {
            frameRateEstimate.update(1 / (timestamp - previous))
        }
        previousFrameTimestamp = timestamp
        imageSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        // 1. Tracking-rate gate: hand this frame to Vision when a tick is due.
        if timestamp - lastTrackTimestamp >= trackingInterval, !visionBusy {
            lastTrackTimestamp = timestamp
            visionBusy = true
            visionQueue.async { [weak self] in
                guard let self else { return }
                let output = self.tracker.track(pixelBuffer: pixelBuffer)
                self.processingQueue.async {
                    self.applyTrackerOutput(output)
                    self.visionBusy = false
                }
            }
        }

        // 2. Frame-rate ROI sampling. The smoother glides the ROI between the 4 Hz
        //    tracker updates, so the sampled region never steps — a 4 Hz staircase
        //    would land right inside the pulse band.
        var faceTracked = false
        var roiQuad: FaceQuad?
        var sample = RGBSample(red: 0, green: 0, blue: 0, timestamp: timestamp, pixelCount: 0)

        if latestFaceQuad != nil, let smoothed = smoother.advance() {
            let roi = smoothed.scaled(roiScale)
            roiQuad = roi
            sample = sampler.sample(roi: roi, pixelBuffer: pixelBuffer, timestamp: timestamp)
            faceTracked = sample.pixelCount > 0
        }

        let output = engine.ingestFrame(sample, faceTracked: faceTracked)

        // 3. Drop stale state once the face has been gone long enough that the buffered
        //    history is no longer about the same measurement.
        if faceTracked {
            lastFaceSeenTimestamp = timestamp
        } else if lastFaceSeenTimestamp.isFinite,
                  timestamp - lastFaceSeenTimestamp > faceLossTimeout {
            engine.reset()
            smoother.reset()
            latestFaceQuad = nil
            lastFaceSeenTimestamp = -.infinity
            logger.info("face lost, accumulated signal discarded")
        }

        // 4. Publish at a human rate, not at the frame rate.
        if timestamp - lastPublishTimestamp >= publishInterval {
            lastPublishTimestamp = timestamp
            publish(output: output, roiQuad: roiQuad)
        }
    }

    // MARK: - Tracking path (tracking rate: 4 Hz)

    private func applyTrackerOutput(_ output: FaceTracker.Output?) {
        dispatchPrecondition(condition: .onQueue(processingQueue))
        guard let output else {
            latestFaceQuad = nil
            return
        }
        latestFaceQuad = output.faceQuad
        smoother?.setTarget(output.faceQuad)
        // Step 1 of the spec: the mean y of the four tracked corners is the
        // respiration signal, sampled here at the tracking rate.
        engine?.ingestTrack(output.faceQuad)
    }

    // MARK: - Publishing

    private func publish(output: RPPGOutput, roiQuad: FaceQuad?) {
        guard let engine else { return }
        var snapshot = CaptureSnapshot()
        snapshot.pulseWaveform = engine.pulseWaveform
        snapshot.respirationWaveform = engine.respirationWaveform
        snapshot.heartRate = output.heartRate
        snapshot.respirationRate = output.respirationRate
        snapshot.quality = output.quality
        snapshot.faceQuad = latestFaceQuad
        snapshot.roiQuad = roiQuad
        snapshot.imageSize = imageSize
        snapshot.frameRate = engine.configuration.pulse.sampleRate
        snapshot.trackingRate = engine.configuration.respiration.sampleRate
        snapshot.measuredFrameRate = frameRateEstimate.value
        snapshot.rollDegrees = (latestFaceQuad?.roll ?? 0) * 180 / .pi

        let handler = onSnapshot
        DispatchQueue.main.async { handler?(snapshot) }
    }
}
