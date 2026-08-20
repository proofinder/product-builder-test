import Foundation

/// Exponentially weighted moving average.
///
/// Implements exactly the recurrence in the specification and in `rPPG_test.m`:
///
///     y = lambda * y + (1 - lambda) * x
///
/// `y` is the persistent state carried between calls, `x` is the input.
///
/// The MATLAB reference primes the state with the first sample rather than decaying
/// from zero:
///
///     if isempty(Cmean); Cmean = C; else; Cmean = lambda1*Cmean + (1-lambda1)*C; end
///
/// so ``update(_:)`` does the same. `(1 - lambda)` is computed here, not written as a
/// literal, because `1 - 0.99` is `0.010000000000000009` in double precision and the
/// reference performs that subtraction too — writing `0.01` would put the two
/// implementations a few ulps apart on every single sample.
public struct EWMA: Sendable, Equatable {

    /// Forgetting factor, in `[0, 1)`.
    public let lambda: Double

    /// Current output value `y` — the persistent state.
    public private(set) var value: Double

    /// `false` until the first sample has been consumed (MATLAB's `isempty`).
    public private(set) var isPrimed: Bool

    public init(lambda: Double) {
        precondition(lambda >= 0 && lambda < 1, "lambda must be in [0, 1)")
        self.lambda = lambda
        self.value = 0
        self.isPrimed = false
    }

    /// Builds an EWMA whose impulse response decays by `1/e` after `timeConstant`
    /// seconds: `lambda = exp(-1 / (tau * fs))`.
    ///
    /// Not used by the POS chain — the reference fixes `lambda1 = 0.99` and
    /// `lambda2 = 0.9` as constants independent of frame rate — but useful for the
    /// auxiliary filters (ROI smoothing, frame-rate estimation).
    public init(timeConstant tau: Double, sampleRate fs: Double) {
        precondition(tau > 0 && fs > 0, "time constant and sample rate must be positive")
        self.init(lambda: exp(-1.0 / (tau * fs)))
    }

    /// Feeds one sample and returns the updated output.
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

    public mutating func reset() {
        value = 0
        isPrimed = false
    }

    /// The time constant, in samples, implied by `lambda`. Reported in diagnostics so
    /// the effective memory of the filter is visible at whatever frame rate is running:
    /// `lambda1 = 0.99` is ~100 samples, i.e. 3.3 s at 30 fps but only 1.7 s at 60 fps.
    public var timeConstantInSamples: Double {
        lambda <= 0 ? 0 : -1.0 / log(lambda)
    }
}
