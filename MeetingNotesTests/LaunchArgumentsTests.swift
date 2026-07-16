import XCTest
@testable import MeetingNotes

final class LaunchArgumentsTests: XCTestCase {
    func testUITestingRequiresExplicitLaunchArgument() {
        XCTAssertTrue(
            LaunchArguments.isUITesting(["MeetingNotes", "-uiTesting"])
        )
        XCTAssertFalse(LaunchArguments.isUITesting(["MeetingNotes"]))
        XCTAssertFalse(
            LaunchArguments.isUITesting(["MeetingNotes", "uiTesting"])
        )
    }

    @MainActor
    func testUITestingContainerRecordsAndTranscribesWithoutLiveServices() async throws {
        #if DEBUG
        let container = try AppContainer.uiTesting()
        XCTAssertFalse(
            container.onboardingState.shouldPresentPrivacyAndConsent
        )

        await container.libraryViewModel.startMeeting(mode: .offline)
        var snapshot = await container.coordinator.snapshot()
        XCTAssertEqual(snapshot.state, .recording)

        try await container.coordinator.stop()
        container.libraryViewModel.load()
        snapshot = await container.coordinator.snapshot()

        XCTAssertEqual(snapshot.state, .idle)
        let meeting = try XCTUnwrap(container.libraryViewModel.meetings.first)
        XCTAssertEqual(meeting.state, .ready)
        XCTAssertEqual(
            meeting.transcripts.map(\.text),
            ["UI 测试会议转录"]
        )
        #endif
    }

    @MainActor
    func testUITestingContainerRenamesArchivedMeetingWithoutNetwork() async throws {
        #if DEBUG
        let container = try AppContainer.uiTesting()
        let meetingID = try container.repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            title: "旧标题"
        )
        try container.repository.updateMeetingState(
            id: meetingID,
            state: .archived
        )
        try container.repository.setNotionPage(
            meetingID: meetingID,
            pageID: "ui-test-page",
            pageURL: "https://www.notion.so/ui-test-page"
        )

        let succeeded = await container
            .detailViewModel(for: meetingID)
            .rename(to: "新标题")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            try container.repository.meeting(id: meetingID).title,
            "新标题"
        )
        #endif
    }

    @MainActor
    func testInMemoryContainerRenamesArchivedMeetingWithoutNetwork() async throws {
        let container = AppContainer.inMemory()
        let meetingID = try container.repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            title: "旧标题"
        )
        try container.repository.updateMeetingState(
            id: meetingID,
            state: .archived
        )
        try container.repository.setNotionPage(
            meetingID: meetingID,
            pageID: "preview-page",
            pageURL: "https://www.notion.so/preview-page"
        )

        let succeeded = await container
            .detailViewModel(for: meetingID)
            .rename(to: "预览标题")

        XCTAssertTrue(succeeded)
        XCTAssertEqual(
            try container.repository.meeting(id: meetingID).title,
            "预览标题"
        )
    }
}
