import Foundation

/// Everything the UI needs after one camera frame.
public struct RPPGOutput: Sendable {
    /// Filtered pulse sample for this frame, `nil` while warming up.
    public var pulseSample: Double?
    /// Filtered respiration sample, non-`nil` only on frames that carried a tracker update.
    public var respirationSample: Double?
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

    public static let none = SignalQuality(
        faceTracked: false, roiPixelCount: 0, clippedFraction: 0,
        pulseConfidence: 0, secondsBuffered: 0
    )
}

/// Top-level signal engine. Owns the dual-rate split described in the spec:
///
/// * ``ingestFrame(_:)`` runs at the **frame rate** (30 / 60 Hz) — one ROI RGB
///   measurement per camera frame, through POS to a pulse sample.
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
            estimateInterval: TimeInterval = 0.5
        ) {
            pulse = PulsePipeline.Configuration(sampleRate: frameRate)
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

    public init(configuration: Configuration) {
        self.configuration = configuration
        pulsePipeline = PulsePipeline(configuration: configuration.pulse)
        respirationPipeline = RespirationPipeline(configuration: configuration.respiration)
    }

    /// Frame-rate entry point.
    @discardableResult
    public func ingestFrame(_ sample: RGBSample, faceTracked: Bool) -> RPPGOutput {
        let pulseSample = faceTracked ? pulsePipeline.process(sample) : nil

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
            secondsBuffered: Double(pulsePipeline.bufferedSampleCount) / configuration.pulse.sampleRate
        )

        return RPPGOutput(
            pulseSample: pulseSample,
            respirationSample: nil,
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

    public var pulseWaveform: [Double] { pulsePipeline.waveform }
    public var respirationWaveform: [Double] { respirationPipeline.waveform }
    public var heartRate: SpectralEstimate? { cachedHeartRate }
    public var respirationRate: SpectralEstimate? { cachedRespirationRate }
    public var quality: SignalQuality { lastQuality }

    /// Clears every persistent filter state. Call when the face is lost for long
    /// enough that the buffered history is no longer about the same subject.
    public func reset() {
        pulsePipeline.reset()
        respirationPipeline.reset()
        cachedHeartRate = nil
        cachedRespirationRate = nil
        lastEstimateTimestamp = -.infinity
        lastQuality = .none
    }
}
