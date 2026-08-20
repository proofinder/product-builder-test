import XCTest
@testable import RPPGCore

/// Stage 4 + Stage 5 verification.
///
/// The recurrences are pinned against hand-computed values, then the whole chain is
/// checked against `Fixtures/golden_pos.csv`, which `tools/gen_golden.py` produced and
/// `matlab/pos_reference.m` reproduces from the same input.
final class POSTests: XCTestCase {

    // MARK: - Stage 4: the EWMA recurrences

    func testEWMARecurrenceMatchesSpecification() {
        let lambda = 0.99
        var filter = EWMA(lambda: lambda)
        let inputs: [Double] = [10, 12, 8, 20, 5]

        // First sample primes the state, as MATLAB's `if isempty(...)` branch does.
        var expected = inputs[0]
        XCTAssertEqual(filter.update(inputs[0]), expected, accuracy: 0)

        for x in inputs.dropFirst() {
            expected = lambda * expected + (1 - lambda) * x
            // Exact: the Swift and reference expressions are the same operations in
            // the same order, so there is no rounding to tolerate.
            XCTAssertEqual(filter.update(x), expected, accuracy: 0)
        }
    }

    func testOneMinusLambdaIsComputedNotLiteral() {
        // 1 - 0.99 is 0.010000000000000009, not 0.01. Writing the literal would put
        // every EWMA update a few ulps away from the reference.
        XCTAssertNotEqual(1 - 0.99, 0.01)

        var filter = EWMA(lambda: 0.99)
        filter.update(0)
        let withComputed = 0.99 * 0.0 + (1 - 0.99) * 1.0
        XCTAssertEqual(filter.update(1), withComputed, accuracy: 0)
    }

    func testTimeConstantInSamplesReportsTheEffectiveMemory() {
        XCTAssertEqual(EWMA(lambda: 0.99).timeConstantInSamples, 99.5, accuracy: 0.5)
        XCTAssertEqual(EWMA(lambda: 0.9).timeConstantInSamples, 9.5, accuracy: 0.5)
    }

    // MARK: - Stage 5: POS structure

    func testFirstStepIsExactlyZeroAndDoesNotDivergeOnZeroSigma() {
        // C == Cmean on the first step, so C./Cmean is [1;1;1] and both projection
        // rows are exactly zero. Sstd is zero too, and the guard makes h = 0/1e-9 = 0
        // rather than a division blow-up.
        var processor = POSProcessor()
        let step = processor.process(ChannelTriple(red: 180, green: 140, blue: 130))
        XCTAssertNotNil(step)
        XCTAssertEqual(step!.cNormalized.red, 1, accuracy: 0)
        XCTAssertEqual(step!.s.first, 0, accuracy: 0)
        XCTAssertEqual(step!.s.second, 0, accuracy: 0)
        XCTAssertEqual(step!.sStd.first, 0, accuracy: 0)
        XCTAssertEqual(step!.h, 0, accuracy: 0)
        XCTAssertEqual(step!.hMean, 0, accuracy: 0)
        XCTAssertEqual(step!.rppg, 0, accuracy: 0)
    }

    func testProjectionMatchesTheSpecifiedMatrix() {
        // S = [0 1 -1; -2 1 1] * Cn
        var processor = POSProcessor()
        processor.process(ChannelTriple(red: 100, green: 100, blue: 100))   // primes Cmean
        let step = processor.process(ChannelTriple(red: 110, green: 90, blue: 120))!

        let cn = step.cNormalized
        XCTAssertEqual(step.s.first, cn.green - cn.blue, accuracy: 0)
        XCTAssertEqual(step.s.second, (-2 * cn.red + cn.green) + cn.blue, accuracy: 0)
    }

    func testHUsesTheReferenceAsymmetricForm() {
        // h = S(1)/(Sstd(1)+eps) + 1/(Sstd(2)+eps)*S(2)
        // — a division for the first term, a reciprocal-then-multiply for the second.
        var processor = POSProcessor()
        let inputs = [
            ChannelTriple(red: 180, green: 140, blue: 130),
            ChannelTriple(red: 181, green: 141, blue: 129),
            ChannelTriple(red: 179, green: 142, blue: 131),
            ChannelTriple(red: 182, green: 139, blue: 132)
        ]
        var last: POSProcessor.Step?
        for input in inputs { last = processor.process(input) }
        let step = last!

        let epsilon = 1.0e-09
        let expected = step.s.first / (step.sStd.first + epsilon)
            + (1 / (step.sStd.second + epsilon)) * step.s.second
        XCTAssertEqual(step.h, expected, accuracy: 0)
    }

    func testVarianceUsesDeviationFromTheCurrentMean() {
        // Svar = lambda1*Svar + (1-lambda1)*(S-Smean).^2, not E[S^2] - E[S]^2.
        var processor = POSProcessor()
        let inputs = [
            ChannelTriple(red: 180, green: 140, blue: 130),
            ChannelTriple(red: 181, green: 141, blue: 129)
        ]
        var steps: [POSProcessor.Step] = []
        for input in inputs { steps.append(processor.process(input)!) }

        // Second step: Svar was primed to 0 on step 1, so it is (1-l1)*(S-Smean)^2.
        let second = steps[1]
        let deviation = second.s.first - second.sMean.first
        XCTAssertEqual(second.sVar.first, 0.99 * 0 + (1 - 0.99) * (deviation * deviation), accuracy: 0)
    }

    func testRPPGIsARunningSumOfHMinusHMean() {
        let samples = (0..<50).map { index -> ChannelTriple in
            let t = Double(index) / 30.0
            let pulse = sin(2 * .pi * 1.2 * t)
            return ChannelTriple(
                red: 180 * (1 + 0.01 * pulse * 0.33),
                green: 140 * (1 + 0.01 * pulse * 0.77),
                blue: 130 * (1 + 0.01 * pulse * 0.53)
            )
        }
        let steps = POSProcessor.run(samples)
        XCTAssertEqual(steps.count, samples.count)

        var running = 0.0
        for step in steps {
            running += step.h - step.hMean
            XCTAssertEqual(step.rppg, running, accuracy: 0)
        }
    }

    func testUnusableSampleLeavesStateUntouched() {
        var processor = POSProcessor()
        let good = ChannelTriple(red: 180, green: 140, blue: 130)
        processor.process(good)
        processor.process(ChannelTriple(red: 181, green: 141, blue: 129))
        let before = processor.currentRPPG
        let countBefore = processor.processedStepCount

        // Face lost: an all-zero ROI mean.
        XCTAssertNil(processor.process(.zero))
        XCTAssertNil(processor.process(ChannelTriple(red: 180, green: .nan, blue: 130)))

        XCTAssertEqual(processor.currentRPPG, before, accuracy: 0)
        XCTAssertEqual(processor.processedStepCount, countBefore)
    }

    func testResetReturnsToThePreFirstSampleState() {
        var processor = POSProcessor()
        for index in 0..<20 {
            processor.process(ChannelTriple(red: 180 + Double(index), green: 140, blue: 130))
        }
        processor.reset()
        XCTAssertEqual(processor.processedStepCount, 0)
        XCTAssertEqual(processor.currentRPPG, 0, accuracy: 0)

        // After reset the first step must again be the exactly-zero one.
        let step = processor.process(ChannelTriple(red: 200, green: 150, blue: 140))!
        XCTAssertEqual(step.h, 0, accuracy: 0)
        XCTAssertEqual(step.rppg, 0, accuracy: 0)
    }

    // MARK: - Stage 5 gate: the golden cross-check

    func testMatchesGoldenReferenceColumnByColumn() throws {
        let samples = try Fixtures.syntheticChannelTriples()
        let steps = POSProcessor.run(samples)
        XCTAssertEqual(steps.count, samples.count)

        let golden = try Fixtures.goldenText()

        // Checked in algorithm order, so the first failure names the earliest stage
        // that diverged.
        let columns: [(String, (POSProcessor.Step) -> Double)] = [
            ("cMeanR", { $0.cMean.red }), ("cMeanG", { $0.cMean.green }), ("cMeanB", { $0.cMean.blue }),
            ("cNormR", { $0.cNormalized.red }), ("cNormG", { $0.cNormalized.green }),
            ("cNormB", { $0.cNormalized.blue }),
            ("s1", { $0.s.first }), ("s2", { $0.s.second }),
            ("sMean1", { $0.sMean.first }), ("sMean2", { $0.sMean.second }),
            ("sVar1", { $0.sVar.first }), ("sVar2", { $0.sVar.second }),
            ("sStd1", { $0.sStd.first }), ("sStd2", { $0.sStd.second }),
            ("h", { $0.h }), ("hMean", { $0.hMean }), ("rppg", { $0.rppg })
        ]

        for (name, extract) in columns {
            let reference = try SignalCSV.parseColumn(name, from: golden)
            XCTAssertEqual(reference.count, steps.count, "row count mismatch for \(name)")

            var worst = 0.0
            for index in steps.indices {
                let mine = extract(steps[index])
                let theirs = reference[index]
                let scale = Swift.max(abs(mine), abs(theirs), 1e-12)
                worst = Swift.max(worst, abs(mine - theirs) / scale)
            }
            // The two implementations perform identical operations in identical order,
            // so the only slack is the 17-digit CSV round-trip.
            XCTAssertLessThan(worst, 1e-14, "column \(name) diverged (max relative diff \(worst))")
        }
    }

    func testGoldenRPPGRecoversTheEmbeddedHeartRate() throws {
        // The fixture carries a 72 bpm pulse at 1% of DC under channel-common
        // disturbances of 3% (breathing) and 5% (drift) — POS has to reject those.
        let samples = try Fixtures.syntheticChannelTriples()
        var pipeline = PulsePipeline(
            configuration: .init(sampleRate: 30, bufferSeconds: 40, minimumSecondsForEstimate: 10)
        )
        for sample in samples {
            pipeline.process(ROISample(channels: sample, timestamp: 0, pixelCount: 4000))
        }

        let estimate = pipeline.heartRate()
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate!.ratePerMinute, 72, accuracy: 1.0)
        XCTAssertGreaterThan(estimate!.signalToNoiseDB, 0)
    }

    func testHStaysBoundedThroughTheWholeFixture() throws {
        // Sstd grows in proportion to |S|, so h stays near 1/sqrt(1-lambda1) rather
        // than exploding through the 1e-9 guard. This pins that empirically.
        let samples = try Fixtures.syntheticChannelTriples()
        let steps = POSProcessor.run(samples)
        let peak = steps.reduce(0.0) { Swift.max($0, abs($1.h)) }
        XCTAssertLessThan(peak, 100, "h peaked at \(peak)")
    }

    // MARK: - Stage 0 gate: recording round-trips through replay

    func testRecordingRoundTripsThroughCSV() throws {
        let samples = try Fixtures.syntheticChannelTriples()
        let steps = POSProcessor.run(samples)

        let records = steps.map { step in
            SignalRecord(
                frameCount: step.index,
                t: Double(step.index) / 30,
                dtMs: 1000.0 / 30,
                corners: [
                    Point2D(x: 100, y: 200), Point2D(x: 300, y: 200),
                    Point2D(x: 300, y: 460), Point2D(x: 100, y: 460)
                ],
                roll: 0.1,
                meanCornerY: 330,
                roiPixelCount: 4000,
                trackSource: "detection",
                faceTracked: true,
                pos: step
            )
        }
        let csv = ([SignalCSV.headerLine] + records.map(SignalCSV.line(for:)))
            .joined(separator: "\n")

        // Re-running POS on the parsed C column must reproduce rppg exactly. If the
        // CSV lost precision this is where it shows.
        let parsed = try SignalCSV.parseChannelTriples(csv)
        XCTAssertEqual(parsed.count, steps.count)
        let replayed = POSProcessor.run(parsed)
        for index in steps.indices {
            XCTAssertEqual(replayed[index].rppg, steps[index].rppg, accuracy: 0,
                           "replay diverged at step \(index)")
        }

        let recordedRPPG = try SignalCSV.parseColumn("rppg", from: csv)
        XCTAssertEqual(recordedRPPG.count, steps.count)
        for index in steps.indices {
            XCTAssertEqual(recordedRPPG[index], steps[index].rppg, accuracy: 0)
        }
    }
}

/// Loads the fixtures shipped as a test-target resource.
enum Fixtures {

    enum Error: Swift.Error, CustomStringConvertible {
        case missing(String)
        var description: String { "fixture not found: \(self)" }
    }

    static func url(_ name: String) throws -> URL {
        if let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) {
            return url
        }
        if let url = Bundle.module.url(forResource: name, withExtension: nil) {
            return url
        }
        throw Error.missing(name)
    }

    static func text(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }

    static func syntheticChannelTriples() throws -> [ChannelTriple] {
        try SignalCSV.parseChannelTriples(text("synthetic_C.csv"))
    }

    static func goldenText() throws -> String {
        try text("golden_pos.csv")
    }
}
