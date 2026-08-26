import SwiftUI

private struct MeetingPlaybackPreparationKey: Hashable {
    let meetingID: UUID
    let isPlayable: Bool

    init(meeting: MeetingRecord) {
        meetingID = meeting.id
        isPlayable = meeting.endedAt != nil
    }
}

enum TranscriptDisclosurePolicy {
    static func initialIsExpanded(hasSummary: Bool) -> Bool {
        !hasSummary
    }

    static func shouldCollapse(
        previouslyHadSummary: Bool,
        hasSummary: Bool,
        userHasInteracted: Bool
    ) -> Bool {
        !previouslyHadSummary && hasSummary && !userHasInteracted
    }
}

private struct TranscriptDisclosureContext: Equatable {
    let meetingID: UUID
    let hasSummary: Bool

    init(meeting: MeetingRecord) {
        meetingID = meeting.id
        hasSummary = meeting.summary != nil || meeting.detailedMinutes != nil
    }
}

private struct MeetingExactReplacementRequest: Identifiable {
    let id = UUID()
    let initialSearchText: String
}

@MainActor
enum MeetingDetailTranscriptProjection {
    static func entries(
        for meeting: MeetingRecord
    ) -> [CanonicalTranscriptEntry] {
        TranscriptCorrectionResolver.resolve(
            transcripts: meeting.transcripts,
            corrections: meeting.transcriptCorrections
        )
    }
}

struct MeetingDetailView: View {
    @State private var viewModel: MeetingDetailViewModel
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    @State private var renameTask: Task<Void, Never>?
    @State private var documentOperationTask: Task<Void, Never>?
    @State private var speakerDiarizationTask: Task<Void, Never>?
    @State private var renameGeneration = 0
    @State private var transcriptMeetingID: UUID?
    @State private var transcriptIsExpanded = true
    @State private var transcriptPreviouslyHadSummary = false
    @State private var transcriptDisclosureUserHasInteracted = false
    @State private var exactReplacementRequest:
        MeetingExactReplacementRequest?
    @State private var isRegenerationConfirmationPresented = false
    @Bindable private var audioPlayerController: MeetingAudioPlayerController
    @FocusState private var isTitleFieldFocused: Bool
    private let onReturnHome: () -> Void
    private let onMeetingChanged: () -> Void

    init(
        viewModel: MeetingDetailViewModel,
        audioPlayerController: MeetingAudioPlayerController,
        onReturnHome: @escaping () -> Void,
        onMeetingChanged: @escaping () -> Void = {}
    ) {
        _viewModel = State(initialValue: viewModel)
        self.audioPlayerController = audioPlayerController
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
            invalidateDocumentOperationTask()
            invalidateSpeakerDiarizationTask()
            flushMeetingEdits()
        }
        .sheet(
            item: $exactReplacementRequest,
            onDismiss: viewModel.cancelExactReplacement
        ) { request in
            MeetingExactReplacementSheet(
                viewModel: viewModel,
                initialSearchText: request.initialSearchText,
                onClose: {
                    exactReplacementRequest = nil
                }
            )
        }
        .confirmationDialog(
            "重新生成会覆盖手动修改",
            isPresented: $isRegenerationConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("重新生成并覆盖", role: .destructive) {
                beginGenerateSelectedDocument(replacingManualEdits: true)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前内容包含手动修改，重新生成后无法恢复。")
        }
    }

    private func detailContent(_ meeting: MeetingRecord) -> some View {
        let playbackKey = MeetingPlaybackPreparationKey(meeting: meeting)
        let disclosureContext = TranscriptDisclosureContext(meeting: meeting)
        let transcriptEntries = MeetingDetailTranscriptProjection.entries(
            for: meeting
        )
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                AdaptiveGlassCard {
                    header(meeting)
                }
                audioSection(meeting)
                speakerProcessingSection
                summarySection(meeting)

                GroupBox {
                    DisclosureGroup(
                        isExpanded: transcriptDisclosureBinding
                    ) {
                        TranscriptView(
                            transcripts: transcriptEntries,
                            bookmarks: meeting.bookmarks,
                            customSpeakerNames: meeting.speakerDisplayNames,
                            frequentSpeakerNames: viewModel
                                .frequentSpeakerNames,
                            speakerNameErrorMessage: viewModel
                                .speakerNameErrorMessage,
                            onBeginSpeakerEditing: {
                                viewModel.dismissSpeakerNameError()
                            },
                            onRenameSpeaker: { speakerID, name in
                                let succeeded = viewModel.renameSpeaker(
                                    speakerID,
                                    to: name
                                )
                                if succeeded { onMeetingChanged() }
                                return succeeded
                            },
                            onClearSpeakerName: { speakerID in
                                let succeeded = viewModel.clearSpeakerName(
                                    speakerID
                                )
                                if succeeded { onMeetingChanged() }
                                return succeeded
                            },
                            onChangeTranscript: { text, target in
                                viewModel.updateTranscriptDraft(
                                    text,
                                    for: target
                                )
                            },
                            onFlushEdits: flushMeetingEdits,
                            onRequestExactReplacement:
                                requestExactReplacement,
                            transcriptDrafts: viewModel.transcriptDrafts
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    } label: {
                        Text("完整转录内容")
                            .font(.headline)
                    }
                    .accessibilityIdentifier(
                        "meeting.transcripts.disclosure"
                    )
                }

                GroupBox("书签") {
                    BookmarkListView(bookmarks: meeting.bookmarks)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("meeting.detail")
        .onChange(of: disclosureContext, initial: true) { _, context in
            synchronizeTranscriptDisclosure(with: context)
        }
        .task(id: playbackKey) {
            if playbackKey.isPlayable {
                await audioPlayerController.prepare(
                    meetingID: playbackKey.meetingID
                )
            } else {
                audioPlayerController.stop(
                    meetingID: playbackKey.meetingID
                )
                await viewModel.refreshWhileRecording()
            }
        }
        .onDisappear {
            audioPlayerController.stop(meetingID: meeting.id)
        }
    }

    private var transcriptDisclosureBinding: Binding<Bool> {
        Binding(
            get: { transcriptIsExpanded },
            set: { isExpanded in
                transcriptIsExpanded = isExpanded
                transcriptDisclosureUserHasInteracted = true
            }
        )
    }

    private func synchronizeTranscriptDisclosure(
        with context: TranscriptDisclosureContext
    ) {
        guard transcriptMeetingID == context.meetingID else {
            transcriptMeetingID = context.meetingID
            #if DEBUG
            if LaunchArguments.isUITesting(),
               LaunchArguments.usesMeetingEditingUITestFixture() {
                transcriptIsExpanded = true
            } else {
                transcriptIsExpanded = TranscriptDisclosurePolicy
                    .initialIsExpanded(hasSummary: context.hasSummary)
            }
            #else
            transcriptIsExpanded = TranscriptDisclosurePolicy
                .initialIsExpanded(hasSummary: context.hasSummary)
            #endif
            transcriptPreviouslyHadSummary = context.hasSummary
            transcriptDisclosureUserHasInteracted = false
            return
        }

        if TranscriptDisclosurePolicy.shouldCollapse(
            previouslyHadSummary: transcriptPreviouslyHadSummary,
            hasSummary: context.hasSummary,
            userHasInteracted: transcriptDisclosureUserHasInteracted
        ) {
            transcriptIsExpanded = false
        }
        transcriptPreviouslyHadSummary = context.hasSummary
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
                liveMetadataDurationLabel
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
                .keyboardShortcut(.cancelAction)
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
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(Rectangle())
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
            && !viewModel.isRetryingSpeakerDiarization
            && !viewModel.isDocumentOperationInProgress
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

    @ViewBuilder
    private func audioSection(_ meeting: MeetingRecord) -> some View {
        if meeting.endedAt != nil {
            MeetingAudioPlayerView(
                meetingID: meeting.id,
                controller: audioPlayerController
            )
        } else {
            AdaptiveGlassCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("音频")
                        .font(.headline)

                    HStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .font(.title2)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("正在录制")
                                .font(.headline)
                            Text("结束会议后可播放完整音频")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        liveDurationLabel
                    }
                }
            }
        }
    }

    private var liveDurationText: String {
        MeetingDisplayFormat.duration(
            viewModel.displayedActiveDuration(
                at: ProcessInfo.processInfo.systemUptime
            )
        )
    }

    private var liveDurationLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(liveDurationText)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var liveMetadataDurationLabel: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Label(liveDurationText, systemImage: "clock")
        }
    }

    private func summarySection(_ meeting: MeetingRecord) -> some View {
        AdaptiveGlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("总结与归档")
                    .font(.headline)

                MeetingDocumentModeSlider(
                    selection: Binding(
                        get: { viewModel.selectedDocumentKind },
                        set: { viewModel.selectedDocumentKind = $0 }
                    ),
                    isDisabled: viewModel.isDocumentOperationInProgress
                        || viewModel.isPerforming
                        || viewModel.isRenaming
                        || viewModel.isRetryingSpeakerDiarization
                        || isEditingTitle
                )

                selectedDocumentContent(meeting)

                localSaveStatus

                if let errorMessage = viewModel.documentErrorMessage(
                    for: viewModel.selectedDocumentKind
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("关闭") {
                            viewModel.dismissDocumentError(
                                for: viewModel.selectedDocumentKind
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack(spacing: 12) {
                    Button(
                        selectedGenerateButtonTitle(meeting),
                        systemImage: "sparkles"
                    ) {
                        if viewModel
                            .selectedDocumentRequiresRegenerationConfirmation {
                            isRegenerationConfirmationPresented = true
                        } else {
                            beginGenerateSelectedDocument(
                                replacingManualEdits: false
                            )
                        }
                    }
                    .adaptivePrimaryButtonStyle()
                    .disabled(
                        !viewModel.canGenerateSelectedDocument
                            || isEditingTitle
                    )
                    .accessibilityIdentifier("meeting.documents.generate")

                    if selectedDocumentOperationIsActive {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if hasSelectedDocument(meeting) {
                        Text(selectedArchiveStatusTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                "meeting.documents.archiveStatus"
                            )
                    }

                    if let archiveButtonTitle = viewModel
                        .selectedDocumentArchiveButtonTitle {
                        Button(archiveButtonTitle) {
                            beginArchiveSelectedDocumentToNotion()
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            !viewModel.canArchiveSelectedDocumentToNotion
                        )
                        .accessibilityIdentifier(
                            "meeting.documents.retryArchive"
                        )
                    }

                    if viewModel.archiveStatus(
                        for: viewModel.selectedDocumentKind
                    ) == .archived,
                       let urlString = meeting.notionPageURL,
                       let url = URL(string: urlString) {
                        Link("在 Notion 中打开", destination: url)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func selectedDocumentContent(_ meeting: MeetingRecord) -> some View {
        switch viewModel.selectedDocumentKind {
        case .summary:
            if meeting.summary != nil,
               let summary = viewModel.summaryDraft {
                editableDocumentText(
                    field: .summaryOverview,
                    fallback: summary.overview,
                    accessibilityIdentifier: "meeting.summary.overview"
                )
                editableStringList(
                    title: "关键结论",
                    items: summary.keyPoints,
                    field: { .summaryKeyPoint($0) },
                    accessibilityIdentifier: "meeting.summary.keyPoint"
                )
                editableStringList(
                    title: "决定事项",
                    items: summary.decisions,
                    field: { .summaryDecision($0) },
                    accessibilityIdentifier: "meeting.summary.decision"
                )
                editableActionItems(
                    title: "行动项",
                    items: summary.actionItems,
                    taskField: { .summaryActionTask($0) },
                    ownerField: { .summaryActionOwner($0) },
                    accessibilityIdentifier: "meeting.summary.action"
                )
            } else {
                emptyDocumentMessage(kind: .summary)
            }
        case .detailedMinutes:
            if meeting.detailedMinutes != nil,
               let minutes = viewModel.detailedMinutesDraft {
                detailedMinutesContent(minutes)
            } else if meeting.detailedMinutes != nil {
                Label(
                    "完整纪要读取失败，请重新生成。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            } else {
                emptyDocumentMessage(kind: .detailedMinutes)
            }
        }
    }

    private func emptyDocumentMessage(kind: MeetingDocumentKind) -> some View {
        Text(
            kind == .summary
                ? "生成提炼后的关键结论、决定事项和行动项。"
                : "生成更完整但经过整理提炼的议题纪要、决定和待确认问题。"
        )
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func detailedMinutesContent(
        _ minutes: GeneratedDetailedMinutes
    ) -> some View {
        editableDocumentText(
            field: .detailedMinutesOverview,
            fallback: minutes.overview,
            accessibilityIdentifier: "meeting.minutes.overview"
        )
        detailedMinutesSections(minutes.sections)
        editableStringList(
            title: "决定事项",
            items: minutes.decisions,
            field: { .detailedMinutesDecision($0) },
            accessibilityIdentifier: "meeting.minutes.decision"
        )
        editableActionItems(
            title: "行动项",
            items: minutes.actionItems,
            taskField: { .detailedMinutesActionTask($0) },
            ownerField: { .detailedMinutesActionOwner($0) },
            accessibilityIdentifier: "meeting.minutes.action"
        )
        editableStringList(
            title: "待确认问题",
            items: minutes.openQuestions,
            field: { .detailedMinutesOpenQuestion($0) },
            accessibilityIdentifier: "meeting.minutes.openQuestion"
        )
    }

    @ViewBuilder
    private func detailedMinutesSections(
        _ sections: [DetailedMinutesSection]
    ) -> some View {
        if !sections.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("议题记录")
                    .font(.headline)
                ForEach(Array(sections.enumerated()), id: \.offset) {
                    sectionIndex, section in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            editableDocumentText(
                                field: .detailedMinutesSectionTitle(
                                    sectionIndex
                                ),
                                fallback: section.title,
                                font: .subheadline,
                                fontWeight: .semibold,
                                accessibilityIdentifier:
                                    "meeting.minutes.section.\(sectionIndex).title"
                            )
                            Spacer()
                            if let timeRange = section.timeRange,
                               !timeRange.isEmpty {
                                Text(timeRange)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !section.speakers.isEmpty {
                            HStack(
                                alignment: .firstTextBaseline,
                                spacing: 0
                            ) {
                                Text("发言人：")
                                ForEach(
                                    Array(section.speakers.enumerated()),
                                    id: \.offset
                                ) { speakerIndex, speaker in
                                    if speakerIndex > 0 {
                                        Text("、")
                                    }
                                    editableDocumentText(
                                        field:
                                            .detailedMinutesSectionSpeaker(
                                                section: sectionIndex,
                                                speaker: speakerIndex
                                            ),
                                        fallback: speaker,
                                        font: .caption,
                                        foregroundColor: .secondary,
                                        expandsHorizontally: false,
                                        accessibilityIdentifier:
                                            "meeting.minutes.section.\(sectionIndex).speaker.\(speakerIndex)"
                                    )
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        editableDocumentText(
                            field: .detailedMinutesSectionContent(
                                sectionIndex
                            ),
                            fallback: section.content,
                            accessibilityIdentifier:
                                "meeting.minutes.section.\(sectionIndex).content"
                        )
                    }
                }
            }
        }
    }

    private func selectedGenerateButtonTitle(_ meeting: MeetingRecord) -> String {
        let prefix = hasSelectedDocument(meeting) ? "重新生成" : "生成"
        return prefix + (viewModel.selectedDocumentKind == .summary
            ? "重点总结"
            : "完整纪要")
    }

    private func beginGenerateSelectedDocument(
        replacingManualEdits: Bool
    ) {
        invalidateDocumentOperationTask()
        // The detail view owns this workflow so navigation cancellation reaches
        // the view model and its use case instead of continuing off-screen.
        documentOperationTask = Task { @MainActor [viewModel] in
            await viewModel.generateSelectedDocument(
                replacingManualEdits: replacingManualEdits
            )
        }
    }

    private func beginArchiveSelectedDocumentToNotion() {
        invalidateDocumentOperationTask()
        documentOperationTask = Task { @MainActor [viewModel] in
            await viewModel.archiveSelectedDocumentToNotion()
        }
    }

    private func invalidateDocumentOperationTask() {
        documentOperationTask?.cancel()
        documentOperationTask = nil
    }

    private func invalidateSpeakerDiarizationTask() {
        speakerDiarizationTask?.cancel()
        speakerDiarizationTask = nil
    }

    private func hasSelectedDocument(_ meeting: MeetingRecord) -> Bool {
        switch viewModel.selectedDocumentKind {
        case .summary: meeting.summary != nil
        case .detailedMinutes: meeting.detailedMinutes != nil
        }
    }

    private var selectedDocumentOperationIsActive: Bool {
        switch viewModel.documentOperation {
        case let .generating(kind), let .archiving(kind):
            kind == viewModel.selectedDocumentKind
        case .idle:
            false
        }
    }

    private var selectedArchiveStatusTitle: String {
        if case let .archiving(kind) = viewModel.documentOperation,
           kind == viewModel.selectedDocumentKind {
            return "正在归档"
        }
        return switch viewModel.archiveStatus(
            for: viewModel.selectedDocumentKind
        ) {
        case .localOnly: "仅本地"
        case .archiving: "正在归档"
        case .archived: "已归档"
        case .failed: "归档失败"
        }
    }

    @ViewBuilder
    private var speakerProcessingSection: some View {
        if let statusMessage = viewModel.speakerProcessingStatusMessage {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("meeting.speakerProcessingStatus")
        }

        if let warningMessage = viewModel.speakerProcessingWarningMessage {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "person.2.badge.exclamationmark")
                    .foregroundStyle(.orange)
                Text(warningMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.shouldShowSpeakerDiarizationRetryAction {
                    Button("重新分离说话人") {
                        invalidateSpeakerDiarizationTask()
                        speakerDiarizationTask = Task { @MainActor [viewModel] in
                            await viewModel.retrySpeakerDiarization()
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !viewModel.canRetrySpeakerDiarization
                            || isEditingTitle
                    )
                    .accessibilityIdentifier(
                        "meeting.speakerDiarization.retry"
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Color.orange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .accessibilityIdentifier("meeting.speakerProcessingWarning")
        }

        if let retryError =
            viewModel.speakerDiarizationRetryErrorMessage {
            Text(retryError)
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier(
                    "meeting.speakerDiarization.retryError"
                )
        }
    }

    @ViewBuilder
    private func editableStringList(
        title: String,
        items: [String],
        field: @escaping (Int) -> MeetingEditableDocumentField,
        accessibilityIdentifier: String
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) {
                    index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("• ")
                        editableDocumentText(
                            field: field(index),
                            fallback: item,
                            accessibilityIdentifier:
                                "\(accessibilityIdentifier).\(index)"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func editableActionItems(
        title: String,
        items: [ActionItem],
        taskField: @escaping (Int) -> MeetingEditableDocumentField,
        ownerField: @escaping (Int) -> MeetingEditableDocumentField,
        accessibilityIdentifier: String
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                ForEach(Array(items.enumerated()), id: \.offset) {
                    index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("• ")
                        editableDocumentText(
                            field: taskField(index),
                            fallback: item.task,
                            expandsHorizontally: item.owner == nil
                                && item.dueDate == nil,
                            accessibilityIdentifier:
                                "\(accessibilityIdentifier).\(index).task"
                        )
                        if let owner = item.owner, !owner.isEmpty {
                            Text("｜负责人：")
                            editableDocumentText(
                                field: ownerField(index),
                                fallback: owner,
                                expandsHorizontally: false,
                                accessibilityIdentifier:
                                    "\(accessibilityIdentifier).\(index).owner"
                            )
                        }
                        if let dueDate = item.dueDate, !dueDate.isEmpty {
                            Text("｜截止：\(dueDate)")
                        }
                    }
                }
            }
        }
    }

    private func editableDocumentText(
        field: MeetingEditableDocumentField,
        fallback: String,
        font: Font.TextStyle = .body,
        fontWeight: Font.Weight? = nil,
        foregroundColor: Color = .primary,
        expandsHorizontally: Bool = true,
        accessibilityIdentifier: String
    ) -> some View {
        InlineEditableMeetingText(
            text: Binding(
                get: {
                    viewModel.documentDraftText(field: field) ?? fallback
                },
                set: { value in
                    _ = viewModel.updateDocumentDraftText(
                        value,
                        field: field
                    )
                }
            ),
            font: font,
            fontWeight: fontWeight,
            foregroundColor: foregroundColor,
            accessibilityIdentifier: accessibilityIdentifier,
            onFlush: flushMeetingEdits,
            onRequestExactReplacement: requestExactReplacement
        )
        .frame(
            minWidth: 0,
            maxWidth: expandsHorizontally ? .infinity : nil,
            alignment: .leading
        )
        .layoutPriority(expandsHorizontally ? 1 : 0)
    }

    @ViewBuilder
    private var localSaveStatus: some View {
        switch viewModel.localSaveState {
        case .idle:
            EmptyView()
        case .saving:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("正在保存…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("meeting.edits.saveStatus")
        case .saved:
            Label("已保存到本机", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("meeting.edits.saveStatus")
        case let .failed(message):
            HStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("重试") {
                    Task { @MainActor [viewModel] in
                        await viewModel.retrySavingEdits()
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("meeting.edits.retry")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("meeting.edits.saveStatus")
        }
    }

    private func flushMeetingEdits() {
        Task { @MainActor [viewModel] in
            await viewModel.flushEdits()
        }
    }

    private func requestExactReplacement(_ text: String) {
        viewModel.cancelExactReplacement()
        exactReplacementRequest = MeetingExactReplacementRequest(
            initialSearchText: text
        )
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
        case .summaryReady: "总结完成"
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
