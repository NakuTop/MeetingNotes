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
        case .unavailable: "总结并归档"
        case .unavailableLocal: "生成总结"
        case .summarizeAndArchive: "总结并归档"
        case .summarizeLocally: "生成总结"
        case .summarizing: "正在总结"
        case .archiveToNotion: "归档到 Notion"
        case .localSummarySaved: "已保存到本机"
        case .archiving: "正在归档"
        case .archived: "已归档"
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

    private(set) var meeting: MeetingRecord?
    private(set) var isPerforming = false
    private(set) var operationState: RecordingState?
    private(set) var errorMessage: String?
    private(set) var isRenaming = false
    private(set) var renameErrorMessage: String?
    private(set) var isRetryingSpeakerDiarization = false
    private(set) var speakerDiarizationRetryErrorMessage: String?
    private(set) var speakerNameErrorMessage: String?
    var selectedDocumentKind: MeetingDocumentKind = .summary
    private(set) var documentOperation: MeetingDocumentOperation = .idle
    private var summaryDocumentErrorMessage: String?
    private var detailedMinutesDocumentErrorMessage: String?
    private var dismissedSpeakerProcessingWarningKey: String?

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
            RecordingSessionPresentationStore? = nil
    ) {
        self.meetingID = meetingID
        self.repository = repository
        self.settingsStore = settingsStore
        self.action = action
        self.documentManager = documentManager
        self.titleUpdater = titleUpdater
        self.speakerDiarizationRetryer = speakerDiarizationRetryer
        self.recordingPresentationStore = recordingPresentationStore
        meeting = try? repository.meeting(id: meetingID)
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
            return isNotionArchivingEnabled ? .unavailable : .unavailableLocal
        }
        if isPerforming {
            return switch operationState ?? state {
            case .summaryReady:
                isNotionArchivingEnabled ? .archiving : .localSummarySaved
            case .archiving:
                .archiving
            case .archived:
                .archived
            default:
                .summarizing
            }
        }
        return switch state {
        case .ready:
            isNotionArchivingEnabled ? .summarizeAndArchive : .summarizeLocally
        case .summarizing: .summarizing
        case .summaryReady:
            isNotionArchivingEnabled ? .archiveToNotion : .localSummarySaved
        case .archiving: .archiving
        case .archived: .archived
        default:
            isNotionArchivingEnabled ? .unavailable : .unavailableLocal
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
        guard isNotionArchivingEnabled,
              hasSelectedDocument else {
            return nil
        }
        return switch archiveStatus(for: selectedDocumentKind) {
        case .localOnly: "归档到 Notion"
        case .failed: "重新归档到 Notion"
        case .archived: "重新归档并覆盖"
        case .archiving: "正在归档"
        }
    }

    var canArchiveSelectedDocumentToNotion: Bool {
        guard documentManager != nil,
              selectedDocumentArchiveButtonTitle != nil,
              archiveStatus(for: selectedDocumentKind) != .archiving,
              canStartDocumentOperation,
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

    func generateSelectedDocument() async {
        guard canGenerateSelectedDocument,
              let documentManager else { return }
        let kind = selectedDocumentKind
        documentOperation = .generating(kind)
        setDocumentErrorMessage(nil, for: kind)
        defer { documentOperation = .idle }

        do {
            try await documentManager.generate(
                meetingID: meetingID,
                kind: kind
            ) { [weak self] operation in
                self?.documentOperation = operation
                if case .archiving = operation {
                    self?.load()
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
        guard canArchiveSelectedDocumentToNotion,
              let documentManager else { return }
        let kind = selectedDocumentKind
        documentOperation = .archiving(kind)
        setDocumentErrorMessage(nil, for: kind)
        defer { documentOperation = .idle }

        do {
            try await documentManager.retryArchive(
                meetingID: meetingID,
                kind: kind
            ) { [weak self] operation in
                self?.documentOperation = operation
            }
        } catch where Self.isCancellation(error) {
            // Cancellation restores the persisted archive state without an error.
        } catch {
            setDocumentErrorMessage(Self.documentMessage(for: error), for: kind)
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
            return "该旧会议缺少可用的分轨标记，无法重新分离说话人。"
        }
        if errorCode == SpeakerDiarizationRetryUseCase
            .transcriptUnavailableCode {
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
            return "部分分轨处理失败，已使用可用录音和转录，不影响播放、总结与归档。"
        }
        if errorCode?.hasPrefix("speaker_diarization_") == true {
            return "说话人区分未完成，已保留可用转录，不影响播放、总结与归档。"
        }
        if errorCode == "speaker_transcript_replacement_failed" {
            return "说话人标记未能保存，已保留普通转录，不影响播放、总结与归档。"
        }
        return "说话人处理未完成，已使用普通转录，不影响播放、总结与归档。"
    }

    var shouldShowSpeakerDiarizationRetryAction: Bool {
        guard speakerDiarizationRetryer != nil,
              !isRetryingSpeakerDiarization else {
            return false
        }
        let errorCode = meeting?.speakerProcessingErrorCode
        guard errorCode != SpeakerDiarizationRetryUseCase
            .sourceUnavailableCode,
            errorCode != SpeakerDiarizationRetryUseCase
                .transcriptUnavailableCode else {
            return false
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

    private static func documentMessage(for error: Error) -> String {
        switch error as? MeetingDocumentsError {
        case .noFinalTranscript:
            "没有可用的最终转录，暂时无法生成。"
        case .missingDeepSeekCredential:
            "请先在设置中保存 DeepSeek API Key。"
        case .missingNotionCredential:
            "内容已保存在本机。请在设置中保存 Notion Token 后重试归档。"
        case .invalidNotionPageURL:
            "内容已保存在本机。请在设置中填写有效的 Notion 父页面链接。"
        case .missingLocalDocument:
            "找不到本地内容，请重新生成。"
        case .invalidGeneratedDocument, .generationFailed:
            "DeepSeek 生成失败，原有内容仍保存在本机，请稍后重试。"
        case .archiveFailed:
            "Notion 归档失败，新内容已保存在本机，可直接重试归档。"
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
            "总结已保存在本机。请在设置中保存 Notion Token 后重试归档。"
        case .invalidNotionPageURL:
            "总结已保存在本机。请在设置中填写有效的 Notion 父页面链接。"
        case .summaryFailed:
            "DeepSeek 总结失败，会议记录仍保存在本机，请稍后重试。"
        case .archiveFailed:
            "Notion 归档失败，可直接重试，不会再次生成总结。"
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
            "会议正在总结或归档，暂时不能重命名。"
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
