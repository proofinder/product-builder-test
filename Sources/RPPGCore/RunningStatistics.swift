import Foundation

/// Running mean and standard deviation (Welford), for the stage pass criteria.
///
/// Deliberately not exponentially weighted: the criteria are about a whole 60-second
/// run — "frame interval jitter std < 2 ms", "corner jitter std < 0.5% of face width"
/// — not about the last second of it.
public struct RunningStatistics: Sendable, Equatable {

    public private(set) var count = 0
    public private(set) var mean: Double = 0
    private var m2: Double = 0
    public private(set) var minimum: Double = .infinity
    public private(set) var maximum: Double = -.infinity

    public init() {}

    public mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        count += 1
        let delta = value - mean
        mean += delta / Double(count)
        m2 += delta * (value - mean)
        minimum = Swift.min(minimum, value)
        maximum = Swift.max(maximum, value)
    }

    /// Sample variance (`n - 1` denominator).
    public var variance: Double { count > 1 ? m2 / Double(count - 1) : 0 }

    public var standardDeviation: Double { variance.squareRoot() }

    public var range: Double { count > 0 ? maximum - minimum : 0 }

    public mutating func reset() {
        count = 0
        mean = 0
        m2 = 0
        minimum = .infinity
        maximum = -.infinity
    }
}
