import XCTest
@testable import RPPGCore

final class EWMATests: XCTestCase {

    func testRecurrenceMatchesSpecification() {
        // y = lambda * y + (1 - lambda) * x, with y primed by the first sample.
        let lambda = 0.9
        var filter = EWMA(lambda: lambda)
        let inputs: [Double] = [10, 12, 8, 20, 5]

        var expected = inputs[0]
        XCTAssertEqual(filter.update(inputs[0]), expected, accuracy: 1e-12)

        for x in inputs.dropFirst() {
            expected = lambda * expected + (1 - lambda) * x
            XCTAssertEqual(filter.update(x), expected, accuracy: 1e-12)
        }
    }

    func testStatePersistsAcrossCalls() {
        var filter = EWMA(lambda: 0.5)
        filter.update(0)
        filter.update(1)
        XCTAssertEqual(filter.value, 0.5, accuracy: 1e-12)
        filter.update(1)
        XCTAssertEqual(filter.value, 0.75, accuracy: 1e-12)
    }

    func testTimeConstantDecaysToOneOverE() {
        let tau = 2.0, fs = 50.0
        var filter = EWMA(timeConstant: tau, sampleRate: fs)
        filter.update(1)                       // primes at 1
        for _ in 0..<Int(tau * fs) {
            filter.update(0)
        }
        XCTAssertEqual(filter.value, exp(-1), accuracy: 1e-3)
    }

    func testNonFiniteInputIsIgnored() {
        var filter = EWMA(lambda: 0.5)
        filter.update(4)
        filter.update(.nan)
        filter.update(.infinity)
        XCTAssertEqual(filter.value, 4, accuracy: 1e-12)
    }

    func testExponentialStatisticsApproximateSampleStatistics() {
        // A long stretch of a stationary sine: EW mean -> 0, EW sd -> amplitude/sqrt(2).
        var statistics = EWStatistics(timeConstant: 4, sampleRate: 100)
        for index in 0..<4000 {
            statistics.update(3 * sin(2 * Double.pi * 1.1 * Double(index) / 100))
        }
        XCTAssertEqual(statistics.mean, 0, accuracy: 0.15)
        XCTAssertEqual(statistics.standardDeviation, 3 / 2.0.squareRoot(), accuracy: 0.15)
    }

    func testHighPassRemovesConstantBaseline() {
        var highPass = EWMAHighPass(timeConstant: 0.5, sampleRate: 100)
        for _ in 0..<500 { highPass.process(7) }
        XCTAssertEqual(highPass.process(7), 0, accuracy: 1e-6)
        XCTAssertEqual(highPass.process(8), 1, accuracy: 0.05)
    }
}
