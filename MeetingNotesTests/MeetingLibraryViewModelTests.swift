import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingLibraryViewModelTests: XCTestCase {
    func testLoadSortsMeetingsNewestFirstAndKeepsSelectionWhenPossible() {
        let older = makeMeeting(seconds: 100, title: "较早会议")
        let newer = makeMeeting(seconds: 300, title: "最近会议")
        let middle = makeMeeting(seconds: 200, title: "中间会议")
        let repository = LibraryRepositorySpy(
            meetings: [older, newer, middle]
        )
        let viewModel = makeViewModel(repository: repository)
        viewModel.select(middle.id)

        viewModel.load()

        XCTAssertEqual(
            viewModel.meetings.map(\.id),
            [newer.id, middle.id, older.id]
        )
        XCTAssertEqual(viewModel.selectedMeetingID, middle.id)
        XCTAssertEqual(viewModel.selectedMeeting?.id, middle.id)
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
        starter: any MeetingStarting = MeetingStarterSpy()
    ) -> MeetingLibraryViewModel {
        MeetingLibraryViewModel(
            repository: repository,
            fileDeleter: files,
            starter: starter
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
    private var startedModes: [MeetingMode] = []

    func start(mode: MeetingMode) async throws {
        startedModes.append(mode)
    }

    func modes() -> [MeetingMode] {
        startedModes
    }
}
