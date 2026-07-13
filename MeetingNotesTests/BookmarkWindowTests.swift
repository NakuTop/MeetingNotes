import XCTest
@testable import MeetingNotes

final class BookmarkWindowTests: XCTestCase {
    func testWindowUsesThirtySecondsBeforeAndAfterBookmark() {
        let window = BookmarkWindow(bookmarkTime: 80)

        XCTAssertEqual(window.range.lowerBound, 50, accuracy: 0.001)
        XCTAssertEqual(window.range.upperBound, 110, accuracy: 0.001)
    }

    func testWindowLowerBoundIsClampedToZero() {
        let window = BookmarkWindow(bookmarkTime: 10)

        XCTAssertEqual(window.range.lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(window.range.upperBound, 40, accuracy: 0.001)
    }

    func testWindowUsesClosedRangeIntersection() {
        let window = BookmarkWindow(bookmarkTime: 10)

        XCTAssertTrue(window.intersects(transcriptStart: 40, transcriptEnd: 45))
        XCTAssertTrue(window.intersects(transcriptStart: 5, transcriptEnd: 8))
        XCTAssertFalse(window.intersects(transcriptStart: 40.001, transcriptEnd: 45))
        XCTAssertFalse(window.intersects(transcriptStart: 41, transcriptEnd: 39))
    }

    func testNegativeBookmarkTimeIsClampedToZero() {
        let window = BookmarkWindow(bookmarkTime: -5)

        XCTAssertEqual(window.bookmarkTime, 0, accuracy: 0.001)
        XCTAssertEqual(window.range.lowerBound, 0, accuracy: 0.001)
        XCTAssertEqual(window.range.upperBound, 30, accuracy: 0.001)
    }
}
