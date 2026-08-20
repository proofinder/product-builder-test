import Foundation

/// Second-order IIR section in transposed direct form II.
///
/// Coefficients follow the usual normalised convention
/// `y[n] = b0*x[n] + b1*x[n-1] + b2*x[n-2] - a1*y[n-1] - a2*y[n-2]`.
public struct Biquad: Sendable, Equatable {

    public let b0: Double, b1: Double, b2: Double
    public let a1: Double, a2: Double

    private var z1: Double = 0
    private var z2: Double = 0

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2
        self.a1 = a1; self.a2 = a2
    }

    @discardableResult
    public mutating func process(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    public mutating func reset() {
        z1 = 0
        z2 = 0
    }

    // MARK: - Designers (RBJ audio-EQ cookbook forms)

    public static func lowpass(cutoff: Double, sampleRate: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * clampCutoff(cutoff, sampleRate) / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: ((1 - cosW0) / 2) / a0,
            b1: (1 - cosW0) / a0,
            b2: ((1 - cosW0) / 2) / a0,
            a1: (-2 * cosW0) / a0,
            a2: (1 - alpha) / a0
        )
    }

    public static func highpass(cutoff: Double, sampleRate: Double, q: Double) -> Biquad {
        let w0 = 2 * Double.pi * clampCutoff(cutoff, sampleRate) / sampleRate
        let cosW0 = cos(w0), sinW0 = sin(w0)
        let alpha = sinW0 / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: ((1 + cosW0) / 2) / a0,
            b1: (-(1 + cosW0)) / a0,
            b2: ((1 + cosW0) / 2) / a0,
            a1: (-2 * cosW0) / a0,
            a2: (1 - alpha) / a0
        )
    }

    /// Keeps the cutoff strictly inside `(0, Nyquist)` so the design never blows up on a
    /// misconfigured band.
    private static func clampCutoff(_ cutoff: Double, _ sampleRate: Double) -> Double {
        let nyquist = sampleRate / 2
        return min(max(cutoff, sampleRate * 1e-4), nyquist * 0.999)
    }
}

/// Butterworth band-pass: a cascade of `order/2` high-pass sections and `order/2`
/// low-pass sections, all sharing the classic Butterworth pole Q factors.
///
/// Two bands matter here:
/// * pulse:       0.7 – 4.0 Hz  (42 – 240 bpm)
/// * respiration: 0.1 – 0.6 Hz  (6 – 36 breaths/min)
public struct BandpassFilter: Sendable, Equatable {

    public let lowCutoff: Double
    public let highCutoff: Double
    public let sampleRate: Double

    private var sections: [Biquad]

    /// - Parameter order: filter order per stage; must be even and >= 2.
    ///   `order: 4` gives a 4th-order high-pass cascaded with a 4th-order low-pass.
    public init(lowCutoff: Double, highCutoff: Double, sampleRate: Double, order: Int = 4) {
        precondition(order >= 2 && order % 2 == 0, "order must be even and >= 2")
        precondition(lowCutoff > 0 && highCutoff > lowCutoff, "invalid band")
        self.lowCutoff = lowCutoff
        self.highCutoff = highCutoff
        self.sampleRate = sampleRate

        let qs = BandpassFilter.butterworthQFactors(order: order)
        var sections: [Biquad] = []
        sections.reserveCapacity(qs.count * 2)
        for q in qs {
            sections.append(.highpass(cutoff: lowCutoff, sampleRate: sampleRate, q: q))
        }
        for q in qs {
            sections.append(.lowpass(cutoff: highCutoff, sampleRate: sampleRate, q: q))
        }
        self.sections = sections
    }

    @discardableResult
    public mutating func process(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        var y = x
        for index in sections.indices {
            y = sections[index].process(y)
        }
        return y
    }

    public mutating func reset() {
        for index in sections.indices {
            sections[index].reset()
        }
    }

    /// Pole Q factors of a Butterworth filter of the given (even) order.
    ///
    /// `Q_k = 1 / (2 * cos((2k + 1) * pi / (2 * order)))`, k = 0 ..< order/2.
    static func butterworthQFactors(order: Int) -> [Double] {
        (0..<(order / 2)).map { k in
            1.0 / (2.0 * cos(Double(2 * k + 1) * Double.pi / Double(2 * order)))
        }
    }
}
