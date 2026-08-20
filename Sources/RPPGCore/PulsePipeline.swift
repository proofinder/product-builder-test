import Foundation

/// Frame-rate pulse chain: ROI RGB → POS → band-pass → rolling buffer → heart rate.
public struct PulsePipeline {

    public struct Configuration: Sendable {

        /// Camera frame rate in Hz (30 or 60 on the supported tablets).
        public var sampleRate: Double

        /// Pass band for the pulse, in Hz. 0.7 – 4.0 Hz is 42 – 240 bpm.
        public var band: ClosedRange<Double>

        /// Length of the analysis buffer, in seconds. Longer buffers sharpen the
        /// spectral peak but respond more slowly to a changing heart rate.
        public var bufferSeconds: Double

        /// Estimation is refused until the buffer holds this many seconds.
        public var minimumSecondsForEstimate: Double

        public var pos: StreamingPOS.Configuration

        public init(
            sampleRate: Double,
            band: ClosedRange<Double> = 0.7...4.0,
            bufferSeconds: Double = 10,
            minimumSecondsForEstimate: Double = 6,
            pos: StreamingPOS.Configuration? = nil
        ) {
            self.sampleRate = sampleRate
            self.band = band
            self.bufferSeconds = bufferSeconds
            self.minimumSecondsForEstimate = minimumSecondsForEstimate
            self.pos = pos ?? StreamingPOS.Configuration(sampleRate: sampleRate)
        }
    }

    public let configuration: Configuration

    private var pos: StreamingPOS
    private var bandpass: BandpassFilter
    private var buffer: RingBuffer<Double>
    private let minimumSamples: Int

    public init(configuration: Configuration) {
        self.configuration = configuration
        pos = StreamingPOS(configuration: configuration.pos)
        bandpass = BandpassFilter(
            lowCutoff: configuration.band.lowerBound,
            highCutoff: configuration.band.upperBound,
            sampleRate: configuration.sampleRate,
            order: 4
        )
        buffer = RingBuffer(
            capacity: max(16, Int((configuration.bufferSeconds * configuration.sampleRate).rounded()))
        )
        minimumSamples = max(16, Int((configuration.minimumSecondsForEstimate * configuration.sampleRate).rounded()))
    }

    /// Feeds one frame. Returns the filtered pulse sample, or `nil` while warming up
    /// or when the ROI measurement was unusable.
    @discardableResult
    public mutating func process(_ sample: RGBSample) -> Double? {
        guard let raw = pos.process(sample) else { return nil }
        let filtered = bandpass.process(raw)
        buffer.append(filtered)
        return filtered
    }

    /// Oldest-to-newest snapshot of the filtered pulse waveform, for plotting.
    public var waveform: [Double] { buffer.elements }

    public var bufferedSampleCount: Int { buffer.count }

    /// Current heart-rate estimate, or `nil` if not enough signal has accumulated.
    public func heartRate() -> SpectralEstimate? {
        guard buffer.count >= minimumSamples else { return nil }
        return SpectralRateEstimator.estimate(
            signal: buffer.elements,
            sampleRate: configuration.sampleRate,
            band: configuration.band
        )
    }

    public mutating func reset() {
        pos.reset()
        bandpass.reset()
        buffer.removeAll()
    }
}

/// Tracking-rate respiration chain.
///
/// Per the spec the respiration signal is the mean `y` of the four tracked face
/// corners: the head rises and falls with the breathing cycle, so that scalar carries
/// the respiratory waveform at the tracking rate (4 Hz by default — well above the
/// 0.6 Hz top of the respiration band).
public struct RespirationPipeline {

    public struct Configuration: Sendable {

        /// Rate the tracker emits quads at, in Hz.
        public var sampleRate: Double

        /// Pass band, in Hz. 0.1 – 0.6 Hz is 6 – 36 breaths/min.
        public var band: ClosedRange<Double>

        /// Analysis buffer length in seconds. Respiration is slow, so this needs to be
        /// far longer than the pulse buffer.
        public var bufferSeconds: Double

        public var minimumSecondsForEstimate: Double

        /// When `true` the corner mean is divided by the quad height before filtering,
        /// making the signal independent of how far the subject sits from the tablet.
        public var normalizeByFaceHeight: Bool

        public init(
            sampleRate: Double,
            band: ClosedRange<Double> = 0.1...0.6,
            bufferSeconds: Double = 45,
            minimumSecondsForEstimate: Double = 20,
            normalizeByFaceHeight: Bool = true
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
        minimumSamples = max(16, Int((configuration.minimumSecondsForEstimate * configuration.sampleRate).rounded()))
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
        // Screen y grows downwards; flip so inhalation (head rising) reads positive.
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
