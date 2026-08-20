import SwiftUI

/// Scrolling trace of a filtered waveform, auto-scaled to its own peak.
///
/// Auto-scaling is deliberate: the POS output has no meaningful absolute unit, only a
/// shape, and a fixed scale would show a flat line at one distance and a clipped mess
/// at another.
struct WaveformView: View {

    let samples: [Double]
    let color: Color
    /// Number of most recent samples to draw.
    let visibleSampleCount: Int

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                let visible = Array(samples.suffix(visibleSampleCount))
                guard visible.count > 1 else { return }

                let peak = visible.reduce(0) { Swift.max($0, abs($1)) }
                guard peak > 0 else { return }

                let midY = size.height / 2
                let amplitude = size.height * 0.44 / peak
                let stepX = size.width / Double(visible.count - 1)

                var path = Path()
                for (index, value) in visible.enumerated() {
                    let point = CGPoint(x: Double(index) * stepX, y: midY - value * amplitude)
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }

                context.stroke(
                    Path { $0.move(to: CGPoint(x: 0, y: midY)); $0.addLine(to: CGPoint(x: size.width, y: midY)) },
                    with: .color(.white.opacity(0.12)),
                    lineWidth: 1
                )
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// One labelled reading — heart rate, respiration rate, quality.
struct MetricCard: View {

    let title: String
    let value: String
    let unit: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text(unit)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Horizontal confidence meter, 0 – 1.
struct ConfidenceBar: View {

    let confidence: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.12))
                Capsule()
                    .fill(tint)
                    .frame(width: geometry.size.width * min(max(confidence, 0), 1))
            }
        }
        .frame(height: 6)
    }
}
