import Foundation

/// The 3×1 column vector `C` of the specification: the spatial mean of the ROI's red,
/// green and blue channels, on MATLAB's 0–255 scale (`mean(mean(faceimg))` on a uint8
/// image promotes to double).
public struct ChannelTriple: Sendable, Equatable {

    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let zero = ChannelTriple(red: 0, green: 0, blue: 0)

    /// Every channel finite and strictly positive — what the `C ./ Cmean` step needs.
    public var isUsable: Bool {
        red.isFinite && green.isFinite && blue.isFinite && red > 0 && green > 0 && blue > 0
    }

    public var asArray: [Double] { [red, green, blue] }

    // Element-wise arithmetic, matching MATLAB's `.*` / `./` semantics.

    public static func + (a: ChannelTriple, b: ChannelTriple) -> ChannelTriple {
        ChannelTriple(red: a.red + b.red, green: a.green + b.green, blue: a.blue + b.blue)
    }

    public static func * (scalar: Double, v: ChannelTriple) -> ChannelTriple {
        ChannelTriple(red: scalar * v.red, green: scalar * v.green, blue: scalar * v.blue)
    }

    /// Element-wise division, MATLAB's `C ./ Cmean`.
    public func dividedElementwise(by other: ChannelTriple) -> ChannelTriple {
        ChannelTriple(red: red / other.red, green: green / other.green, blue: blue / other.blue)
    }
}

/// The 2×1 vector `S` (and `Smean`, `Svar`, `Sstd`) of the specification.
public struct ProjectionPair: Sendable, Equatable {

    /// MATLAB's `S(1)`.
    public var first: Double
    /// MATLAB's `S(2)`.
    public var second: Double

    public init(first: Double, second: Double) {
        self.first = first
        self.second = second
    }

    public static let zero = ProjectionPair(first: 0, second: 0)

    public static func + (a: ProjectionPair, b: ProjectionPair) -> ProjectionPair {
        ProjectionPair(first: a.first + b.first, second: a.second + b.second)
    }

    public static func - (a: ProjectionPair, b: ProjectionPair) -> ProjectionPair {
        ProjectionPair(first: a.first - b.first, second: a.second - b.second)
    }

    public static func * (scalar: Double, v: ProjectionPair) -> ProjectionPair {
        ProjectionPair(first: scalar * v.first, second: scalar * v.second)
    }

    /// MATLAB's `v.^2`.
    public var squaredElementwise: ProjectionPair {
        ProjectionPair(first: first * first, second: second * second)
    }

    /// MATLAB's `sqrt(v)`.
    public var squareRootElementwise: ProjectionPair {
        ProjectionPair(first: first.squareRoot(), second: second.squareRoot())
    }
}
