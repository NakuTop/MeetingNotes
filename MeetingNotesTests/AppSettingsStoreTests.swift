import XCTest
@testable import MeetingNotes

final class AppSettingsStoreTests: XCTestCase {
    func testModelAndNotionParentURLPersistAcrossStoreInstances() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let first = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(first.deepSeekModel, AppSettingsStore.defaultDeepSeekModel)
        XCTAssertEqual(first.notionParentPageURL, "")

        first.deepSeekModel = "deepseek-reasoner"
        first.notionParentPageURL = "https://www.notion.so/parent-page"

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.deepSeekModel, "deepseek-reasoner")
        XCTAssertEqual(
            reloaded.notionParentPageURL,
            "https://www.notion.so/parent-page"
        )
    }

    func testEmptyModelFallsBackToDefault() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AppSettingsStore(defaults: defaults)

        store.deepSeekModel = ""

        XCTAssertEqual(store.deepSeekModel, AppSettingsStore.defaultDeepSeekModel)
    }
}
