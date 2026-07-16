import SwiftUI

struct MeetingDetailView: View {
    @State private var viewModel: MeetingDetailViewModel
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var renameTask: Task<Void, Never>?
    @State private var renameGeneration = 0
    @FocusState private var isTitleFieldFocused: Bool
    private let onReturnHome: () -> Void
    private let onMeetingChanged: () -> Void

    init(
        viewModel: MeetingDetailViewModel,
        onReturnHome: @escaping () -> Void,
        onMeetingChanged: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onReturnHome = onReturnHome
        self.onMeetingChanged = onMeetingChanged
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
        .onDisappear {
            invalidateRenameTask()
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
                titleEditor(meeting)
                Spacer()
                Label(
                    MeetingDisplayFormat.state(meeting.state),
                    systemImage: MeetingDisplayFormat.stateSymbol(meeting.state)
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(MeetingDisplayFormat.stateColor(meeting.state))
            }

            if let renameErrorMessage = viewModel.renameErrorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(renameErrorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("关闭") {
                        viewModel.dismissRenameError()
                    }
                    .buttonStyle(.plain)
                }
                .accessibilityIdentifier("meeting.detail.renameError")
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

    @ViewBuilder
    private func titleEditor(_ meeting: MeetingRecord) -> some View {
        if isEditingTitle {
            HStack(spacing: 8) {
                TextField("会议标题", text: $titleDraft)
                    .font(.largeTitle.bold())
                    .textFieldStyle(.plain)
                    .focused($isTitleFieldFocused)
                    .onSubmit {
                        saveTitle(meeting)
                    }
                    .onExitCommand {
                        cancelTitleEditing(meeting)
                    }
                    .disabled(viewModel.isRenaming || !canRename(meeting))
                    .accessibilityIdentifier("meeting.detail.renameField")

                Button {
                    saveTitle(meeting)
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.borderless)
                .disabled(
                    trimmedTitleDraft.isEmpty
                        || viewModel.isRenaming
                        || !canRename(meeting)
                )
                .accessibilityLabel("保存会议标题")
                .accessibilityIdentifier("meeting.detail.renameSave")

                Button {
                    cancelTitleEditing(meeting)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("取消重命名")
                .accessibilityIdentifier("meeting.detail.renameCancel")

                if viewModel.isRenaming {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        } else {
            HStack(spacing: 8) {
                Text(meeting.title)
                    .font(.largeTitle.bold())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("meeting.detail.title")

                Button {
                    beginTitleEditing(meeting)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .disabled(!canRename(meeting) || viewModel.isRenaming)
                .accessibilityLabel("重命名会议")
                .accessibilityIdentifier("meeting.detail.rename")
            }
        }
    }

    private var trimmedTitleDraft: String {
        titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func canRename(_ meeting: MeetingRecord) -> Bool {
        !viewModel.isPerforming
            && meeting.state != .summarizing
            && meeting.state != .archiving
    }

    private func beginTitleEditing(_ meeting: MeetingRecord) {
        titleDraft = meeting.title
        viewModel.dismissRenameError()
        isEditingTitle = true
        Task { @MainActor in
            await Task.yield()
            isTitleFieldFocused = true
        }
    }

    private func cancelTitleEditing(_ meeting: MeetingRecord) {
        invalidateRenameTask()
        titleDraft = meeting.title
        isEditingTitle = false
        viewModel.dismissRenameError()
    }

    private func saveTitle(_ meeting: MeetingRecord) {
        guard !trimmedTitleDraft.isEmpty,
              !viewModel.isRenaming,
              canRename(meeting) else {
            return
        }
        let title = trimmedTitleDraft
        renameGeneration &+= 1
        let generation = renameGeneration
        let submittedMeetingID = meeting.id
        renameTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let succeeded = await viewModel.rename(to: title)
            guard !Task.isCancelled,
                  generation == renameGeneration,
                  submittedMeetingID == viewModel.meetingID,
                  viewModel.meeting?.id == submittedMeetingID else {
                return
            }
            renameTask = nil
            if succeeded {
                titleDraft = title
                isEditingTitle = false
                onMeetingChanged()
            } else {
                isTitleFieldFocused = true
            }
        }
    }

    private func invalidateRenameTask() {
        renameGeneration &+= 1
        renameTask?.cancel()
        renameTask = nil
        isTitleFieldFocused = false
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
                    .disabled(
                        !action.isEnabled
                            || viewModel.isPerforming
                            || isEditingTitle
                            || viewModel.isRenaming
                    )
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
