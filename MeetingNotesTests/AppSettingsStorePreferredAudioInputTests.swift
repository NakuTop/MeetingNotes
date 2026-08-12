import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class AppSettingsStorePreferredAudioInputTests: XCTestCase {
    func testNewInstallationDefaultsToAutomatic() throws {
        let fixture = try makeFixture()

        XCTAssertEqual(fixture.store.preferredAudioInput, .automatic)
        XCTAssertNil(fixture.store.preferredInputDeviceID)
    }

    func testLegacyPreferenceMigratesOnFirstRead() throws {
        let fixture = try makeFixture()
        fixture.defaults.set(
            "legacy-microphone",
            forKey: "settings.preferredInputDeviceID"
        )

        let migrated = fixture.store.preferredAudioInput

        XCTAssertEqual(migrated.backend, .automatic)
        XCTAssertEqual(migrated.legacyAVFoundationID, "legacy-microphone")
        XCTAssertEqual(migrated.stableID, "avf:legacy-microphone")
        XCTAssertNil(migrated.coreAudioUID)
        XCTAssertEqual(
            fixture.store.preferredInputDeviceID,
            "legacy-microphone"
        )
    }

    func testRoundTripPreservesBackendAndIdentifiers() throws {
        let fixture = try makeFixture()
        let preferred = PreferredAudioInput(
            backend: .coreAudio,
            stableID: "ca:external-mic",
            legacyAVFoundationID: nil,
            coreAudioUID: "external-mic"
        )

        fixture.store.preferredAudioInput = preferred

        let reloaded = AppSettingsStore(defaults: fixture.defaults)
        XCTAssertEqual(reloaded.preferredAudioInput, preferred)
        XCTAssertEqual(reloaded.preferredInputDeviceID, "ca:external-mic")
    }

    func testLegacyPropertyRemainsCompatibleWithExistingCallers() throws {
        let fixture = try makeFixture()

        fixture.store.preferredInputDeviceID = "old-api-id"
        fixture.store.preferredOutputDeviceID = "output-id"

        let reloaded = AppSettingsStore(defaults: fixture.defaults)
        XCTAssertEqual(reloaded.preferredInputDeviceID, "old-api-id")
        XCTAssertEqual(reloaded.preferredOutputDeviceID, "output-id")
        XCTAssertEqual(
            reloaded.preferredAudioInput.legacyAVFoundationID,
            "old-api-id"
        )
    }

    func testClearingPreferenceRemovesBackingKeys() throws {
        let fixture = try makeFixture()
        fixture.store.preferredInputDeviceID = "some-mic"

        fixture.store.preferredInputDeviceID = nil

        XCTAssertNil(
            fixture.defaults.object(
                forKey: "settings.preferredInputDeviceID"
            )
        )
        XCTAssertEqual(fixture.store.preferredAudioInput, .automatic)
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "PreferredAudioInputTests-\(UUID().uuidString)"
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
