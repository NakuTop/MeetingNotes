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
        systemRequirements: any SystemRequirementChecking =
            SystemRequirementsStub.supported
    ) -> MeetingLibraryViewModel {
        MeetingLibraryViewModel(
            repository: repository,
            fileDeleter: files,
            starter: starter,
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
    private(set) var deletedIDs: [UUID] = []

    init(meetings: [MeetingRecord] = []) {
        storedMeetings = meetings
    }

    func meetings() throws -> [MeetingRecord] {
        storedMeetings
    }

    func deleteMeeting(id: UUID) throws {
        deletedIDs.append(id)
        storedMeetings.removeAll { $0.id == id }
    }

    func setPinned(meetingID: UUID, pinnedAt: Date?) throws {
        guard let meeting = storedMeetings.first(where: { $0.id == meetingID }) else {
            throw MeetingRepositoryError.meetingNotFound(meetingID)
        }
        meeting.pinnedAt = pinnedAt
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

private actor MeetingStarterSpy: MeetingStarting {
    private let error: MeetingCoordinatorError?
    private var startedModes: [MeetingMode] = []

    init(error: MeetingCoordinatorError? = nil) {
        self.error = error
    }

    func start(mode: MeetingMode) async throws {
        if let error { throw error }
        startedModes.append(mode)
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
