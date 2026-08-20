import Foundation
@testable import RPPGCore

/// Generates synthetic ROI measurements for a "skin patch" so the pipelines can be
/// exercised without a camera.
///
/// The model is the one POS is derived from:
///
///     C(t) = I(t) * ( dc + amplitude * p(t) * pulseDirection )
///
/// `I(t)` is a channel-common intensity term (illumination drift, motion) that POS is
/// supposed to cancel, and `pulseDirection` is the normalised blood-volume-pulse
/// signature in RGB.
enum SyntheticSignal {

    /// Typical camera response to skin under white light, 0–255.
    static let skinDC = (red: 180.0, green: 140.0, blue: 130.0)

    /// Normalised blood-volume-pulse direction (de Haan & van Leest, 2014).
    static let pulseDirection = (red: 0.33, green: 0.77, blue: 0.53)

    /// - Parameters:
    ///   - duration: seconds of signal.
    ///   - sampleRate: frame rate, Hz.
    ///   - pulseHz: pulse frequency to embed.
    ///   - pulseAmplitude: pulsatile amplitude as a fraction of DC (0.01 = 1%, which
    ///     is roughly what a face gives at normal room light).
    ///   - intensityHz: frequency of the channel-common intensity disturbance.
    ///   - intensityAmplitude: amplitude of that disturbance as a fraction of DC. Made
    ///     deliberately much larger than the pulse to prove POS cancels it.
    ///   - noiseAmplitude: deterministic pseudo-random per-channel sensor noise.
    static func makeSamples(
        duration: Double,
        sampleRate: Double,
        pulseHz: Double,
        pulseAmplitude: Double = 0.01,
        intensityHz: Double = 0.2,
        intensityAmplitude: Double = 0.10,
        noiseAmplitude: Double = 0.0
    ) -> [RGBSample] {
        let count = Int(duration * sampleRate)
        var generator = DeterministicNoise(seed: 0x5EED)
        var samples: [RGBSample] = []
        samples.reserveCapacity(count)

        for index in 0..<count {
            let t = Double(index) / sampleRate
            let intensity = 1 + intensityAmplitude * sin(2 * Double.pi * intensityHz * t)
            let pulse = sin(2 * Double.pi * pulseHz * t)

            func channel(_ dc: Double, _ direction: Double) -> Double {
                let noise = noiseAmplitude > 0 ? noiseAmplitude * generator.next() : 0
                return intensity * (dc + dc * pulseAmplitude * pulse * direction + dc * noise)
            }

            samples.append(
                RGBSample(
                    red: channel(skinDC.red, pulseDirection.red),
                    green: channel(skinDC.green, pulseDirection.green),
                    blue: channel(skinDC.blue, pulseDirection.blue),
                    timestamp: t,
                    pixelCount: 4000,
                    clippedFraction: 0
                )
            )
        }
        return samples
    }
}

/// Tiny xorshift so tests stay reproducible across platforms.
struct DeterministicNoise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 1 : seed
    }

    /// Uniform in `-1 ... 1`.
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 20001) / 10000.0 - 1.0
    }
}
