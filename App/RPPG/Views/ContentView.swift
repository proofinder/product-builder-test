import RPPGCore
import SwiftUI

/// Tablet layout: live preview on the left, readings, traces and the stage-by-stage
/// diagnostics on the right. Sized for an iPad in landscape, which is how a stationary
/// measurement rig sits.
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
                            .frame(width: geometry.size.width * 0.52)
                        panel
                    }
                } else {
                    VStack(spacing: 0) {
                        preview
                            .frame(height: geometry.size.height * 0.45)
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
                if viewModel.snapshot.isRecording { recordingBanner }
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

    private var recordingBanner: some View {
        Label(
            "Recording — \(viewModel.snapshot.recordedRowCount) rows",
            systemImage: "record.circle.fill"
        )
        .font(.callout.weight(.semibold).monospacedDigit())
        .foregroundStyle(.red)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 16)
    }

    // MARK: - Readings side

    private var panel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                metrics
                debugTrace
                posIntermediates
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
                ConfidenceBar(confidence: viewModel.snapshot.heartRate?.confidence ?? 0, tint: .red)
            }
            VStack(spacing: 8) {
                MetricCard(
                    title: "Respiration",
                    value: viewModel.respirationRateText,
                    unit: "br/min",
                    detail: detail(for: viewModel.snapshot.respirationRate),
                    tint: .cyan
                )
                ConfidenceBar(confidence: viewModel.snapshot.respirationRate?.confidence ?? 0, tint: .cyan)
            }
        }
    }

    private var debugTrace: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Signal", selection: $viewModel.debugSignal) {
                ForEach(DebugSignal.allCases) { signal in
                    Text(signal.rawValue).tag(signal)
                }
            }
            .pickerStyle(.segmented)

            WaveformView(
                samples: viewModel.debugSamples,
                color: viewModel.debugSignal == .respiration ? .cyan : .red,
                visibleSampleCount: max(Int(viewModel.debugSampleRate * visibleSeconds), 2)
            )
            .frame(height: 130)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    /// 8 s of pulse shows four to ten beats; respiration needs far longer to show a cycle.
    private var visibleSeconds: Double {
        viewModel.debugSignal == .respiration ? 45 : 8
    }

    /// Every POS intermediate, live. This is what makes Stage 5 checkable on the device
    /// rather than only in a CSV afterwards.
    private var posIntermediates: some View {
        let step = viewModel.snapshot.posStep
        return VStack(alignment: .leading, spacing: 6) {
            Text("POS intermediates")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            vectorRow("C", step.map { [$0.c.red, $0.c.green, $0.c.blue] })
            vectorRow("Cmean", step.map { [$0.cMean.red, $0.cMean.green, $0.cMean.blue] })
            vectorRow("C./Cmean", step.map { [$0.cNormalized.red, $0.cNormalized.green, $0.cNormalized.blue] })
            vectorRow("S", step.map { [$0.s.first, $0.s.second] })
            vectorRow("Smean", step.map { [$0.sMean.first, $0.sMean.second] })
            vectorRow("Sstd", step.map { [$0.sStd.first, $0.sStd.second] })
            vectorRow("h", step.map { [$0.h] })
            vectorRow("hmean", step.map { [$0.hMean] })
            vectorRow("rPPG", step.map { [$0.rppg] })
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func vectorRow(_ label: String, _ values: [Double]?) -> some View {
        let text: String
        if let values {
            text = values.map { String(format: "%+.6g", $0) }.joined(separator: "   ")
        } else {
            text = "—"
        }
        return HStack(alignment: .top) {
            Text(label)
                .frame(width: 76, alignment: .leading)
            Text(text)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    private var diagnostics: some View {
        let snapshot = viewModel.snapshot
        let dropRate = snapshot.deliveredFrameCount > 0
            ? Double(snapshot.droppedFrameCount)
                / Double(snapshot.droppedFrameCount + snapshot.deliveredFrameCount) * 100
            : 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("Capture diagnostics")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            diagnosticRow(
                "Frame rate  set / measured",
                String(format: "%.0f / %.2f Hz", snapshot.frameRate, snapshot.measuredFrameRate)
            )
            diagnosticRow("Frame jitter (std)", String(format: "%.2f ms", snapshot.frameIntervalJitterMs))
            diagnosticRow(
                "Dropped frames",
                String(format: "%d  (%.2f %%)", snapshot.droppedFrameCount, dropRate)
            )
            diagnosticRow(
                "Tracking rate  set / measured",
                String(format: "%.0f / %.2f Hz", snapshot.trackingRate, snapshot.measuredTrackingRate)
            )
            diagnosticRow("Track source", snapshot.trackSource)
            diagnosticRow("Face roll", String(format: "%+.1f°", snapshot.rollDegrees))
            diagnosticRow("ROI pixels", "\(snapshot.quality.roiPixelCount)")
            diagnosticRow("Clipped", String(format: "%.1f %%", snapshot.quality.clippedFraction * 100))
            diagnosticRow("POS steps", "\(snapshot.quality.posStepCount)")
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
            Button {
                viewModel.toggleRecording()
            } label: {
                Label(
                    viewModel.snapshot.isRecording ? "Stop recording" : "Record CSV",
                    systemImage: viewModel.snapshot.isRecording ? "stop.circle" : "record.circle"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.snapshot.isRecording ? .red : .blue)
            .disabled(!viewModel.isRunning)

            if let url = viewModel.finishedRecording {
                ShareLink(item: url) {
                    Label("Export \(url.lastPathComponent)", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            HStack {
                Text("ROI scale")
                Slider(value: $viewModel.roiScale, in: 0.5...1.0, step: 0.05)
                Text(String(format: "%.2f", viewModel.roiScale))
                    .monospacedDigit()
                    .frame(width: 46, alignment: .trailing)
            }
            Text("1.00 matches the MATLAB reference, which averages the whole rotated box.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

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
            .tint(viewModel.isRunning ? .orange : .accentColor)
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
