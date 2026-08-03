import SwiftUI

struct FloatingRecorderView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isPaused: Bool
    let recordingPresentationStore: RecordingSessionPresentationStore
    let action: (FloatingControl) -> Void
    let controls = FloatingControl.allCases

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    controlsRow(liquidGlass: true)
                        .padding(8)
                        .glassEffect(.regular, in: Capsule())
                }
            } else {
                controlsRow(liquidGlass: false)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(.white.opacity(0.16), lineWidth: 0.5)
                    }
            }
        }
        .padding(1)
        .animation(
            AppVisualPolicy.motion(reduceMotion: reduceMotion).animation,
            value: isPaused
        )
    }

    private func controlsRow(liquidGlass: Bool) -> some View {
        HStack(spacing: 8) {
            elapsedDisplay

            Divider()
                .frame(height: 24)
                .opacity(0.45)

            ForEach(controls) { control in
                controlButton(control, liquidGlass: liquidGlass)
            }
        }
    }

    private var elapsedDisplay: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .opacity(statusOpacity(at: context.date))

                Text(
                    elapsedText(
                        at: ProcessInfo.processInfo.systemUptime
                    )
                )
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .contentTransition(.numericText())
                .frame(minWidth: 46, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(statusAccessibilityLabel) \(elapsedText(at: ProcessInfo.processInfo.systemUptime))"
            )
            .accessibilityIdentifier("floating.elapsed")
        }
    }

    func elapsedText(at monotonicTime: TimeInterval) -> String {
        guard let meetingID = recordingPresentationStore.meetingID else {
            return MeetingDisplayFormat.duration(0)
        }
        return MeetingDisplayFormat.duration(
            recordingPresentationStore.activeDuration(
                for: meetingID,
                at: monotonicTime
            ) ?? 0
        )
    }

    private var presentationPhase: RecordingSessionPresentationPhase {
        recordingPresentationStore.phase ?? (isPaused ? .paused : .recording)
    }

    private var statusColor: Color {
        presentationPhase == .paused ? .orange : .red
    }

    var statusAccessibilityLabel: String {
        switch presentationPhase {
        case .recording: "正在录音"
        case .paused: "录音已暂停"
        case .finished: "录音已结束"
        }
    }

    private func statusOpacity(at date: Date) -> Double {
        guard presentationPhase == .recording, !reduceMotion else {
            return 1
        }
        return Int(date.timeIntervalSinceReferenceDate) % 2 == 0
            ? 1
            : 0.42
    }

    @ViewBuilder
    private func controlButton(
        _ control: FloatingControl,
        liquidGlass: Bool
    ) -> some View {
        let presentation = control.presentation(isPaused: isPaused)
        let button = Button {
            action(control)
        } label: {
            Image(systemName: presentation.symbolName)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 36, height: 36)
                .contentShape(.circle)
                .contentTransition(
                    reduceMotion ? .identity : .symbolEffect(.replace)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle(for: control))
        .disabled(control == .record)
        .opacity(control == .record && isPaused ? 0.45 : 1)
        .accessibilityLabel(Text(presentation.accessibilityLabel))
        .accessibilityIdentifier("floating.\(control.rawValue)")

        if #available(macOS 26.0, *), liquidGlass {
            button.glassEffect(
                Glass.regular
                    .tint(foregroundStyle(for: control).opacity(0.18))
                    .interactive(control != .record),
                in: Circle()
            )
        } else {
            button.background(
                Circle()
                    .fill(.primary.opacity(0.08))
            )
        }
    }

    private func foregroundStyle(for control: FloatingControl) -> Color {
        switch control {
        case .record, .stop:
            .red
        case .pause:
            isPaused ? .green : .orange
        case .bookmark:
            .blue
        }
    }
}
