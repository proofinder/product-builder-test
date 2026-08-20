import Foundation

/// Frame-rate pulse chain: ROI mean `C` → POS → `rppg`.
///
/// Two buffers are kept, and the distinction matters:
///
/// * `rppgWaveform` is the specification's `H` exactly as computed — a running sum,
///   nothing applied to it. This is what gets recorded and compared against MATLAB.
/// * `analysisWaveform` is a band-passed copy used **only** for the on-screen trace and
///   the heart-rate estimate. The running sum re-introduces the low frequencies that
///   `h - hmean` removed, so it drifts; that drift would dominate a spectrum without
///   being anything to do with the pulse.
///
/// Nothing in the analysis path feeds back into the POS state.
public struct PulsePipeline {

    public struct Configuration: Sendable {

        /// Camera frame rate in Hz, used to size the buffers and the analysis filter.
        /// Note that it does **not** affect `lambda1`/`lambda2`, which the reference
        /// fixes as constants.
        public var sampleRate: Double

        public var pos: POSProcessor.Configuration

        /// Pass band for the analysis copy, in Hz. 0.7–4.0 Hz is 42–240 bpm.
        public var band: ClosedRange<Double>

        /// Length of the analysis buffer, in seconds. Longer sharpens the spectral peak
        /// but responds more slowly to a changing heart rate.
        public var bufferSeconds: Double

        /// Estimation is refused until the buffer holds this many seconds.
        public var minimumSecondsForEstimate: Double

        public init(
            sampleRate: Double,
            pos: POSProcessor.Configuration = .reference,
            band: ClosedRange<Double> = 0.7...4.0,
            bufferSeconds: Double = 10,
            minimumSecondsForEstimate: Double = 6
        ) {
            self.sampleRate = sampleRate
            self.pos = pos
            self.band = band
            self.bufferSeconds = bufferSeconds
            self.minimumSecondsForEstimate = minimumSecondsForEstimate
        }
    }

    public let configuration: Configuration

    private var processor: POSProcessor
    private var analysisFilter: BandpassFilter
    private var rppgBuffer: RingBuffer<Double>
    private var analysisBuffer: RingBuffer<Double>
    private let minimumSamples: Int

    public init(configuration: Configuration) {
        self.configuration = configuration
        processor = POSProcessor(configuration: configuration.pos)
        analysisFilter = BandpassFilter(
            lowCutoff: configuration.band.lowerBound,
            highCutoff: configuration.band.upperBound,
            sampleRate: configuration.sampleRate,
            order: 4
        )
        let capacity = max(16, Int((configuration.bufferSeconds * configuration.sampleRate).rounded()))
        rppgBuffer = RingBuffer(capacity: capacity)
        analysisBuffer = RingBuffer(capacity: capacity)
        minimumSamples = max(
            16,
            Int((configuration.minimumSecondsForEstimate * configuration.sampleRate).rounded())
        )
    }

    /// Feeds one frame's ROI mean.
    ///
    /// - Returns: the full POS step, so the caller can record every intermediate, or
    ///   `nil` when the sample was unusable.
    @discardableResult
    public mutating func process(_ sample: ROISample) -> POSProcessor.Step? {
        guard sample.isUsable, let step = processor.process(sample.channels) else { return nil }
        rppgBuffer.append(step.rppg)
        analysisBuffer.append(analysisFilter.process(step.rppg))
        return step
    }

    /// The specification's `H`, oldest to newest, unmodified.
    public var rppgWaveform: [Double] { rppgBuffer.elements }

    /// Band-passed copy, for display and rate estimation only.
    public var analysisWaveform: [Double] { analysisBuffer.elements }

    public var bufferedSampleCount: Int { analysisBuffer.count }

    public var currentRPPG: Double { processor.currentRPPG }

    public func heartRate() -> SpectralEstimate? {
        guard analysisBuffer.count >= minimumSamples else { return nil }
        return SpectralRateEstimator.estimate(
            signal: analysisBuffer.elements,
            sampleRate: configuration.sampleRate,
            band: configuration.band
        )
    }

    public mutating func reset() {
        processor.reset()
        analysisFilter.reset()
        rppgBuffer.removeAll()
        analysisBuffer.removeAll()
    }
}

/// Tracking-rate respiration chain.
///
/// The reference marks the source explicitly:
///
/// ```matlab
/// % motion(frameCount,:) = mean(bboxPoints);   % 1:x축, 2:y축, y축 호흡 신호로 활용
/// ```
///
/// so the signal is the mean `y` of the four tracked corners, sampled at the tracking
/// rate (4 Hz — comfortably above the 0.6 Hz top of the respiration band).
public struct RespirationPipeline {

    public struct Configuration: Sendable {

        /// Rate the tracker emits quads at, in Hz.
        public var sampleRate: Double

        /// Pass band, in Hz. 0.1–0.6 Hz is 6–36 breaths/min.
        public var band: ClosedRange<Double>

        /// Analysis buffer length in seconds. Respiration is slow, so this has to be
        /// far longer than the pulse buffer.
        public var bufferSeconds: Double

        public var minimumSecondsForEstimate: Double

        /// When `true` the corner mean is divided by the quad height before filtering,
        /// making the signal independent of how far the subject sits from the tablet.
        /// The reference does not do this; it is off by default so the recorded signal
        /// matches `mean(bboxPoints)` directly.
        public var normalizeByFaceHeight: Bool

        public init(
            sampleRate: Double,
            band: ClosedRange<Double> = 0.1...0.6,
            bufferSeconds: Double = 45,
            minimumSecondsForEstimate: Double = 20,
            normalizeByFaceHeight: Bool = false
        ) {
            self.sampleRate = sampleRate
            self.band = band
            self.bufferSeconds = bufferSeconds
            self.minimumSecondsForEstimate = minimumSecondsForEstimate
            self.normalizeByFaceHeight = normalizeByFaceHeight
        }
    }

    public let configuration: Configuration

    private var bandpass: BandpassFilter
    private var buffer: RingBuffer<Double>
    private let minimumSamples: Int

    public init(configuration: Configuration) {
        self.configuration = configuration
        bandpass = BandpassFilter(
            lowCutoff: configuration.band.lowerBound,
            highCutoff: configuration.band.upperBound,
            sampleRate: configuration.sampleRate,
            order: 2
        )
        buffer = RingBuffer(
            capacity: max(16, Int((configuration.bufferSeconds * configuration.sampleRate).rounded()))
        )
        minimumSamples = max(
            16,
            Int((configuration.minimumSecondsForEstimate * configuration.sampleRate).rounded())
        )
    }

    /// Feeds one tracker output. Returns the filtered respiration sample.
    @discardableResult
    public mutating func process(quad: FaceQuad) -> Double? {
        var value = quad.meanCornerY
        if configuration.normalizeByFaceHeight {
            let height = quad.height
            guard height > .ulpOfOne else { return nil }
            value /= height
        }
        // Screen y grows downwards; flip so a rising head reads positive.
        let filtered = bandpass.process(-value)
        buffer.append(filtered)
        return filtered
    }

    public var waveform: [Double] { buffer.elements }

    public var bufferedSampleCount: Int { buffer.count }

    public func respirationRate() -> SpectralEstimate? {
        guard buffer.count >= minimumSamples else { return nil }
        return SpectralRateEstimator.estimate(
            signal: buffer.elements,
            sampleRate: configuration.sampleRate,
            band: configuration.band,
            harmonicHalfWidth: 0.03
        )
    }

    public mutating func reset() {
        bandpass.reset()
        buffer.removeAll()
    }
}
