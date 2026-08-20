import Foundation
import RPPGCore

/// Everything needed to decide whether Stage 1 and Stage 2 pass, measured rather than
/// eyeballed.
///
/// The live values are cheap; the *statistics* (jitter, loss count, re-acquire time)
/// accumulate over a window the user resets with a button, so the procedure is: reset,
/// hold still for a minute, read the numbers.
struct TrackingDiagnostics: Sendable {

    // MARK: Stage 1 — capture

    /// Frame rate the DSP is configured for.
    var configuredFrameRate: Double = 0
    /// From the presentation timestamps.
    var measuredFrameRate: Double = 0
    /// Standard deviation of the frame interval, ms.
    var frameIntervalJitterMs: Double = 0
    var deliveredFrameCount: Int = 0
    var droppedFrameCount: Int = 0

    var configuredTrackingRate: Double = 0
    var measuredTrackingRate: Double = 0
    /// Standard deviation of the tracking-tick interval, ms.
    var trackingIntervalJitterMs: Double = 0
    var trackingTickCount: Int = 0

    var dropPercent: Double {
        let total = deliveredFrameCount + droppedFrameCount
        return total > 0 ? Double(droppedFrameCount) / Double(total) * 100 : 0
    }

    // MARK: Stage 2 — tracking, current tick

    var source: String = "none"
    var landmarkCount: Int = 0
    var inlierCount: Int = 0
    /// RMS similarity-fit residual, px. `nan` when no fit ran this tick.
    var rmsResidualPx: Double = .nan
    /// Scale relative to the anchor.
    var scale: Double = 1
    var anchorCount: Int = 0
    var rollDegrees: Double = 0
    var faceWidthPx: Double = 0
    var faceHeightPx: Double = 0
    var faceTracked: Bool = false

    // MARK: Stage 2 — statistics over the measurement window

    var statsSampleCount: Int = 0
    var statsSeconds: Double = 0
    /// Mean, over the eight corner coordinates, of each one's standard deviation, px.
    var cornerJitterPx: Double = 0
    /// The same as a percentage of the mean face width — the pass criterion's units.
    var cornerJitterPercentOfWidth: Double = 0
    /// Standard deviation of the respiration signal source itself, px.
    var meanCornerYStdPx: Double = 0
    var rollStdDegrees: Double = 0
    var residualRmsMeanPx: Double = 0

    var faceLostCount: Int = 0
    /// Tracking ticks the last recovery took.
    var lastReacquireTicks: Int = 0
    var worstReacquireTicks: Int = 0
}

/// Accumulates the Stage 2 statistics. Owned by the capture coordinator's processing
/// queue.
struct TrackingStatistics {

    /// x and y of each of the four corners.
    private var corners = [RunningStatistics](repeating: RunningStatistics(), count: 8)
    private var meanCornerY = RunningStatistics()
    private var roll = RunningStatistics()
    private var width = RunningStatistics()
    private var residual = RunningStatistics()

    private(set) var tickCount = 0
    private(set) var faceLostCount = 0
    private(set) var lastReacquireTicks = 0
    private(set) var worstReacquireTicks = 0

    private var consecutiveLostTicks = 0
    private var hadFace = false

    mutating func addTracked(quad: FaceQuad, roll rollRadians: Double, residualPx: Double) {
        tickCount += 1
        for index in 0..<4 {
            corners[index * 2].add(quad.corners[index].x)
            corners[index * 2 + 1].add(quad.corners[index].y)
        }
        meanCornerY.add(quad.meanCornerY)
        roll.add(rollRadians * 180 / .pi)
        width.add(quad.width)
        if residualPx.isFinite { residual.add(residualPx) }

        if consecutiveLostTicks > 0 {
            // A recovery just completed: how many ticks was the face gone?
            lastReacquireTicks = consecutiveLostTicks
            worstReacquireTicks = Swift.max(worstReacquireTicks, consecutiveLostTicks)
            consecutiveLostTicks = 0
        }
        hadFace = true
    }

    mutating func addLost() {
        tickCount += 1
        // Only a transition from tracked to lost counts as a loss event; the ticks that
        // follow are the same event continuing.
        if hadFace {
            faceLostCount += 1
            hadFace = false
        }
        consecutiveLostTicks += 1
    }

    mutating func reset() {
        corners = [RunningStatistics](repeating: RunningStatistics(), count: 8)
        meanCornerY.reset()
        roll.reset()
        width.reset()
        residual.reset()
        tickCount = 0
        faceLostCount = 0
        lastReacquireTicks = 0
        worstReacquireTicks = 0
        consecutiveLostTicks = 0
        hadFace = false
    }

    /// Mean of the eight per-coordinate standard deviations.
    var cornerJitterPx: Double {
        let tracked = corners.filter { $0.count > 1 }
        guard !tracked.isEmpty else { return 0 }
        return tracked.reduce(0) { $0 + $1.standardDeviation } / Double(tracked.count)
    }

    var meanFaceWidthPx: Double { width.count > 0 ? width.mean : 0 }
    var meanCornerYStdPx: Double { meanCornerY.standardDeviation }
    var rollStdDegrees: Double { roll.standardDeviation }
    var residualMeanPx: Double { residual.count > 0 ? residual.mean : 0 }
    var sampleCount: Int { meanCornerY.count }
}
