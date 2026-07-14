import XCTest
@testable import MeetingNotes

final class BootstrapTests: XCTestCase {
    @MainActor
    func testRootViewCanBeConstructed() {
        XCTAssertNotNil(RootView())
    }
}
