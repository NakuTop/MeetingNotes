import XCTest
@testable import MeetingNotes

final class WaveformSeekInteractionTests: XCTestCase {
    func testCancelledGestureEndsOnceAndNextGestureBeginsFresh() {
        var interaction = WaveformSeekInteraction()

        XCTAssertEqual(interaction.update(to: 0.2), .began(0.2))
        XCTAssertEqual(interaction.update(to: 0.4), .changed(0.4))
        XCTAssertEqual(interaction.finish(), .ended(0.4))
        XCTAssertNil(interaction.finish())
        XCTAssertEqual(interaction.update(to: 0.6), .began(0.6))
    }

    func testNormalEndThenGestureStateResetDoesNotEndTwice() {
        var interaction = WaveformSeekInteraction()

        XCTAssertEqual(interaction.update(to: 0.25), .began(0.25))
        XCTAssertEqual(interaction.finish(at: 0.75), .ended(0.75))
        XCTAssertNil(interaction.finish())
    }

    func testDisappearEndsActiveInteractionAtLastFraction() {
        var interaction = WaveformSeekInteraction()

        XCTAssertEqual(interaction.update(to: 0.3), .began(0.3))
        XCTAssertEqual(interaction.update(to: 0.45), .changed(0.45))

        XCTAssertEqual(interaction.finish(), .ended(0.45))
        XCTAssertFalse(interaction.isActive)
    }
}
