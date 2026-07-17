import SwiftUI

struct MeetingAudioPlayerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable private var controller: MeetingAudioPlayerController
    private let meetingID: UUID

    init(
        meetingID: UUID,
        controller: MeetingAudioPlayerController
    ) {
        self.meetingID = meetingID
        self.controller = controller
    }

    var body: some View {
        AdaptiveGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("本地录音")
                    .font(.headline)

                switch visibleState {
                case .idle, .loading:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .accessibilityLabel("正在准备录音")
                case let .failed(message):
                    Label(message, systemImage: "waveform.badge.exclamationmark")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .ready, .playing, .paused, .ended:
                    playerControls
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("meeting.audioPlayer")
        .animation(
            AppVisualPolicy.motion(reduceMotion: reduceMotion).animation,
            value: visibleState
        )
    }

    private var playerControls: some View {
        HStack(spacing: 16) {
            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 24, height: 24)
            }
            .adaptivePrimaryButtonStyle()
            .controlSize(.large)
            .accessibilityLabel(isPlaying ? "暂停播放" : "播放录音")
            .accessibilityIdentifier("meeting.audioPlayer.toggle")

            VStack(spacing: 7) {
                WaveformProgressView(
                    values: controller.waveform,
                    progress: progress,
                    duration: safeDuration,
                    onSeekBegan: controller.beginSeeking,
                    onSeekChanged: controller.updateSeeking,
                    onSeekEnded: controller.endSeeking
                )
                .frame(height: 58)

                HStack {
                    Text(MeetingDisplayFormat.timecode(safeCurrentTime))
                        .accessibilityIdentifier(
                            "meeting.audioPlayer.currentTime"
                        )
                    Spacer()
                    Text(MeetingDisplayFormat.timecode(safeDuration))
                        .accessibilityIdentifier(
                            "meeting.audioPlayer.duration"
                        )
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }

    private var visibleState: MeetingAudioPlayerState {
        controller.meetingID == meetingID ? controller.state : .idle
    }

    private var isPlaying: Bool {
        visibleState == .playing
    }

    private var safeDuration: TimeInterval {
        controller.duration.isFinite && controller.duration > 0
            ? controller.duration
            : 0
    }

    private var safeCurrentTime: TimeInterval {
        guard controller.currentTime.isFinite else { return 0 }
        return min(max(controller.currentTime, 0), safeDuration)
    }

    private var progress: Double {
        guard safeDuration > 0 else { return 0 }
        return min(max(safeCurrentTime / safeDuration, 0), 1)
    }
}
