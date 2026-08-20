import XCTest
@testable import RPPGCore

final class POSTests: XCTestCase {

    func testProjectionRowsMatchTheSpecifiedMatrix() {
        let projected = POSProjection.project(red: 1.1, green: 0.9, blue: 1.3)
        XCTAssertEqual(projected.s1, 0.9 - 1.3, accuracy: 1e-12)
        XCTAssertEqual(projected.s2, -2 * 1.1 + 0.9 + 1.3, accuracy: 1e-12)
    }

    func testStreamingPOSSuppressesWarmupThenEmits() {
        let fs = 30.0
        var pos = StreamingPOS(
            configuration: .init(sampleRate: fs, warmupSeconds: 1.6)
        )
        let samples = SyntheticSignal.makeSamples(duration: 5, sampleRate: fs, pulseHz: 1.2)
        let warmupCount = Int(1.6 * fs)

        var emitted = 0
        for (index, sample) in samples.enumerated() {
            let output = pos.process(sample)
            if index < warmupCount - 1 {
                XCTAssertNil(output, "output must be suppressed during warm-up")
            }
            if output != nil { emitted += 1 }
        }
        XCTAssertEqual(emitted, samples.count - warmupCount + 1)
    }

    func testStreamingPOSIgnoresUnusableSamples() {
        var pos = StreamingPOS(configuration: .init(sampleRate: 30, warmupSeconds: 0))
        let good = RGBSample(red: 180, green: 140, blue: 130, timestamp: 0, pixelCount: 100)
        XCTAssertNotNil(pos.process(good))

        // Face lost: no pixels in the ROI.
        let empty = RGBSample(red: 0, green: 0, blue: 0, timestamp: 0, pixelCount: 0)
        XCTAssertNil(pos.process(empty))
        // The persistent normalisation state must be untouched by the bad sample.
        XCTAssertNotNil(pos.process(good))
    }

    func testStreamingPOSRecoversTheHeartRate() {
        for (pulseHz, expectedBPM) in [(0.9, 54.0), (1.2, 72.0), (1.7, 102.0)] {
            let fs = 30.0
            var pipeline = PulsePipeline(configuration: .init(sampleRate: fs, bufferSeconds: 15))
            let samples = SyntheticSignal.makeSamples(
                duration: 25,
                sampleRate: fs,
                pulseHz: pulseHz,
                pulseAmplitude: 0.01,
                intensityAmplitude: 0.10,   // 10x the pulse, and POS must reject it
                noiseAmplitude: 0.0005
            )
            for sample in samples { pipeline.process(sample) }

            let estimate = pipeline.heartRate()
            XCTAssertNotNil(estimate, "no estimate at \(expectedBPM) bpm")
            XCTAssertEqual(estimate!.ratePerMinute, expectedBPM, accuracy: 3.0)
            XCTAssertGreaterThan(estimate!.signalToNoiseDB, 0)
        }
    }

    func testStreamingPOSTracksTheWindowedReference() {
        let fs = 30.0
        let samples = SyntheticSignal.makeSamples(
            duration: 30, sampleRate: fs, pulseHz: 1.4, noiseAmplitude: 0.0005
        )

        var streaming = StreamingPOS(configuration: .init(sampleRate: fs, warmupSeconds: 0))
        let streamingOutput = samples.compactMap { streaming.process($0) }
        let windowedOutput = WindowedPOS.process(samples: samples, sampleRate: fs)

        // Compare only the settled part, and only the frequency both agree on: the two
        // formulations use different (exponential vs rectangular) analysis windows, so
        // their sample-by-sample amplitudes differ while the recovered rate must not.
        let settled = Int(fs * 5)
        let streamingRate = SpectralRateEstimator.estimate(
            signal: Array(streamingOutput[settled...]), sampleRate: fs, band: 0.7...4.0
        )
        let windowedRate = SpectralRateEstimator.estimate(
            signal: Array(windowedOutput[settled...]), sampleRate: fs, band: 0.7...4.0
        )
        XCTAssertNotNil(streamingRate)
        XCTAssertNotNil(windowedRate)
        XCTAssertEqual(streamingRate!.ratePerMinute, 1.4 * 60, accuracy: 2.0)
        XCTAssertEqual(windowedRate!.ratePerMinute, 1.4 * 60, accuracy: 2.0)
        XCTAssertEqual(streamingRate!.ratePerMinute, windowedRate!.ratePerMinute, accuracy: 2.0)
    }

    func testPOSRejectsChannelCommonIntensityChanges() {
        // A pure intensity modulation with no pulse at all: the pulse band must stay
        // empty, i.e. POS output energy must be far below the same signal's own.
        let fs = 30.0
        var pipeline = PulsePipeline(configuration: .init(sampleRate: fs, bufferSeconds: 15))
        let samples = SyntheticSignal.makeSamples(
            duration: 25, sampleRate: fs, pulseHz: 1.2,
            pulseAmplitude: 0,            // no pulse
            intensityHz: 1.5,             // disturbance sitting inside the pulse band
            intensityAmplitude: 0.20
        )
        for sample in samples { pipeline.process(sample) }

        let energy = pipeline.waveform.reduce(0) { $0 + $1 * $1 } / Double(max(pipeline.waveform.count, 1))
        // The disturbance is 20% of a ~150 DC level; anything POS failed to cancel
        // would show up far above this floor.
        XCTAssertLessThan(energy.squareRoot(), 1e-3)
    }

    func testEngineDualRateWiring() {
        let frameRate = 30.0, trackingRate = 4.0
        let engine = RPPGEngine(configuration: .init(frameRate: frameRate, trackingRate: trackingRate))
        let samples = SyntheticSignal.makeSamples(duration: 30, sampleRate: frameRate, pulseHz: 1.2)

        // 15 breaths/min = 0.25 Hz vertical head motion.
        let respirationHz = 0.25
        let framesPerTrack = Int(frameRate / trackingRate)

        for (index, sample) in samples.enumerated() {
            if index % framesPerTrack == 0 {
                let t = sample.timestamp
                let y = 300 + 6 * sin(2 * Double.pi * respirationHz * t)
                engine.ingestTrack(FaceQuad(center: Point2D(x: 400, y: y), width: 220, height: 300, roll: 0))
            }
            engine.ingestFrame(sample, faceTracked: true)
        }

        XCTAssertEqual(engine.heartRate?.ratePerMinute ?? 0, 72, accuracy: 3.0)
        XCTAssertEqual(engine.respirationRate?.ratePerMinute ?? 0, 15, accuracy: 2.5)
        XCTAssertTrue(engine.quality.faceTracked)
        XCTAssertFalse(engine.pulseWaveform.isEmpty)
        XCTAssertFalse(engine.respirationWaveform.isEmpty)

        engine.reset()
        XCTAssertNil(engine.heartRate)
        XCTAssertTrue(engine.pulseWaveform.isEmpty)
    }

    func testRespirationPipelineUsesMeanCornerY() {
        let trackingRate = 4.0
        var pipeline = RespirationPipeline(
            configuration: .init(sampleRate: trackingRate, bufferSeconds: 60, minimumSecondsForEstimate: 20)
        )
        let respirationHz = 0.3   // 18 breaths/min
        for index in 0..<Int(trackingRate * 60) {
            let t = Double(index) / trackingRate
            let y = 250 + 5 * sin(2 * Double.pi * respirationHz * t)
            pipeline.process(quad: FaceQuad(center: Point2D(x: 300, y: y), width: 200, height: 260, roll: 0.1))
        }
        let estimate = pipeline.respirationRate()
        XCTAssertNotNil(estimate)
        XCTAssertEqual(estimate!.ratePerMinute, 18, accuracy: 1.5)
    }
}
