import AppKit
import XCTest
@testable import MeetingNotes

@MainActor
final class BackgroundTestSafetyTests: XCTestCase {
    func testExplicitBackgroundHostNeverActivatesOrShowsWindows() throws {
        #if MEETINGNOTES_BACKGROUND_TEST_HOST
        XCTAssertEqual(NSApplication.shared.activationPolicy(), .prohibited)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool, true)
        XCTAssertFalse(NSApplication.shared.windows.contains(where: \.isVisible))
        #else
        throw XCTSkip("Only applicable to the explicitly compiled background host")
        #endif
    }
}
