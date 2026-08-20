import Foundation

/// Exponentially weighted moving average.
///
/// Implements exactly the recurrence given in the project specification:
///
///     y = lambda * y + (1 - lambda) * x
///
/// `y` is the persistent (static) state carried between calls, `x` is the input.
/// `lambda` close to 1 means a long memory (slow adaptation); `lambda` close to 0
/// means the filter follows the input almost immediately.
///
/// The first sample primes the state (`y = x`) instead of decaying from zero, which
/// removes the long start-up transient a zero-initialised EWMA would otherwise show.
public struct EWMA: Sendable, Equatable {

    /// Forgetting factor, in `[0, 1)`.
    public let lambda: Double

    /// Current output value `y`. This is the persistent state of the filter.
    public private(set) var value: Double

    /// `false` until the first sample has been consumed.
    public private(set) var isPrimed: Bool

    /// - Parameters:
    ///   - lambda: forgetting factor in `[0, 1)`.
    ///   - initialValue: value the state starts at when `primed` is `true`.
    ///   - primed: when `true` the filter starts from `initialValue` instead of
    ///     snapping to the first input sample.
    public init(lambda: Double, initialValue: Double = 0, primed: Bool = false) {
        precondition(lambda >= 0 && lambda < 1, "lambda must be in [0, 1)")
        self.lambda = lambda
        self.value = initialValue
        self.isPrimed = primed
    }

    /// Builds an EWMA whose impulse response decays by `1/e` after `timeConstant` seconds.
    ///
    /// `lambda = exp(-1 / (tau * fs))`
    ///
    /// - Parameters:
    ///   - timeConstant: tau, in seconds. Must be > 0.
    ///   - sampleRate: fs, in Hz. Must be > 0.
    public init(timeConstant tau: Double, sampleRate fs: Double) {
        precondition(tau > 0 && fs > 0, "time constant and sample rate must be positive")
        self.init(lambda: exp(-1.0 / (tau * fs)))
    }

    /// Feeds one sample and returns the updated output.
    ///
    /// Non-finite inputs (NaN / infinity, e.g. from an empty ROI) are ignored so a
    /// single bad frame cannot poison the persistent state.
    @discardableResult
    public mutating func update(_ x: Double) -> Double {
        guard x.isFinite else { return value }
        if isPrimed {
            value = lambda * value + (1 - lambda) * x
        } else {
            value = x
            isPrimed = true
        }
        return value
    }

    /// Clears the persistent state.
    public mutating func reset(to newValue: Double = 0, primed: Bool = false) {
        value = newValue
        isPrimed = primed
    }
}

/// Exponentially weighted mean and variance, sharing a single `lambda`.
///
/// Variance is tracked as `E[x^2] - E[x]^2`, both terms being plain ``EWMA`` states,
/// which keeps the update O(1) and allocation free. The POS alpha-tuning step needs a
/// running standard deviation of two projected signals, and this is what provides it.
public struct EWStatistics: Sendable, Equatable {

    private var meanFilter: EWMA
    private var squareFilter: EWMA

    public init(lambda: Double) {
        meanFilter = EWMA(lambda: lambda)
        squareFilter = EWMA(lambda: lambda)
    }

    public init(timeConstant tau: Double, sampleRate fs: Double) {
        self.init(lambda: exp(-1.0 / (tau * fs)))
    }

    public var mean: Double { meanFilter.value }

    /// Clamped at zero: the `E[x^2] - E[x]^2` form can go slightly negative from
    /// floating point cancellation when the signal is nearly constant.
    public var variance: Double { max(0, squareFilter.value - meanFilter.value * meanFilter.value) }

    public var standardDeviation: Double { variance.squareRoot() }

    public var isPrimed: Bool { meanFilter.isPrimed }

    public mutating func update(_ x: Double) {
        guard x.isFinite else { return }
        meanFilter.update(x)
        squareFilter.update(x * x)
    }

    public mutating func reset() {
        meanFilter.reset()
        squareFilter.reset()
    }
}

/// First-order high-pass built from an EWMA: `out = x - ewma(x)`.
///
/// Used to strip the slowly drifting baseline (illumination changes, subject drift)
/// from the raw POS output and from the respiration trace.
public struct EWMAHighPass: Sendable, Equatable {

    private var baseline: EWMA

    public init(lambda: Double) {
        baseline = EWMA(lambda: lambda)
    }

    public init(timeConstant tau: Double, sampleRate fs: Double) {
        baseline = EWMA(timeConstant: tau, sampleRate: fs)
    }

    /// The current baseline estimate.
    public var baselineValue: Double { baseline.value }

    @discardableResult
    public mutating func process(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        return x - baseline.update(x)
    }

    public mutating func reset() {
        baseline.reset()
    }
}
