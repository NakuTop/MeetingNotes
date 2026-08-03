import XCTest
@testable import MeetingNotes

final class CaptureHealthMonitorTests: XCTestCase {
    func testNoFramesAfterStartupWindowBecomesFailure() {
        let monitor = CaptureHealthMonitor(startedAt: 100)

        XCTAssertEqual(monitor.status(at: 104.9), .waitingForFrames)
        XCTAssertEqual(monitor.status(at: 105), .noFrames)
    }

    func testSilentFramesBecomeWarningOnlyAfterContinuousWindow() {
        var monitor = CaptureHealthMonitor(startedAt: 100)
        monitor.ingest(
            samples: Array(repeating: 0, count: 48_000),
            at: 101
        )

        XCTAssertEqual(monitor.status(at: 102), .observing)
        XCTAssertEqual(monitor.status(at: 106), .sustainedSilence)
    }

    func testAudibleFrameEndsSilentWindow() {
        var monitor = CaptureHealthMonitor(startedAt: 100)
        monitor.ingest(samples: [0, 0], at: 101)
        monitor.ingest(samples: [0, 0.2], at: 104)

        XCTAssertEqual(monitor.status(at: 110), .observing)
    }

    func testEmptyFramesDoNotSatisfyFirstFrameDeadline() {
        var monitor = CaptureHealthMonitor(startedAt: 100)
        monitor.ingest(samples: [], at: 101)

        XCTAssertEqual(monitor.status(at: 105), .noFrames)
    }
}
