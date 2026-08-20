import Foundation

/// Minimal in-place radix-2 complex FFT.
///
/// Deliberately dependency free (no Accelerate) so the whole signal core stays
/// portable and unit-testable off-device. The transform sizes used here are small
/// (a few thousand points, a handful of times per second), so this is not a hot path.
public enum FFT {

    /// In-place forward DFT. `real` and `imag` must have the same, power-of-two length.
    public static func forward(real: inout [Double], imaginary: inout [Double]) {
        let n = real.count
        precondition(n == imaginary.count, "real and imaginary must match in length")
        guard n > 1 else { return }
        precondition(n & (n - 1) == 0, "length must be a power of two")

        // Bit-reversal permutation.
        var j = 0
        for i in 0..<(n - 1) {
            if i < j {
                real.swapAt(i, j)
                imaginary.swapAt(i, j)
            }
            var k = n >> 1
            while k <= j {
                j -= k
                k >>= 1
            }
            j += k
        }

        // Butterflies.
        var span = 1
        while span < n {
            let step = span << 1
            let theta = -Double.pi / Double(span)
            for m in 0..<span {
                let angle = theta * Double(m)
                let wr = cos(angle), wi = sin(angle)
                var i = m
                while i < n {
                    let k = i + span
                    let tr = wr * real[k] - wi * imaginary[k]
                    let ti = wr * imaginary[k] + wi * real[k]
                    real[k] = real[i] - tr
                    imaginary[k] = imaginary[i] - ti
                    real[i] += tr
                    imaginary[i] += ti
                    i += step
                }
            }
            span = step
        }
    }

    /// Power spectrum of a real signal, returned for bins `0 ... n/2`.
    ///
    /// - Parameters:
    ///   - signal: real input, zero-padded internally to `paddedLength`.
    ///   - paddedLength: power-of-two transform length; must be >= `signal.count`.
    public static func powerSpectrum(of signal: [Double], paddedLength: Int) -> [Double] {
        precondition(paddedLength >= signal.count, "padded length too small")
        precondition(paddedLength & (paddedLength - 1) == 0, "padded length must be a power of two")

        var real = signal
        real.append(contentsOf: repeatElement(0, count: paddedLength - signal.count))
        var imaginary = [Double](repeating: 0, count: paddedLength)
        forward(real: &real, imaginary: &imaginary)

        let half = paddedLength / 2
        var power = [Double](repeating: 0, count: half + 1)
        for i in 0...half {
            power[i] = real[i] * real[i] + imaginary[i] * imaginary[i]
        }
        return power
    }

    /// Smallest power of two that is >= `value`.
    public static func nextPowerOfTwo(_ value: Int) -> Int {
        guard value > 1 else { return 1 }
        return 1 << (Int.bitWidth - (value - 1).leadingZeroBitCount)
    }
}
