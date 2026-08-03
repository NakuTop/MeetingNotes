import XCTest
@testable import MeetingNotes

@MainActor
final class RecordingSessionPresentationStoreTests: XCTestCase {
    func testRecordingPauseAndResumeUseOnlyExplicitMonotonicTime()
        async throws {
        let meetingID = UUID()
        let store = RecordingSessionPresentationStore()

        await store.start(meetingID: meetingID, monotonicTime: 100)
        XCTAssertEqual(
            try XCTUnwrap(store.activeDuration(for: meetingID, at: 103.4)),
            3.4,
            accuracy: 0.001
        )

        await store.pause(meetingID: meetingID, activeDuration: 3.4)
        XCTAssertEqual(
            try XCTUnwrap(store.activeDuration(for: meetingID, at: 200)),
            3.4,
            accuracy: 0.001
        )
        XCTAssertEqual(store.phase, .paused)

        await store.resume(
            meetingID: meetingID,
            activeDuration: 3.4,
            monotonicTime: 200
        )
        XCTAssertEqual(
            try XCTUnwrap(store.activeDuration(for: meetingID, at: 203)),
            6.4,
            accuracy: 0.001
        )
        XCTAssertEqual(store.phase, .recording)
    }

    func testAnotherMeetingAndStaleTransitionsCannotChangeActiveSession()
        async throws {
        let oldMeetingID = UUID()
        let currentMeetingID = UUID()
        let store = RecordingSessionPresentationStore()
        await store.start(meetingID: oldMeetingID, monotonicTime: 10)
        await store.start(meetingID: currentMeetingID, monotonicTime: 20)

        await store.pause(meetingID: oldMeetingID, activeDuration: 99)
        await store.resume(
            meetingID: oldMeetingID,
            activeDuration: 99,
            monotonicTime: 40
        )
        await store.finish(meetingID: oldMeetingID, activeDuration: 99)
        await store.clear(meetingID: oldMeetingID)

        XCTAssertNil(store.activeDuration(for: oldMeetingID, at: 30))
        XCTAssertEqual(
            try XCTUnwrap(
                store.activeDuration(for: currentMeetingID, at: 30)
            ),
            10,
            accuracy: 0.001
        )
        XCTAssertEqual(store.phase, .recording)
    }

    func testFinishFreezesDurationUntilMatchingClear() async throws {
        let meetingID = UUID()
        let store = RecordingSessionPresentationStore()
        await store.start(meetingID: meetingID, monotonicTime: 100)

        await store.finish(meetingID: meetingID, activeDuration: 8)

        XCTAssertEqual(
            try XCTUnwrap(store.activeDuration(for: meetingID, at: 1_000)),
            8,
            accuracy: 0.001
        )
        XCTAssertEqual(store.phase, .finished)

        await store.clear(meetingID: meetingID)
        XCTAssertNil(store.activeDuration(for: meetingID, at: 1_000))
        XCTAssertNil(store.phase)
    }

    func testInvalidDurationsAndTimesAreClampedToZero() async throws {
        let meetingID = UUID()
        let store = RecordingSessionPresentationStore()

        await store.start(meetingID: meetingID, monotonicTime: -.infinity)
        XCTAssertEqual(
            try XCTUnwrap(
                store.activeDuration(for: meetingID, at: -.infinity)
            ),
            0,
            accuracy: 0.001
        )
        await store.pause(meetingID: meetingID, activeDuration: -.infinity)
        XCTAssertEqual(
            try XCTUnwrap(store.activeDuration(for: meetingID, at: 100)),
            0,
            accuracy: 0.001
        )
    }
}
