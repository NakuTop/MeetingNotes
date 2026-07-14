import SwiftUI

struct ModelStatusView: View {
    @Bindable var viewModel: TranscriptionModelViewModel

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

            if viewModel.status == .downloading {
                ProgressView()
                    .controlSize(.small)
            } else if viewModel.canRetry {
                Button("重试模型准备", systemImage: "arrow.clockwise") {
                    Task {
                        await viewModel.retry()
                    }
                }
                .controlSize(.small)
                .accessibilityIdentifier("model.retry")
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("model.status")
        .task {
            await viewModel.prepareIfNeeded()
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewModel.status {
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
        switch viewModel.status {
        case .notDownloaded: "本地转录模型尚未准备"
        case .downloading: "正在下载或加载本地转录模型"
        case .ready: "本地转录模型可用"
        case .failed: "本地转录模型准备失败"
        }
    }

    private var detail: String {
        switch viewModel.status {
        case .notDownloaded:
            "仍可开始录音；模型就绪前不会宣称实时转录。"
        case .downloading:
            "录音不受影响，音频会安全保存在本机。"
        case .ready:
            "会议音频会在这台 Mac 上转录。"
        case .failed:
            "可继续录音；请检查网络、磁盘空间后重试。"
        }
    }
}
