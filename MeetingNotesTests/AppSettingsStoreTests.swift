import Observation
import XCTest
@testable import MeetingNotes

final class AppSettingsStoreTests: XCTestCase {
    @MainActor
    func testMainActorSpeakerPreferenceAdapterReadsStoreAsynchronously() async throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AppSettingsStore(defaults: defaults)
        let reader = MainActorSpeakerDiarizationPreferenceAdapter(
            settingsStore: store
        )
        store.isSpeakerDiarizationEnabled = true

        let isEnabled = await reader.isSpeakerDiarizationEnabled()

        XCTAssertTrue(isEnabled)
    }

    func testSpeakerDiarizationDefaultsToDisabledWhenPreferenceIsMissing() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertFalse(store.isSpeakerDiarizationEnabled)
    }

    func testEnabledSpeakerDiarizationPersistsAcrossStoreInstances() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let first = AppSettingsStore(defaults: defaults)

        first.isSpeakerDiarizationEnabled = true

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertTrue(reloaded.isSpeakerDiarizationEnabled)
    }

    func testSpeakerDiarizationMutationNotifiesObservationTracking() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AppSettingsStore(defaults: defaults)
        let changeObserved = expectation(
            description: "Speaker diarization preference change observed"
        )

        withObservationTracking {
            _ = store.isSpeakerDiarizationEnabled
        } onChange: {
            changeObserved.fulfill()
        }

        store.isSpeakerDiarizationEnabled = true

        wait(for: [changeObserved], timeout: 0.1)
    }

    func testNotionArchivingDefaultsToEnabledWhenPreferenceIsMissing() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertTrue(store.isNotionArchivingEnabled)
    }

    func testDisabledNotionArchivingPersistsAcrossStoreInstances() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let first = AppSettingsStore(defaults: defaults)

        first.isNotionArchivingEnabled = false

        let reloaded = AppSettingsStore(defaults: defaults)
        XCTAssertFalse(reloaded.isNotionArchivingEnabled)
    }

    func testNotionArchivingMutationNotifiesObservationTracking() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AppSettingsStore(defaults: defaults)
        let changeObserved = expectation(
            description: "Notion archiving preference change observed"
        )

        withObservationTracking {
            _ = store.isNotionArchivingEnabled
        } onChange: {
            changeObserved.fulfill()
        }

        store.isNotionArchivingEnabled = false

        wait(for: [changeObserved], timeout: 0.1)
    }

    func testModelAndNotionParentURLPersistAcrossStoreInstances() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let first = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(AppSettingsStore.defaultDeepSeekModel, "deepseek-v4-flash")
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
