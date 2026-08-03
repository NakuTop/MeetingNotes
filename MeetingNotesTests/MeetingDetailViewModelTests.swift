import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingDetailViewModelTests: XCTestCase {
    func testDisplayedActiveDurationUsesLivePresentationForCurrentMeeting() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.finalizeMeeting(
            id: meetingID,
            endedAt: .now,
            activeDuration: 12
        )
        let presentation = RecordingSessionPresentationStore()
        await presentation.start(meetingID: meetingID, monotonicTime: 100)
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy(),
            recordingPresentationStore: presentation
        )

        XCTAssertEqual(
            viewModel.displayedActiveDuration(at: 104),
            4,
            accuracy: 0.001
        )

        await presentation.start(meetingID: UUID(), monotonicTime: 200)
        XCTAssertEqual(
            viewModel.displayedActiveDuration(at: 204),
            12,
            accuracy: 0.001
        )
    }

    func testRefreshWhileRecordingMakesNewTranscriptVisibleAndStopsWhenReady() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .recording)
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        let refreshTask = Task {
            await viewModel.refreshWhileRecording(
                interval: .milliseconds(1)
            )
        }
        defer { refreshTask.cancel() }

        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "录音中新转录"
        )

        for _ in 0..<100 where viewModel.meeting?.transcripts.isEmpty == true {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(
            viewModel.meeting?.transcripts.map(\.text),
            ["录音中新转录"]
        )

        try repository.updateMeetingState(id: meetingID, state: .ready)
        await refreshTask.value
        XCTAssertEqual(viewModel.meeting?.state, .ready)
    }

    func testPrimaryButtonReflectsWorkflowState() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let action = DetailActionSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: action,
            titleUpdater: DetailTitleUpdaterSpy()
        )

        let cases: [(RecordingState, MeetingDetailPrimaryAction)] = [
            (.recording, .unavailable),
            (.ready, .summarizeAndArchive),
            (.summarizing, .summarizing),
            (.summaryReady, .archiveToNotion),
            (.archiving, .archiving),
            (.archived, .archived)
        ]

        for (state, expected) in cases {
            try repository.updateMeetingState(id: meetingID, state: state)
            viewModel.load()
            XCTAssertEqual(viewModel.primaryAction, expected)
        }
    }

    func testPrimaryButtonReflectsNotionArchivingPreference() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let settingsStore = makeSettingsStore(
            isNotionArchivingEnabled: false
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: settingsStore,
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        try repository.updateMeetingState(id: meetingID, state: .recording)
        viewModel.load()
        XCTAssertEqual(viewModel.primaryAction, .unavailableLocal)

        try repository.updateMeetingState(id: meetingID, state: .ready)
        viewModel.load()
        XCTAssertFalse(viewModel.isNotionArchivingEnabled)
        XCTAssertEqual(viewModel.primaryAction, .summarizeLocally)

        settingsStore.isNotionArchivingEnabled = true
        XCTAssertTrue(viewModel.isNotionArchivingEnabled)
        XCTAssertEqual(viewModel.primaryAction, .summarizeAndArchive)

        settingsStore.isNotionArchivingEnabled = false
        try repository.updateMeetingState(id: meetingID, state: .summaryReady)
        viewModel.load()
        XCTAssertEqual(viewModel.primaryAction, .localSummarySaved)

        settingsStore.isNotionArchivingEnabled = true
        XCTAssertEqual(viewModel.primaryAction, .archiveToNotion)
    }

    func testPrimaryActionKeepsLegacySummaryAdapterUntilDocumentPickerMigration()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let action = DetailActionSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: action,
            titleUpdater: DetailTitleUpdaterSpy()
        )

        await viewModel.performPrimaryAction()

        XCTAssertEqual(action.callCount, 1)
    }

    func testSpeakerProcessingStatusReflectsPersistedActiveState() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        XCTAssertEqual(
            viewModel.speakerProcessingStatusMessage,
            "正在准备说话人区分…"
        )

        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .processing
        try repository.updateMeetingState(id: meetingID, state: meeting.state)
        viewModel.load()

        XCTAssertEqual(
            viewModel.speakerProcessingStatusMessage,
            "正在区分不同说话人…"
        )
    }

    func testStableProcessingMeetingsShowInterruptedWarningAndRetryAction()
        throws {
        for state in [
            RecordingState.ready,
            .summaryReady,
            .archived,
        ] {
            let repository = try MeetingRepository.inMemory()
            let meetingID = try repository.createMeeting(
                mode: .offline,
                startedAt: .now,
                speakerDiarizationRequested: true
            )
            let meeting = try repository.meeting(id: meetingID)
            meeting.speakerProcessingState = .processing
            try repository.updateMeetingState(id: meetingID, state: state)
            let viewModel = MeetingDetailViewModel(
                meetingID: meetingID,
                repository: repository,
                settingsStore: makeSettingsStore(),
                action: DetailActionSpy(),
                titleUpdater: DetailTitleUpdaterSpy(),
                speakerDiarizationRetryer: DetailSpeakerRetrySpy()
            )

            XCTAssertNil(viewModel.speakerProcessingStatusMessage)
            XCTAssertEqual(
                viewModel.speakerProcessingWarningMessage,
                "上次说话人分离被中断，可重新尝试。"
            )
            XCTAssertTrue(viewModel.shouldShowSpeakerDiarizationRetryAction)
            XCTAssertTrue(viewModel.canRetrySpeakerDiarization)
        }
    }

    func testLiveProcessingMeetingsKeepProgressWithoutRetryAction() throws {
        for state in [
            RecordingState.summarizing,
            .archiving,
        ] {
            let repository = try MeetingRepository.inMemory()
            let meetingID = try repository.createMeeting(
                mode: .offline,
                startedAt: .now,
                speakerDiarizationRequested: true
            )
            let meeting = try repository.meeting(id: meetingID)
            meeting.speakerProcessingState = .processing
            try repository.updateMeetingState(id: meetingID, state: state)
            let viewModel = MeetingDetailViewModel(
                meetingID: meetingID,
                repository: repository,
                settingsStore: makeSettingsStore(),
                action: DetailActionSpy(),
                titleUpdater: DetailTitleUpdaterSpy(),
                speakerDiarizationRetryer: DetailSpeakerRetrySpy()
            )

            XCTAssertEqual(
                viewModel.speakerProcessingStatusMessage,
                "正在区分不同说话人…"
            )
            XCTAssertNil(viewModel.speakerProcessingWarningMessage)
            XCTAssertFalse(viewModel.shouldShowSpeakerDiarizationRetryAction)
            XCTAssertFalse(viewModel.canRetrySpeakerDiarization)
        }
    }

    func testSpeakerProcessingFailureCodesMapToSafeWarnings() throws {
        let cases = [
            (
                "source_track_write_failed_microphone",
                "部分分轨处理失败，已使用可用录音和转录，不影响播放、总结与归档。"
            ),
            (
                "speaker_diarization_model_preparation_failed",
                "说话人模型未准备好，请检查网络后重试。"
            ),
            (
                "speaker_diarization_source_unavailable",
                "该旧会议缺少可用的分轨标记，无法重新分离说话人。"
            ),
            (
                "speaker_transcript_replacement_failed",
                "说话人标记未能保存，已保留普通转录，不影响播放、总结与归档。"
            ),
            (
                "private_internal_detail",
                "说话人处理未完成，已使用普通转录，不影响播放、总结与归档。"
            )
        ]

        for (errorCode, expectedMessage) in cases {
            let repository = try MeetingRepository.inMemory()
            let meetingID = try repository.createMeeting(
                mode: .online,
                startedAt: .now,
                speakerDiarizationRequested: true
            )
            let meeting = try repository.meeting(id: meetingID)
            meeting.speakerProcessingState = .degraded
            meeting.speakerProcessingErrorCode = errorCode
            try repository.updateMeetingState(
                id: meetingID,
                state: .ready
            )
            let viewModel = MeetingDetailViewModel(
                meetingID: meetingID,
                repository: repository,
                settingsStore: makeSettingsStore(),
                action: DetailActionSpy(),
                titleUpdater: DetailTitleUpdaterSpy()
            )

            XCTAssertEqual(
                viewModel.speakerProcessingWarningMessage,
                expectedMessage
            )
            XCTAssertEqual(viewModel.primaryAction, .summarizeAndArchive)
        }
    }

    func testPermanentSpeakerRetryErrorsKeepWarningWithoutRetryAction()
        throws {
        let cases = [
            SpeakerDiarizationRetryUseCase.sourceUnavailableCode,
            SpeakerDiarizationRetryUseCase.transcriptUnavailableCode,
        ]

        for errorCode in cases {
            let repository = try MeetingRepository.inMemory()
            let meetingID = try repository.createMeeting(
                mode: .online,
                startedAt: .now,
                speakerDiarizationRequested: true
            )
            let meeting = try repository.meeting(id: meetingID)
            meeting.speakerProcessingState = .degraded
            meeting.speakerProcessingErrorCode = errorCode
            try repository.updateMeetingState(id: meetingID, state: .ready)
            let viewModel = MeetingDetailViewModel(
                meetingID: meetingID,
                repository: repository,
                settingsStore: makeSettingsStore(),
                action: DetailActionSpy(),
                titleUpdater: DetailTitleUpdaterSpy(),
                speakerDiarizationRetryer: DetailSpeakerRetrySpy()
            )

            XCTAssertNotNil(viewModel.speakerProcessingWarningMessage)
            XCTAssertFalse(
                viewModel.shouldShowSpeakerDiarizationRetryAction
            )
            XCTAssertFalse(viewModel.canRetrySpeakerDiarization)
        }
    }

    func testSpeakerProcessingWarningCanBeDismissedWithoutBlockingActions()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode =
            "speaker_diarization_inference_failed"
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        XCTAssertNotNil(viewModel.speakerProcessingWarningMessage)
        XCTAssertTrue(viewModel.primaryAction.isEnabled)

        viewModel.dismissSpeakerProcessingWarning()

        XCTAssertNil(viewModel.speakerProcessingWarningMessage)
        XCTAssertTrue(viewModel.primaryAction.isEnabled)
    }

    func testSpeakerRetryShowsProgressBlocksOtherDetailActionsAndReloadsSuccess()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode =
            "speaker_diarization_inference_failed"
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let retryer = BlockingDetailSpeakerRetryer {
            meeting.speakerProcessingState = .completed
            meeting.speakerProcessingErrorCode = nil
            try repository.updateMeetingState(id: meetingID, state: .ready)
        }
        let action = DetailActionSpy()
        let titleUpdater = DetailTitleUpdaterSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: action,
            titleUpdater: titleUpdater,
            speakerDiarizationRetryer: retryer
        )

        let retry = Task { await viewModel.retrySpeakerDiarization() }
        await retryer.waitUntilStarted()

        XCTAssertTrue(viewModel.isRetryingSpeakerDiarization)
        XCTAssertFalse(viewModel.canRetrySpeakerDiarization)
        XCTAssertFalse(viewModel.shouldShowSpeakerDiarizationRetryAction)
        XCTAssertEqual(
            viewModel.speakerProcessingStatusMessage,
            "正在重新分离说话人…"
        )
        await viewModel.retrySpeakerDiarization()
        await viewModel.performPrimaryAction()
        let renamed = await viewModel.rename(to: "blocked")
        XCTAssertFalse(renamed)
        XCTAssertEqual(retryer.requests, [meetingID])
        XCTAssertEqual(action.callCount, 0)
        XCTAssertTrue(titleUpdater.requests.isEmpty)

        retryer.finish()
        await retry.value

        XCTAssertFalse(viewModel.isRetryingSpeakerDiarization)
        XCTAssertEqual(viewModel.speakerProcessingState, .completed)
        XCTAssertNil(viewModel.speakerProcessingWarningMessage)
    }

    func testSpeakerRetryIsOnlyAvailableForDegradedMeetingWithRetryService()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy(),
            speakerDiarizationRetryer: DetailSpeakerRetrySpy()
        )

        XCTAssertTrue(viewModel.canRetrySpeakerDiarization)

        meeting.speakerProcessingState = .completed
        try repository.updateMeetingState(id: meetingID, state: .ready)
        viewModel.load()
        XCTAssertFalse(viewModel.canRetrySpeakerDiarization)
    }

    func testArchiveFailureReloadsSummaryReadyAndShowsRetryMessage() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let action = DetailActionSpy(
            execute: {
                try repository.updateMeetingState(
                    id: meetingID,
                    state: .summaryReady
                )
                throw SummarizeAndArchiveError.archiveFailed
            }
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: action,
            titleUpdater: DetailTitleUpdaterSpy()
        )

        await viewModel.performPrimaryAction()

        XCTAssertEqual(viewModel.primaryAction, .archiveToNotion)
        XCTAssertEqual(viewModel.errorMessage, "Notion 归档失败，可直接重试，不会再次生成总结。")
        XCTAssertEqual(action.callCount, 1)
    }

    func testActionImmediatelyShowsSummarizingWhileRequestIsRunning() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let action = BlockingDetailAction()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: action,
            titleUpdater: DetailTitleUpdaterSpy()
        )

        let operation = Task {
            await viewModel.performPrimaryAction()
        }
        await action.waitUntilStarted()

        XCTAssertEqual(viewModel.primaryAction, .summarizing)
        XCTAssertTrue(viewModel.isPerforming)

        action.finish()
        await operation.value
    }

    func testActionShowsArchivingWhenWorkflowReportsTransition() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let action = ProgressingDetailAction()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: action,
            titleUpdater: DetailTitleUpdaterSpy()
        )

        let operation = Task {
            await viewModel.performPrimaryAction()
        }
        await action.waitUntilStarted()

        XCTAssertEqual(viewModel.primaryAction, .archiving)
        XCTAssertTrue(viewModel.isPerforming)

        action.finish()
        await operation.value
    }

    func testLocalSummaryShowsSavedWhenWorkflowReportsSummaryReady() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let action = ProgressingDetailAction(progressState: .summaryReady)
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(
                isNotionArchivingEnabled: false
            ),
            action: action,
            titleUpdater: DetailTitleUpdaterSpy()
        )

        let operation = Task {
            await viewModel.performPrimaryAction()
        }
        await action.waitUntilStarted()

        XCTAssertEqual(viewModel.primaryAction, .localSummarySaved)
        XCTAssertTrue(viewModel.isPerforming)

        action.finish()
        await operation.value
    }

    func testRenameTracksProgressReloadsTitleAndReturnsTrue() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let updater = BlockingDetailTitleUpdater { _, title in
            try repository.updateTitle(meetingID: meetingID, title: title)
        }
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: updater
        )

        let operation = Task {
            await viewModel.rename(to: "新会议标题")
        }
        await updater.waitUntilStarted()

        XCTAssertTrue(viewModel.isRenaming)
        updater.finish()
        let succeeded = await operation.value

        XCTAssertTrue(succeeded)
        XCTAssertFalse(viewModel.isRenaming)
        XCTAssertEqual(viewModel.meeting?.title, "新会议标题")
        XCTAssertNil(viewModel.renameErrorMessage)
    }

    func testRenameErrorsUseIndependentChannelAndMapActionableMessages() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let cases: [(MeetingTitleUpdateError, String)] = [
            (.emptyTitle, "会议标题不能为空。"),
            (.operationInProgress, "正在重命名该会议，请稍候。"),
            (
                .missingNotionCredential,
                "请先在设置中保存 Notion Token，再重试重命名。"
            ),
            (
                .missingNotionPage,
                "找不到该会议对应的 Notion 页面，无法同步标题。"
            ),
            (
                .credentialAccessFailed,
                "无法读取 Notion Token，请重新保存后重试。"
            ),
            (
                .invalidState(.summarizing),
                "会议正在总结或归档，暂时不能重命名。"
            ),
            (
                .localUpdateFailed,
                "无法保存会议标题，请检查本地存储后重试。"
            ),
            (
                .notion(.unauthorized),
                "Notion Token 无效，请在设置中重新保存。"
            ),
            (
                .notion(.forbidden),
                "Notion 集成无权修改该页面，请检查页面共享权限。"
            ),
            (
                .notion(.pageNotFound),
                "找不到对应的 Notion 页面，请检查页面是否仍存在并已共享。"
            ),
            (
                .notion(.rateLimited),
                "Notion 请求过于频繁，请稍后重试。"
            ),
            (
                .notion(.timeout),
                "连接 Notion 超时，请检查网络后重试。"
            ),
            (
                .notion(.transport),
                "无法连接 Notion，请检查网络后重试。"
            )
        ]

        for (error, expectedMessage) in cases {
            let updater = DetailTitleUpdaterSpy(error: error)
            let viewModel = MeetingDetailViewModel(
                meetingID: meetingID,
                repository: repository,
                settingsStore: makeSettingsStore(),
                action: DetailActionSpy(),
                titleUpdater: updater
            )

            let succeeded = await viewModel.rename(to: "新标题")

            XCTAssertFalse(succeeded, "Expected \(error) to fail")
            XCTAssertEqual(
                viewModel.renameErrorMessage,
                expectedMessage,
                "Unexpected message for \(error)"
            )
            XCTAssertNil(viewModel.errorMessage)
            viewModel.dismissRenameError()
            XCTAssertNil(viewModel.renameErrorMessage)
        }
    }

    func testCancelledRenameIsSilentAndClearsInFlightState() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy(error: CancellationError())
        )

        let succeeded = await viewModel.rename(to: "不应保存")

        XCTAssertFalse(succeeded)
        XCTAssertNil(viewModel.renameErrorMessage)
        XCTAssertFalse(viewModel.isRenaming)
        XCTAssertEqual(viewModel.meeting?.title, MeetingRecord.defaultTitle)
    }

    func testRenameDoesNotSubmitTwiceWhileRequestIsRunning() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let updater = BlockingDetailTitleUpdater()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: updater
        )

        let first = Task { await viewModel.rename(to: "第一个标题") }
        await updater.waitUntilStarted()
        let secondSucceeded = await viewModel.rename(to: "第二个标题")

        XCTAssertFalse(secondSucceeded)
        XCTAssertEqual(updater.requests.count, 1)
        updater.finish()
        _ = await first.value
    }

    func testPrimaryActionDoesNotStartWhileRenameIsRunning() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let updater = BlockingDetailTitleUpdater()
        let action = DetailActionSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: action,
            titleUpdater: updater
        )
        let rename = Task { await viewModel.rename(to: "新标题") }
        await updater.waitUntilStarted()

        await viewModel.performPrimaryAction()

        XCTAssertEqual(action.callCount, 0)
        updater.finish()
        _ = await rename.value
    }

    func testRenameDoesNotStartWhilePrimaryActionIsRunning() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let action = BlockingDetailAction()
        let updater = DetailTitleUpdaterSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: action,
            titleUpdater: updater
        )
        let primaryAction = Task { await viewModel.performPrimaryAction() }
        await action.waitUntilStarted()

        let succeeded = await viewModel.rename(to: "新标题")

        XCTAssertFalse(succeeded)
        XCTAssertTrue(updater.requests.isEmpty)
        action.finish()
        _ = await primaryAction.value
    }

    func testDefaultSelectedDocumentIsSummary() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            documentManager: DetailDocumentManagerSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        XCTAssertEqual(viewModel.selectedDocumentKind, .summary)
        XCTAssertEqual(viewModel.documentOperation, .idle)
    }

    func testGenerateActsOnlyOnSelectedDocument() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "可用最终转录"
        )
        let documentManager = DetailDocumentManagerSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            documentManager: documentManager,
            titleUpdater: DetailTitleUpdaterSpy()
        )
        viewModel.selectedDocumentKind = .detailedMinutes

        await viewModel.generateSelectedDocument()

        XCTAssertEqual(documentManager.generatedKinds, [.detailedMinutes])
        XCTAssertTrue(documentManager.retriedKinds.isEmpty)
    }

    func testRetryArchiveUsesSelectedSavedDocumentWithoutGeneration()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "本地重点总结",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            ),
            model: "test-model"
        )
        try repository.updateDocumentArchiveState(
            meetingID: meetingID,
            kind: .summary,
            archiveState: .failed,
            meetingState: .summaryReady,
            errorCode: MeetingDocumentsUseCase.archiveFailureCode
        )
        let documentManager = DetailDocumentManagerSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            documentManager: documentManager,
            titleUpdater: DetailTitleUpdaterSpy()
        )

        await viewModel.archiveSelectedDocumentToNotion()

        XCTAssertTrue(documentManager.generatedKinds.isEmpty)
        XCTAssertEqual(documentManager.retriedKinds, [.summary])
    }

    func testSavedDocumentArchiveButtonCoversLocalFailedAndArchivedStates()
        throws {
        let expectations: [
            (MeetingDocumentArchiveState, RecordingState, String, Bool)
        ] = [
            (.localOnly, .summaryReady, "归档到 Notion", true),
            (.failed, .summaryReady, "重新归档到 Notion", true),
            (.archived, .archived, "重新归档并覆盖", true),
            (.archiving, .archiving, "正在归档", false),
        ]

        for (archiveState, meetingState, title, isEnabled) in expectations {
            let repository = try MeetingRepository.inMemory()
            let meetingID = try repository.createMeeting(
                mode: .offline,
                startedAt: .now
            )
            try repository.saveGeneratedSummary(
                meetingID: meetingID,
                generated: GeneratedMeetingSummary(
                    suggestedTitle: "",
                    overview: "本地重点总结",
                    keyPoints: [],
                    decisions: [],
                    actionItems: [],
                    bookmarkInsights: []
                ),
                model: "test-model"
            )
            if archiveState != .localOnly {
                try repository.updateDocumentArchiveState(
                    meetingID: meetingID,
                    kind: .summary,
                    archiveState: archiveState,
                    meetingState: meetingState
                )
            }
            let viewModel = MeetingDetailViewModel(
                meetingID: meetingID,
                repository: repository,
                settingsStore: makeSettingsStore(),
                action: DetailActionSpy(),
                documentManager: DetailDocumentManagerSpy(),
                titleUpdater: DetailTitleUpdaterSpy()
            )

            XCTAssertEqual(
                viewModel.selectedDocumentArchiveButtonTitle,
                title,
                "Unexpected title for \(archiveState)"
            )
            XCTAssertEqual(
                viewModel.canArchiveSelectedDocumentToNotion,
                isEnabled,
                "Unexpected enabled state for \(archiveState)"
            )
        }
    }

    func testArchiveButtonIsHiddenWithoutSelectedDocumentOrNotion() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let noDocument = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            documentManager: DetailDocumentManagerSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        XCTAssertNil(noDocument.selectedDocumentArchiveButtonTitle)

        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "本地重点总结",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            ),
            model: "test-model"
        )
        let notionDisabled = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(
                isNotionArchivingEnabled: false
            ),
            action: DetailActionSpy(),
            documentManager: DetailDocumentManagerSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        XCTAssertNil(notionDisabled.selectedDocumentArchiveButtonTitle)
        XCTAssertFalse(
            notionDisabled.canArchiveSelectedDocumentToNotion
        )
    }

    func testArchiveActionHandlesLocalOnlyAndArchivedWithoutGeneration()
        async throws {
        for archiveState in [
            MeetingDocumentArchiveState.localOnly,
            .archived,
        ] {
            let repository = try MeetingRepository.inMemory()
            let meetingID = try repository.createMeeting(
                mode: .offline,
                startedAt: .now
            )
            try repository.saveGeneratedSummary(
                meetingID: meetingID,
                generated: GeneratedMeetingSummary(
                    suggestedTitle: "",
                    overview: "本地重点总结",
                    keyPoints: [],
                    decisions: [],
                    actionItems: [],
                    bookmarkInsights: []
                ),
                model: "test-model"
            )
            if archiveState == .archived {
                try repository.completeDocumentArchive(
                    meetingID: meetingID,
                    kind: .summary
                )
            }
            let documentManager = DetailDocumentManagerSpy()
            let viewModel = MeetingDetailViewModel(
                meetingID: meetingID,
                repository: repository,
                settingsStore: makeSettingsStore(),
                action: DetailActionSpy(),
                documentManager: documentManager,
                titleUpdater: DetailTitleUpdaterSpy()
            )

            await viewModel.archiveSelectedDocumentToNotion()

            XCTAssertTrue(documentManager.generatedKinds.isEmpty)
            XCTAssertEqual(documentManager.retriedKinds, [.summary])
        }
    }

    func testDocumentGenerationBusyStateBlocksRenameAndSpeakerRetry()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "可用最终转录"
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode =
            SpeakerAwareTranscriptFinalizer.diarizationInferenceFailedCode
        let documentManager = BlockingDetailDocumentManager()
        let titleUpdater = DetailTitleUpdaterSpy()
        let speakerRetryer = DetailSpeakerRetrySpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            documentManager: documentManager,
            titleUpdater: titleUpdater,
            speakerDiarizationRetryer: speakerRetryer
        )

        let generation = Task { await viewModel.generateSelectedDocument() }
        await documentManager.waitUntilStarted()

        XCTAssertEqual(viewModel.documentOperation, .generating(.summary))
        let renamed = await viewModel.rename(to: "不应重命名")
        XCTAssertFalse(renamed)
        await viewModel.retrySpeakerDiarization()
        XCTAssertTrue(titleUpdater.requests.isEmpty)
        XCTAssertTrue(speakerRetryer.requests.isEmpty)

        documentManager.finish()
        await generation.value
    }

    func testGenerateRequiresAtLeastOneSanitizedFinalTranscript() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            documentManager: DetailDocumentManagerSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        XCTAssertFalse(viewModel.canGenerateSelectedDocument)

        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "<|endoftext|>",
            isFinal: true
        )
        viewModel.load()
        XCTAssertFalse(viewModel.canGenerateSelectedDocument)

        try repository.appendTranscript(
            meetingID: meetingID,
            start: 1,
            end: 2,
            text: "真正可用于总结的内容",
            isFinal: true
        )
        viewModel.load()
        XCTAssertTrue(viewModel.canGenerateSelectedDocument)
    }

    func testDocumentOperationKeepsCapturedKindWhenSelectionChanges()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.updateMeetingState(id: meetingID, state: .ready)
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "可用最终转录"
        )
        let documentManager = CapturedKindDetailDocumentManager()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            documentManager: documentManager,
            titleUpdater: DetailTitleUpdaterSpy()
        )

        let generation = Task { await viewModel.generateSelectedDocument() }
        await documentManager.waitUntilStarted()
        viewModel.selectedDocumentKind = .detailedMinutes
        documentManager.beginArchiving()
        await documentManager.waitUntilArchiving()

        XCTAssertEqual(viewModel.selectedDocumentKind, .detailedMinutes)
        XCTAssertEqual(viewModel.documentOperation, .archiving(.summary))

        documentManager.failArchive()
        await generation.value

        XCTAssertNotNil(viewModel.documentErrorMessage(for: .summary))
        XCTAssertNil(viewModel.documentErrorMessage(for: .detailedMinutes))
    }

    func testRenamingSpeakerUpdatesEveryMatchingRowAndRemembersName() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        for offset in [0.0, 2.0] {
            try repository.appendTranscript(
                meetingID: meetingID,
                start: offset,
                end: offset + 1,
                text: "发言",
                speakerID: "room-1"
            )
        }
        let settingsStore = makeSettingsStore()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: settingsStore,
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        XCTAssertTrue(viewModel.renameSpeaker("room-1", to: " 张三 "))

        XCTAssertEqual(viewModel.speakerDisplayNames, ["room-1": "张三"])
        XCTAssertEqual(settingsStore.frequentSpeakerNames, ["张三"])
        XCTAssertEqual(
            viewModel.meeting?.transcripts.filter {
                $0.speakerID == "room-1"
            }.count,
            2
        )

        XCTAssertTrue(viewModel.clearSpeakerName("room-1"))
        XCTAssertTrue(viewModel.speakerDisplayNames.isEmpty)
        XCTAssertEqual(settingsStore.frequentSpeakerNames, ["张三"])
    }

    func testSpeakerRenameRejectsInvalidNamesWithoutChangingHistory() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "发言",
            speakerID: "room-1"
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        XCTAssertFalse(viewModel.renameSpeaker("room-1", to: "   "))
        XCTAssertEqual(
            viewModel.speakerNameErrorMessage,
            "请输入 1 到 40 个字符的名称。"
        )
        XCTAssertFalse(
            viewModel.renameSpeaker(
                "room-1",
                to: String(repeating: "长", count: 41)
            )
        )
        XCTAssertTrue(viewModel.speakerDisplayNames.isEmpty)
        XCTAssertEqual(viewModel.meeting?.transcripts.map(\.text), ["发言"])
    }

    func testSpeakerRenameSaveFailureLeavesNamesAndSuggestionsUntouched()
        throws {
        let failure = DetailRepositoryFailureSwitch()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                if failure.shouldFail {
                    throw DetailInjectedRepositoryError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "发言",
            speakerID: "room-1"
        )
        let settingsStore = makeSettingsStore()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: settingsStore,
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )
        failure.shouldFail = true

        XCTAssertFalse(viewModel.renameSpeaker("room-1", to: "张三"))

        XCTAssertEqual(
            viewModel.speakerNameErrorMessage,
            "无法保存说话人名称，请稍后重试。"
        )
        XCTAssertTrue(viewModel.speakerDisplayNames.isEmpty)
        XCTAssertTrue(settingsStore.frequentSpeakerNames.isEmpty)
    }

    private func makeSettingsStore(
        isNotionArchivingEnabled: Bool = true
    ) -> AppSettingsStore {
        let suiteName = "MeetingDetailViewModelTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create isolated test defaults")
        }
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AppSettingsStore(defaults: defaults)
        store.isNotionArchivingEnabled = isNotionArchivingEnabled
        return store
    }
}

@MainActor
private final class DetailDocumentManagerSpy: MeetingDocumentManaging {
    private(set) var generatedKinds: [MeetingDocumentKind] = []
    private(set) var retriedKinds: [MeetingDocumentKind] = []

    func generate(meetingID: UUID, kind: MeetingDocumentKind) async throws {
        _ = meetingID
        generatedKinds.append(kind)
    }

    func retryArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) async throws {
        _ = meetingID
        retriedKinds.append(kind)
    }
}

@MainActor
private final class BlockingDetailDocumentManager: MeetingDocumentManaging {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func generate(meetingID: UUID, kind: MeetingDocumentKind) async throws {
        _ = meetingID
        _ = kind
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func retryArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) async throws {
        _ = meetingID
        _ = kind
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

@MainActor
private final class CapturedKindDetailDocumentManager:
    MeetingDocumentManaging {
    private var started = false
    private var archiving = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var archiveWaiters: [CheckedContinuation<Void, Never>] = []
    private var beginArchiveContinuation: CheckedContinuation<Void, Never>?
    private var failContinuation: CheckedContinuation<Void, Never>?

    func generate(meetingID: UUID, kind: MeetingDocumentKind) async throws {
        _ = meetingID
        _ = kind
    }

    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws {
        _ = meetingID
        onOperationChange(.generating(kind))
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            beginArchiveContinuation = continuation
        }
        onOperationChange(.archiving(kind))
        archiving = true
        archiveWaiters.forEach { $0.resume() }
        archiveWaiters.removeAll()
        await withCheckedContinuation { continuation in
            failContinuation = continuation
        }
        throw MeetingDocumentsError.archiveFailed(kind)
    }

    func retryArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) async throws {
        _ = meetingID
        _ = kind
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func beginArchiving() {
        beginArchiveContinuation?.resume()
        beginArchiveContinuation = nil
    }

    func waitUntilArchiving() async {
        if archiving { return }
        await withCheckedContinuation { continuation in
            archiveWaiters.append(continuation)
        }
    }

    func failArchive() {
        failContinuation?.resume()
        failContinuation = nil
    }
}

private struct TitleUpdateRequest: Equatable {
    let meetingID: UUID
    let title: String
}

@MainActor
private final class DetailTitleUpdaterSpy: MeetingTitleUpdating {
    private let error: Error?
    private(set) var requests: [TitleUpdateRequest] = []

    init(error: Error? = nil) {
        self.error = error
    }

    func updateTitle(meetingID: UUID, title: String) async throws {
        requests.append(TitleUpdateRequest(meetingID: meetingID, title: title))
        if let error { throw error }
    }
}

@MainActor
private final class DetailSpeakerRetrySpy:
    MeetingSpeakerDiarizationRetrying {
    private(set) var requests: [UUID] = []

    func retry(meetingID: UUID) async throws {
        requests.append(meetingID)
    }
}

@MainActor
private final class BlockingDetailSpeakerRetryer:
    MeetingSpeakerDiarizationRetrying {
    private let onFinish: () throws -> Void
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [UUID] = []

    init(onFinish: @escaping () throws -> Void) {
        self.onFinish = onFinish
    }

    func retry(meetingID: UUID) async throws {
        requests.append(meetingID)
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
        try onFinish()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

@MainActor
private final class BlockingDetailTitleUpdater: MeetingTitleUpdating {
    private let onFinish: (UUID, String) throws -> Void
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [TitleUpdateRequest] = []

    init(onFinish: @escaping (UUID, String) throws -> Void = { _, _ in }) {
        self.onFinish = onFinish
    }

    func updateTitle(meetingID: UUID, title: String) async throws {
        requests.append(TitleUpdateRequest(meetingID: meetingID, title: title))
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
        try onFinish(meetingID, title)
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

@MainActor
private final class DetailActionSpy: SummarizeAndArchiving {
    private let executeBlock: () async throws -> Void
    private(set) var callCount = 0

    init(execute: @escaping () async throws -> Void = {}) {
        executeBlock = execute
    }

    func execute(meetingID: UUID) async throws {
        _ = meetingID
        callCount += 1
        try await executeBlock()
    }
}

@MainActor
private final class BlockingDetailAction: SummarizeAndArchiving {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func execute(meetingID: UUID) async throws {
        _ = meetingID
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

@MainActor
private final class ProgressingDetailAction: SummarizeAndArchiving {
    private let progressState: RecordingState
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(progressState: RecordingState = .archiving) {
        self.progressState = progressState
    }

    func execute(meetingID: UUID) async throws {
        _ = meetingID
        await waitForFinish()
    }

    func execute(
        meetingID: UUID,
        onProgress: @escaping (RecordingState) -> Void
    ) async throws {
        _ = meetingID
        onProgress(progressState)
        await waitForFinish()
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func waitForFinish() async {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }
}

private enum DetailInjectedRepositoryError: Error {
    case forced
}

private final class DetailRepositoryFailureSwitch {
    var shouldFail = false
}
