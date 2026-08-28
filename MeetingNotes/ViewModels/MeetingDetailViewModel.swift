import Foundation
import Observation

enum MeetingDetailPrimaryAction: Equatable, Sendable {
    case unavailable
    case unavailableLocal
    case summarizeAndArchive
    case summarizeLocally
    case summarizing
    case archiveToNotion
    case localSummarySaved
    case archiving
    case archived

    var title: String {
        switch self {
        case .unavailable: "总结并同步"
        case .unavailableLocal: "生成总结"
        case .summarizeAndArchive: "总结并同步"
        case .summarizeLocally: "生成总结"
        case .summarizing: "正在总结"
        case .archiveToNotion: "同步到 Notion"
        case .localSummarySaved: "已保存到本机"
        case .archiving: "正在同步"
        case .archived: "已同步"
        }
    }

    var symbolName: String {
        switch self {
        case .unavailable, .unavailableLocal, .summarizeAndArchive,
             .summarizeLocally:
            "sparkles"
        case .summarizing, .archiving: "clock.arrow.circlepath"
        case .archiveToNotion: "square.and.arrow.up"
        case .localSummarySaved, .archived: "checkmark.circle.fill"
        }
    }

    var isEnabled: Bool {
        self == .summarizeAndArchive
            || self == .summarizeLocally
            || self == .archiveToNotion
    }
}

struct MeetingTranscriptEditTarget: Equatable, Sendable {
    let canonicalEntryID: UUID
    let correctionID: UUID?
    let transcriptIDs: [UUID]
    let anchorStartTime: TimeInterval
    let anchorEndTime: TimeInterval
    let source: TranscriptAudioSource
    let originalText: String

    init(
        canonicalEntryID: UUID,
        correctionID: UUID?,
        transcriptIDs: [UUID],
        anchorStartTime: TimeInterval,
        anchorEndTime: TimeInterval,
        source: TranscriptAudioSource,
        originalText: String
    ) {
        self.canonicalEntryID = canonicalEntryID
        self.correctionID = correctionID
        self.transcriptIDs = transcriptIDs
        self.anchorStartTime = anchorStartTime
        self.anchorEndTime = anchorEndTime
        self.source = source
        self.originalText = originalText
    }

    init(entry: CanonicalTranscriptEntry) {
        self.init(
            canonicalEntryID: entry.id,
            correctionID: entry.isManuallyEdited ? entry.id : nil,
            transcriptIDs: entry.transcriptIDs,
            anchorStartTime: entry.startTime,
            anchorEndTime: entry.endTime,
            source: entry.source,
            originalText: entry.text
        )
    }

    init(turn: TranscriptDisplayTurn) {
        self.init(
            canonicalEntryID: turn.canonicalEntryID,
            correctionID: turn.correctionID,
            transcriptIDs: turn.transcriptIDs,
            anchorStartTime: turn.startTime,
            anchorEndTime: turn.endTime,
            source: turn.source,
            originalText: turn.text
        )
    }

    func hasSameDraftIdentity(
        as other: MeetingTranscriptEditTarget
    ) -> Bool {
        switch (correctionID, other.correctionID) {
        case let (lhs?, rhs?):
            lhs == rhs
        case (nil, nil):
            canonicalEntryID == other.canonicalEntryID
        case (_?, nil), (nil, _?):
            false
        }
    }
}

struct MeetingTranscriptEditDraft: Equatable, Sendable {
    let target: MeetingTranscriptEditTarget
    let text: String
}

enum MeetingEditableDocumentField: Hashable, Sendable {
    case summaryOverview
    case summaryKeyPoint(Int)
    case summaryDecision(Int)
    case summaryActionTask(Int)
    case summaryActionOwner(Int)
    case detailedMinutesOverview
    case detailedMinutesSectionTitle(Int)
    case detailedMinutesSectionSpeaker(section: Int, speaker: Int)
    case detailedMinutesSectionContent(Int)
    case detailedMinutesDecision(Int)
    case detailedMinutesActionTask(Int)
    case detailedMinutesActionOwner(Int)
    case detailedMinutesOpenQuestion(Int)
}

@MainActor
@Observable
final class MeetingDetailViewModel {
    let meetingID: UUID
    private let repository: MeetingRepository
    private let settingsStore: AppSettingsStore
    private let action: any SummarizeAndArchiving
    private let documentManager: (any MeetingDocumentManaging)?
    private let titleUpdater: any MeetingTitleUpdating
    private let speakerDiarizationRetryer:
        (any MeetingSpeakerDiarizationRetrying)?
    private let recordingPresentationStore:
        RecordingSessionPresentationStore?
    private let editAutosaver: MeetingEditAutosaver
    private let exactReplacement: MeetingExactReplacement

    private(set) var meeting: MeetingRecord?
    private(set) var summaryDraft: GeneratedMeetingSummary?
    private(set) var detailedMinutesDraft: GeneratedDetailedMinutes?
    private(set) var isPerforming = false
    private(set) var operationState: RecordingState?
    private(set) var errorMessage: String?
    private(set) var isRenaming = false
    private(set) var renameErrorMessage: String?
    private(set) var isRetryingSpeakerDiarization = false
    private(set) var speakerDiarizationRetryErrorMessage: String?
    private(set) var speakerNameErrorMessage: String?
    private(set) var replacementPreview: MeetingExactReplacementPreview?
    private(set) var replacementErrorMessage: String?
    private(set) var notionSyncErrorMessage: String?
    var selectedDocumentKind: MeetingDocumentKind = .summary
    private(set) var documentOperation: MeetingDocumentOperation = .idle
    private var summaryDocumentErrorMessage: String?
    private var detailedMinutesDocumentErrorMessage: String?
    private var dismissedSpeakerProcessingWarningKey: String?
    private var pendingTranscriptDrafts: [PendingTranscriptDraft] = []
    private var summaryDraftToken: UUID?
    private var detailedMinutesDraftToken: UUID?

    init(
        meetingID: UUID,
        repository: MeetingRepository,
        settingsStore: AppSettingsStore,
        action: any SummarizeAndArchiving,
        documentManager: (any MeetingDocumentManaging)? = nil,
        titleUpdater: any MeetingTitleUpdating,
        speakerDiarizationRetryer:
            (any MeetingSpeakerDiarizationRetrying)? = nil,
        recordingPresentationStore:
            RecordingSessionPresentationStore? = nil,
        editAutosaver: MeetingEditAutosaver? = nil,
        exactReplacement: MeetingExactReplacement? = nil
    ) {
        self.meetingID = meetingID
        self.repository = repository
        self.settingsStore = settingsStore
        self.action = action
        self.documentManager = documentManager
        self.titleUpdater = titleUpdater
        self.speakerDiarizationRetryer = speakerDiarizationRetryer
        self.recordingPresentationStore = recordingPresentationStore
        self.editAutosaver = editAutosaver ?? MeetingEditAutosaver()
        self.exactReplacement = exactReplacement
            ?? MeetingExactReplacement(repository: repository)
        meeting = try? repository.meeting(id: meetingID)
        synchronizeCleanDocumentDrafts()
    }

    var transcriptDrafts: [MeetingTranscriptEditDraft] {
        pendingTranscriptDrafts.map(\.draft)
    }

    var localSaveState: MeetingLocalSaveState {
        editAutosaver.state
    }

    var hasPendingEdits: Bool {
        !pendingTranscriptDrafts.isEmpty
            || summaryDraftToken != nil
            || detailedMinutesDraftToken != nil
    }

    func displayedActiveDuration(
        at monotonicTime: TimeInterval
    ) -> TimeInterval {
        recordingPresentationStore?.activeDuration(
            for: meetingID,
            at: monotonicTime
        ) ?? meeting?.activeDuration ?? 0
    }

    var primaryAction: MeetingDetailPrimaryAction {
        guard let state = meeting?.state else {
            return .unavailableLocal
        }
        if isPerforming {
            return switch operationState ?? state {
            case .summaryReady:
                .localSummarySaved
            case .archiving:
                .archiving
            case .archived:
                .localSummarySaved
            default:
                .summarizing
            }
        }
        return switch state {
        case .ready:
            .summarizeLocally
        case .summarizing: .summarizing
        case .summaryReady:
            .localSummarySaved
        case .archiving: .archiving
        case .archived: .localSummarySaved
        default:
            .unavailableLocal
        }
    }

    var isNotionArchivingEnabled: Bool {
        settingsStore.isNotionArchivingEnabled
    }

    var canGenerateSelectedDocument: Bool {
        guard documentManager != nil,
              documentOperation == .idle,
              !isPerforming,
              !isRenaming,
              !isRetryingSpeakerDiarization,
              let meeting else {
            return false
        }
        let state = meeting.state
        let isStable = state == .ready
            || state == .summaryReady
            || state == .archived
        return isStable
            && !MeetingDocumentInputBuilder.inputs(for: meeting).transcripts
                .isEmpty
    }

    var selectedDocumentArchiveButtonTitle: String? {
        notionSyncButtonTitle
    }

    var canArchiveSelectedDocumentToNotion: Bool {
        canSyncMeetingToNotion
    }

    var notionSyncButtonTitle: String? {
        guard isNotionArchivingEnabled, hasAnyLocalDocument else {
            return nil
        }
        return "同步到 Notion"
    }

    var notionSyncStatusTitle: String? {
        guard notionSyncButtonTitle != nil, let meeting else { return nil }
        if documentOperation == .syncingNotion
            || meeting.notionSyncState == .syncing {
            return "正在同步"
        }
        if meeting.notionSyncState == .failed {
            return "同步失败"
        }
        if meeting.notionSyncState == .synced,
           meeting.notionSyncedContentRevision == meeting.contentRevision {
            return "已同步"
        }
        if let syncedRevision = meeting.notionSyncedContentRevision,
           syncedRevision < meeting.contentRevision {
            return "有本地更改待同步"
        }
        return "尚未同步"
    }

    var canSyncMeetingToNotion: Bool {
        guard documentManager != nil,
              notionSyncButtonTitle != nil,
              canStartDocumentOperation,
              meeting?.notionSyncState != .syncing,
              let state = meeting?.state else {
            return false
        }
        return state == .ready
            || state == .summaryReady
            || state == .archived
    }

    var isDocumentOperationInProgress: Bool {
        documentOperation != .idle
    }

    func archiveStatus(
        for kind: MeetingDocumentKind
    ) -> MeetingDocumentArchiveState {
        switch kind {
        case .summary:
            meeting?.summary?.archiveState ?? .localOnly
        case .detailedMinutes:
            meeting?.detailedMinutes?.archiveState ?? .localOnly
        }
    }

    func documentErrorMessage(for kind: MeetingDocumentKind) -> String? {
        switch kind {
        case .summary: summaryDocumentErrorMessage
        case .detailedMinutes: detailedMinutesDocumentErrorMessage
        }
    }

    func dismissDocumentError(for kind: MeetingDocumentKind) {
        setDocumentErrorMessage(nil, for: kind)
    }

    var selectedDocumentRequiresRegenerationConfirmation: Bool {
        switch selectedDocumentKind {
        case .summary:
            summaryDraftToken != nil
                || meeting?.summary?.isManuallyEdited == true
        case .detailedMinutes:
            detailedMinutesDraftToken != nil
                || meeting?.detailedMinutes?.isManuallyEdited == true
        }
    }

    func generateSelectedDocument(
        replacingManualEdits: Bool = false
    ) async {
        guard replacingManualEdits
                || !selectedDocumentRequiresRegenerationConfirmation else {
            return
        }
        if hasPendingEdits {
            await flushEdits()
            guard !hasPendingEdits else {
                setDocumentErrorMessage(
                    "本地修改尚未安全保存，请重试后再重新生成。",
                    for: selectedDocumentKind
                )
                return
            }
        }
        guard canGenerateSelectedDocument,
              let documentManager else { return }
        let kind = selectedDocumentKind
        documentOperation = .generating(kind)
        setDocumentErrorMessage(nil, for: kind)
        defer { documentOperation = .idle }

        do {
            if replacingManualEdits {
                try await documentManager.generate(
                    meetingID: meetingID,
                    kind: kind,
                    replacingManualEdits: true
                )
            } else {
                try await documentManager.generate(
                    meetingID: meetingID,
                    kind: kind
                ) { [weak self] operation in
                    self?.documentOperation = operation
                    if case .archiving = operation {
                        self?.load()
                    }
                }
            }
        } catch where Self.isCancellation(error) {
            // Cancellation leaves the previous visible document intact.
        } catch {
            setDocumentErrorMessage(Self.documentMessage(for: error), for: kind)
        }
        load()
    }

    func archiveSelectedDocumentToNotion() async {
        await syncMeetingToNotion()
    }

    func syncMeetingToNotion() async {
        if hasPendingEdits {
            await flushEdits()
            guard !hasPendingEdits else {
                notionSyncErrorMessage =
                    "本地修改尚未安全保存，请重试后再同步到 Notion。"
                return
            }
        }
        guard canSyncMeetingToNotion,
              let documentManager else { return }
        documentOperation = .syncingNotion
        notionSyncErrorMessage = nil
        defer { documentOperation = .idle }

        do {
            try await documentManager.syncToNotion(
                meetingID: meetingID
            ) { [weak self] operation in
                self?.documentOperation = operation
            }
        } catch where Self.isCancellation(error) {
            // Cancellation restores the persisted meeting-level sync state.
        } catch {
            notionSyncErrorMessage = Self.documentMessage(for: error)
        }
        load()
    }

    var speakerProcessingState: SpeakerProcessingState {
        meeting?.speakerProcessingState ?? .notRequested
    }

    var speakerDisplayNames: [String: String] {
        meeting?.speakerDisplayNames ?? [:]
    }

    var frequentSpeakerNames: [String] {
        settingsStore.frequentSpeakerNames
    }

    @discardableResult
    func renameSpeaker(_ speakerID: String, to displayName: String) -> Bool {
        guard let normalizedName = AppSettingsStore.normalizedSpeakerNames(
            [displayName]
        ).first else {
            speakerNameErrorMessage = "请输入 1 到 40 个字符的名称。"
            return false
        }

        speakerNameErrorMessage = nil
        do {
            try repository.setSpeakerDisplayName(
                meetingID: meetingID,
                speakerID: speakerID,
                displayName: normalizedName
            )
            settingsStore.rememberSpeakerName(normalizedName)
            load()
            return true
        } catch let error as SpeakerNameRepositoryError {
            speakerNameErrorMessage = switch error {
            case .invalidDisplayName:
                "请输入 1 到 40 个字符的名称。"
            case .speakerNotFound:
                "找不到这个说话人，请重新分离后再试。"
            }
            return false
        } catch {
            speakerNameErrorMessage = "无法保存说话人名称，请稍后重试。"
            return false
        }
    }

    @discardableResult
    func clearSpeakerName(_ speakerID: String) -> Bool {
        speakerNameErrorMessage = nil
        do {
            try repository.clearSpeakerDisplayName(
                meetingID: meetingID,
                speakerID: speakerID
            )
            load()
            return true
        } catch {
            speakerNameErrorMessage = "无法恢复默认名称，请稍后重试。"
            return false
        }
    }

    func dismissSpeakerNameError() {
        speakerNameErrorMessage = nil
    }

    func transcriptDraftText(
        for entry: CanonicalTranscriptEntry
    ) -> String {
        transcriptDraftText(for: MeetingTranscriptEditTarget(entry: entry))
    }

    func transcriptDraftText(
        for target: MeetingTranscriptEditTarget
    ) -> String {
        pendingTranscriptDrafts.first {
            $0.draft.target.hasSameDraftIdentity(as: target)
        }?
            .draft.text ?? target.originalText
    }

    func updateTranscriptDraft(
        _ text: String,
        for entry: CanonicalTranscriptEntry
    ) {
        updateTranscriptDraft(
            text,
            for: MeetingTranscriptEditTarget(entry: entry)
        )
    }

    func updateTranscriptDraft(
        _ text: String,
        for target: MeetingTranscriptEditTarget
    ) {
        if text == target.originalText {
            pendingTranscriptDrafts.removeAll {
                $0.draft.target.hasSameDraftIdentity(as: target)
            }
        } else if let index = pendingTranscriptDrafts.firstIndex(where: {
            $0.draft.target.hasSameDraftIdentity(as: target)
        }) {
            let existingTarget = pendingTranscriptDrafts[index].draft.target
            pendingTranscriptDrafts[index] = PendingTranscriptDraft(
                draft: MeetingTranscriptEditDraft(
                    target: existingTarget,
                    text: text
                ),
                token: UUID()
            )
        } else {
            pendingTranscriptDrafts.append(
                PendingTranscriptDraft(
                    draft: MeetingTranscriptEditDraft(
                        target: target,
                        text: text
                    ),
                    token: UUID()
                )
            )
        }
        reschedulePendingEdits()
    }

    func updateSummaryDraft(_ value: GeneratedMeetingSummary) {
        summaryDraft = value
        if value == persistedSummaryValue {
            summaryDraftToken = nil
        } else {
            summaryDraftToken = UUID()
        }
        reschedulePendingEdits()
    }

    func updateDetailedMinutesDraft(_ value: GeneratedDetailedMinutes) {
        detailedMinutesDraft = value
        if value == persistedDetailedMinutesValue {
            detailedMinutesDraftToken = nil
        } else {
            detailedMinutesDraftToken = UUID()
        }
        reschedulePendingEdits()
    }

    func documentDraftText(
        field: MeetingEditableDocumentField
    ) -> String? {
        switch field {
        case .summaryOverview:
            summaryDraft?.overview
        case let .summaryKeyPoint(index):
            summaryDraft?.keyPoints[safe: index]
        case let .summaryDecision(index):
            summaryDraft?.decisions[safe: index]
        case let .summaryActionTask(index):
            summaryDraft?.actionItems[safe: index]?.task
        case let .summaryActionOwner(index):
            summaryDraft?.actionItems[safe: index]?.owner
        case .detailedMinutesOverview:
            detailedMinutesDraft?.overview
        case let .detailedMinutesSectionTitle(index):
            detailedMinutesDraft?.sections[safe: index]?.title
        case let .detailedMinutesSectionSpeaker(section, speaker):
            detailedMinutesDraft?.sections[safe: section]?
                .speakers[safe: speaker]
        case let .detailedMinutesSectionContent(index):
            detailedMinutesDraft?.sections[safe: index]?.content
        case let .detailedMinutesDecision(index):
            detailedMinutesDraft?.decisions[safe: index]
        case let .detailedMinutesActionTask(index):
            detailedMinutesDraft?.actionItems[safe: index]?.task
        case let .detailedMinutesActionOwner(index):
            detailedMinutesDraft?.actionItems[safe: index]?.owner
        case let .detailedMinutesOpenQuestion(index):
            detailedMinutesDraft?.openQuestions[safe: index]
        }
    }

    @discardableResult
    func updateDocumentDraftText(
        _ text: String,
        field: MeetingEditableDocumentField
    ) -> Bool {
        switch field {
        case .summaryOverview:
            guard let summaryDraft else { return false }
            updateSummaryDraft(
                summaryDraft.replacing(overview: text)
            )
        case let .summaryKeyPoint(index):
            guard let summaryDraft,
                  let keyPoints = summaryDraft.keyPoints.replacing(
                      at: index,
                      with: text
                  ) else { return false }
            updateSummaryDraft(summaryDraft.replacing(keyPoints: keyPoints))
        case let .summaryDecision(index):
            guard let summaryDraft,
                  let decisions = summaryDraft.decisions.replacing(
                      at: index,
                      with: text
                  ) else { return false }
            updateSummaryDraft(summaryDraft.replacing(decisions: decisions))
        case let .summaryActionTask(index):
            guard let summaryDraft,
                  let actionItems = summaryDraft.actionItems.replacingAction(
                      at: index,
                      task: text
                  ) else { return false }
            updateSummaryDraft(
                summaryDraft.replacing(actionItems: actionItems)
            )
        case let .summaryActionOwner(index):
            guard let summaryDraft,
                  let actionItems = summaryDraft.actionItems.replacingAction(
                      at: index,
                      owner: text
                  ) else { return false }
            updateSummaryDraft(
                summaryDraft.replacing(actionItems: actionItems)
            )
        case .detailedMinutesOverview:
            guard let detailedMinutesDraft else { return false }
            updateDetailedMinutesDraft(
                detailedMinutesDraft.replacing(overview: text)
            )
        case let .detailedMinutesSectionTitle(index):
            guard let detailedMinutesDraft,
                  let sections = detailedMinutesDraft.sections
                    .replacingSection(at: index, title: text) else {
                return false
            }
            updateDetailedMinutesDraft(
                detailedMinutesDraft.replacing(sections: sections)
            )
        case let .detailedMinutesSectionSpeaker(section, speaker):
            guard let detailedMinutesDraft,
                  let sections = detailedMinutesDraft.sections
                    .replacingSectionSpeaker(
                        section: section,
                        speaker: speaker,
                        with: text
                    ) else { return false }
            updateDetailedMinutesDraft(
                detailedMinutesDraft.replacing(sections: sections)
            )
        case let .detailedMinutesSectionContent(index):
            guard let detailedMinutesDraft,
                  let sections = detailedMinutesDraft.sections
                    .replacingSection(at: index, content: text) else {
                return false
            }
            updateDetailedMinutesDraft(
                detailedMinutesDraft.replacing(sections: sections)
            )
        case let .detailedMinutesDecision(index):
            guard let detailedMinutesDraft,
                  let decisions = detailedMinutesDraft.decisions.replacing(
                      at: index,
                      with: text
                  ) else { return false }
            updateDetailedMinutesDraft(
                detailedMinutesDraft.replacing(decisions: decisions)
            )
        case let .detailedMinutesActionTask(index):
            guard let detailedMinutesDraft,
                  let actionItems = detailedMinutesDraft.actionItems
                    .replacingAction(at: index, task: text) else {
                return false
            }
            updateDetailedMinutesDraft(
                detailedMinutesDraft.replacing(actionItems: actionItems)
            )
        case let .detailedMinutesActionOwner(index):
            guard let detailedMinutesDraft,
                  let actionItems = detailedMinutesDraft.actionItems
                    .replacingAction(at: index, owner: text) else {
                return false
            }
            updateDetailedMinutesDraft(
                detailedMinutesDraft.replacing(actionItems: actionItems)
            )
        case let .detailedMinutesOpenQuestion(index):
            guard let detailedMinutesDraft,
                  let openQuestions = detailedMinutesDraft.openQuestions
                    .replacing(at: index, with: text) else {
                return false
            }
            updateDetailedMinutesDraft(
                detailedMinutesDraft.replacing(openQuestions: openQuestions)
            )
        }
        return true
    }

    func prepareExactReplacement(
        searchText: String,
        replacementText: String
    ) async {
        replacementErrorMessage = nil
        if hasPendingEdits {
            await flushEdits()
            guard !hasPendingEdits else {
                replacementPreview = nil
                replacementErrorMessage =
                    "本地修改尚未安全保存，请重试后再替换。"
                return
            }
        }
        do {
            replacementPreview = try exactReplacement.preview(
                meetingID: meetingID,
                old: searchText,
                new: replacementText
            )
        } catch {
            replacementPreview = nil
            replacementErrorMessage = Self.replacementMessage(for: error)
        }
    }

    func cancelExactReplacement() {
        replacementPreview = nil
        replacementErrorMessage = nil
    }

    @discardableResult
    func confirmExactReplacement() async -> Bool {
        guard let confirmedPreview = replacementPreview,
              confirmedPreview.totalMatches > 0 else {
            return false
        }
        do {
            _ = try exactReplacement.apply(confirmedPreview)
            replacementPreview = nil
            replacementErrorMessage = nil
            load()
            return true
        } catch let error as MeetingExactReplacementError {
            switch error {
            case .stalePreview:
                do {
                    replacementPreview = try exactReplacement.preview(
                        meetingID: meetingID,
                        old: confirmedPreview.searchText,
                        new: confirmedPreview.replacementText
                    )
                    replacementErrorMessage =
                        "会议内容已变化，请确认更新后的替换范围。"
                } catch {
                    replacementPreview = nil
                    replacementErrorMessage = Self.replacementMessage(
                        for: error
                    )
                }
            default:
                replacementErrorMessage = Self.replacementMessage(for: error)
            }
            return false
        } catch {
            replacementErrorMessage = Self.replacementMessage(for: error)
            return false
        }
    }

    func flushEdits() async {
        await editAutosaver.flush()
    }

    func retrySavingEdits() async {
        await editAutosaver.retry()
    }

    var speakerProcessingStatusMessage: String? {
        if isRetryingSpeakerDiarization {
            return "正在重新分离说话人…"
        }
        if isInterruptedSpeakerDiarizationRetry {
            return nil
        }
        return switch speakerProcessingState {
        case .pending:
            "正在准备说话人区分…"
        case .processing:
            "正在区分不同说话人…"
        case .notRequested, .completed, .degraded:
            nil
        }
    }

    var speakerProcessingWarningMessage: String? {
        guard (speakerProcessingState == .degraded
                || isInterruptedSpeakerDiarizationRetry),
              speakerProcessingWarningKey
                != dismissedSpeakerProcessingWarningKey else {
            return nil
        }
        let errorCode = meeting?.speakerProcessingErrorCode
        if errorCode == SpeakerDiarizationRetryUseCase.sourceUnavailableCode {
            if meeting?.mode == .online {
                return "原始分轨录音仍可用于重建，请重新分离说话人。"
            }
            return "该会议缺少可用录音，无法重新分离说话人。"
        }
        if errorCode == SpeakerDiarizationRetryUseCase
            .transcriptUnavailableCode {
            if meeting?.mode == .online {
                return "没有现成转录，可从原始分轨重新生成并分离说话人。"
            }
            return "该会议没有可用的最终转录，无法重新分离说话人。"
        }
        if isInterruptedSpeakerDiarizationRetry {
            return "上次说话人分离被中断，可重新尝试。"
        }
        if errorCode == SpeakerAwareTranscriptFinalizer
            .diarizationModelPreparationFailedCode {
            return "说话人模型未准备好，请检查网络后重试。"
        }
        if errorCode == SpeakerAwareTranscriptFinalizer
            .diarizationInvalidSourceCode {
            return "录音源不可用或已损坏，无法区分说话人。"
        }
        if errorCode == SpeakerAwareTranscriptFinalizer
            .diarizationTimelineAssemblyFailedCode {
            return "录音时间轴无法组装，请稍后重试。"
        }
        if errorCode == SpeakerAwareTranscriptFinalizer
            .diarizationConversionFailedCode {
            return "录音转换失败，请稍后重试。"
        }
        if errorCode == SpeakerAwareTranscriptFinalizer
            .diarizationInferenceFailedCode {
            return "说话人识别运行失败，请稍后重试。"
        }
        if errorCode == SpeakerAwareTranscriptFinalizer
            .diarizationResultValidationFailedCode {
            return "说话人识别结果无效，请稍后重试。"
        }
        if errorCode == SpeakerDiarizationRetryUseCase.cancelledCode {
            return "说话人分离已取消，原有转录已保留。"
        }
        if errorCode?.hasPrefix("source_track_") == true {
            return "部分分轨处理失败，已使用可用录音和转录，不影响播放、总结与同步。"
        }
        if errorCode?.hasPrefix("speaker_diarization_") == true {
            return "说话人区分未完成，已保留可用转录，不影响播放、总结与同步。"
        }
        if errorCode == "speaker_transcript_replacement_failed" {
            return "说话人标记未能保存，已保留普通转录，不影响播放、总结与同步。"
        }
        return "说话人处理未完成，已使用普通转录，不影响播放、总结与同步。"
    }

    var shouldShowSpeakerDiarizationRetryAction: Bool {
        guard speakerDiarizationRetryer != nil,
              !isRetryingSpeakerDiarization else {
            return false
        }
        let errorCode = meeting?.speakerProcessingErrorCode
        if errorCode == SpeakerDiarizationRetryUseCase
            .sourceUnavailableCode
            || errorCode == SpeakerDiarizationRetryUseCase
                .transcriptUnavailableCode {
            return meeting?.mode == .online
                && speakerProcessingState == .degraded
        }
        return speakerProcessingState == .degraded
            || isInterruptedSpeakerDiarizationRetry
    }

    var canRetrySpeakerDiarization: Bool {
        shouldShowSpeakerDiarizationRetryAction
            && !isPerforming
            && !isRenaming
            && documentOperation == .idle
    }

    func load() {
        do {
            meeting = try repository.meeting(id: meetingID)
            reconcilePendingTranscriptDrafts()
            synchronizeCleanDocumentDrafts()
        } catch {
            meeting = nil
            errorMessage = "无法加载会议详情。"
        }
    }

    func refreshWhileRecording(
        interval: Duration = .milliseconds(400)
    ) async {
        load()
        while !Task.isCancelled, isRecordingActive {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            load()
        }
    }

    func performPrimaryAction() async {
        guard primaryAction.isEnabled,
              !isPerforming,
              !isRenaming,
              !isRetryingSpeakerDiarization,
              documentOperation == .idle else {
            return
        }
        isPerforming = true
        operationState = meeting?.state
        errorMessage = nil
        defer {
            isPerforming = false
            operationState = nil
        }

        do {
            try await action.execute(meetingID: meetingID) { [weak self] state in
                self?.operationState = state
            }
        } catch {
            errorMessage = Self.message(for: error)
        }
        load()
    }

    func dismissError() {
        errorMessage = nil
    }

    func rename(to title: String) async -> Bool {
        guard !isRenaming,
              !isPerforming,
              !isRetryingSpeakerDiarization,
              documentOperation == .idle else { return false }
        isRenaming = true
        renameErrorMessage = nil
        defer { isRenaming = false }

        do {
            try await titleUpdater.updateTitle(
                meetingID: meetingID,
                title: title
            )
            load()
            return true
        } catch is CancellationError {
            return false
        } catch let error as MeetingTitleUpdateError {
            renameErrorMessage = error.userMessage
            return false
        } catch {
            renameErrorMessage = "无法重命名会议，请稍后重试。"
            return false
        }
    }

    func dismissRenameError() {
        renameErrorMessage = nil
    }

    func dismissSpeakerProcessingWarning() {
        dismissedSpeakerProcessingWarningKey = speakerProcessingWarningKey
    }

    func retrySpeakerDiarization() async {
        guard canRetrySpeakerDiarization,
              let speakerDiarizationRetryer else {
            return
        }
        isRetryingSpeakerDiarization = true
        speakerDiarizationRetryErrorMessage = nil
        dismissedSpeakerProcessingWarningKey = nil
        defer { isRetryingSpeakerDiarization = false }

        do {
            try await speakerDiarizationRetryer.retry(meetingID: meetingID)
        } catch is CancellationError {
            // Cancellation is reflected by the persisted speaker state.
        } catch let error as SpeakerDiarizationRetryError {
            speakerDiarizationRetryErrorMessage = Self.retryMessage(for: error)
        } catch {
            speakerDiarizationRetryErrorMessage =
                "说话人分离重试失败，原有转录已保留。"
        }
        load()
    }

    private var isRecordingActive: Bool {
        guard let state = meeting?.state else { return false }
        return state == .recording || state == .paused
    }

    private var persistedSummaryValue: GeneratedMeetingSummary? {
        guard let meeting,
              let summary = meeting.summary else {
            return nil
        }
        return GeneratedMeetingSummary(
            suggestedTitle: meeting.suggestedTitle ?? "",
            overview: summary.overview,
            keyPoints: summary.keyPoints,
            decisions: summary.decisions,
            actionItems: summary.actionItemRecords,
            bookmarkInsights: summary.bookmarkInsights
        )
    }

    private var persistedDetailedMinutesValue: GeneratedDetailedMinutes? {
        guard let minutes = meeting?.detailedMinutes,
              let sections = try? minutes.sections,
              let decisions = try? minutes.decisions,
              let actionItems = try? minutes.actionItems,
              let openQuestions = try? minutes.openQuestions else {
            return nil
        }
        return GeneratedDetailedMinutes(
            overview: minutes.overview,
            sections: sections,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions
        )
    }

    private func synchronizeCleanDocumentDrafts() {
        if summaryDraftToken == nil {
            summaryDraft = persistedSummaryValue
        }
        if detailedMinutesDraftToken == nil {
            detailedMinutesDraft = persistedDetailedMinutesValue
        }
    }

    private func reconcilePendingTranscriptDrafts() {
        guard !pendingTranscriptDrafts.isEmpty,
              let canonical = try? repository.canonicalTranscripts(
                  meetingID: meetingID
              ) else {
            return
        }

        for index in pendingTranscriptDrafts.indices {
            let pending = pendingTranscriptDrafts[index]
            let target = pending.draft.target
            let currentEntry: CanonicalTranscriptEntry?
            if let correctionID = target.correctionID {
                currentEntry = canonical.first {
                    $0.isManuallyEdited && $0.id == correctionID
                }
            } else {
                let currentGeneratedIDs = Set(
                    canonical
                        .filter { !$0.isManuallyEdited }
                        .flatMap(\.transcriptIDs)
                )
                if !target.transcriptIDs.isEmpty,
                   target.transcriptIDs.allSatisfy(
                       currentGeneratedIDs.contains
                   ) {
                    // A displayed turn can own multiple generated rows. Keep
                    // that exact editing scope while every row still exists;
                    // selecting only its first canonical entry would persist
                    // the combined draft over one row and duplicate the rest.
                    continue
                }
                currentEntry = try? repository
                    .reconciledTranscriptCorrectionTarget(
                        meetingID: meetingID,
                        transcriptIDs: target.transcriptIDs,
                        anchorStartTime: target.anchorStartTime,
                        anchorEndTime: target.anchorEndTime,
                        source: target.source
                    )
            }
            guard let currentEntry else { continue }
            pendingTranscriptDrafts[index] = PendingTranscriptDraft(
                draft: MeetingTranscriptEditDraft(
                    target: MeetingTranscriptEditTarget(entry: currentEntry),
                    text: pending.draft.text
                ),
                token: pending.token
            )
        }
    }

    private func reschedulePendingEdits() {
        guard hasPendingEdits else {
            editAutosaver.cancel()
            return
        }
        editAutosaver.schedule { [weak self] in
            try self?.persistPendingEdits()
        }
    }

    private func persistPendingEdits() throws {
        let transcriptSnapshots = pendingTranscriptDrafts
        let summarySnapshot = summaryDraftToken.flatMap { token in
            summaryDraft.map { (token: token, value: $0) }
        }
        let detailedMinutesSnapshot = detailedMinutesDraftToken.flatMap {
            token in
            detailedMinutesDraft.map { (token: token, value: $0) }
        }

        for snapshot in transcriptSnapshots {
            let target = snapshot.draft.target
            guard pendingTranscriptDrafts.contains(where: {
                $0.token == snapshot.token
            }) else {
                continue
            }
            if let correctionID = target.correctionID {
                try repository.updateTranscriptCorrection(
                    meetingID: meetingID,
                    correctionID: correctionID,
                    replacementText: snapshot.draft.text
                )
            } else {
                try repository.saveTranscriptCorrection(
                    meetingID: meetingID,
                    transcriptIDs: target.transcriptIDs,
                    anchorStartTime: target.anchorStartTime,
                    anchorEndTime: target.anchorEndTime,
                    source: target.source,
                    originalText: target.originalText,
                    replacementText: snapshot.draft.text
                )
            }
            pendingTranscriptDrafts.removeAll {
                $0.token == snapshot.token
            }
        }

        if let summarySnapshot,
           summaryDraftToken == summarySnapshot.token {
            try repository.updateSummaryManually(
                meetingID: meetingID,
                value: summarySnapshot.value
            )
            if summaryDraftToken == summarySnapshot.token {
                summaryDraftToken = nil
            }
        }

        if let detailedMinutesSnapshot,
           detailedMinutesDraftToken == detailedMinutesSnapshot.token {
            try repository.updateDetailedMinutesManually(
                meetingID: meetingID,
                value: detailedMinutesSnapshot.value
            )
            if detailedMinutesDraftToken == detailedMinutesSnapshot.token {
                detailedMinutesDraftToken = nil
            }
        }

        meeting = try? repository.meeting(id: meetingID)
        synchronizeCleanDocumentDrafts()
    }

    private struct PendingTranscriptDraft {
        let draft: MeetingTranscriptEditDraft
        let token: UUID
    }

    private var canStartDocumentOperation: Bool {
        documentOperation == .idle
            && !isPerforming
            && !isRenaming
            && !isRetryingSpeakerDiarization
    }

    private var hasSelectedDocument: Bool {
        switch selectedDocumentKind {
        case .summary:
            meeting?.summary != nil
        case .detailedMinutes:
            meeting?.detailedMinutes != nil
        }
    }

    private var hasAnyLocalDocument: Bool {
        meeting?.summary != nil || meeting?.detailedMinutes != nil
    }

    private func setDocumentErrorMessage(
        _ message: String?,
        for kind: MeetingDocumentKind
    ) {
        switch kind {
        case .summary:
            summaryDocumentErrorMessage = message
        case .detailedMinutes:
            detailedMinutesDocumentErrorMessage = message
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
    }

    private static func replacementMessage(for error: Error) -> String {
        switch error as? MeetingExactReplacementError {
        case .emptySearchText:
            "请输入要替换的文字。"
        case .identicalSearchAndReplacement:
            "新旧文字相同，无需替换。"
        case .stalePreview:
            "会议内容已变化，请重新预览替换范围。"
        case .invalidStructuredField:
            "会议内容无法安全替换，请重试。"
        case nil:
            "无法替换本会议文字，请重试。"
        }
    }

    private static func documentMessage(for error: Error) -> String {
        switch error as? MeetingDocumentsError {
        case .noFinalTranscript:
            "没有可用的最终转录，暂时无法生成。"
        case .missingDeepSeekCredential:
            "请先在设置中保存 DeepSeek API Key。"
        case .missingNotionCredential:
            "内容已保存在本机。请在设置中保存 Notion Token 后重试同步。"
        case .invalidNotionPageURL:
            "内容已保存在本机。请在设置中填写有效的 Notion 父页面链接。"
        case .missingLocalDocument:
            "找不到本地内容，请重新生成。"
        case .invalidGeneratedDocument, .generationFailed:
            "DeepSeek 生成失败，原有内容仍保存在本机，请稍后重试。"
        case .archiveFailed:
            "Notion 同步失败，新内容已保存在本机，可直接重试同步。"
        case .localPersistenceFailed:
            "无法保存本地内容，请检查磁盘空间后重试。"
        case .operationInProgress:
            "会议正在处理中，请稍候。"
        case .invalidState:
            "当前会议状态不能执行该操作。"
        case nil:
            "操作失败，请稍后重试。"
        }
    }

    private var isInterruptedSpeakerDiarizationRetry: Bool {
        speakerProcessingState == .processing
            && meeting?.state
                .allowsInterruptedSpeakerDiarizationRetryRecovery == true
            && !isRetryingSpeakerDiarization
    }

    private var speakerProcessingWarningKey: String {
        meeting?.speakerProcessingErrorCode ?? "speaker_processing_unknown"
    }

    private static func message(for error: Error) -> String {
        switch error as? SummarizeAndArchiveError {
        case .noFinalTranscript:
            "没有可用的最终转录，暂时无法总结。"
        case .missingDeepSeekCredential:
            "请先在设置中保存 DeepSeek API Key。"
        case .missingNotionCredential:
            "总结已保存在本机。请在设置中保存 Notion Token 后重试同步。"
        case .invalidNotionPageURL:
            "总结已保存在本机。请在设置中填写有效的 Notion 父页面链接。"
        case .summaryFailed:
            "DeepSeek 总结失败，会议记录仍保存在本机，请稍后重试。"
        case .archiveFailed:
            "Notion 同步失败，可直接重试，不会再次生成总结。"
        case .localPersistenceFailed:
            "无法保存本地总结，请检查磁盘空间后重试。"
        case .operationInProgress:
            "会议正在处理中，请稍候。"
        case .missingLocalSummary:
            "找不到本地总结，请重新生成。"
        case .invalidState:
            "当前会议状态不能执行该操作。"
        case nil:
            "操作失败，请稍后重试。"
        }
    }

    private static func retryMessage(
        for error: SpeakerDiarizationRetryError
    ) -> String? {
        switch error {
        case .operationInProgress:
            "会议正在处理中，请稍候。"
        case .invalidState:
            "当前状态不能重新分离说话人。"
        case .noFinalTranscript:
            "没有可用的最终转录，无法重新分离说话人。"
        case .sourceUnavailable:
            nil
        case .failed:
            nil
        }
    }
}

private extension Collection {
    subscript(safe offset: Int) -> Element? {
        guard offset >= 0,
              let index = index(startIndex, offsetBy: offset, limitedBy: endIndex),
              index != endIndex else {
            return nil
        }
        return self[index]
    }
}

private extension Array {
    func replacing(at index: Int, with value: Element) -> [Element]? {
        guard indices.contains(index) else { return nil }
        var copy = self
        copy[index] = value
        return copy
    }
}

private extension GeneratedMeetingSummary {
    func replacing(overview: String) -> GeneratedMeetingSummary {
        GeneratedMeetingSummary(
            suggestedTitle: suggestedTitle,
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            bookmarkInsights: bookmarkInsights
        )
    }

    func replacing(keyPoints: [String]) -> GeneratedMeetingSummary {
        GeneratedMeetingSummary(
            suggestedTitle: suggestedTitle,
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            bookmarkInsights: bookmarkInsights
        )
    }

    func replacing(decisions: [String]) -> GeneratedMeetingSummary {
        GeneratedMeetingSummary(
            suggestedTitle: suggestedTitle,
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            bookmarkInsights: bookmarkInsights
        )
    }

    func replacing(actionItems: [ActionItem]) -> GeneratedMeetingSummary {
        GeneratedMeetingSummary(
            suggestedTitle: suggestedTitle,
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            actionItems: actionItems,
            bookmarkInsights: bookmarkInsights
        )
    }
}

private extension GeneratedDetailedMinutes {
    func replacing(overview: String) -> GeneratedDetailedMinutes {
        GeneratedDetailedMinutes(
            overview: overview,
            sections: sections,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions
        )
    }

    func replacing(
        sections: [DetailedMinutesSection]
    ) -> GeneratedDetailedMinutes {
        GeneratedDetailedMinutes(
            overview: overview,
            sections: sections,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions
        )
    }

    func replacing(decisions: [String]) -> GeneratedDetailedMinutes {
        GeneratedDetailedMinutes(
            overview: overview,
            sections: sections,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions
        )
    }

    func replacing(actionItems: [ActionItem]) -> GeneratedDetailedMinutes {
        GeneratedDetailedMinutes(
            overview: overview,
            sections: sections,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions
        )
    }

    func replacing(openQuestions: [String]) -> GeneratedDetailedMinutes {
        GeneratedDetailedMinutes(
            overview: overview,
            sections: sections,
            decisions: decisions,
            actionItems: actionItems,
            openQuestions: openQuestions
        )
    }
}

private extension Array where Element == ActionItem {
    func replacingAction(at index: Int, task: String) -> [ActionItem]? {
        guard let item = self[safe: index] else { return nil }
        return replacing(
            at: index,
            with: ActionItem(
                task: task,
                owner: item.owner,
                dueDate: item.dueDate
            )
        )
    }

    func replacingAction(at index: Int, owner: String) -> [ActionItem]? {
        guard let item = self[safe: index] else { return nil }
        return replacing(
            at: index,
            with: ActionItem(
                task: item.task,
                owner: owner,
                dueDate: item.dueDate
            )
        )
    }
}

private extension Array where Element == DetailedMinutesSection {
    func replacingSection(
        at index: Int,
        title: String
    ) -> [DetailedMinutesSection]? {
        guard let section = self[safe: index] else { return nil }
        return replacing(
            at: index,
            with: DetailedMinutesSection(
                title: title,
                timeRange: section.timeRange,
                speakers: section.speakers,
                content: section.content
            )
        )
    }

    func replacingSection(
        at index: Int,
        content: String
    ) -> [DetailedMinutesSection]? {
        guard let section = self[safe: index] else { return nil }
        return replacing(
            at: index,
            with: DetailedMinutesSection(
                title: section.title,
                timeRange: section.timeRange,
                speakers: section.speakers,
                content: content
            )
        )
    }

    func replacingSectionSpeaker(
        section index: Int,
        speaker speakerIndex: Int,
        with value: String
    ) -> [DetailedMinutesSection]? {
        guard let section = self[safe: index],
              let speakers = section.speakers.replacing(
                  at: speakerIndex,
                  with: value
              ) else { return nil }
        return replacing(
            at: index,
            with: DetailedMinutesSection(
                title: section.title,
                timeRange: section.timeRange,
                speakers: speakers,
                content: section.content
            )
        )
    }
}

extension MeetingTitleUpdateError {
    var userMessage: String {
        switch self {
        case .emptyTitle:
            "会议标题不能为空。"
        case .operationInProgress:
            "正在重命名该会议，请稍候。"
        case .missingNotionCredential:
            "请先在设置中保存 Notion Token，再重试重命名。"
        case .missingNotionPage:
            "找不到该会议对应的 Notion 页面，无法同步标题。"
        case .credentialAccessFailed:
            "无法读取 Notion Token，请重新保存后重试。"
        case .localUpdateFailed:
            "无法保存会议标题，请检查本地存储后重试。"
        case .invalidState:
            "会议正在总结或同步，暂时不能重命名。"
        case let .notion(error):
            switch error {
            case .unauthorized:
                "Notion Token 无效，请在设置中重新保存。"
            case .forbidden:
                "Notion 集成无权修改该页面，请检查页面共享权限。"
            case .pageNotFound:
                "找不到对应的 Notion 页面，请检查页面是否仍存在并已共享。"
            case .rateLimited:
                "Notion 请求过于频繁，请稍后重试。"
            case .timeout:
                "连接 Notion 超时，请检查网络后重试。"
            case .transport:
                "无法连接 Notion，请检查网络后重试。"
            case .server, .http:
                "Notion 服务暂时无法更新标题，请稍后重试。"
            case .invalidRequest:
                "Notion 拒绝了标题更新请求，请检查页面状态。"
            case .invalidResponse:
                "Notion 返回异常响应，请稍后重试。"
            }
        }
    }
}
