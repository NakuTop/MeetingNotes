import SwiftUI

struct ModelStatusView: View {
    @Bindable var viewModel: TranscriptionModelViewModel
    let mode: TranscriptionQualityMode?
    let accessibilityIdentifier: String
    let showsRetryButton: Bool

    init(
        viewModel: TranscriptionModelViewModel,
        mode: TranscriptionQualityMode? = nil,
        accessibilityIdentifier: String = "model.status",
        showsRetryButton: Bool = true
    ) {
        self.viewModel = viewModel
        self.mode = mode
        self.accessibilityIdentifier = accessibilityIdentifier
        self.showsRetryButton = showsRetryButton
    }

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if status == .downloading {
                ProgressView()
                    .controlSize(.small)
            } else if showsRetryButton && viewModel.canRetry(mode: displayMode) {
                Button("重试模型准备", systemImage: "arrow.clockwise") {
                    let mode = displayMode
                    Task {
                        await viewModel.retry(mode: mode)
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier("model.retry")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .downloading:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }

    private var title: String {
        let displayName = viewModel.descriptor(for: displayMode).mode.displayName
        return switch status {
        case .notDownloaded: "\(displayName)模型尚未准备"
        case .downloading: "正在下载或加载\(displayName)模型"
        case .ready: "\(displayName)模型可用"
        case .failed: "\(displayName)模型准备失败"
        }
    }

    private var detail: String {
        switch status {
        case .notDownloaded:
            "仍可发起会议；开始录音前会先准备模型。"
        case .downloading:
            "正在准备本地转录模型，会议开始前会等待完成。"
        case .ready:
            "会议音频会在这台 Mac 上转录。"
        case .failed:
            "会议开始时会重试；也可先检查网络和磁盘空间。"
        }
    }

    private var displayMode: TranscriptionQualityMode {
        mode ?? viewModel.selectedMode
    }

    private var status: TranscriptionModelStatus {
        viewModel.status(for: displayMode)
    }
}
