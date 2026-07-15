import SwiftUI

struct MeetingDetailView: View {
    @State private var viewModel: MeetingDetailViewModel
    private let onReturnHome: () -> Void

    init(
        viewModel: MeetingDetailViewModel,
        onReturnHome: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onReturnHome = onReturnHome
    }

    var body: some View {
        Group {
            if let meeting = viewModel.meeting {
                detailContent(meeting)
            } else {
                ContentUnavailableView(
                    "无法加载会议",
                    systemImage: "doc.badge.exclamationmark"
                )
            }
        }
        .navigationTitle(viewModel.meeting?.title ?? "会议详情")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("返回首页", systemImage: "chevron.backward") {
                    onReturnHome()
                }
                .accessibilityIdentifier("meeting.returnHome")
                .help("返回录音首页，保留历史会议")
                .adaptiveSecondaryButtonStyle()
            }
        }
        .task {
            viewModel.load()
        }
    }

    private func detailContent(_ meeting: MeetingRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AdaptiveGlassCard {
                    header(meeting)
                }
                audioSection(meeting)

                GroupBox("转录") {
                    TranscriptView(
                        transcripts: meeting.transcripts,
                        bookmarks: meeting.bookmarks
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                }

                GroupBox("书签") {
                    BookmarkListView(bookmarks: meeting.bookmarks)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }

                summarySection(meeting)
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("meeting.detail")
    }

    private func header(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title)
                    .font(.largeTitle.bold())
                    .textSelection(.enabled)
                Spacer()
                Label(
                    MeetingDisplayFormat.state(meeting.state),
                    systemImage: MeetingDisplayFormat.stateSymbol(meeting.state)
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(MeetingDisplayFormat.stateColor(meeting.state))
            }

            HStack(spacing: 14) {
                Label(
                    meeting.startedAt.formatted(date: .long, time: .shortened),
                    systemImage: "calendar"
                )
                Label(
                    meeting.mode == .offline ? "线下会议" : "在线会议",
                    systemImage: meeting.mode == .offline
                        ? "person.2.fill"
                        : "display"
                )
                Label(
                    MeetingDisplayFormat.duration(meeting.activeDuration),
                    systemImage: "clock"
                )
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private func audioSection(_ meeting: MeetingRecord) -> some View {
        AdaptiveGlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("音频")
                    .font(.headline)

                HStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.title2)
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.endedAt == nil ? "正在录制" : "本地录音")
                            .font(.headline)
                        Text(
                            meeting.endedAt == nil
                                ? "结束会议后可播放完整音频"
                                : "音频保留在这台 Mac 上"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(MeetingDisplayFormat.duration(meeting.activeDuration))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func summarySection(_ meeting: MeetingRecord) -> some View {
        AdaptiveGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("总结与归档")
                    .font(.headline)

                if let summary = meeting.summary {
                    Text(summary.overview)
                        .textSelection(.enabled)
                    summaryList(title: "关键结论", items: summary.keyPoints)
                    summaryList(title: "决定事项", items: summary.decisions)
                    summaryList(
                        title: "行动项",
                        items: summary.actionItemRecords.map(actionItemText)
                    )
                } else {
                    Text("会议结束并完成转录后，可生成总结并归档到 Notion。")
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = viewModel.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("关闭") {
                            viewModel.dismissError()
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 12) {
                    let action = viewModel.primaryAction
                    Button(action.title, systemImage: action.symbolName) {
                        Task {
                            await viewModel.performPrimaryAction()
                        }
                    }
                    .adaptivePrimaryButtonStyle()
                    .disabled(!action.isEnabled || viewModel.isPerforming)
                    .accessibilityIdentifier("meeting.summarizeArchive")

                    if action == .summarizing || action == .archiving {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let urlString = meeting.notionPageURL,
                       let url = URL(string: urlString) {
                        Link("在 Notion 中打开", destination: url)
                    } else {
                        Text("尚未归档")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actionItemText(_ item: ActionItem) -> String {
        var details: [String] = []
        if let owner = item.owner, !owner.isEmpty {
            details.append("负责人：\(owner)")
        }
        if let dueDate = item.dueDate, !dueDate.isEmpty {
            details.append("截止：\(dueDate)")
        }
        guard !details.isEmpty else { return item.task }
        return "\(item.task)｜\(details.joined(separator: "｜"))"
    }

    @ViewBuilder
    private func summaryList(title: String, items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)")
                        .textSelection(.enabled)
                }
            }
        }
    }
}

enum MeetingDisplayFormat {
    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func timecode(_ interval: TimeInterval) -> String {
        duration(interval)
    }

    static func state(_ state: RecordingState) -> String {
        switch state {
        case .idle: "待开始"
        case .preparing: "准备中"
        case .recording: "录音中"
        case .paused: "已暂停"
        case .finalizing: "处理中"
        case .ready: "可总结"
        case .summarizing: "总结中"
        case .summaryReady: "待归档"
        case .archiving: "归档中"
        case .archived: "已归档"
        }
    }

    static func stateSymbol(_ state: RecordingState) -> String {
        switch state {
        case .recording: "record.circle.fill"
        case .paused: "pause.circle.fill"
        case .archived: "checkmark.circle.fill"
        case .summarizing, .archiving, .finalizing, .preparing:
            "clock.arrow.circlepath"
        default: "circle.fill"
        }
    }

    static func stateColor(_ state: RecordingState) -> Color {
        switch state {
        case .recording: .red
        case .paused: .orange
        case .archived: .green
        case .ready, .summaryReady: .blue
        default: .secondary
        }
    }
}
