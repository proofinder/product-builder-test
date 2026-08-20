import Foundation

/// POS (Plane-Orthogonal-to-Skin), transcribed line by line from the reference
/// implementation in `matlab/rPPG_test.m` (lines 133–170).
///
/// ```matlab
/// C(1:3,1) = mean(mean(faceimg));
/// if isempty(Cmean); Cmean = C;    else; Cmean = lambda1*Cmean + (1-lambda1)*C;            end
/// S = [0 1 -1; -2 1 1] * (C./Cmean);
/// if isempty(Smean); Smean = S;    else; Smean = lambda1*Smean + (1-lambda1)*S;            end
/// if isempty(Svar);  Svar = (S-Smean).^2; else; Svar = lambda1*Svar + (1-lambda1)*(S-Smean).^2; end
/// Sstd = sqrt(Svar);
/// h = S(1)/(Sstd(1)+1.0000e-09) + 1/(Sstd(2)+1.0000e-09)*S(2);
/// if isempty(hmean); hmean = h;    else; hmean = lambda2*hmean + (1-lambda2)*h;            end
/// H(frameCount) = H(frameCount-1) + (h-hmean);
/// ```
///
/// Several details here exist purely so the two implementations agree to the last few
/// ulps, which is what makes the cross-check in `POSGoldenTests` meaningful:
///
/// * `(1 - lambda)` is computed, never written as a literal (`1 - 0.99` is
///   `0.010000000000000009`, not `0.01`).
/// * `h` keeps the reference's asymmetry — `S(1)` is *divided* by its denominator while
///   `S(2)` is multiplied by the *reciprocal* of its own. Those differ in the last bit,
///   and the difference compounds through the running sum in `rppg`.
/// * The projection rows are evaluated left to right, as the matrix product is.
///
/// Not thread-safe: feed it from a single serial queue.
public struct POSProcessor: Sendable {

    public struct Configuration: Sendable {

        /// `lambda1` — drives `Cmean`, `Smean` and `Svar`.
        ///
        /// The reference fixes this at 0.99 (with a noted usable range of 0.95–0.99)
        /// as a **constant, independent of frame rate**. That is kept: matching the
        /// reference numerically matters more than holding the time constant fixed
        /// across 30 and 60 fps. Note the consequence — 0.99 is a memory of about 100
        /// samples, so 3.3 s at 30 fps but 1.7 s at 60 fps.
        public var lambda1: Double

        /// `lambda2` — drives `hmean`. The reference fixes this at 0.9 (~10 samples).
        public var lambda2: Double

        /// The `1.0000e-09` guard added to each standard deviation before dividing.
        public var epsilon: Double

        public init(lambda1: Double = 0.99, lambda2: Double = 0.9, epsilon: Double = 1.0e-09) {
            precondition(lambda1 >= 0 && lambda1 < 1, "lambda1 must be in [0, 1)")
            precondition(lambda2 >= 0 && lambda2 < 1, "lambda2 must be in [0, 1)")
            self.lambda1 = lambda1
            self.lambda2 = lambda2
            self.epsilon = epsilon
        }

        /// The reference values from `rPPG_test.m`.
        public static let reference = Configuration()
    }

    /// Every intermediate of one POS step, in the order the reference computes them.
    ///
    /// All of it is exposed — and written to the recording CSV — because the whole
    /// verification plan rests on being able to compare each stage against MATLAB, not
    /// just the final `rppg`.
    public struct Step: Sendable, Equatable {
        /// Index of this POS step (0-based). Counts only frames that produced output,
        /// which is also what the recording CSV rows count.
        public let index: Int
        public let c: ChannelTriple
        public let cMean: ChannelTriple
        /// `C ./ Cmean`
        public let cNormalized: ChannelTriple
        public let s: ProjectionPair
        public let sMean: ProjectionPair
        public let sVar: ProjectionPair
        public let sStd: ProjectionPair
        public let h: Double
        public let hMean: Double
        /// The specification's `H(frameCount)` — a running sum, unfiltered.
        public let rppg: Double
    }

    public let configuration: Configuration

    // MARK: Persistent state (the "static" variables of the specification)

    private var cMean = ChannelTriple.zero
    private var sMean = ProjectionPair.zero
    private var sVar = ProjectionPair.zero
    private var hMean: Double = 0
    private var rppg: Double = 0

    private var cMeanPrimed = false
    private var sMeanPrimed = false
    private var sVarPrimed = false
    private var hMeanPrimed = false

    private var stepIndex = 0

    public init(configuration: Configuration = .reference) {
        self.configuration = configuration
    }

    /// Number of steps consumed since the last ``reset()``.
    public var processedStepCount: Int { stepIndex }

    /// The current `H` value.
    public var currentRPPG: Double { rppg }

    /// Consumes one ROI mean `C` and advances every persistent state by one step.
    ///
    /// - Returns: `nil` when `c` is unusable (face lost, empty ROI, a zero channel),
    ///   in which case **no state is touched** — a dropped ROI must not perturb the
    ///   running normalisation, and it must not advance `rppg` either.
    @discardableResult
    public mutating func process(_ c: ChannelTriple) -> Step? {
        guard c.isUsable else { return nil }

        let lambda1 = configuration.lambda1
        let lambda2 = configuration.lambda2
        let epsilon = configuration.epsilon

        // --- temporal normalization -----------------------------------------------
        // if isempty(Cmean); Cmean = C; else; Cmean = lambda1*Cmean + (1-lambda1)*C; end
        if cMeanPrimed {
            cMean = lambda1 * cMean + (1 - lambda1) * c
        } else {
            cMean = c
            cMeanPrimed = true
        }
        guard cMean.isUsable else { return nil }

        // --- projection -------------------------------------------------------------
        // S = [0 1 -1; -2 1 1] * (C./Cmean);
        let cNormalized = c.dividedElementwise(by: cMean)
        let s = ProjectionPair(
            first: cNormalized.green - cNormalized.blue,
            second: (-2 * cNormalized.red + cNormalized.green) + cNormalized.blue
        )

        // --- tuning -----------------------------------------------------------------
        // if isempty(Smean); Smean = S; else; Smean = lambda1*Smean + (1-lambda1)*S; end
        if sMeanPrimed {
            sMean = lambda1 * sMean + (1 - lambda1) * s
        } else {
            sMean = s
            sMeanPrimed = true
        }

        // if isempty(Svar); Svar = (S-Smean).^2;
        // else; Svar = lambda1*Svar + (1-lambda1)*(S-Smean).^2; end
        let deviation = (s - sMean).squaredElementwise
        if sVarPrimed {
            sVar = lambda1 * sVar + (1 - lambda1) * deviation
        } else {
            sVar = deviation
            sVarPrimed = true
        }

        // Sstd = sqrt(Svar);
        let sStd = sVar.squareRootElementwise

        // h = S(1)/(Sstd(1)+1.0000e-09) + 1/(Sstd(2)+1.0000e-09)*S(2);
        //
        // On the very first step S is exactly [0; 0] (C == Cmean), so both terms are
        // 0/1e-9 == 0 rather than a division blow-up. On later steps Sstd grows in
        // proportion to |S| — early on it is roughly sqrt(1-lambda1)*|S| — so the ratio
        // stays bounded at around 1/sqrt(1-lambda1), i.e. ~10 for lambda1 = 0.99.
        let h = s.first / (sStd.first + epsilon) + (1 / (sStd.second + epsilon)) * s.second

        // --- overlap-adding ---------------------------------------------------------
        // if isempty(hmean); hmean = h; else; hmean = lambda2*hmean + (1-lambda2)*h; end
        if hMeanPrimed {
            hMean = lambda2 * hMean + (1 - lambda2) * h
        } else {
            hMean = h
            hMeanPrimed = true
        }

        // H(frameCount) = H(frameCount-1) + (h-hmean);
        rppg = rppg + (h - hMean)

        let step = Step(
            index: stepIndex,
            c: c,
            cMean: cMean,
            cNormalized: cNormalized,
            s: s,
            sMean: sMean,
            sVar: sVar,
            sStd: sStd,
            h: h,
            hMean: hMean,
            rppg: rppg
        )
        stepIndex += 1
        return step
    }

    /// Clears every persistent state, returning the processor to its pre-first-sample
    /// condition (MATLAB's `Cmean = []` and friends).
    public mutating func reset() {
        cMean = .zero;  cMeanPrimed = false
        sMean = .zero;  sMeanPrimed = false
        sVar = .zero;   sVarPrimed = false
        hMean = 0;      hMeanPrimed = false
        rppg = 0
        stepIndex = 0
    }

    /// Runs a whole sequence offline. Used by the replay tool and the golden tests.
    public static func run(
        _ samples: [ChannelTriple],
        configuration: Configuration = .reference
    ) -> [Step] {
        var processor = POSProcessor(configuration: configuration)
        return samples.compactMap { processor.process($0) }
    }
}
