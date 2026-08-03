import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class AppSettingsStoreAudioDeviceTests: XCTestCase {
    func testPreferredDeviceIDsDefaultToNil() throws {
        let fixture = try makeFixture()

        XCTAssertNil(fixture.store.preferredInputDeviceID)
        XCTAssertNil(fixture.store.preferredOutputDeviceID)
    }

    func testPreferredDeviceIDsRoundTripAcrossStoreInstances() throws {
        let fixture = try makeFixture()

        fixture.store.preferredInputDeviceID = "input-123"
        fixture.store.preferredOutputDeviceID = "output-456"

        let reloaded = AppSettingsStore(defaults: fixture.defaults)
        XCTAssertEqual(reloaded.preferredInputDeviceID, "input-123")
        XCTAssertEqual(reloaded.preferredOutputDeviceID, "output-456")
    }

    func testPreferredDeviceIDsTrimWhitespaceBeforePersisting() throws {
        let fixture = try makeFixture()

        fixture.store.preferredInputDeviceID = " \n input-123 \t"
        fixture.store.preferredOutputDeviceID = "\t output-456 \n"

        XCTAssertEqual(fixture.store.preferredInputDeviceID, "input-123")
        XCTAssertEqual(fixture.store.preferredOutputDeviceID, "output-456")
    }

    func testNilOrBlankPreferredDeviceIDsRemoveBackingKeys() throws {
        let fixture = try makeFixture()
        let inputKey = "settings.preferredInputDeviceID"
        let outputKey = "settings.preferredOutputDeviceID"
        fixture.store.preferredInputDeviceID = "input-123"
        fixture.store.preferredOutputDeviceID = "output-456"

        fixture.store.preferredInputDeviceID = nil
        fixture.store.preferredOutputDeviceID = " \n\t "

        XCTAssertNil(fixture.defaults.object(forKey: inputKey))
        XCTAssertNil(fixture.defaults.object(forKey: outputKey))
        XCTAssertNil(fixture.store.preferredInputDeviceID)
        XCTAssertNil(fixture.store.preferredOutputDeviceID)
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "AppSettingsStoreAudioDeviceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return Fixture(
            store: AppSettingsStore(defaults: defaults),
            defaults: defaults
        )
    }

    private struct Fixture {
        let store: AppSettingsStore
        let defaults: UserDefaults
    }
}
