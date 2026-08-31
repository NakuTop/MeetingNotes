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

    func testScreenshotFixtureRequiresExplicitUITestingContext() {
        let fixture = "-ui-testing-screenshot-fixture"

        XCTAssertTrue(
            LaunchArguments.usesScreenshotUITestFixture([
                "MeetingNotes", "-uiTesting", fixture,
            ])
        )
        XCTAssertFalse(
            LaunchArguments.usesScreenshotUITestFixture([
                "MeetingNotes", fixture,
            ])
        )
        XCTAssertFalse(
            LaunchArguments.usesScreenshotUITestFixture([
                "MeetingNotes", "-uiTesting",
            ])
        )
    }

    @MainActor
    func testScreenshotFixtureSavesAnInMemoryCaptureWithoutLivePermission()
        async throws {
        #if DEBUG
        let recordingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LaunchArgumentsTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: recordingsURL) }
        let container = try AppContainer.uiTesting(arguments: [
            "MeetingNotes",
            "-uiTesting",
            "-ui-testing-screenshot-fixture",
        ], recordingsURL: recordingsURL)

        await container.libraryViewModel.startMeeting(mode: .offline)
        await container.recordingAnnotationViewModel.captureScreenshot()

        let snapshot = await container.coordinator.snapshot()
        let meetingID = try XCTUnwrap(snapshot.meetingID)
        let screenshots = try container.repository.screenshots(
            meetingID: meetingID
        )
        XCTAssertEqual(screenshots.count, 1)
        XCTAssertEqual(screenshots.first?.pixelWidth, 1)
        XCTAssertEqual(screenshots.first?.pixelHeight, 1)
        XCTAssertEqual(
            container.recordingAnnotationViewModel.screenshotState,
            ScreenshotCaptureState.saved
        )
        try await container.coordinator.stop()
        #endif
    }

    func testAudioLifecycleTriggerAcceptsOnlyDirectTemporaryFixturePath() {
        let key = "MEETING_NOTES_UI_AUDIO_PLAYER_LIFECYCLE_TRIGGER"
        let validPath = "/tmp/MeetingNotes-UITesting-Trigger-123"

        XCTAssertEqual(
            LaunchArguments.audioPlayerLifecycleTriggerURL(
                [key: validPath]
            )?.path,
            validPath
        )
        XCTAssertNil(
            LaunchArguments.audioPlayerLifecycleTriggerURL(
                [key: "/tmp/not-a-meeting-notes-trigger"]
            )
        )
        XCTAssertNil(
            LaunchArguments.audioPlayerLifecycleTriggerURL(
                [key: "/Users/example/MeetingNotes-UITesting-Trigger-123"]
            )
        )
        XCTAssertNil(
            LaunchArguments.audioPlayerLifecycleTriggerURL(
                [key: "/tmp/nested/MeetingNotes-UITesting-Trigger-123"]
            )
        )
    }

    func testAudioPlayerFixtureMeetingIDRequiresAUUID() {
        let key = "MEETING_NOTES_UI_AUDIO_PLAYER_MEETING_ID"
        let meetingID = UUID()

        XCTAssertEqual(
            LaunchArguments.audioPlayerMeetingID(
                [key: meetingID.uuidString]
            ),
            meetingID
        )
        XCTAssertNil(
            LaunchArguments.audioPlayerMeetingID([key: "not-a-uuid"])
        )
        XCTAssertNil(LaunchArguments.audioPlayerMeetingID([:]))
    }

    @MainActor
    func testUITestingContainerRecordsAndTranscribesWithoutLiveServices() async throws {
        #if DEBUG
        let container = try AppContainer.uiTesting(
            speakerDiarizationEnabled: true
        )
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
        XCTAssertTrue(meeting.speakerDiarizationRequested)
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
