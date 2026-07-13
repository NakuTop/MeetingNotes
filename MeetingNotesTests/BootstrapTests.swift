import XCTest
@testable import MeetingNotes

final class BootstrapTests: XCTestCase {
    func testRootViewCanBeConstructed() {
        XCTAssertNotNil(RootView())
    }
}
