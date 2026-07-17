import SwiftUI

struct WaveformProgressView: View {
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 2
    private static let minimumBarHeight: CGFloat = 2

    let values: [Float]
    let progress: Double
    let duration: TimeInterval
    let onSeekBegan: (Double) -> Void
    let onSeekChanged: (Double) -> Void
    let onSeekEnded: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let visibleCount = max(
                1,
                Int(
                    (width + Self.barGap)
                        / (Self.barWidth + Self.barGap)
                )
            )
            let visibleValues = Self.resample(values, count: visibleCount)

            Canvas { context, size in
                let drawingHeight = max(size.height, Self.minimumBarHeight)
                let safeProgress = Self.clampFraction(progress)

                for (index, value) in visibleValues.enumerated() {
                    let amplitude = CGFloat(Self.sanitize(value))
                    let barHeight = min(
                        drawingHeight,
                        max(Self.minimumBarHeight, amplitude * drawingHeight)
                    )
                    let x = CGFloat(index)
                        * (Self.barWidth + Self.barGap)
                    let rect = CGRect(
                        x: x,
                        y: (drawingHeight - barHeight) / 2,
                        width: Self.barWidth,
                        height: barHeight
                    )
                    let centerFraction = (Double(index) + 0.5)
                        / Double(visibleCount)
                    let color: Color = centerFraction < safeProgress
                        ? .accentColor
                        : .secondary.opacity(0.28)
                    context.fill(
                        Path(
                            roundedRect: rect,
                            cornerRadius: Self.barWidth / 2
                        ),
                        with: .color(color)
                    )
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = Self.clampFraction(
                            value.location.x / width
                        )
                        if isDragging {
                            onSeekChanged(fraction)
                        } else {
                            isDragging = true
                            onSeekBegan(fraction)
                        }
                    }
                    .onEnded { value in
                        let fraction = Self.clampFraction(
                            value.location.x / width
                        )
                        isDragging = false
                        onSeekEnded(fraction)
                    }
            )
        }
        .accessibilityRepresentation {
            Slider(
                value: accessibilityProgress,
                in: 0...1,
                step: accessibilityStep
            )
            .accessibilityIdentifier("meeting.audioPlayer.waveform")
            .accessibilityLabel("录音进度")
            .accessibilityValue(accessibilityValue)
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    seek(to: safeProgress + accessibilityStep)
                case .decrement:
                    seek(to: safeProgress - accessibilityStep)
                @unknown default:
                    break
                }
            }
        }
    }

    private var safeProgress: Double {
        Self.clampFraction(progress)
    }

    private var safeDuration: TimeInterval {
        duration.isFinite && duration > 0 ? duration : 0
    }

    private var accessibilityStep: Double {
        guard safeDuration > 0 else { return 1 }
        return min(1, 5 / safeDuration)
    }

    private var accessibilityProgress: Binding<Double> {
        Binding(
            get: { safeProgress },
            set: { seek(to: $0) }
        )
    }

    private var accessibilityValue: String {
        let current = safeProgress * safeDuration
        let percentage = Int((safeProgress * 100).rounded())
        return "当前 \(MeetingDisplayFormat.timecode(current))，"
            + "总时长 \(MeetingDisplayFormat.timecode(safeDuration))，"
            + "\(percentage)%"
    }

    private func seek(to fraction: Double) {
        let safeFraction = Self.clampFraction(fraction)
        onSeekBegan(safeFraction)
        onSeekEnded(safeFraction)
    }

    private static func resample(
        _ values: [Float],
        count: Int
    ) -> [Float] {
        guard count > 0 else { return [] }
        let source = values.map(sanitize)
        guard !source.isEmpty else {
            return Array(repeating: 0, count: count)
        }
        guard source.count != count else { return source }

        if source.count > count {
            return (0..<count).map { index in
                let lower = index * source.count / count
                let upper = max(
                    lower + 1,
                    (index + 1) * source.count / count
                )
                return source[lower..<min(upper, source.count)].max() ?? 0
            }
        }

        guard source.count > 1, count > 1 else {
            return Array(repeating: source[0], count: count)
        }
        return (0..<count).map { index in
            let position = Double(index) * Double(source.count - 1)
                / Double(count - 1)
            let lower = Int(position.rounded(.down))
            let upper = min(lower + 1, source.count - 1)
            let fraction = Float(position - Double(lower))
            return source[lower]
                + (source[upper] - source[lower]) * fraction
        }
    }

    private static func sanitize(_ value: Float) -> Float {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private static func clampFraction<T: BinaryFloatingPoint>(
        _ fraction: T
    ) -> Double {
        let value = Double(fraction)
        if value.isNaN { return 0 }
        guard value.isFinite else { return value.sign == .minus ? 0 : 1 }
        return min(max(value, 0), 1)
    }
}
