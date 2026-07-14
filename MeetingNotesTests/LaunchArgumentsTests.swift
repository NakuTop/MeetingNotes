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

        XCTAssertEqual(snapshot.state, .ready)
        let meeting = try XCTUnwrap(container.libraryViewModel.meetings.first)
        XCTAssertEqual(
            meeting.transcripts.map(\.text),
            ["UI 测试会议转录"]
        )
        #endif
    }
}
