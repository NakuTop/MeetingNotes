import XCTest
@testable import MeetingNotes

@MainActor
final class UpdateActivityPolicyTests: XCTestCase {
    func testPreparingRecordingPausedFinalizingAndArchivingBlockInstallation() {
        let blockingStates: [RecordingState] = [
            .preparing,
            .recording,
            .paused,
            .finalizing,
            .summarizing,
            .archiving
        ]

        for state in blockingStates {
            let policy = UpdateActivityPolicy(
                loadMeetingStates: { [state] }
            )

            XCTAssertEqual(
                policy.installationDecision(),
                .blocked(.activeMeeting(state))
            )
        }
    }

    func testReadySummaryReadyArchivedAndIdlePermitInstallation() {
        let policy = UpdateActivityPolicy(
            loadMeetingStates: {
                [.ready, .summaryReady, .archived, .idle]
            }
        )

        XCTAssertEqual(policy.installationDecision(), .allowed)
    }

    func testRepositoryReadFailureBlocksInstallation() {
        let policy = UpdateActivityPolicy(
            loadMeetingStates: { throw UpdatePolicyTestError.readFailed }
        )

        XCTAssertEqual(
            policy.installationDecision(),
            .blocked(.repositoryUnavailable)
        )
    }
}

private enum UpdatePolicyTestError: Error {
    case readFailed
}
