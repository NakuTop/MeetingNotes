import AppKit
import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingDetailViewModelTests: XCTestCase {
    func testInlineTextSizingAdvertisesACompressibleHStackMinimum() {
        XCTAssertEqual(
            InlineEditableMeetingText.layoutWidth(
                proposal: 0,
                fittingWidth: 480
            ),
            0
        )
        XCTAssertEqual(
            InlineEditableMeetingText.layoutWidth(
                proposal: 180,
                fittingWidth: 480
            ),
            180
        )
        XCTAssertEqual(
            InlineEditableMeetingText.layoutWidth(
                proposal: nil,
                fittingWidth: 480
            ),
            480
        )
        XCTAssertEqual(
            InlineEditableMeetingText.measurementWidth(
                proposal: nil,
                currentWidth: 180,
                fittingWidth: 480
            ),
            180
        )
        XCTAssertEqual(
            InlineEditableMeetingText.measurementWidth(
                proposal: nil,
                currentWidth: 0,
                fittingWidth: 480
            ),
            480
        )
    }

    func testInlineContextMenuBindsNativeEditingCommandsToClickedEditor()
        throws {
        let editor = InlineMeetingNativeTextView()
        let nativeMenu = NSMenu()
        for (title, action) in [
            ("Cut", #selector(NSText.cut(_:))),
            ("Copy", #selector(NSText.copy(_:))),
            ("Paste", #selector(NSText.paste(_:))),
        ] {
            nativeMenu.addItem(
                NSMenuItem(
                    title: title,
                    action: action,
                    keyEquivalent: ""
                )
            )
        }
        let replacementTarget = InlineContextMenuTarget()

        let menu = editor.augmentedContextMenu(
            sourceMenu: nativeMenu,
            replacementTarget: replacementTarget,
            replacementAction:
                #selector(InlineContextMenuTarget.requestReplacement(_:))
        )

        XCTAssertFalse(menu === nativeMenu)
        XCTAssertNil(nativeMenu.item(withTitle: "Cut")?.target)
        XCTAssertTrue(menu.item(withTitle: "Cut")?.target === editor)
        XCTAssertTrue(menu.item(withTitle: "Copy")?.target === editor)
        XCTAssertTrue(menu.item(withTitle: "Paste")?.target === editor)
        XCTAssertTrue(
            menu.item(withTitle: "替换本会议相同文字…")?.target
                === replacementTarget
        )
    }

    func testInlineNativeTextViewReportsTextChangesDirectly() {
        let editor = InlineMeetingNativeTextView()
        var observedValues: [String] = []
        editor.onStringChange = { observedValues.append($0) }

        editor.string = "用户输入"
        editor.didChangeText()

        XCTAssertEqual(observedValues, ["用户输入"])
    }

    func testDirtyGroupedTurnDoesNotAbsorbNewSameSpeakerSegmentBetweenKeystrokes()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "已合并第一段",
            speakerID: "room-1"
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 1.2,
            end: 2,
            text: "已合并第二段",
            speakerID: "room-1"
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )
        let initialTurn = try XCTUnwrap(
            TranscriptDisplayPolicy.turns(
                from: repository.canonicalTranscripts(meetingID: meetingID),
                bookmarks: []
            ).first
        )
        let initialTarget = MeetingTranscriptEditTarget(turn: initialTurn)
        XCTAssertEqual(initialTurn.transcriptIDs.count, 2)

        viewModel.updateTranscriptDraft(
            "人工修正后的完整合并发言",
            for: initialTarget
        )

        try repository.appendTranscript(
            meetingID: meetingID,
            start: 2.2,
            end: 3,
            text: "后续新语音",
            speakerID: "room-1"
        )
        viewModel.load()
        let refreshedTurns = TranscriptDisplayPolicy.turns(
            from: try repository.canonicalTranscripts(meetingID: meetingID),
            bookmarks: [],
            preservingDraftTargets: viewModel.transcriptDrafts.map(\.target)
        )

        XCTAssertEqual(refreshedTurns.count, 2)
        XCTAssertEqual(
            viewModel.transcriptDraftText(
                for: MeetingTranscriptEditTarget(turn: refreshedTurns[0])
            ),
            "人工修正后的完整合并发言"
        )
        XCTAssertEqual(refreshedTurns[1].text, "后续新语音")

        viewModel.updateTranscriptDraft(
            "人工修正后的完整合并发言继续输入",
            for: MeetingTranscriptEditTarget(turn: refreshedTurns[0])
        )
        let pending = try XCTUnwrap(viewModel.transcriptDrafts.first)
        XCTAssertEqual(pending.target.transcriptIDs, initialTurn.transcriptIDs)

        await viewModel.flushEdits()

        let canonical = try repository.canonicalTranscripts(
            meetingID: meetingID
        )
        XCTAssertEqual(
            canonical.map(\.text),
            ["人工修正后的完整合并发言继续输入", "后续新语音"]
        )
    }

    func testPersistedCorrectionKeepsIndependentEditableIdentityFromAdjacentSpeech()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "原始第一段",
            speakerID: "room-1"
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 1.2,
            end: 2,
            text: "后续生成语音",
            speakerID: "room-1"
        )
        let raw = try repository.transcripts(meetingID: meetingID)
        try repository.saveTranscriptCorrection(
            meetingID: meetingID,
            transcriptIDs: [raw[0].id],
            anchorStartTime: raw[0].startTime,
            anchorEndTime: raw[0].endTime,
            source: raw[0].source,
            originalText: raw[0].text,
            replacementText: "已保存的第一段修正"
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )
        let turns = TranscriptDisplayPolicy.turns(
            from: try repository.canonicalTranscripts(meetingID: meetingID),
            bookmarks: []
        )

        XCTAssertEqual(turns.count, 2)
        XCTAssertNotNil(turns[0].correctionID)
        XCTAssertNil(turns[1].correctionID)
        XCTAssertEqual(turns[0].transcriptIDs, [raw[0].id])
        XCTAssertEqual(turns[1].transcriptIDs, [raw[1].id])

        viewModel.updateTranscriptDraft(
            "再次修正第一段",
            for: MeetingTranscriptEditTarget(turn: turns[0])
        )
        await viewModel.flushEdits()

        XCTAssertEqual(
            try repository.canonicalTranscripts(meetingID: meetingID)
                .map(\.text),
            ["再次修正第一段", "后续生成语音"]
        )
    }

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
            (.recording, .unavailableLocal),
            (.ready, .summarizeLocally),
            (.summarizing, .summarizing),
            (.summaryReady, .localSummarySaved),
            (.archiving, .archiving),
            (.archived, .localSummarySaved)
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
        XCTAssertEqual(viewModel.primaryAction, .summarizeLocally)

        settingsStore.isNotionArchivingEnabled = false
        try repository.updateMeetingState(id: meetingID, state: .summaryReady)
        viewModel.load()
        XCTAssertEqual(viewModel.primaryAction, .localSummarySaved)

        settingsStore.isNotionArchivingEnabled = true
        XCTAssertEqual(viewModel.primaryAction, .localSummarySaved)
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
                "部分分轨处理失败，已使用可用录音和转录，不影响播放、总结与同步。"
            ),
            (
                "speaker_diarization_model_preparation_failed",
                "说话人模型未准备好，请检查网络后重试。"
            ),
            (
                "speaker_diarization_source_unavailable",
                "原始分轨录音仍可用于重建，请重新分离说话人。"
            ),
            (
                "speaker_transcript_replacement_failed",
                "说话人标记未能保存，已保留普通转录，不影响播放、总结与同步。"
            ),
            (
                "private_internal_detail",
                "说话人处理未完成，已使用普通转录，不影响播放、总结与同步。"
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
            XCTAssertEqual(viewModel.primaryAction, .summarizeLocally)
        }
    }

    func testLegacyOnlineSpeakerErrorsOfferPhysicalTrackRebuild()
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
            XCTAssertTrue(
                viewModel.shouldShowSpeakerDiarizationRetryAction
            )
            XCTAssertTrue(viewModel.canRetrySpeakerDiarization)
        }
    }

    func testOfflineMissingTranscriptRemainsNonRetryable() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode =
            SpeakerDiarizationRetryUseCase.transcriptUnavailableCode
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy(),
            speakerDiarizationRetryer: DetailSpeakerRetrySpy()
        )

        XCTAssertFalse(viewModel.shouldShowSpeakerDiarizationRetryAction)
        XCTAssertFalse(viewModel.canRetrySpeakerDiarization)
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

        XCTAssertEqual(viewModel.primaryAction, .localSummarySaved)
        XCTAssertEqual(viewModel.errorMessage, "Notion 同步失败，可直接重试，不会再次生成总结。")
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
                "会议正在总结或同步，暂时不能重命名。"
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

    func testExplicitSyncUsesWholeMeetingWithoutGeneration()
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

        await viewModel.syncMeetingToNotion()

        XCTAssertTrue(documentManager.generatedKinds.isEmpty)
        XCTAssertTrue(documentManager.retriedKinds.isEmpty)
        XCTAssertEqual(documentManager.syncedMeetingIDs, [meetingID])
    }

    func testMeetingSyncButtonUsesMeetingLevelState()
        throws {
        let expectations: [
            (MeetingNotionSyncState, String, Bool)
        ] = [
            (.localOnly, "尚未同步", true),
            (.failed, "同步失败", true),
            (.synced, "已同步", true),
            (.syncing, "正在同步", false),
        ]

        for (syncState, status, isEnabled) in expectations {
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
            let meeting = try repository.meeting(id: meetingID)
            meeting.notionSyncState = syncState
            if syncState == .synced {
                meeting.notionSyncedContentRevision = meeting.contentRevision
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
                viewModel.notionSyncButtonTitle,
                "同步到 Notion"
            )
            XCTAssertEqual(
                viewModel.notionSyncStatusTitle,
                status,
                "Unexpected status for \(syncState)"
            )
            XCTAssertEqual(
                viewModel.canSyncMeetingToNotion,
                isEnabled,
                "Unexpected enabled state for \(syncState)"
            )
        }
    }

    func testSyncButtonShowsDirtyWhenMeetingRevisionExceedsSyncedRevision()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "原总结",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            ),
            model: "test-model"
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.notionSyncState = .synced
        meeting.notionSyncedContentRevision = meeting.contentRevision
        try repository.updateSummaryManually(
            meetingID: meetingID,
            value: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "已修改总结",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            )
        )

        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            documentManager: DetailDocumentManagerSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        XCTAssertEqual(viewModel.notionSyncButtonTitle, "同步到 Notion")
        XCTAssertEqual(viewModel.notionSyncStatusTitle, "有本地更改待同步")
        XCTAssertTrue(viewModel.canSyncMeetingToNotion)
    }

    func testSyncButtonIsHiddenWithoutAnyDocumentOrNotion() throws {
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

        XCTAssertNil(noDocument.notionSyncButtonTitle)

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

        XCTAssertNil(notionDisabled.notionSyncButtonTitle)
        XCTAssertFalse(
            notionDisabled.canSyncMeetingToNotion
        )
    }

    func testSyncActionHandlesLocalOnlyAndSyncedWithoutGeneration()
        async throws {
        for syncState in [
            MeetingNotionSyncState.localOnly,
            .synced,
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
            let meeting = try repository.meeting(id: meetingID)
            meeting.notionSyncState = syncState
            if syncState == .synced {
                meeting.notionSyncedContentRevision = meeting.contentRevision
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

            await viewModel.syncMeetingToNotion()

            XCTAssertTrue(documentManager.generatedKinds.isEmpty)
            XCTAssertTrue(documentManager.retriedKinds.isEmpty)
            XCTAssertEqual(documentManager.syncedMeetingIDs, [meetingID])
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

    func testTranscriptDraftSurvivesReloadAndFlushesAsCanonicalCorrection()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 1,
            end: 2,
            text: "原始转录"
        )
        let entry = try XCTUnwrap(
            repository.canonicalTranscripts(meetingID: meetingID).first
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        viewModel.updateTranscriptDraft("人工纠正", for: entry)
        viewModel.load()

        XCTAssertEqual(
            viewModel.transcriptDraftText(for: entry),
            "人工纠正"
        )
        XCTAssertTrue(viewModel.hasPendingEdits)

        await viewModel.flushEdits()

        XCTAssertEqual(
            try repository.canonicalTranscripts(meetingID: meetingID)
                .map(\.text),
            ["人工纠正"]
        )
        XCTAssertFalse(viewModel.hasPendingEdits)
        XCTAssertEqual(viewModel.localSaveState, .saved)
    }

    func testExistingCorrectionAutosaveKeepsReboundIdentityAfterFinalization()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 10,
                        endTime: 12,
                        text: "旧生成文字"
                    ),
                    speakerID: "room-old",
                    source: .room
                )
            ],
            sourceRevision: 1
        )
        let oldTranscriptID = try XCTUnwrap(
            repository.transcripts(meetingID: meetingID).first?.id
        )
        try repository.saveTranscriptCorrection(
            meetingID: meetingID,
            transcriptIDs: [oldTranscriptID],
            anchorStartTime: 10,
            anchorEndTime: 12,
            source: .room,
            originalText: "旧生成文字",
            replacementText: "第一次人工修正"
        )
        let initialEntry = try XCTUnwrap(
            repository.canonicalTranscripts(meetingID: meetingID).first
        )
        let correctionID = initialEntry.id
        let delay = ControlledMeetingEditDelay()
        let completion = MeetingEditAutosaverCompletionBarrier()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            },
            onDelayedTaskCompletion: {
                completion.signal()
            }
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy(),
            editAutosaver: autosaver
        )

        viewModel.updateTranscriptDraft("最新人工修正", for: initialEntry)
        let initialDraft = try XCTUnwrap(viewModel.transcriptDrafts.first)
        XCTAssertEqual(initialDraft.target.canonicalEntryID, correctionID)
        XCTAssertEqual(initialDraft.target.correctionID, correctionID)
        await delay.waitForCallCount(1)
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 9.75,
                        endTime: 12.25,
                        text: "最终生成文字"
                    ),
                    speakerID: "room-new",
                    source: .room
                )
            ],
            sourceRevision: 2
        )
        let newTranscriptID = try XCTUnwrap(
            repository.transcripts(meetingID: meetingID).first?.id
        )

        await viewModel.flushEdits()
        delay.release(call: 0)
        try await completion.wait(for: 1)

        let meeting = try repository.meeting(id: meetingID)
        let correction = try XCTUnwrap(meeting.transcriptCorrections.first)
        XCTAssertEqual(meeting.transcriptCorrections.count, 1)
        XCTAssertEqual(correction.id, correctionID)
        XCTAssertEqual(correction.replacementText, "最新人工修正")
        XCTAssertEqual(correction.transcriptIDs, [newTranscriptID])
        XCTAssertEqual(correction.anchorStartTime, 9.75, accuracy: 0.001)
        XCTAssertEqual(correction.anchorEndTime, 12.25, accuracy: 0.001)
        XCTAssertEqual(correction.source, .room)

        let canonical = try repository.canonicalTranscripts(
            meetingID: meetingID
        )
        let corrected = try XCTUnwrap(canonical.first)
        XCTAssertEqual(canonical.count, 1)
        XCTAssertEqual(corrected.id, correctionID)
        XCTAssertEqual(corrected.text, "最新人工修正")
        XCTAssertEqual(corrected.transcriptIDs, [newTranscriptID])
        XCTAssertEqual(corrected.startTime, 9.75, accuracy: 0.001)
        XCTAssertEqual(corrected.endTime, 12.25, accuracy: 0.001)
        XCTAssertEqual(corrected.speakerID, "room-new")
    }

    func testFirstCorrectionAutosaveReattachesToUniqueFinalizedTranscript()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 20,
                        endTime: 22,
                        text: "实时生成文字"
                    ),
                    speakerID: "room-old",
                    source: .room
                )
            ],
            sourceRevision: 1
        )
        let initialEntry = try XCTUnwrap(
            repository.canonicalTranscripts(meetingID: meetingID).first
        )
        XCTAssertFalse(initialEntry.isManuallyEdited)
        let delay = ControlledMeetingEditDelay()
        let completion = MeetingEditAutosaverCompletionBarrier()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            },
            onDelayedTaskCompletion: {
                completion.signal()
            }
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy(),
            editAutosaver: autosaver
        )

        viewModel.updateTranscriptDraft("用户最新文字", for: initialEntry)
        let initialDraft = try XCTUnwrap(viewModel.transcriptDrafts.first)
        XCTAssertEqual(initialDraft.target.canonicalEntryID, initialEntry.id)
        XCTAssertNil(initialDraft.target.correctionID)
        await delay.waitForCallCount(1)
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 19.8,
                        endTime: 22.2,
                        text: "最终生成文字"
                    ),
                    speakerID: "room-new",
                    source: .room
                )
            ],
            sourceRevision: 2
        )
        let newTranscriptID = try XCTUnwrap(
            repository.transcripts(meetingID: meetingID).first?.id
        )

        await viewModel.flushEdits()
        delay.release(call: 0)
        try await completion.wait(for: 1)

        let meeting = try repository.meeting(id: meetingID)
        let correction = try XCTUnwrap(meeting.transcriptCorrections.first)
        XCTAssertEqual(meeting.transcriptCorrections.count, 1)
        XCTAssertEqual(correction.replacementText, "用户最新文字")
        XCTAssertEqual(correction.transcriptIDs, [newTranscriptID])
        XCTAssertEqual(correction.anchorStartTime, 19.8, accuracy: 0.001)
        XCTAssertEqual(correction.anchorEndTime, 22.2, accuracy: 0.001)
        XCTAssertEqual(correction.source, .room)

        let canonical = try repository.canonicalTranscripts(
            meetingID: meetingID
        )
        let corrected = try XCTUnwrap(canonical.first)
        XCTAssertEqual(canonical.count, 1)
        XCTAssertEqual(corrected.id, correction.id)
        XCTAssertEqual(corrected.text, "用户最新文字")
        XCTAssertEqual(corrected.transcriptIDs, [newTranscriptID])
        XCTAssertEqual(corrected.startTime, 19.8, accuracy: 0.001)
        XCTAssertEqual(corrected.endTime, 22.2, accuracy: 0.001)
        XCTAssertEqual(corrected.speakerID, "room-new")
    }

    func testReloadReconcilesDirtyCorrectionTargetWithoutReplacingTypedText()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 30,
                        endTime: 32,
                        text: "旧生成文字"
                    ),
                    speakerID: "room-old",
                    source: .room
                )
            ],
            sourceRevision: 1
        )
        let oldTranscriptID = try XCTUnwrap(
            repository.transcripts(meetingID: meetingID).first?.id
        )
        try repository.saveTranscriptCorrection(
            meetingID: meetingID,
            transcriptIDs: [oldTranscriptID],
            anchorStartTime: 30,
            anchorEndTime: 32,
            source: .room,
            originalText: "旧生成文字",
            replacementText: "原人工文字"
        )
        let initialEntry = try XCTUnwrap(
            repository.canonicalTranscripts(meetingID: meetingID).first
        )
        let correctionID = initialEntry.id
        let delay = ControlledMeetingEditDelay()
        let completion = MeetingEditAutosaverCompletionBarrier()
        let autosaver = MeetingEditAutosaver(
            delay: { duration in
                try await delay.suspend(for: duration)
            },
            onDelayedTaskCompletion: {
                completion.signal()
            }
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy(),
            editAutosaver: autosaver
        )

        viewModel.updateTranscriptDraft("键盘中的最新文字", for: initialEntry)
        await delay.waitForCallCount(1)
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 29.8,
                        endTime: 32.2,
                        text: "最终生成文字"
                    ),
                    speakerID: "room-new",
                    source: .room
                )
            ],
            sourceRevision: 2
        )
        let newTranscriptID = try XCTUnwrap(
            repository.transcripts(meetingID: meetingID).first?.id
        )

        viewModel.load()

        let currentEntry = try XCTUnwrap(
            repository.canonicalTranscripts(meetingID: meetingID).first
        )
        let pending = try XCTUnwrap(viewModel.transcriptDrafts.first)
        XCTAssertEqual(viewModel.transcriptDrafts.count, 1)
        XCTAssertEqual(currentEntry.id, correctionID)
        XCTAssertEqual(
            viewModel.transcriptDraftText(for: currentEntry),
            "键盘中的最新文字"
        )
        XCTAssertEqual(pending.text, "键盘中的最新文字")
        XCTAssertEqual(pending.target.canonicalEntryID, correctionID)
        XCTAssertEqual(pending.target.correctionID, correctionID)
        XCTAssertEqual(pending.target.transcriptIDs, [newTranscriptID])
        XCTAssertEqual(pending.target.anchorStartTime, 29.8, accuracy: 0.001)
        XCTAssertEqual(pending.target.anchorEndTime, 32.2, accuracy: 0.001)
        XCTAssertEqual(pending.target.source, .room)

        await viewModel.flushEdits()
        delay.release(call: 0)
        try await completion.wait(for: 1)
        XCTAssertEqual(
            try repository.canonicalTranscripts(meetingID: meetingID)
                .map(\.text),
            ["键盘中的最新文字"]
        )
    }

    func testStructuredDraftsFlushThroughManualRepositoryUpdates()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "原重点总结",
                keyPoints: ["原要点"],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            ),
            model: "test-model"
        )
        try repository.saveGeneratedDetailedMinutes(
            meetingID: meetingID,
            generated: GeneratedDetailedMinutes(
                overview: "原完整纪要",
                sections: [],
                decisions: [],
                actionItems: [],
                openQuestions: []
            ),
            model: "test-model",
            promptVersion: 1
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )
        let editedSummary = GeneratedMeetingSummary(
            suggestedTitle: "",
            overview: "编辑后的重点总结",
            keyPoints: ["新要点"],
            decisions: ["新决策"],
            actionItems: [
                ActionItem(task: "新任务", owner: "张三", dueDate: nil)
            ],
            bookmarkInsights: ["新书签见解"]
        )
        let editedMinutes = GeneratedDetailedMinutes(
            overview: "编辑后的完整纪要",
            sections: [
                DetailedMinutesSection(
                    title: "议题",
                    timeRange: nil,
                    speakers: ["张三"],
                    content: "议题内容"
                )
            ],
            decisions: ["纪要决策"],
            actionItems: [
                ActionItem(task: "纪要任务", owner: "李四", dueDate: nil)
            ],
            openQuestions: ["待确认"]
        )

        viewModel.updateSummaryDraft(editedSummary)
        viewModel.updateDetailedMinutesDraft(editedMinutes)
        await viewModel.flushEdits()

        let meeting = try repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.overview, editedSummary.overview)
        XCTAssertEqual(
            meeting.summary?.actionItemRecords,
            editedSummary.actionItems
        )
        XCTAssertTrue(meeting.summary?.isManuallyEdited == true)
        XCTAssertEqual(
            try meeting.detailedMinutes?.sections,
            editedMinutes.sections
        )
        XCTAssertTrue(meeting.detailedMinutes?.isManuallyEdited == true)
        XCTAssertFalse(viewModel.hasPendingEdits)
        XCTAssertEqual(viewModel.localSaveState, .saved)
    }

    func testRepositoryReloadCannotOverwriteDirtySummaryDraft() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "已保存的旧文本",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            ),
            model: "test-model"
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )
        let edited = GeneratedMeetingSummary(
            suggestedTitle: "",
            overview: "尚未落盘的键盘输入",
            keyPoints: [],
            decisions: [],
            actionItems: [],
            bookmarkInsights: []
        )
        viewModel.updateSummaryDraft(edited)

        try repository.updateTitle(
            meetingID: meetingID,
            title: "后台更新的会议标题"
        )
        viewModel.load()

        XCTAssertEqual(viewModel.meeting?.title, "后台更新的会议标题")
        XCTAssertEqual(viewModel.summaryDraft, edited)
        XCTAssertTrue(viewModel.hasPendingEdits)
        await viewModel.flushEdits()
    }

    func testViewModelSaveFailureKeepsDraftAndRetryPersists() async throws {
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
        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "旧总结",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            ),
            model: "test-model"
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )
        let edited = GeneratedMeetingSummary(
            suggestedTitle: "",
            overview: "需要重试的本地草稿",
            keyPoints: [],
            decisions: [],
            actionItems: [],
            bookmarkInsights: []
        )
        viewModel.updateSummaryDraft(edited)
        failure.shouldFail = true

        await viewModel.flushEdits()

        XCTAssertEqual(viewModel.summaryDraft, edited)
        XCTAssertTrue(viewModel.hasPendingEdits)
        XCTAssertEqual(
            viewModel.localSaveState,
            .failed(message: "无法自动保存本地修改，请稍后重试。")
        )
        XCTAssertEqual(
            try repository.meeting(id: meetingID).summary?.overview,
            "旧总结"
        )

        failure.shouldFail = false
        await viewModel.retrySavingEdits()

        XCTAssertEqual(
            try repository.meeting(id: meetingID).summary?.overview,
            edited.overview
        )
        XCTAssertFalse(viewModel.hasPendingEdits)
        XCTAssertEqual(viewModel.localSaveState, .saved)
    }

    func testMeetingSwitchFlushesOriginalMeetingOnly() async throws {
        let repository = try MeetingRepository.inMemory()
        let originalMeetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let newMeetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now.addingTimeInterval(1)
        )
        try repository.appendTranscript(
            meetingID: originalMeetingID,
            start: 0,
            end: 1,
            text: "原会议文本"
        )
        try repository.appendTranscript(
            meetingID: newMeetingID,
            start: 0,
            end: 1,
            text: "新会议文本"
        )
        let originalEntry = try XCTUnwrap(
            repository.canonicalTranscripts(
                meetingID: originalMeetingID
            ).first
        )
        let originalViewModel = MeetingDetailViewModel(
            meetingID: originalMeetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )
        originalViewModel.updateTranscriptDraft(
            "原会议已纠正",
            for: originalEntry
        )

        let selectedViewModel = MeetingDetailViewModel(
            meetingID: newMeetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )
        await originalViewModel.flushEdits()

        XCTAssertEqual(selectedViewModel.meetingID, newMeetingID)
        XCTAssertEqual(
            try repository.canonicalTranscripts(
                meetingID: originalMeetingID
            ).map(\.text),
            ["原会议已纠正"]
        )
        XCTAssertEqual(
            try repository.canonicalTranscripts(
                meetingID: newMeetingID
            ).map(\.text),
            ["新会议文本"]
        )
        XCTAssertEqual(selectedViewModel.localSaveState, .idle)
    }

    func testInlineEditableFieldsUpdateAllDraftKindsImmediately() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "原转录"
        )
        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "原重点总结",
                keyPoints: ["原要点"],
                decisions: ["原决定"],
                actionItems: [
                    ActionItem(
                        task: "原行动项",
                        owner: "原负责人",
                        dueDate: "周五"
                    )
                ],
                bookmarkInsights: ["原书签洞察"]
            ),
            model: "test-model"
        )
        try repository.saveGeneratedDetailedMinutes(
            meetingID: meetingID,
            generated: GeneratedDetailedMinutes(
                overview: "原完整纪要",
                sections: [
                    DetailedMinutesSection(
                        title: "原议题",
                        timeRange: "00:00–00:01",
                        speakers: ["原发言人"],
                        content: "原议题内容"
                    )
                ],
                decisions: ["原纪要决定"],
                actionItems: [
                    ActionItem(
                        task: "原纪要行动项",
                        owner: "原纪要负责人",
                        dueDate: nil
                    )
                ],
                openQuestions: ["原待确认问题"]
            ),
            model: "test-model",
            promptVersion: 1
        )
        let entry = try XCTUnwrap(
            repository.canonicalTranscripts(meetingID: meetingID).first
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        viewModel.updateTranscriptDraft("键盘中的转录", for: entry)
        XCTAssertTrue(
            viewModel.updateDocumentDraftText(
                "键盘中的重点总结",
                field: .summaryOverview
            )
        )
        XCTAssertTrue(
            viewModel.updateDocumentDraftText(
                "键盘中的完整纪要",
                field: .detailedMinutesOverview
            )
        )

        XCTAssertEqual(
            viewModel.transcriptDraftText(for: entry),
            "键盘中的转录"
        )
        XCTAssertEqual(
            viewModel.documentDraftText(field: .summaryOverview),
            "键盘中的重点总结"
        )
        XCTAssertEqual(
            viewModel.documentDraftText(field: .detailedMinutesOverview),
            "键盘中的完整纪要"
        )
        XCTAssertTrue(viewModel.hasPendingEdits)
    }

    func testOriginalVisibleStructuredFieldsUpdateWithoutFlatteningDocuments()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "原建议标题",
                overview: "概览",
                keyPoints: ["要点"],
                decisions: ["决定"],
                actionItems: [
                    ActionItem(task: "任务", owner: "负责人", dueDate: "周五")
                ],
                bookmarkInsights: ["后端保留但未显示"]
            ),
            model: "test-model"
        )
        try repository.saveGeneratedDetailedMinutes(
            meetingID: meetingID,
            generated: GeneratedDetailedMinutes(
                overview: "纪要概览",
                sections: [
                    DetailedMinutesSection(
                        title: "议题",
                        timeRange: "00:00–00:10",
                        speakers: ["甲", "乙"],
                        content: "内容"
                    )
                ],
                decisions: ["纪要决定"],
                actionItems: [
                    ActionItem(task: "纪要任务", owner: "丙", dueDate: nil)
                ],
                openQuestions: ["待确认"]
            ),
            model: "test-model",
            promptVersion: 1
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )
        let edits: [(MeetingEditableDocumentField, String)] = [
            (.summaryKeyPoint(0), "新要点"),
            (.summaryDecision(0), "新决定"),
            (.summaryActionTask(0), "新任务"),
            (.summaryActionOwner(0), "新负责人"),
            (.detailedMinutesSectionTitle(0), "新议题"),
            (.detailedMinutesSectionSpeaker(section: 0, speaker: 1), "丁"),
            (.detailedMinutesSectionContent(0), "新内容"),
            (.detailedMinutesDecision(0), "新纪要决定"),
            (.detailedMinutesActionTask(0), "新纪要任务"),
            (.detailedMinutesActionOwner(0), "戊"),
            (.detailedMinutesOpenQuestion(0), "新待确认")
        ]

        for (field, value) in edits {
            XCTAssertTrue(viewModel.updateDocumentDraftText(value, field: field))
            XCTAssertEqual(viewModel.documentDraftText(field: field), value)
        }

        XCTAssertEqual(
            viewModel.summaryDraft?.bookmarkInsights,
            ["后端保留但未显示"]
        )
        XCTAssertEqual(viewModel.summaryDraft?.suggestedTitle, "原建议标题")
        XCTAssertEqual(viewModel.summaryDraft?.actionItems[0].dueDate, "周五")
        XCTAssertEqual(
            viewModel.detailedMinutesDraft?.sections[0].timeRange,
            "00:00–00:10"
        )
    }

    func testReplacementPreviewCancelAndApplyUseConfirmedTaskFourPreview()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let currentMeetingID = try makeExactReplacementMeeting(
            in: repository,
            startedAt: .now,
            title: "当前会议"
        )
        let isolatedMeetingID = try makeExactReplacementMeeting(
            in: repository,
            startedAt: .now.addingTimeInterval(-100),
            title: "隔离会议"
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: currentMeetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        await viewModel.prepareExactReplacement(
            searchText: "错名",
            replacementText: "正确名"
        )

        let preview = try XCTUnwrap(viewModel.replacementPreview)
        XCTAssertEqual(preview.meetingID, currentMeetingID)
        XCTAssertEqual(preview.transcriptMatches, 2)
        XCTAssertEqual(preview.speakerMatches, 1)
        XCTAssertEqual(preview.summaryMatches, 6)
        XCTAssertEqual(preview.detailedMinutesMatches, 8)
        XCTAssertEqual(preview.totalMatches, 17)

        viewModel.cancelExactReplacement()

        XCTAssertNil(viewModel.replacementPreview)
        XCTAssertEqual(
            try repository.canonicalTranscripts(
                meetingID: currentMeetingID
            ).first?.text,
            "错名跟进错名任务"
        )

        await viewModel.prepareExactReplacement(
            searchText: "错名",
            replacementText: "正确名"
        )
        let applied = await viewModel.confirmExactReplacement()
        XCTAssertTrue(applied)

        XCTAssertNil(viewModel.replacementPreview)
        XCTAssertEqual(
            try repository.canonicalTranscripts(
                meetingID: currentMeetingID
            ).first?.text,
            "正确名跟进正确名任务"
        )
        XCTAssertEqual(
            try repository.canonicalTranscripts(
                meetingID: isolatedMeetingID
            ).first?.text,
            "错名跟进错名任务"
        )
    }

    func testStaleReplacementPreviewRefreshesWithoutApplying() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeExactReplacementMeeting(
            in: repository,
            startedAt: .now,
            title: "内容变化会议"
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )
        await viewModel.prepareExactReplacement(
            searchText: "错名",
            replacementText: "正确名"
        )
        let staleRevision = try XCTUnwrap(
            viewModel.replacementPreview?.observedContentRevision
        )
        let summary = try XCTUnwrap(
            try repository.meeting(id: meetingID).summary
        )
        try repository.updateSummaryManually(
            meetingID: meetingID,
            value: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: summary.overview + "错名",
                keyPoints: summary.keyPoints,
                decisions: summary.decisions,
                actionItems: summary.actionItemRecords,
                bookmarkInsights: summary.bookmarkInsights
            )
        )

        let applied = await viewModel.confirmExactReplacement()
        XCTAssertFalse(applied)

        let refreshed = try XCTUnwrap(viewModel.replacementPreview)
        XCTAssertGreaterThan(refreshed.observedContentRevision, staleRevision)
        XCTAssertEqual(refreshed.summaryMatches, 7)
        XCTAssertEqual(
            viewModel.replacementErrorMessage,
            "会议内容已变化，请确认更新后的替换范围。"
        )
        XCTAssertEqual(
            try repository.canonicalTranscripts(
                meetingID: meetingID
            ).first?.text,
            "错名跟进错名任务"
        )
    }

    func testManualDocumentRegenerationRequiresExplicitDestructiveIntent()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "可生成的最终转录",
            isFinal: true
        )
        try repository.finalizeMeeting(
            id: meetingID,
            endedAt: .now,
            activeDuration: 1
        )
        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "生成的总结",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            ),
            model: "test-model"
        )
        try repository.updateSummaryManually(
            meetingID: meetingID,
            value: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "人工修改的总结",
                keyPoints: [],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            )
        )
        let manager = DetailDocumentManagerSpy()
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            documentManager: manager,
            titleUpdater: DetailTitleUpdaterSpy()
        )

        XCTAssertTrue(
            viewModel.selectedDocumentRequiresRegenerationConfirmation
        )

        await viewModel.generateSelectedDocument()
        XCTAssertTrue(manager.generatedKinds.isEmpty)

        await viewModel.generateSelectedDocument(replacingManualEdits: true)
        XCTAssertEqual(manager.generatedKinds, [.summary])
        XCTAssertEqual(manager.generatedReplacingManualEdits, [true])
    }

    func testTimelineNoteDraftAutosavesAndRetryPersistsAfterFailure()
        async throws {
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
        let noteID = UUID()
        try repository.upsertNote(
            meetingID: meetingID,
            id: noteID,
            timestamp: 4,
            text: "原笔记",
            sequenceIndex: 0
        )
        let note = MeetingNoteDisplayItem(
            id: noteID,
            timestamp: 4,
            text: "原笔记",
            sequenceIndex: 0
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy()
        )

        viewModel.updateNoteDraft("修正后的笔记", for: note)
        failure.shouldFail = true
        await viewModel.flushEdits()

        XCTAssertEqual(viewModel.noteDraftText(for: note), "修正后的笔记")
        XCTAssertTrue(viewModel.hasPendingEdits)
        XCTAssertEqual(
            try repository.notes(meetingID: meetingID).first?.text,
            "原笔记"
        )

        failure.shouldFail = false
        await viewModel.retrySavingEdits()

        XCTAssertEqual(
            try repository.notes(meetingID: meetingID).first?.text,
            "修正后的笔记"
        )
        XCTAssertFalse(viewModel.hasPendingEdits)
        XCTAssertEqual(viewModel.localSaveState, .saved)
    }

    func testScreenshotDeleteRestoresFileAndRecordWhenRepositorySaveFails()
        async throws {
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
        let screenshotID = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingTimelineDelete-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let fileStore = MeetingFileStore(rootURL: root)
        let relativePath = try await fileStore.saveScreenshotPNG(
            Data([0x89, 0x50, 0x4E, 0x47]),
            meetingID: meetingID,
            screenshotID: screenshotID
        )
        try repository.appendScreenshot(
            meetingID: meetingID,
            id: screenshotID,
            timestamp: 2,
            relativePath: relativePath,
            pixelWidth: 100,
            pixelHeight: 80,
            byteCount: 4,
            sequenceIndex: 0
        )
        let screenshot = MeetingScreenshotDisplayItem(
            id: screenshotID,
            timestamp: 2,
            relativePath: relativePath,
            pixelWidth: 100,
            pixelHeight: 80,
            byteCount: 4,
            sequenceIndex: 0
        )
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy(),
            fileStore: fileStore
        )
        failure.shouldFail = true

        let deleted = await viewModel.deleteScreenshot(screenshot)

        XCTAssertFalse(deleted)
        XCTAssertEqual(
            try repository.screenshots(meetingID: meetingID).map(\.id),
            [screenshotID]
        )
        let restoredURL = try await fileStore.resolveScreenshotURL(
            meetingID: meetingID,
            relativePath: relativePath
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredURL.path))
    }

    func testScreenshotPreviewRejectsExternalAbsolutePath() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MeetingTimelinePreview-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let viewModel = MeetingDetailViewModel(
            meetingID: meetingID,
            repository: repository,
            settingsStore: makeSettingsStore(),
            action: DetailActionSpy(),
            titleUpdater: DetailTitleUpdaterSpy(),
            fileStore: MeetingFileStore(rootURL: root)
        )
        let screenshot = MeetingScreenshotDisplayItem(
            id: UUID(),
            timestamp: 0,
            relativePath: "/tmp/outside.png",
            pixelWidth: 1,
            pixelHeight: 1,
            byteCount: 1,
            sequenceIndex: 0
        )

        let previewURL = await viewModel.screenshotPreviewURL(for: screenshot)

        XCTAssertNil(previewURL)
    }

    private func makeExactReplacementMeeting(
        in repository: MeetingRepository,
        startedAt: Date,
        title: String
    ) throws -> UUID {
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: startedAt,
            title: title
        )
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 0,
                        endTime: 2,
                        text: "错名跟进错名任务"
                    ),
                    speakerID: "room-1",
                    source: .room
                )
            ],
            sourceRevision: 1
        )
        try repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "room-1",
            displayName: "错名"
        )
        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "",
                overview: "错名确认范围",
                keyPoints: ["错名确认要点"],
                decisions: ["错名批准决定"],
                actionItems: [
                    ActionItem(
                        task: "错名准备发布",
                        owner: "错名",
                        dueDate: nil
                    )
                ],
                bookmarkInsights: ["错名书签洞察"]
            ),
            model: "test-model"
        )
        try repository.saveGeneratedDetailedMinutes(
            meetingID: meetingID,
            generated: GeneratedDetailedMinutes(
                overview: "错名纪要概览",
                sections: [
                    DetailedMinutesSection(
                        title: "错名议题",
                        timeRange: "00:00–00:02",
                        speakers: ["错名"],
                        content: "错名议题内容"
                    )
                ],
                decisions: ["错名纪要决定"],
                actionItems: [
                    ActionItem(task: "错名纪要任务", owner: "错名", dueDate: nil)
                ],
                openQuestions: ["错名待确认"]
            ),
            model: "test-model",
            promptVersion: 1
        )
        return meetingID
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
    private(set) var generatedReplacingManualEdits: [Bool] = []
    private(set) var retriedKinds: [MeetingDocumentKind] = []
    private(set) var syncedMeetingIDs: [UUID] = []

    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        replacingManualEdits: Bool
    ) async throws {
        _ = meetingID
        generatedKinds.append(kind)
        generatedReplacingManualEdits.append(replacingManualEdits)
    }

    func retryArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) async throws {
        _ = meetingID
        retriedKinds.append(kind)
    }

    func syncToNotion(meetingID: UUID) async throws {
        syncedMeetingIDs.append(meetingID)
    }
}

private final class InlineContextMenuTarget: NSObject {
    @objc func requestReplacement(_ sender: Any?) {
        _ = sender
    }
}

@MainActor
private final class BlockingDetailDocumentManager: MeetingDocumentManaging {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        replacingManualEdits: Bool
    ) async throws {
        _ = meetingID
        _ = kind
        _ = replacingManualEdits
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

    func syncToNotion(meetingID: UUID) async throws {
        _ = meetingID
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

    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        replacingManualEdits: Bool
    ) async throws {
        _ = meetingID
        _ = kind
        _ = replacingManualEdits
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

    func syncToNotion(meetingID: UUID) async throws {
        _ = meetingID
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
