import XCTest
@testable import RPPGCore

/// The POS-facing recurrence checks live in `POSTests`; this covers the auxiliary
/// constructor and the robustness behaviour the capture path depends on.
final class EWMATests: XCTestCase {

    func testStatePersistsAcrossCalls() {
        var filter = EWMA(lambda: 0.5)
        filter.update(0)
        filter.update(1)
        XCTAssertEqual(filter.value, 0.5, accuracy: 1e-15)
        filter.update(1)
        XCTAssertEqual(filter.value, 0.75, accuracy: 1e-15)
    }

    func testTimeConstantConstructorDecaysToOneOverE() {
        // Used for the ROI smoother and the frame-rate estimate, not for POS.
        let tau = 2.0, fs = 50.0
        var filter = EWMA(timeConstant: tau, sampleRate: fs)
        filter.update(1)
        for _ in 0..<Int(tau * fs) {
            filter.update(0)
        }
        XCTAssertEqual(filter.value, exp(-1), accuracy: 1e-3)
    }

    func testNonFiniteInputIsIgnored() {
        // One bad frame — an empty ROI producing NaN — must not poison the persistent
        // state for every frame that follows.
        var filter = EWMA(lambda: 0.5)
        filter.update(4)
        filter.update(.nan)
        filter.update(.infinity)
        XCTAssertEqual(filter.value, 4, accuracy: 0)
        XCTAssertTrue(filter.isPrimed)
    }

    func testResetClearsPriming() {
        var filter = EWMA(lambda: 0.9)
        filter.update(42)
        XCTAssertTrue(filter.isPrimed)
        filter.reset()
        XCTAssertFalse(filter.isPrimed)
        XCTAssertEqual(filter.value, 0, accuracy: 0)
        // The next sample primes again rather than decaying from zero.
        XCTAssertEqual(filter.update(7), 7, accuracy: 0)
    }
}
