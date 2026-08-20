import AVFoundation
import CoreVideo
import Foundation
import RPPGCore
import os

/// Snapshot handed to the UI. Produced on the processing queue, delivered on main.
struct CaptureSnapshot: Sendable {
    /// The specification's `H`, unmodified.
    var rppgWaveform: [Double] = []
    /// Band-passed copy of `H`, for display and rate estimation only.
    var pulseAnalysisWaveform: [Double] = []
    var respirationWaveform: [Double] = []
    /// The most recent POS step, so the debug view can show every intermediate live.
    var posStep: POSProcessor.Step?
    var heartRate: SpectralEstimate?
    var respirationRate: SpectralEstimate?
    var quality: SignalQuality = .none

    /// Tracked face box in image pixel coordinates, for the overlay.
    var faceQuad: FaceQuad?
    /// The ROI actually sampled.
    var roiQuad: FaceQuad?
    var imageSize: CGSize = .zero

    /// Frame rate the DSP is configured for.
    var frameRate: Double = 0
    /// Frame rate actually observed from the presentation timestamps.
    var measuredFrameRate: Double = 0
    /// Standard deviation of the frame interval, ms — the Stage 1 jitter figure.
    var frameIntervalJitterMs: Double = 0
    var trackingRate: Double = 0
    /// Measured tracking-tick rate, Hz.
    var measuredTrackingRate: Double = 0
    var rollDegrees: Double = 0
    var droppedFrameCount: Int = 0
    var deliveredFrameCount: Int = 0
    var trackSource: String = "none"

    /// Raw mean-corner-y at the tracking rate, mean removed for plotting. This is the
    /// respiration signal before any filtering — what Stage 2 has to get right.
    var cornerYWaveform: [Double] = []
    var tracking = TrackingDiagnostics()

    var isRecording = false
    var recordedRowCount = 0
}

/// Wires the camera, the tracker, the ROI sampler, the DSP engine and the recorder
/// together, and owns the **frame rate / tracking rate split** from the specification.
///
/// * Every frame (30 or 60 Hz) → glide the ROI forward, average its pixels into `C`,
///   push one POS step.
/// * Every tracking tick (4 Hz) → hand the newest frame to Vision on a *separate*
///   queue, and feed the resulting quad's mean corner `y` into the respiration chain.
///
/// Vision never runs on the frame path, so a slow detection delays a tracking tick
/// instead of dropping camera frames. At most one detection is in flight; ticks that
/// come due while one is running are skipped.
///
/// Threading contract: every stored property is owned by `processingQueue` except the
/// camera handle and `onSnapshot`, which belong to the main actor.
/// `@unchecked Sendable` is a claim about that contract, not an escape hatch.
final class CaptureCoordinator: @unchecked Sendable {

    struct Settings {
        var targetFrameRate: Double = 60
        var trackingRate: Double = 4
        /// Central fraction of the face used as the skin ROI.
        ///
        /// The written specification says 0.8. Note the MATLAB reference averages the
        /// **whole** rotated box, so a run being compared against it must use 1.0.
        var roiScale: Double = 0.8
        /// EWMA time constant, in seconds, for gliding the ROI between tracking ticks.
        var roiSmoothingTimeConstant: Double = 0.25
        var skinGateEnabled: Bool = false
        /// Seconds without a tracked face before the accumulated signal is discarded.
        var resetAfterFaceLoss: TimeInterval = 3.0
        /// UI refresh rate, Hz.
        var publishRate: Double = 15
        var pos: POSProcessor.Configuration = .reference
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
    private var recorder: SignalRecorder?
    private var roiScale: Double = 0.8
    private var trackingInterval: TimeInterval = 0.25
    private var faceLossTimeout: TimeInterval = 3.0
    private var publishInterval: TimeInterval = 1.0 / 15.0

    private var latestFaceQuad: FaceQuad?
    private var latestTrackSource = "none"
    private var latestRoll: Double = 0
    private var imageSize: CGSize = .zero
    private var frameCount = 0
    private var deliveredFrameCount = 0
    private var lastTrackTimestamp: TimeInterval = -.infinity
    private var lastFaceSeenTimestamp: TimeInterval = -.infinity
    private var lastPublishTimestamp: TimeInterval = -.infinity
    private var visionBusy = false
    private var previousFrameTimestamp: TimeInterval?
    private var frameIntervalStats = RunningStatistics()
    private var trackIntervalStats = RunningStatistics()
    private var trackingStats = TrackingStatistics()
    private var cornerYBuffer = RingBuffer<Double>(capacity: 240)
    private var latestTracking = TrackingDiagnostics()

    init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// The session the SwiftUI preview layer attaches to.
    @MainActor var captureSession: AVCaptureSession? { camera?.session }

    // MARK: - Lifecycle

    /// Starts the camera and builds the DSP chain around the frame rate the device
    /// actually granted.
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
        camera.onDrop = { [weak self] in
            self?.processingQueue.async { self?.noteDroppedFrame() }
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
                configuration: .init(
                    frameRate: frameRate,
                    trackingRate: settings.trackingRate,
                    pos: settings.pos
                )
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
            self.recorder?.finish { _ in }
            self.recorder = nil
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

    /// Re-runs auto exposure / white balance and then re-locks them. Once exposure is
    /// locked a change in room lighting cannot be corrected any other way.
    @MainActor
    func rebalanceCamera() {
        camera?.relock()
        resetSignal()
    }

    func setSkinGateEnabled(_ enabled: Bool) {
        settings.skinGateEnabled = enabled
        processingQueue.async { self.sampler.skinGateEnabled = enabled }
    }

    /// Clears the Stage 1 / Stage 2 measurement window. The procedure is: press this,
    /// hold still for a minute, read the numbers.
    func resetStatistics() {
        processingQueue.async {
            self.frameIntervalStats.reset()
            self.trackIntervalStats.reset()
            self.trackingStats.reset()
            self.cornerYBuffer.removeAll()
            self.frameCount = 0
            self.deliveredFrameCount = 0
        }
    }

    func setROIScale(_ scale: Double) {
        settings.roiScale = scale
        processingQueue.async { self.roiScale = scale }
    }

    // MARK: - Recording (Stage 0)

    /// Begins a recording. Returns the file URL, or throws if the file cannot be made.
    @discardableResult
    func startRecording(name: String = SignalRecorder.timestampedName()) throws -> URL {
        let recorder = try SignalRecorder(directory: SignalRecorder.documentsDirectory, name: name)
        processingQueue.async {
            self.recorder?.finish { _ in }
            self.recorder = recorder
        }
        logger.info("recording to \(recorder.url.lastPathComponent, privacy: .public)")
        return recorder.url
    }

    /// Ends the recording; `completion` receives the finished file on the main queue.
    func stopRecording(completion: @escaping (URL?) -> Void) {
        processingQueue.async {
            guard let recorder = self.recorder else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.recorder = nil
            recorder.finish { url in completion(url) }
        }
    }

    private func clearProcessingState() {
        latestFaceQuad = nil
        latestTrackSource = "none"
        latestRoll = 0
        frameCount = 0
        deliveredFrameCount = 0
        lastTrackTimestamp = -.infinity
        lastFaceSeenTimestamp = -.infinity
        lastPublishTimestamp = -.infinity
        previousFrameTimestamp = nil
        frameIntervalStats.reset()
        trackIntervalStats.reset()
        trackingStats.reset()
        cornerYBuffer.removeAll()
        latestTracking = TrackingDiagnostics()
    }

    private func noteDroppedFrame() {
        frameCount += 1
    }

    // MARK: - Frame path (frame rate: 30 / 60 Hz)

    private func handleFrame(_ pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) {
        // The camera's output queue *is* the processing queue, so this is already
        // serialised against everything else that touches the state below.
        dispatchPrecondition(condition: .onQueue(processingQueue))
        guard let engine, let smoother else { return }

        frameCount += 1
        deliveredFrameCount += 1

        var dtMs = Double.nan
        if let previous = previousFrameTimestamp, timestamp > previous {
            dtMs = (timestamp - previous) * 1000
            frameIntervalStats.add(dtMs)
        }
        previousFrameTimestamp = timestamp
        imageSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        // 1. Tracking-rate gate: hand this frame to Vision when a tick is due.
        if timestamp - lastTrackTimestamp >= trackingInterval, !visionBusy {
            if lastTrackTimestamp.isFinite {
                trackIntervalStats.add((timestamp - lastTrackTimestamp) * 1000)
            }
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
        var sample = ROISample.empty(timestamp: timestamp)

        if latestFaceQuad != nil, let smoothed = smoother.advance() {
            let roi = smoothed.scaled(roiScale)
            roiQuad = roi
            sample = sampler.sample(roi: roi, pixelBuffer: pixelBuffer, timestamp: timestamp)
            faceTracked = sample.isUsable
        }

        let output = engine.ingestFrame(sample, faceTracked: faceTracked)

        // 3. Record before anything can reset it.
        if let recorder {
            recorder.append(
                SignalRecord(
                    frameCount: frameCount,
                    t: timestamp,
                    dtMs: dtMs,
                    corners: latestFaceQuad?.corners ?? [],
                    roll: latestRoll,
                    meanCornerY: latestFaceQuad?.meanCornerY ?? .nan,
                    roiPixelCount: sample.pixelCount,
                    trackSource: latestTrackSource,
                    faceTracked: faceTracked,
                    pos: output.posStep
                )
            )
        }

        // 4. Drop stale state once the face has been gone long enough that the buffered
        //    history is no longer about the same measurement.
        if faceTracked {
            lastFaceSeenTimestamp = timestamp
        } else if lastFaceSeenTimestamp.isFinite,
                  timestamp - lastFaceSeenTimestamp > faceLossTimeout {
            engine.reset()
            smoother.reset()
            latestFaceQuad = nil
            latestTrackSource = "none"
            lastFaceSeenTimestamp = -.infinity
            logger.info("face lost, accumulated signal discarded")
        }

        // 5. Publish at a human rate, not at the frame rate.
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
            latestTrackSource = "none"
            latestTracking.faceTracked = false
            latestTracking.source = "none"
            trackingStats.addLost()
            return
        }
        latestFaceQuad = output.faceQuad
        latestRoll = output.roll
        latestTrackSource = output.source.rawValue
        smoother?.setTarget(output.faceQuad)

        // The mean y of the four tracked corners is the respiration signal —
        // `motion(frameCount,:) = mean(bboxPoints)` in the reference.
        engine?.ingestTrack(output.faceQuad)
        cornerYBuffer.append(output.faceQuad.meanCornerY)

        trackingStats.addTracked(
            quad: output.faceQuad,
            roll: output.roll,
            residualPx: output.rmsResidual
        )

        latestTracking.faceTracked = true
        latestTracking.source = output.source.rawValue
        latestTracking.landmarkCount = output.landmarkCount
        latestTracking.inlierCount = output.inlierCount
        latestTracking.rmsResidualPx = output.rmsResidual
        latestTracking.scale = output.scale
        latestTracking.anchorCount = output.anchorCount
        latestTracking.rollDegrees = output.roll * 180 / .pi
        latestTracking.faceWidthPx = output.faceQuad.width
        latestTracking.faceHeightPx = output.faceQuad.height
    }

    // MARK: - Publishing

    private func publish(output: RPPGOutput, roiQuad: FaceQuad?) {
        guard let engine else { return }
        var snapshot = CaptureSnapshot()
        snapshot.rppgWaveform = engine.rppgWaveform
        snapshot.pulseAnalysisWaveform = engine.pulseAnalysisWaveform
        snapshot.respirationWaveform = engine.respirationWaveform
        snapshot.posStep = output.posStep
        snapshot.heartRate = output.heartRate
        snapshot.respirationRate = output.respirationRate
        snapshot.quality = output.quality
        snapshot.faceQuad = latestFaceQuad
        snapshot.roiQuad = roiQuad
        snapshot.imageSize = imageSize
        snapshot.frameRate = engine.configuration.pulse.sampleRate
        snapshot.trackingRate = engine.configuration.respiration.sampleRate
        snapshot.measuredFrameRate = frameIntervalStats.mean > 0 ? 1000 / frameIntervalStats.mean : 0
        snapshot.frameIntervalJitterMs = frameIntervalStats.standardDeviation
        snapshot.measuredTrackingRate = trackIntervalStats.mean > 0 ? 1000 / trackIntervalStats.mean : 0
        snapshot.rollDegrees = latestRoll * 180 / .pi
        snapshot.trackSource = latestTrackSource
        snapshot.deliveredFrameCount = deliveredFrameCount
        snapshot.droppedFrameCount = max(0, frameCount - deliveredFrameCount)
        snapshot.isRecording = recorder != nil
        snapshot.recordedRowCount = recorder?.recordedRowCount ?? 0

        // Mean removed so the plot shows the breathing excursion rather than where the
        // subject happens to sit in the frame.
        let cornerY = cornerYBuffer.elements
        if !cornerY.isEmpty {
            let mean = cornerY.reduce(0, +) / Double(cornerY.count)
            snapshot.cornerYWaveform = cornerY.map { $0 - mean }
        }

        var tracking = latestTracking
        tracking.configuredFrameRate = snapshot.frameRate
        tracking.measuredFrameRate = snapshot.measuredFrameRate
        tracking.frameIntervalJitterMs = frameIntervalStats.standardDeviation
        tracking.deliveredFrameCount = deliveredFrameCount
        tracking.droppedFrameCount = snapshot.droppedFrameCount
        tracking.configuredTrackingRate = snapshot.trackingRate
        tracking.measuredTrackingRate = snapshot.measuredTrackingRate
        tracking.trackingIntervalJitterMs = trackIntervalStats.standardDeviation
        tracking.trackingTickCount = trackingStats.tickCount
        tracking.statsSampleCount = trackingStats.sampleCount
        tracking.statsSeconds = snapshot.trackingRate > 0
            ? Double(trackingStats.sampleCount) / snapshot.trackingRate : 0
        tracking.cornerJitterPx = trackingStats.cornerJitterPx
        tracking.cornerJitterPercentOfWidth = trackingStats.meanFaceWidthPx > 0
            ? trackingStats.cornerJitterPx / trackingStats.meanFaceWidthPx * 100 : 0
        tracking.meanCornerYStdPx = trackingStats.meanCornerYStdPx
        tracking.rollStdDegrees = trackingStats.rollStdDegrees
        tracking.residualRmsMeanPx = trackingStats.residualMeanPx
        tracking.faceLostCount = trackingStats.faceLostCount
        tracking.lastReacquireTicks = trackingStats.lastReacquireTicks
        tracking.worstReacquireTicks = trackingStats.worstReacquireTicks
        snapshot.tracking = tracking

        let handler = onSnapshot
        DispatchQueue.main.async { handler?(snapshot) }
    }
}
