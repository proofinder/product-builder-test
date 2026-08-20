import RPPGCore
import SwiftUI

/// Tablet layout: live preview on the left, readings and waveforms on the right.
/// Sized for an iPad in landscape, which is how a stationary measurement rig sits.
@MainActor
struct ContentView: View {

    @StateObject private var viewModel = RPPGViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > geometry.size.height

            Group {
                if isWide {
                    HStack(spacing: 0) {
                        preview
                            .frame(width: geometry.size.width * 0.58)
                        panel
                    }
                } else {
                    VStack(spacing: 0) {
                        preview
                            .frame(height: geometry.size.height * 0.5)
                        panel
                    }
                }
            }
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .task { await viewModel.start() }
        .onChange(of: scenePhase) { phase in
            // Never keep the camera alive in the background, and pick the measurement
            // back up when the app returns. `start()` is a no-op while already running.
            if phase == .active {
                Task { await viewModel.start() }
            } else {
                viewModel.stop()
            }
        }
    }

    // MARK: - Preview side

    private var preview: some View {
        ZStack {
            CameraPreviewView(session: viewModel.coordinator.captureSession)
            FaceOverlayView(
                faceQuad: viewModel.snapshot.faceQuad,
                roiQuad: viewModel.snapshot.roiQuad,
                imageSize: viewModel.snapshot.imageSize,
                showsROI: viewModel.showsROIOverlay
            )
            VStack {
                statusBanner
                Spacer()
            }
        }
        .clipped()
    }

    private var statusBanner: some View {
        Text(viewModel.statusText)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 16)
    }

    // MARK: - Readings side

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                metrics
                waveforms
                diagnostics
                controls
            }
            .padding(20)
        }
        .background(Color(white: 0.07))
    }

    private var metrics: some View {
        HStack(spacing: 14) {
            VStack(spacing: 8) {
                MetricCard(
                    title: "Pulse",
                    value: viewModel.heartRateText,
                    unit: "bpm",
                    detail: detail(for: viewModel.snapshot.heartRate),
                    tint: .red
                )
                ConfidenceBar(
                    confidence: viewModel.snapshot.heartRate?.confidence ?? 0,
                    tint: .red
                )
            }
            VStack(spacing: 8) {
                MetricCard(
                    title: "Respiration",
                    value: viewModel.respirationRateText,
                    unit: "br/min",
                    detail: detail(for: viewModel.snapshot.respirationRate),
                    tint: .cyan
                )
                ConfidenceBar(
                    confidence: viewModel.snapshot.respirationRate?.confidence ?? 0,
                    tint: .cyan
                )
            }
        }
    }

    private var waveforms: some View {
        VStack(alignment: .leading, spacing: 14) {
            labelledWaveform(
                title: "rPPG (POS output, band-passed)",
                samples: viewModel.snapshot.pulseWaveform,
                visible: Int(viewModel.snapshot.frameRate * 8),
                color: .red
            )
            labelledWaveform(
                title: "Respiration (mean corner y of the tracked face)",
                samples: viewModel.snapshot.respirationWaveform,
                visible: Int(viewModel.snapshot.trackingRate * 40),
                color: .cyan
            )
        }
    }

    private func labelledWaveform(
        title: String,
        samples: [Double],
        visible: Int,
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            WaveformView(samples: samples, color: color, visibleSampleCount: max(visible, 2))
                .frame(height: 96)
                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var diagnostics: some View {
        let snapshot = viewModel.snapshot
        return VStack(alignment: .leading, spacing: 6) {
            diagnosticRow(
                "Frame / tracking rate",
                String(format: "%.0f Hz / %.0f Hz", snapshot.frameRate, snapshot.trackingRate)
            )
            diagnosticRow("Measured frame rate", String(format: "%.1f Hz", snapshot.measuredFrameRate))
            diagnosticRow("ROI pixels", "\(snapshot.quality.roiPixelCount)")
            diagnosticRow("Face roll", String(format: "%+.1f°", snapshot.rollDegrees))
            diagnosticRow("Clipped", String(format: "%.1f %%", snapshot.quality.clippedFraction * 100))
            diagnosticRow("Buffered", String(format: "%.0f s", snapshot.quality.secondsBuffered))
            if let snr = snapshot.heartRate?.signalToNoiseDB, snr.isFinite {
                diagnosticRow("Pulse SNR", String(format: "%.1f dB", snr))
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Toggle("Show ROI overlay", isOn: $viewModel.showsROIOverlay)
            Toggle("Skin-tone gate inside ROI", isOn: $viewModel.skinGateEnabled)

            HStack(spacing: 12) {
                Button {
                    viewModel.resetSignal()
                } label: {
                    Label("Reset signal", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.rebalanceCamera()
                } label: {
                    Label("Re-balance camera", systemImage: "sun.max")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                Task {
                    if viewModel.isRunning {
                        viewModel.stop()
                    } else {
                        await viewModel.start()
                    }
                }
            } label: {
                Label(
                    viewModel.isRunning ? "Stop" : "Start",
                    systemImage: viewModel.isRunning ? "stop.fill" : "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isRunning ? .red : .accentColor)
        }
        .font(.callout)
    }

    private func detail(for estimate: SpectralEstimate?) -> String {
        guard let estimate else { return "waiting for signal" }
        return String(
            format: "%.2f Hz · SNR %.1f dB",
            estimate.frequencyHz,
            estimate.signalToNoiseDB.isFinite ? estimate.signalToNoiseDB : 0
        )
    }
}

#Preview {
    ContentView()
}
