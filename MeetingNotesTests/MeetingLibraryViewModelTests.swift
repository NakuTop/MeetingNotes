import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingLibraryViewModelTests: XCTestCase {
    func testLoadPreservesRepositoryOrderAndKeepsSelectionWhenPossible() {
        let mostRecentlyPinned = makeMeeting(
            seconds: 100,
            title: "最近置顶会议"
        )
        let previouslyPinned = makeMeeting(
            seconds: 300,
            title: "较早置顶会议"
        )
        let unpinned = makeMeeting(seconds: 200, title: "普通会议")
        let repository = LibraryRepositorySpy(
            meetings: [mostRecentlyPinned, previouslyPinned, unpinned]
        )
        let viewModel = makeViewModel(repository: repository)
        viewModel.select(previouslyPinned.id)

        viewModel.load()

        XCTAssertEqual(
            viewModel.meetings.map(\.id),
            [mostRecentlyPinned.id, previouslyPinned.id, unpinned.id]
        )
        XCTAssertEqual(viewModel.selectedMeetingID, previouslyPinned.id)
        XCTAssertEqual(viewModel.selectedMeeting?.id, previouslyPinned.id)
    }

    func testLoadClearsSelectionWhenMeetingNoLongerExists() {
        let meeting = makeMeeting(seconds: 100)
        let repository = LibraryRepositorySpy(meetings: [meeting])
        let viewModel = makeViewModel(repository: repository)
        viewModel.select(meeting.id)
        repository.storedMeetings = []

        viewModel.load()

        XCTAssertNil(viewModel.selectedMeetingID)
        XCTAssertNil(viewModel.selectedMeeting)
    }

    func testReturnHomeClearsOnlySelectionAndPreservesHistory() {
        let first = makeMeeting(seconds: 100, title: "第一次会议")
        let second = makeMeeting(seconds: 200, title: "第二次会议")
        let repository = LibraryRepositorySpy(meetings: [second, first])
        let viewModel = makeViewModel(repository: repository)
        viewModel.load()
        viewModel.select(second.id)

        viewModel.returnHome()

        XCTAssertNil(viewModel.selectedMeetingID)
        XCTAssertEqual(viewModel.meetings.map(\.id), [second.id, first.id])
    }

    func testTogglePinnedSetsRequestedDateReloadsRepositoryOrderAndThenUnpins() {
        let meeting = makeMeeting(seconds: 100)
        let other = makeMeeting(seconds: 200)
        let repository = LibraryRepositorySpy(meetings: [other, meeting])
        let viewModel = makeViewModel(repository: repository)
        viewModel.load()
        let pinnedAt = Date(timeIntervalSince1970: 500)
        repository.orderAfterPin = [meeting, other]

        viewModel.togglePinned(id: meeting.id, at: pinnedAt)

        XCTAssertEqual(
            repository.pinUpdates,
            [PinUpdate(meetingID: meeting.id, pinnedAt: pinnedAt)]
        )
        XCTAssertEqual(viewModel.meetings.map(\.id), [meeting.id, other.id])
        XCTAssertTrue(viewModel.pinningMeetingIDs.isEmpty)

        repository.orderAfterPin = [other, meeting]
        viewModel.togglePinned(id: meeting.id, at: .now)

        XCTAssertEqual(
            repository.pinUpdates.last,
            PinUpdate(meetingID: meeting.id, pinnedAt: nil)
        )
        XCTAssertEqual(viewModel.meetings.map(\.id), [other.id, meeting.id])
    }

    func testTogglePinnedFailureShowsOperationSpecificErrorAndClearsInFlightState() {
        let meeting = makeMeeting(seconds: 100)
        let repository = LibraryRepositorySpy(
            meetings: [meeting],
            pinError: TestFailure.expected
        )
        let viewModel = makeViewModel(repository: repository)
        viewModel.load()

        viewModel.togglePinned(
            id: meeting.id,
            at: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(viewModel.errorMessage, "无法置顶会议，请重试。")
        XCTAssertTrue(viewModel.pinningMeetingIDs.isEmpty)
        XCTAssertNil(meeting.pinnedAt)
    }

    func testRenameUsesSharedUpdaterTracksMeetingReloadsAndReturnsTrue() async {
        let meeting = makeMeeting(seconds: 100, title: "旧标题")
        let repository = LibraryRepositorySpy(meetings: [meeting])
        let updater = BlockingTitleUpdater { _, title in
            meeting.title = title
        }
        let viewModel = makeViewModel(
            repository: repository,
            titleUpdater: updater
        )
        viewModel.load()

        let operation = Task {
            await viewModel.renameMeeting(id: meeting.id, title: "新标题")
        }
        await updater.waitUntilStarted()

        XCTAssertEqual(viewModel.renamingMeetingIDs, [meeting.id])
        updater.finish()
        let succeeded = await operation.value

        XCTAssertTrue(succeeded)
        XCTAssertTrue(viewModel.renamingMeetingIDs.isEmpty)
        XCTAssertEqual(viewModel.meetings.first?.title, "新标题")
        XCTAssertEqual(
            updater.requests,
            [TitleUpdateRequest(meetingID: meeting.id, title: "新标题")]
        )
    }

    func testRenameFailureKeepsTitleReturnsFalseAndMapsExactError() async {
        let meeting = makeMeeting(seconds: 100, title: "旧标题")
        let updater = TitleUpdaterSpy(
            error: MeetingTitleUpdateError.missingNotionCredential
        )
        let viewModel = makeViewModel(
            repository: LibraryRepositorySpy(meetings: [meeting]),
            titleUpdater: updater
        )
        viewModel.load()

        let succeeded = await viewModel.renameMeeting(
            id: meeting.id,
            title: "新标题"
        )

        XCTAssertFalse(succeeded)
        XCTAssertEqual(viewModel.meetings.first?.title, "旧标题")
        XCTAssertEqual(
            viewModel.errorMessage,
            "请先在设置中保存 Notion Token，再重试重命名。"
        )
        XCTAssertTrue(viewModel.renamingMeetingIDs.isEmpty)
    }

    func testCancelledRenameIsSilentAndClearsInFlightState() async {
        let meeting = makeMeeting(seconds: 100, title: "旧标题")
        let viewModel = makeViewModel(
            repository: LibraryRepositorySpy(meetings: [meeting]),
            titleUpdater: TitleUpdaterSpy(error: CancellationError())
        )
        viewModel.load()

        let succeeded = await viewModel.renameMeeting(
            id: meeting.id,
            title: "不应保存"
        )

        XCTAssertFalse(succeeded)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.renamingMeetingIDs.isEmpty)
        XCTAssertEqual(viewModel.meetings.first?.title, "旧标题")
    }

    func testRenameDoesNotSubmitSameMeetingTwice() async {
        let meeting = makeMeeting(seconds: 100)
        let updater = BlockingTitleUpdater()
        let viewModel = makeViewModel(
            repository: LibraryRepositorySpy(meetings: [meeting]),
            titleUpdater: updater
        )
        viewModel.load()

        let first = Task {
            await viewModel.renameMeeting(id: meeting.id, title: "第一个标题")
        }
        await updater.waitUntilStarted()
        let secondSucceeded = await viewModel.renameMeeting(
            id: meeting.id,
            title: "第二个标题"
        )

        XCTAssertFalse(secondSucceeded)
        XCTAssertEqual(updater.requests.count, 1)
        updater.finish()
        _ = await first.value
    }

    func testDeleteAndRenameAvailabilityReflectMeetingState() {
        let viewModel = makeViewModel()
        let deleteExpectations: [RecordingState: Bool] = [
            .idle: true,
            .preparing: false,
            .recording: false,
            .paused: false,
            .finalizing: false,
            .ready: true,
            .summarizing: false,
            .summaryReady: true,
            .archiving: false,
            .archived: true
        ]
        let renameExpectations: [RecordingState: Bool] = [
            .idle: true,
            .preparing: true,
            .recording: true,
            .paused: true,
            .finalizing: true,
            .ready: true,
            .summarizing: false,
            .summaryReady: true,
            .archiving: false,
            .archived: true
        ]

        for state in RecordingState.allCases {
            let meeting = makeMeeting(seconds: 1, state: state)
            XCTAssertEqual(
                viewModel.canDelete(meeting),
                deleteExpectations[state],
                "Unexpected delete availability for \(state)"
            )
            XCTAssertEqual(
                viewModel.canRename(meeting),
                renameExpectations[state],
                "Unexpected rename availability for \(state)"
            )
        }
    }

    func testDeleteBusyMeetingDoesNotTouchFilesOrRepository() async {
        let meeting = makeMeeting(seconds: 100, state: .recording)
        let repository = LibraryRepositorySpy(meetings: [meeting])
        let files = FileDeletionSpy()
        let viewModel = makeViewModel(repository: repository, files: files)
        viewModel.load()

        await viewModel.deleteMeeting(id: meeting.id)

        XCTAssertEqual(
            viewModel.errorMessage,
            "会议正在录制或处理中，暂时不能删除。"
        )
        let deletedFileIDs = await files.deletedMeetingIDs()
        XCTAssertTrue(deletedFileIDs.isEmpty)
        XCTAssertTrue(repository.deletedIDs.isEmpty)
        XCTAssertEqual(viewModel.meetings.map(\.id), [meeting.id])
    }

    func testActiveRenameOrSummaryGateBlocksDeleteWithoutSideEffects() async {
        for operation in [
            MeetingOperationKind.rename,
            .summarizeArchive
        ] {
            let meeting = makeMeeting(seconds: 100, state: .ready)
            let repository = LibraryRepositorySpy(meetings: [meeting])
            let files = FileDeletionSpy()
            let gate = MeetingOperationGate()
            let playback = PlaybackStopperSpy()
            let viewModel = makeViewModel(
                repository: repository,
                files: files,
                operationGate: gate,
                playbackStopper: playback
            )
            viewModel.load()
            XCTAssertTrue(gate.acquire(operation, for: meeting.id))

            await viewModel.deleteMeeting(id: meeting.id)

            let deletedFileIDs = await files.deletedMeetingIDs()
            XCTAssertTrue(deletedFileIDs.isEmpty)
            XCTAssertTrue(repository.deletedIDs.isEmpty)
            XCTAssertTrue(playback.stoppedMeetingIDs.isEmpty)
            gate.release(operation, for: meeting.id)
        }
    }

    func testDeleteHoldsGateWhileAwaitingFileDeletion() async {
        let meeting = makeMeeting(seconds: 100, state: .ready)
        let repository = LibraryRepositorySpy(meetings: [meeting])
        let files = BlockingFileDeletionSpy()
        let gate = MeetingOperationGate()
        let viewModel = makeViewModel(
            repository: repository,
            files: files,
            operationGate: gate
        )
        viewModel.load()

        let deletion = Task {
            await viewModel.deleteMeeting(id: meeting.id)
        }
        await files.waitUntilStarted()

        XCTAssertTrue(gate.isActive(for: meeting.id))
        XCTAssertFalse(gate.acquire(.rename, for: meeting.id))
        await files.finish()
        await deletion.value
        XCTAssertFalse(gate.isActive(for: meeting.id))
    }

    func testDeleteRemovesAudioDirectoryAndMeetingThenClearsSelection() async {
        let meeting = makeMeeting(seconds: 100)
        let repository = LibraryRepositorySpy(meetings: [meeting])
        let files = FileDeletionSpy()
        let viewModel = makeViewModel(
            repository: repository,
            files: files
        )
        viewModel.select(meeting.id)

        await viewModel.deleteMeeting(id: meeting.id)

        let deletedFileIDs = await files.deletedMeetingIDs()
        XCTAssertEqual(deletedFileIDs, [meeting.id])
        XCTAssertEqual(repository.deletedIDs, [meeting.id])
        XCTAssertTrue(viewModel.meetings.isEmpty)
        XCTAssertNil(viewModel.selectedMeetingID)
    }

    func testDeleteStopsExactMeetingBeforeDeletingFilesAndRepository() async {
        let meeting = makeMeeting(seconds: 100)
        let events = DeletionEventRecorder()
        let repository = OrderedDeletionRepositorySpy(
            meetings: [meeting],
            events: events
        )
        let files = OrderedFileDeletionSpy(events: events)
        let playback = PlaybackStopperSpy(events: events)
        let viewModel = MeetingLibraryViewModel(
            repository: repository,
            fileDeleter: files,
            starter: MeetingStarterSpy(),
            titleUpdater: TitleUpdaterSpy(),
            operationGate: MeetingOperationGate(),
            playbackStopper: playback,
            systemRequirements: SystemRequirementsStub.supported
        )
        viewModel.load()

        await viewModel.deleteMeeting(id: meeting.id)

        XCTAssertEqual(playback.stoppedMeetingIDs, [meeting.id])
        XCTAssertEqual(events.values, [
            .stop(meeting.id),
            .deleteFiles(meeting.id),
            .deleteRepository(meeting.id)
        ])
    }

    func testDeleteFailureStillStopsPlaybackBeforeAttemptingFiles() async {
        let meeting = makeMeeting(seconds: 100)
        let events = DeletionEventRecorder()
        let repository = OrderedDeletionRepositorySpy(
            meetings: [meeting],
            events: events
        )
        let playback = PlaybackStopperSpy(events: events)
        let viewModel = MeetingLibraryViewModel(
            repository: repository,
            fileDeleter: OrderedFileDeletionSpy(
                events: events,
                error: TestFailure.expected
            ),
            starter: MeetingStarterSpy(),
            titleUpdater: TitleUpdaterSpy(),
            operationGate: MeetingOperationGate(),
            playbackStopper: playback,
            systemRequirements: SystemRequirementsStub.supported
        )
        viewModel.load()

        await viewModel.deleteMeeting(id: meeting.id)

        XCTAssertEqual(events.values, [
            .stop(meeting.id),
            .deleteFiles(meeting.id)
        ])
        XCTAssertTrue(repository.deletedIDs.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, "无法完整删除会议，请重试。")
    }

    func testRejectedDeleteDoesNotStopUnrelatedPlayback() async {
        let meeting = makeMeeting(seconds: 100, state: .recording)
        let playback = PlaybackStopperSpy()
        let viewModel = makeViewModel(
            repository: LibraryRepositorySpy(meetings: [meeting]),
            playbackStopper: playback
        )
        viewModel.load()

        await viewModel.deleteMeeting(id: meeting.id)

        XCTAssertTrue(playback.stoppedMeetingIDs.isEmpty)
    }

    func testStartEntriesPassOfflineAndOnlineModesToCoordinator() async {
        let repository = LibraryRepositorySpy()
        let starter = MeetingStarterSpy()
        let viewModel = makeViewModel(
            repository: repository,
            starter: starter
        )

        await viewModel.startMeeting(mode: .offline)
        await viewModel.startMeeting(mode: .online)

        let startedModes = await starter.modes()
        XCTAssertEqual(startedModes, [.offline, .online])
    }

    func testStartSelectsCreatedMeetingInsteadOfOlderPinnedMeeting() async {
        let pinned = makeMeeting(seconds: 100, title: "旧置顶会议")
        pinned.pinnedAt = Date(timeIntervalSince1970: 500)
        let created = makeMeeting(seconds: 600, title: "新会议")
        let repository = LibraryRepositorySpy(meetings: [pinned, created])
        let starter = MeetingStarterSpy(meetingID: created.id)
        let viewModel = makeViewModel(
            repository: repository,
            starter: starter
        )

        await viewModel.startMeeting(mode: .offline)

        XCTAssertEqual(viewModel.selectedMeetingID, created.id)
    }

    func testInsufficientDiskSpaceBlocksMeetingBeforeCoordinatorStarts() async {
        let starter = MeetingStarterSpy()
        let snapshot = SystemRequirements.evaluate(
            architecture: "arm64",
            systemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 0,
                patchVersion: 0
            ),
            availableDiskBytes: SystemRequirements.minimumFreeDiskBytes - 1
        )
        let viewModel = makeViewModel(
            starter: starter,
            systemRequirements: SystemRequirementsStub(snapshot: snapshot)
        )

        await viewModel.startMeeting(mode: .offline)

        let startedModes = await starter.modes()
        XCTAssertTrue(startedModes.isEmpty)
        XCTAssertEqual(
            viewModel.errorMessage,
            "可用磁盘空间不足 2 GB，无法安全开始录音。"
        )
    }

    func testPermissionDenialExposesMatchingSystemSettingsRepairs() async {
        let starter = MeetingStarterSpy(
            error: .permissionDenied([.microphone, .screenRecording])
        )
        let viewModel = makeViewModel(starter: starter)

        await viewModel.startMeeting(mode: .online)

        XCTAssertEqual(
            viewModel.permissionRepairPermissions,
            [.microphone, .screenRecording]
        )
        XCTAssertEqual(viewModel.lastFailedStartMode, .online)
        XCTAssertEqual(
            viewModel.errorMessage,
            "缺少麦克风、屏幕与系统音频录制权限，请在系统设置中允许后重试。屏幕录制权限更改后，macOS 可能要求完全退出并重新打开 App。"
        )
    }

    func testRetryLastStartUsesSameFailedModeOnceAndClearsRepairOnSuccess() async {
        let meetingID = UUID()
        let starter = SequencedMeetingStarterSpy(
            outcomes: [
                .failure(.permissionDenied([.screenRecording])),
                .success(meetingID)
            ]
        )
        let viewModel = makeViewModel(starter: starter)

        await viewModel.startMeeting(mode: .online)
        XCTAssertEqual(viewModel.lastFailedStartMode, .online)
        XCTAssertEqual(viewModel.permissionRepairPermissions, [.screenRecording])

        await viewModel.retryLastStart()

        let startedModes = await starter.modes()
        XCTAssertEqual(startedModes, [.online, .online])
        XCTAssertNil(viewModel.lastFailedStartMode)
        XCTAssertTrue(viewModel.permissionRepairPermissions.isEmpty)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.selectedMeetingID, meetingID)
    }

    func testRetryLastStartWithoutFailedModeIsNoOp() async {
        let starter = MeetingStarterSpy()
        let viewModel = makeViewModel(starter: starter)

        await viewModel.retryLastStart()

        let startedModes = await starter.modes()
        XCTAssertTrue(startedModes.isEmpty)
        XCTAssertFalse(viewModel.isStarting)
    }

    func testRetryClearsStaleRepairImmediatelyAndRejectsReentrantRetry() async {
        let starter = BlockingRetryMeetingStarterSpy()
        let viewModel = makeViewModel(starter: starter)
        await viewModel.startMeeting(mode: .online)

        let retry = Task {
            await viewModel.retryLastStart()
        }
        await starter.waitUntilRetryStarted()

        XCTAssertTrue(viewModel.isStarting)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.permissionRepairPermissions.isEmpty)
        XCTAssertNil(viewModel.lastFailedStartMode)

        await viewModel.retryLastStart()
        let startedModes = await starter.modes()
        XCTAssertEqual(startedModes, [.online, .online])

        await starter.finishRetry()
        await retry.value

        XCTAssertFalse(viewModel.isStarting)
        XCTAssertNil(viewModel.lastFailedStartMode)
    }

    func testUnrelatedPinFailureClearsPermissionRepairAndMakesRetryNoOp() async {
        let meeting = makeMeeting(seconds: 100)
        let repository = LibraryRepositorySpy(
            meetings: [meeting],
            pinError: TestFailure.expected
        )
        let starter = SequencedMeetingStarterSpy(
            outcomes: [
                .failure(.permissionDenied([.screenRecording]))
            ]
        )
        let viewModel = makeViewModel(
            repository: repository,
            starter: starter
        )
        viewModel.load()
        await viewModel.startMeeting(mode: .online)

        viewModel.togglePinned(id: meeting.id)

        XCTAssertEqual(viewModel.errorMessage, "无法置顶会议，请重试。")
        XCTAssertTrue(viewModel.permissionRepairPermissions.isEmpty)
        XCTAssertNil(viewModel.lastFailedStartMode)

        await viewModel.retryLastStart()
        let startedModes = await starter.modes()
        XCTAssertEqual(startedModes, [.online])
    }

    func testSuccessfulLoadClearsPermissionErrorAndRepairContext() async {
        let starter = SequencedMeetingStarterSpy(
            outcomes: [
                .failure(.permissionDenied([.screenRecording]))
            ]
        )
        let viewModel = makeViewModel(starter: starter)
        await viewModel.startMeeting(mode: .online)

        viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.permissionRepairPermissions.isEmpty)
        XCTAssertNil(viewModel.lastFailedStartMode)

        viewModel.reportControlFailure(TestFailure.expected)
        XCTAssertEqual(
            viewModel.errorMessage,
            "录音操作未完成，请返回主窗口重试。"
        )
        XCTAssertTrue(viewModel.permissionRepairPermissions.isEmpty)
        XCTAssertNil(viewModel.lastFailedStartMode)
    }

    func testDismissErrorClearsPermissionRepairContextAndMakesRetryNoOp() async {
        let starter = SequencedMeetingStarterSpy(
            outcomes: [
                .failure(.permissionDenied([.screenRecording]))
            ]
        )
        let viewModel = makeViewModel(starter: starter)
        await viewModel.startMeeting(mode: .online)

        viewModel.dismissError()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.permissionRepairPermissions.isEmpty)
        XCTAssertNil(viewModel.lastFailedStartMode)

        await viewModel.retryLastStart()
        let startedModes = await starter.modes()
        XCTAssertEqual(startedModes, [.online])
    }

    func testControlFailureReplacesPermissionErrorAndClearsRepairContext() async {
        let starter = SequencedMeetingStarterSpy(
            outcomes: [
                .failure(.permissionDenied([.microphone, .screenRecording]))
            ]
        )
        let viewModel = makeViewModel(starter: starter)
        await viewModel.startMeeting(mode: .online)

        viewModel.reportControlFailure(TestFailure.expected)

        XCTAssertEqual(
            viewModel.errorMessage,
            "录音操作未完成，请返回主窗口重试。"
        )
        XCTAssertTrue(viewModel.permissionRepairPermissions.isEmpty)
        XCTAssertNil(viewModel.lastFailedStartMode)

        await viewModel.retryLastStart()
        let startedModes = await starter.modes()
        XCTAssertEqual(startedModes, [.online])
    }

    func testSummaryActionIsDisabledBeforeReady() {
        let viewModel = makeViewModel()

        XCTAssertFalse(viewModel.canSummarize(meetingIn: .preparing))
        XCTAssertFalse(viewModel.canSummarize(meetingIn: .recording))
        XCTAssertFalse(viewModel.canSummarize(meetingIn: .paused))
        XCTAssertFalse(viewModel.canSummarize(meetingIn: .finalizing))
        XCTAssertTrue(viewModel.canSummarize(meetingIn: .ready))
        XCTAssertFalse(viewModel.canSummarize(meetingIn: .summarizing))
        XCTAssertFalse(viewModel.canSummarize(meetingIn: .archiving))
        XCTAssertFalse(viewModel.canSummarize(meetingIn: .archived))
    }

    func testTranscriptHighlightUsesThirtySecondBookmarkWindow() {
        let viewModel = makeViewModel()

        XCTAssertTrue(
            viewModel.shouldHighlightTranscript(
                start: 39,
                end: 41,
                bookmarkTimes: [70]
            )
        )
        XCTAssertTrue(
            viewModel.shouldHighlightTranscript(
                start: 99,
                end: 101,
                bookmarkTimes: [70]
            )
        )
        XCTAssertFalse(
            viewModel.shouldHighlightTranscript(
                start: 101.01,
                end: 110,
                bookmarkTimes: [70]
            )
        )
    }

    private func makeViewModel(
        repository: LibraryRepositorySpy = LibraryRepositorySpy(),
        files: any MeetingFileDeleting = FileDeletionSpy(),
        starter: any MeetingStarting = MeetingStarterSpy(),
        titleUpdater: any MeetingTitleUpdating = TitleUpdaterSpy(),
        operationGate: MeetingOperationGate = MeetingOperationGate(),
        playbackStopper: any MeetingPlaybackStopping = PlaybackStopperSpy(),
        systemRequirements: any SystemRequirementChecking =
            SystemRequirementsStub.supported
    ) -> MeetingLibraryViewModel {
        MeetingLibraryViewModel(
            repository: repository,
            fileDeleter: files,
            starter: starter,
            titleUpdater: titleUpdater,
            operationGate: operationGate,
            playbackStopper: playbackStopper,
            systemRequirements: systemRequirements,
            recordingsURL: FileManager.default.temporaryDirectory
        )
    }

    private func makeMeeting(
        seconds: TimeInterval,
        title: String = "会议",
        state: RecordingState = .ready
    ) -> MeetingRecord {
        MeetingRecord(
            title: title,
            mode: .offline,
            state: state,
            startedAt: Date(timeIntervalSince1970: seconds),
            createdAt: Date(timeIntervalSince1970: seconds),
            updatedAt: Date(timeIntervalSince1970: seconds)
        )
    }
}

@MainActor
private final class LibraryRepositorySpy: MeetingLibraryRepository {
    var storedMeetings: [MeetingRecord]
    var orderAfterPin: [MeetingRecord]?
    private(set) var deletedIDs: [UUID] = []
    private(set) var pinUpdates: [PinUpdate] = []
    private let pinError: Error?

    init(meetings: [MeetingRecord] = [], pinError: Error? = nil) {
        storedMeetings = meetings
        self.pinError = pinError
    }

    func meetings() throws -> [MeetingRecord] {
        storedMeetings
    }

    func deleteMeeting(id: UUID) throws {
        deletedIDs.append(id)
        storedMeetings.removeAll { $0.id == id }
    }

    func setPinned(meetingID: UUID, pinnedAt: Date?) throws {
        if let pinError { throw pinError }
        guard let meeting = storedMeetings.first(where: { $0.id == meetingID }) else {
            throw MeetingRepositoryError.meetingNotFound(meetingID)
        }
        pinUpdates.append(PinUpdate(meetingID: meetingID, pinnedAt: pinnedAt))
        meeting.pinnedAt = pinnedAt
        if let orderAfterPin {
            storedMeetings = orderAfterPin
        }
    }
}

private struct PinUpdate: Equatable {
    let meetingID: UUID
    let pinnedAt: Date?
}

private struct TitleUpdateRequest: Equatable {
    let meetingID: UUID
    let title: String
}

@MainActor
private final class TitleUpdaterSpy: MeetingTitleUpdating {
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
private final class BlockingTitleUpdater: MeetingTitleUpdating {
    private let onFinish: (UUID, String) -> Void
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private(set) var requests: [TitleUpdateRequest] = []

    init(onFinish: @escaping (UUID, String) -> Void = { _, _ in }) {
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
        onFinish(meetingID, title)
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

private enum TestFailure: Error {
    case expected
}

private enum DeletionEvent: Equatable {
    case stop(UUID)
    case deleteFiles(UUID)
    case deleteRepository(UUID)
}

private final class DeletionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [DeletionEvent] = []

    var values: [DeletionEvent] {
        lock.withLock { storedValues }
    }

    func append(_ event: DeletionEvent) {
        lock.withLock { storedValues.append(event) }
    }
}

@MainActor
private final class PlaybackStopperSpy: MeetingPlaybackStopping {
    private let events: DeletionEventRecorder?
    private(set) var stoppedMeetingIDs: [UUID] = []

    init(events: DeletionEventRecorder? = nil) {
        self.events = events
    }

    func stop(meetingID: UUID?) {
        guard let meetingID else { return }
        stoppedMeetingIDs.append(meetingID)
        events?.append(.stop(meetingID))
    }
}

@MainActor
private final class OrderedDeletionRepositorySpy: MeetingLibraryRepository {
    private var storedMeetings: [MeetingRecord]
    private let events: DeletionEventRecorder
    private(set) var deletedIDs: [UUID] = []

    init(meetings: [MeetingRecord], events: DeletionEventRecorder) {
        storedMeetings = meetings
        self.events = events
    }

    func meetings() throws -> [MeetingRecord] { storedMeetings }

    func setPinned(meetingID: UUID, pinnedAt: Date?) throws {
        _ = meetingID
        _ = pinnedAt
    }

    func deleteMeeting(id: UUID) throws {
        events.append(.deleteRepository(id))
        deletedIDs.append(id)
        storedMeetings.removeAll { $0.id == id }
    }
}

private actor OrderedFileDeletionSpy: MeetingFileDeleting {
    private let events: DeletionEventRecorder
    private let error: Error?

    init(events: DeletionEventRecorder, error: Error? = nil) {
        self.events = events
        self.error = error
    }

    func deleteMeetingDirectory(for meetingID: UUID) throws {
        events.append(.deleteFiles(meetingID))
        if let error { throw error }
    }
}

private actor FileDeletionSpy: MeetingFileDeleting {
    private var deletedIDs: [UUID] = []

    func deleteMeetingDirectory(for meetingID: UUID) throws {
        deletedIDs.append(meetingID)
    }

    func deletedMeetingIDs() -> [UUID] {
        deletedIDs
    }
}

private actor BlockingFileDeletionSpy: MeetingFileDeleting {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func deleteMeetingDirectory(for meetingID: UUID) async throws {
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

private actor MeetingStarterSpy: MeetingStarting {
    private let error: MeetingCoordinatorError?
    private let meetingID: UUID
    private var startedModes: [MeetingMode] = []

    init(
        error: MeetingCoordinatorError? = nil,
        meetingID: UUID = UUID()
    ) {
        self.error = error
        self.meetingID = meetingID
    }

    func start(mode: MeetingMode) async throws -> UUID {
        if let error { throw error }
        startedModes.append(mode)
        return meetingID
    }

    func modes() -> [MeetingMode] {
        startedModes
    }
}

private actor SequencedMeetingStarterSpy: MeetingStarting {
    private var outcomes: [Result<UUID, MeetingCoordinatorError>]
    private var startedModes: [MeetingMode] = []

    init(outcomes: [Result<UUID, MeetingCoordinatorError>]) {
        self.outcomes = outcomes
    }

    func start(mode: MeetingMode) async throws -> UUID {
        startedModes.append(mode)
        guard !outcomes.isEmpty else {
            throw MeetingCoordinatorError.sessionUnavailable
        }
        switch outcomes.removeFirst() {
        case let .success(meetingID):
            return meetingID
        case let .failure(error):
            throw error
        }
    }

    func modes() -> [MeetingMode] {
        startedModes
    }
}

private actor BlockingRetryMeetingStarterSpy: MeetingStarting {
    private let meetingID = UUID()
    private var startedModes: [MeetingMode] = []
    private var retryStarted = false
    private var retryStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var retryFinishContinuation: CheckedContinuation<Void, Never>?

    func start(mode: MeetingMode) async throws -> UUID {
        startedModes.append(mode)
        if startedModes.count == 1 {
            throw MeetingCoordinatorError.permissionDenied([.screenRecording])
        }
        retryStarted = true
        retryStartWaiters.forEach { $0.resume() }
        retryStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            retryFinishContinuation = continuation
        }
        return meetingID
    }

    func waitUntilRetryStarted() async {
        if retryStarted { return }
        await withCheckedContinuation { continuation in
            retryStartWaiters.append(continuation)
        }
    }

    func finishRetry() {
        retryFinishContinuation?.resume()
        retryFinishContinuation = nil
    }

    func modes() -> [MeetingMode] {
        startedModes
    }
}

private struct SystemRequirementsStub: SystemRequirementChecking {
    static let supported = SystemRequirementsStub(
        snapshot: SystemRequirements.evaluate(
            architecture: "arm64",
            systemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 0,
                patchVersion: 0
            ),
            availableDiskBytes: SystemRequirements.minimumFreeDiskBytes
        )
    )

    let snapshot: SystemRequirementsSnapshot

    func snapshot(for storageURL: URL) -> SystemRequirementsSnapshot {
        _ = storageURL
        return snapshot
    }
}
