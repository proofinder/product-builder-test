import Foundation
import RPPGCore
import SwiftUI
import UIKit

/// Main-actor face of the capture stack. Holds nothing but published UI state; all the
/// real work lives on ``CaptureCoordinator``'s private queues.
@MainActor
final class RPPGViewModel: ObservableObject {

    @Published private(set) var snapshot = CaptureSnapshot()
    @Published private(set) var isRunning = false
    @Published var errorMessage: String?

    @Published var showsROIOverlay = true
    @Published var skinGateEnabled = false {
        didSet { coordinator.setSkinGateEnabled(skinGateEnabled) }
    }

    let coordinator: CaptureCoordinator

    init(coordinator: CaptureCoordinator = CaptureCoordinator()) {
        self.coordinator = coordinator
        coordinator.onSnapshot = { [weak self] snapshot in
            // The coordinator already hops to main; the task only re-establishes the
            // actor isolation the compiler can see.
            Task { @MainActor in self?.snapshot = snapshot }
        }
    }

    func start() async {
        guard !isRunning else { return }
        do {
            try await coordinator.start()
            isRunning = true
            errorMessage = nil
            // A measurement runs for tens of seconds with no touch input; without this
            // the tablet dims and auto-locks in the middle of it.
            UIApplication.shared.isIdleTimerDisabled = true
        } catch {
            isRunning = false
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        guard isRunning else { return }
        coordinator.stop()
        isRunning = false
        snapshot = CaptureSnapshot()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func resetSignal() {
        coordinator.resetSignal()
        snapshot.pulseWaveform = []
        snapshot.respirationWaveform = []
        snapshot.heartRate = nil
        snapshot.respirationRate = nil
    }

    func rebalanceCamera() {
        coordinator.rebalanceCamera()
    }

    // MARK: - Display helpers

    var heartRateText: String {
        guard let estimate = snapshot.heartRate, estimate.confidence > 0.25 else { return "--" }
        return String(format: "%.0f", estimate.ratePerMinute)
    }

    var respirationRateText: String {
        guard let estimate = snapshot.respirationRate, estimate.confidence > 0.25 else { return "--" }
        return String(format: "%.0f", estimate.ratePerMinute)
    }

    var statusText: String {
        if let errorMessage { return errorMessage }
        if !isRunning { return "Tap Start to begin measuring." }
        if !snapshot.quality.faceTracked { return "Looking for a face — sit facing the tablet." }
        if snapshot.quality.clippedFraction > 0.15 { return "Too bright: the skin is over-exposed." }
        if snapshot.quality.roiPixelCount < 500 { return "Move closer to the tablet." }
        if snapshot.quality.secondsBuffered < 6 {
            return String(format: "Acquiring signal… %.0f s", snapshot.quality.secondsBuffered)
        }
        if let snr = snapshot.heartRate?.signalToNoiseDB, snr < 0 {
            return "Weak signal — hold still and avoid backlight."
        }
        return "Measuring."
    }
}
