import Foundation

/// One spatially averaged RGB measurement of the skin ROI, produced once per camera
/// frame. Channel values are in `0 ... 255`.
public struct RGBSample: Sendable, Equatable {

    public var red: Double
    public var green: Double
    public var blue: Double

    /// Presentation timestamp of the source frame, in seconds.
    public var timestamp: TimeInterval

    /// How many pixels were averaged. A collapsing count means the ROI is drifting off
    /// the frame or the face was lost.
    public var pixelCount: Int

    /// Fraction of averaged pixels with a channel at or near full scale. High values
    /// mean the ROI is blown out and the pulse is being clipped away.
    public var clippedFraction: Double

    public init(
        red: Double,
        green: Double,
        blue: Double,
        timestamp: TimeInterval,
        pixelCount: Int = 0,
        clippedFraction: Double = 0
    ) {
        self.red = red
        self.green = green
        self.blue = blue
        self.timestamp = timestamp
        self.pixelCount = pixelCount
        self.clippedFraction = clippedFraction
    }

    /// `true` when every channel is finite and strictly positive, which is what the
    /// POS temporal normalisation requires.
    public var isUsable: Bool {
        red.isFinite && green.isFinite && blue.isFinite
            && red > 0 && green > 0 && blue > 0
            && pixelCount > 0
    }
}
