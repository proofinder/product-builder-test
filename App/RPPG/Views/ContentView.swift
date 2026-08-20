import RPPGCore
import SwiftUI

/// Tablet layout: live preview on the left, the current stage's panel on the right.
///
/// The panel switch matters more than it looks. The development plan says a stage is
/// not finished until its pass criteria are met, so the app opens on **Tracking**
/// (Stage 1–2) and the signal chain is somewhere you go on purpose — not the first
/// thing you stare at while the box it depends on is still wrong.
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
                showsROI: viewModel.showsROIOverlay,
                showsCorners: viewModel.showsCornerMarkers
            )
            VStack {
                statusBanner
                Spacer()
                HStack {
                    trackingBadge
                    Spacer()
                    if viewModel.snapshot.isRecording { recordingBadge }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
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

    /// Roll and tracking source, right on the preview, so head tilt can be checked
    /// without looking away from the overlay.
    private var trackingBadge: some View {
        let tracking = viewModel.snapshot.tracking
        return Text(
            String(format: "roll %+.1f°   %@", tracking.rollDegrees, tracking.source)
        )
        .font(.callout.monospacedDigit())
        .foregroundStyle(tracking.faceTracked ? .primary : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var recordingBadge: some View {
        Label(
            "\(viewModel.snapshot.recordedRowCount) rows",
            systemImage: "record.circle.fill"
        )
        .font(.callout.weight(.semibold).monospacedDigit())
        .foregroundStyle(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
    }

    // MARK: - Panel side

    private var panel: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $viewModel.panel) {
                ForEach(PanelMode.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                Group {
                    switch viewModel.panel {
                    case .tracking: TrackingPanel(viewModel: viewModel)
                    case .signal: SignalPanel(viewModel: viewModel)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }

            startStopButton
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .background(Color(white: 0.07))
    }

    private var startStopButton: some View {
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
                viewModel.isRunning ? "Stop camera" : "Start camera",
                systemImage: viewModel.isRunning ? "stop.fill" : "play.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.isRunning ? .orange : .accentColor)
        .font(.callout)
    }
}

#Preview {
    ContentView()
}
