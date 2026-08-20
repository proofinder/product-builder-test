import Foundation

/// The two fixed projection rows of the POS (Plane-Orthogonal-to-Skin) algorithm,
/// applied to temporally normalised RGB:
///
///     S1 = [ 0,  1, -1] . Cn   =  Gn - Bn
///     S2 = [-2,  1,  1] . Cn   = -2*Rn + Gn + Bn
///
/// Both rows are orthogonal to the standardised skin-tone vector, so specular and
/// intensity variation cancels while the pulsatile component survives. The pulse is
/// then recovered as `h = S1 + alpha * S2` with `alpha = std(S1) / std(S2)`
/// ("alpha tuning"), which cancels the residual motion component the two projections
/// share.
public enum POSProjection {

    @inline(__always)
    public static func project(red: Double, green: Double, blue: Double) -> (s1: Double, s2: Double) {
        (s1: green - blue, s2: -2 * red + green + blue)
    }
}

/// Streaming, O(1)-per-frame POS.
///
/// The published algorithm normalises each 1.6 s window by that window's temporal
/// mean and stitches the windows back together with overlap-add. Here the window mean
/// is replaced by the persistent ``EWMA`` state defined in the spec
/// (`y = lambda * y + (1 - lambda) * x`), and the same idea supplies the running
/// standard deviations that alpha tuning needs, plus the mean removal that overlap-add
/// performed at the end. The result is mathematically the same construction with an
/// exponential rather than rectangular window, and it costs a handful of multiplies
/// per frame — which is what makes it viable at 60 Hz on a tablet front camera.
///
/// Not thread-safe: feed it from a single serial queue.
public struct StreamingPOS: Sendable {

    public struct Configuration: Sendable {

        /// Frame rate the samples arrive at, in Hz.
        public var sampleRate: Double

        /// Time constant of the per-channel EWMA used for temporal normalisation.
        /// 1.6 s matches the window length used by the original POS paper.
        public var normalizationTimeConstant: Double

        /// Time constant of the running standard deviations behind alpha tuning.
        public var statisticsTimeConstant: Double

        /// Time constant of the EWMA high-pass applied to `h`, replacing the
        /// mean-removal step of overlap-add.
        public var outputTimeConstant: Double

        /// Output is suppressed until this many seconds of samples have been seen, so
        /// the caller never receives the start-up transient.
        public var warmupSeconds: Double

        public init(
            sampleRate: Double,
            normalizationTimeConstant: Double = 1.6,
            statisticsTimeConstant: Double = 1.6,
            outputTimeConstant: Double = 1.0,
            warmupSeconds: Double = 1.6
        ) {
            self.sampleRate = sampleRate
            self.normalizationTimeConstant = normalizationTimeConstant
            self.statisticsTimeConstant = statisticsTimeConstant
            self.outputTimeConstant = outputTimeConstant
            self.warmupSeconds = warmupSeconds
        }
    }

    public let configuration: Configuration

    // Persistent EWMA state — the "static" variables of the spec.
    private var meanRed: EWMA
    private var meanGreen: EWMA
    private var meanBlue: EWMA
    private var s1Statistics: EWStatistics
    private var s2Statistics: EWStatistics
    private var outputHighPass: EWMAHighPass

    private var samplesSeen: Int = 0
    private let warmupSamples: Int

    /// Most recent alpha (`std(S1) / std(S2)`), exposed for diagnostics.
    public private(set) var alpha: Double = 0

    public init(configuration: Configuration) {
        self.configuration = configuration
        let fs = configuration.sampleRate
        meanRed = EWMA(timeConstant: configuration.normalizationTimeConstant, sampleRate: fs)
        meanGreen = EWMA(timeConstant: configuration.normalizationTimeConstant, sampleRate: fs)
        meanBlue = EWMA(timeConstant: configuration.normalizationTimeConstant, sampleRate: fs)
        s1Statistics = EWStatistics(timeConstant: configuration.statisticsTimeConstant, sampleRate: fs)
        s2Statistics = EWStatistics(timeConstant: configuration.statisticsTimeConstant, sampleRate: fs)
        outputHighPass = EWMAHighPass(timeConstant: configuration.outputTimeConstant, sampleRate: fs)
        warmupSamples = max(1, Int((configuration.warmupSeconds * fs).rounded()))
    }

    /// Consumes one ROI measurement and returns one raw pulse sample.
    ///
    /// - Returns: `nil` while warming up, or when the sample is unusable (face lost,
    ///   empty ROI). The persistent state is left untouched for unusable samples so a
    ///   dropped frame does not disturb the running normalisation.
    public mutating func process(_ sample: RGBSample) -> Double? {
        guard sample.isUsable else { return nil }

        // 1. Temporal normalisation, Cn = C / EWMA(C).
        let muR = meanRed.update(sample.red)
        let muG = meanGreen.update(sample.green)
        let muB = meanBlue.update(sample.blue)
        guard muR > .ulpOfOne, muG > .ulpOfOne, muB > .ulpOfOne else { return nil }

        let normalizedRed = sample.red / muR
        let normalizedGreen = sample.green / muG
        let normalizedBlue = sample.blue / muB

        // 2. Projection onto the plane orthogonal to the skin-tone direction.
        let projected = POSProjection.project(
            red: normalizedRed,
            green: normalizedGreen,
            blue: normalizedBlue
        )

        // 3. Alpha tuning from the running standard deviations.
        s1Statistics.update(projected.s1)
        s2Statistics.update(projected.s2)
        let deviation2 = s2Statistics.standardDeviation
        alpha = deviation2 > .ulpOfOne ? s1Statistics.standardDeviation / deviation2 : 0
        let h = projected.s1 + alpha * projected.s2

        // 4. Mean removal (the role overlap-add plays in the windowed formulation).
        let pulse = outputHighPass.process(h)

        samplesSeen += 1
        guard samplesSeen >= warmupSamples else { return nil }
        return pulse
    }

    public mutating func reset() {
        meanRed.reset(); meanGreen.reset(); meanBlue.reset()
        s1Statistics.reset(); s2Statistics.reset()
        outputHighPass.reset()
        samplesSeen = 0
        alpha = 0
    }
}

/// Reference implementation of POS exactly as published (Wang et al., *Algorithmic
/// Principles of Remote PPG*, IEEE TBME 2017): sliding window, per-window temporal
/// mean, overlap-add.
///
/// Kept for offline analysis and as the ground truth the streaming filter is checked
/// against in the tests. It is batch-only and allocates, so it is not used on the
/// capture path.
public enum WindowedPOS {

    /// - Parameters:
    ///   - samples: ROI measurements, oldest first, uniformly sampled.
    ///   - sampleRate: frame rate in Hz.
    ///   - windowSeconds: analysis window length; 1.6 s in the paper.
    /// - Returns: one pulse sample per input sample.
    public static func process(
        samples: [RGBSample],
        sampleRate: Double,
        windowSeconds: Double = 1.6
    ) -> [Double] {
        let count = samples.count
        let windowLength = max(2, Int((windowSeconds * sampleRate).rounded()))
        var output = [Double](repeating: 0, count: count)
        guard count >= windowLength else { return output }

        for end in windowLength...count {
            let start = end - windowLength
            let window = samples[start..<end]

            var sumR = 0.0, sumG = 0.0, sumB = 0.0
            for sample in window {
                sumR += sample.red; sumG += sample.green; sumB += sample.blue
            }
            let n = Double(windowLength)
            let meanR = sumR / n, meanG = sumG / n, meanB = sumB / n
            guard meanR > .ulpOfOne, meanG > .ulpOfOne, meanB > .ulpOfOne else { continue }

            var s1 = [Double](repeating: 0, count: windowLength)
            var s2 = [Double](repeating: 0, count: windowLength)
            for (offset, sample) in window.enumerated() {
                let projected = POSProjection.project(
                    red: sample.red / meanR,
                    green: sample.green / meanG,
                    blue: sample.blue / meanB
                )
                s1[offset] = projected.s1
                s2[offset] = projected.s2
            }

            let deviation1 = standardDeviation(s1)
            let deviation2 = standardDeviation(s2)
            let alpha = deviation2 > .ulpOfOne ? deviation1 / deviation2 : 0

            var h = [Double](repeating: 0, count: windowLength)
            var sumH = 0.0
            for i in 0..<windowLength {
                h[i] = s1[i] + alpha * s2[i]
                sumH += h[i]
            }
            let meanH = sumH / n

            // Overlap-add of the zero-mean window.
            for i in 0..<windowLength {
                output[start + i] += h[i] - meanH
            }
        }
        return output
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        let n = Double(values.count)
        guard n > 1 else { return 0 }
        let mean = values.reduce(0, +) / n
        let sumSquares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumSquares / n).squareRoot()
    }
}
