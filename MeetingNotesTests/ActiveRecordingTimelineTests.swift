import XCTest
@testable import MeetingNotes

final class ActiveRecordingTimelineTests: XCTestCase {
    func testPausedWallClockTimeIsExcluded() throws {
        var timeline = ActiveRecordingTimeline(startedAt: 100)

        try timeline.pause(at: 120)
        try timeline.resume(at: 140)

        XCTAssertEqual(timeline.activeTime(at: 150), 30, accuracy: 0.001)
    }

    func testActiveTimeFreezesWhilePaused() throws {
        var timeline = ActiveRecordingTimeline(startedAt: 100)

        try timeline.pause(at: 120)

        XCTAssertEqual(timeline.activeTime(at: 120), 20, accuracy: 0.001)
        XCTAssertEqual(timeline.activeTime(at: 180), 20, accuracy: 0.001)
    }

    func testDuplicatePauseAndResumeAreRejectedWithoutChangingTimeline() throws {
        var timeline = ActiveRecordingTimeline(startedAt: 100)

        try timeline.pause(at: 120)
        XCTAssertThrowsError(try timeline.pause(at: 125)) { error in
            XCTAssertEqual(error as? ActiveRecordingTimelineError, .alreadyPaused)
        }
        XCTAssertEqual(timeline.activeTime(at: 130), 20, accuracy: 0.001)

        try timeline.resume(at: 140)
        XCTAssertThrowsError(try timeline.resume(at: 145)) { error in
            XCTAssertEqual(error as? ActiveRecordingTimelineError, .notPaused)
        }
        XCTAssertEqual(timeline.activeTime(at: 150), 30, accuracy: 0.001)
    }

    func testTransitionTimestampsCannotMoveBackward() throws {
        var timeline = ActiveRecordingTimeline(startedAt: 100)

        XCTAssertThrowsError(try timeline.pause(at: 99)) { error in
            XCTAssertEqual(error as? ActiveRecordingTimelineError, .nonMonotonicTime)
        }

        try timeline.pause(at: 120)
        XCTAssertThrowsError(try timeline.resume(at: 119)) { error in
            XCTAssertEqual(error as? ActiveRecordingTimelineError, .nonMonotonicTime)
        }
        XCTAssertEqual(timeline.activeTime(at: 150), 20, accuracy: 0.001)
    }

    func testActiveTimeNeverFallsBelowZero() {
        let timeline = ActiveRecordingTimeline(startedAt: 100)

        XCTAssertEqual(timeline.activeTime(at: 90), 0, accuracy: 0.001)
    }
}
