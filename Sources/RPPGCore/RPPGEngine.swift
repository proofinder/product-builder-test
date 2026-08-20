import Foundation

/// Everything the UI and the recorder need after one camera frame.
public struct RPPGOutput: Sendable {
    /// The full POS step, `nil` when the frame produced no output.
    public var posStep: POSProcessor.Step?
    public var heartRate: SpectralEstimate?
    public var respirationRate: SpectralEstimate?
    public var quality: SignalQuality
}

/// Coarse health of the capture, so the UI can tell the user what to fix.
public struct SignalQuality: Sendable, Equatable {
    public var faceTracked: Bool
    public var roiPixelCount: Int
    public var clippedFraction: Double
    public var pulseConfidence: Double
    public var secondsBuffered: Double
    /// POS steps processed since the last reset — the warm-up indicator.
    public var posStepCount: Int

    public static let none = SignalQuality(
        faceTracked: false, roiPixelCount: 0, clippedFraction: 0,
        pulseConfidence: 0, secondsBuffered: 0, posStepCount: 0
    )
}

/// Top-level signal engine. Owns the dual-rate split from the specification:
///
/// * ``ingestFrame(_:faceTracked:)`` runs at the **frame rate** (30 / 60 Hz) — one ROI
///   mean `C` per camera frame, through POS to one `rppg` sample.
/// * ``ingestTrack(_:)`` runs at the **tracking rate** (4 Hz) — one face quad per
///   tracker update, whose mean corner `y` is the respiration signal.
///
/// Not thread-safe by design: the capture coordinator calls it from a single serial
/// processing queue, which keeps the hot path allocation- and lock-free.
public final class RPPGEngine {

    public struct Configuration: Sendable {
        public var pulse: PulsePipeline.Configuration
        public var respiration: RespirationPipeline.Configuration

        /// How often the spectral estimates are recomputed, in seconds. The FFT is
        /// cheap but pointless to run every frame.
        public var estimateInterval: TimeInterval

        public init(
            frameRate: Double,
            trackingRate: Double,
            pos: POSProcessor.Configuration = .reference,
            estimateInterval: TimeInterval = 0.5
        ) {
            pulse = PulsePipeline.Configuration(sampleRate: frameRate, pos: pos)
            respiration = RespirationPipeline.Configuration(sampleRate: trackingRate)
            self.estimateInterval = estimateInterval
        }
    }

    public let configuration: Configuration

    private var pulsePipeline: PulsePipeline
    private var respirationPipeline: RespirationPipeline

    private var cachedHeartRate: SpectralEstimate?
    private var cachedRespirationRate: SpectralEstimate?
    private var lastEstimateTimestamp: TimeInterval = -.infinity
    private var lastQuality: SignalQuality = .none
    private var posStepCount = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
        pulsePipeline = PulsePipeline(configuration: configuration.pulse)
        respirationPipeline = RespirationPipeline(configuration: configuration.respiration)
    }

    /// Frame-rate entry point.
    @discardableResult
    public func ingestFrame(_ sample: ROISample, faceTracked: Bool) -> RPPGOutput {
        let step = faceTracked ? pulsePipeline.process(sample) : nil
        if step != nil { posStepCount += 1 }

        if sample.timestamp - lastEstimateTimestamp >= configuration.estimateInterval {
            lastEstimateTimestamp = sample.timestamp
            cachedHeartRate = pulsePipeline.heartRate()
            cachedRespirationRate = respirationPipeline.respirationRate()
        }

        lastQuality = SignalQuality(
            faceTracked: faceTracked,
            roiPixelCount: sample.pixelCount,
            clippedFraction: sample.clippedFraction,
            pulseConfidence: cachedHeartRate?.confidence ?? 0,
            secondsBuffered: Double(pulsePipeline.bufferedSampleCount) / configuration.pulse.sampleRate,
            posStepCount: posStepCount
        )

        return RPPGOutput(
            posStep: step,
            heartRate: cachedHeartRate,
            respirationRate: cachedRespirationRate,
            quality: lastQuality
        )
    }

    /// Tracking-rate entry point. Returns the filtered respiration sample.
    @discardableResult
    public func ingestTrack(_ quad: FaceQuad) -> Double? {
        respirationPipeline.process(quad: quad)
    }

    /// The specification's `H`, unmodified.
    public var rppgWaveform: [Double] { pulsePipeline.rppgWaveform }
    /// Band-passed copy, for display and rate estimation only.
    public var pulseAnalysisWaveform: [Double] { pulsePipeline.analysisWaveform }
    public var respirationWaveform: [Double] { respirationPipeline.waveform }
    public var heartRate: SpectralEstimate? { cachedHeartRate }
    public var respirationRate: SpectralEstimate? { cachedRespirationRate }
    public var quality: SignalQuality { lastQuality }

    /// Clears every persistent filter state. Call when the face has been lost long
    /// enough that the buffered history is no longer about the same measurement.
    public func reset() {
        pulsePipeline.reset()
        respirationPipeline.reset()
        cachedHeartRate = nil
        cachedRespirationRate = nil
        lastEstimateTimestamp = -.infinity
        lastQuality = .none
        posStepCount = 0
    }
}
