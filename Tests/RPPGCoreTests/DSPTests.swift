import XCTest
@testable import RPPGCore

final class DSPTests: XCTestCase {

    func testRingBufferKeepsNewestSamplesInOrder() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1)
        buffer.append(2)
        XCTAssertEqual(buffer.elements, [1, 2])
        XCTAssertFalse(buffer.isFull)

        buffer.append(3)
        XCTAssertTrue(buffer.isFull)
        XCTAssertEqual(buffer.elements, [1, 2, 3])

        buffer.append(4)
        buffer.append(5)
        XCTAssertEqual(buffer.elements, [3, 4, 5])
        XCTAssertEqual(buffer.oldest, 3)
        XCTAssertEqual(buffer.newest, 5)
        XCTAssertEqual(buffer[0], 3)
        XCTAssertEqual(buffer[2], 5)
    }

    func testButterworthQFactors() {
        // Second order Butterworth has the single pole Q = 1/sqrt(2).
        let second = BandpassFilter.butterworthQFactors(order: 2)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(second[0], 1 / 2.0.squareRoot(), accuracy: 1e-12)

        // Fourth order has Q = 0.5412 and 1.3066.
        let fourth = BandpassFilter.butterworthQFactors(order: 4)
        XCTAssertEqual(fourth.count, 2)
        XCTAssertEqual(fourth[0], 0.54120, accuracy: 1e-4)
        XCTAssertEqual(fourth[1], 1.30656, accuracy: 1e-4)
    }

    func testBandpassPassesInBandAndRejectsOutOfBand() {
        let fs = 60.0
        func steadyStateAmplitude(of frequency: Double) -> Double {
            var filter = BandpassFilter(lowCutoff: 0.7, highCutoff: 4.0, sampleRate: fs, order: 4)
            var peak = 0.0
            let total = Int(fs * 30)
            for index in 0..<total {
                let y = filter.process(sin(2 * Double.pi * frequency * Double(index) / fs))
                // Ignore the first 20 s so only the steady state is measured.
                if index > Int(fs * 20) { peak = max(peak, abs(y)) }
            }
            return peak
        }

        XCTAssertEqual(steadyStateAmplitude(of: 1.2), 1.0, accuracy: 0.05)   // 72 bpm
        XCTAssertLessThan(steadyStateAmplitude(of: 0.1), 0.05)               // baseline drift
        XCTAssertLessThan(steadyStateAmplitude(of: 15.0), 0.05)              // high frequency noise
    }

    func testFFTFindsAKnownTone() {
        let n = 1024
        let fs = 128.0
        let tone = 8.0
        let signal = (0..<n).map { sin(2 * Double.pi * tone * Double($0) / fs) }
        let power = FFT.powerSpectrum(of: signal, paddedLength: n)
        let peakBin = power.indices.max(by: { power[$0] < power[$1] })!
        XCTAssertEqual(Double(peakBin) * fs / Double(n), tone, accuracy: 0.2)
    }

    func testNextPowerOfTwo() {
        XCTAssertEqual(FFT.nextPowerOfTwo(1), 1)
        XCTAssertEqual(FFT.nextPowerOfTwo(2), 2)
        XCTAssertEqual(FFT.nextPowerOfTwo(3), 4)
        XCTAssertEqual(FFT.nextPowerOfTwo(1024), 1024)
        XCTAssertEqual(FFT.nextPowerOfTwo(1025), 2048)
    }

    func testLinearDetrendRemovesARamp() {
        let signal = (0..<100).map { 5.0 + 0.3 * Double($0) }
        let detrended = SpectralRateEstimator.linearDetrend(signal)
        for value in detrended {
            XCTAssertEqual(value, 0, accuracy: 1e-9)
        }
    }

    func testSpectralEstimatorRecoversRateAndScoresSNR() {
        let fs = 30.0
        let frequency = 1.25   // 75 bpm
        let clean = (0..<Int(fs * 12)).map { sin(2 * Double.pi * frequency * Double($0) / fs) }
        let estimate = SpectralRateEstimator.estimate(signal: clean, sampleRate: fs, band: 0.7...4.0)
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate!.ratePerMinute, 75, accuracy: 1.0)
        XCTAssertGreaterThan(estimate!.signalToNoiseDB, 10)
        XCTAssertGreaterThan(estimate!.confidence, 0.9)
    }

    func testSpectralEstimatorRefusesTooShortAndFlatInput() {
        XCTAssertNil(SpectralRateEstimator.estimate(signal: [1, 2, 3], sampleRate: 30, band: 0.7...4.0))
        let flat = [Double](repeating: 1, count: 300)
        XCTAssertNil(SpectralRateEstimator.estimate(signal: flat, sampleRate: 30, band: 0.7...4.0))
    }
}
