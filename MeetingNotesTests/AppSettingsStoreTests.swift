import Observation
import XCTest
@testable import MeetingNotes

final class AppSettingsStoreTests: XCTestCase {
    func testTranscriptionQualityDefaultsToBalancedWhenPreferenceIsMissing() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.transcriptionQualityMode, .balanced)
    }

    func testTranscriptionQualityModesPersistAcrossStoreInstances() throws {
        for mode in TranscriptionQualityMode.allCases {
            let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer {
                defaults.removePersistentDomain(forName: suiteName)
            }
            let first = AppSettingsStore(defaults: defaults)

            first.transcriptionQualityMode = mode

            let reloaded = AppSettingsStore(defaults: defaults)
            XCTAssertEqual(reloaded.transcriptionQualityMode, mode)
            XCTAssertEqual(
                defaults.string(forKey: "settings.transcriptionQualityMode"),
                mode.rawValue
            )
        }
    }

    func testUnknownTranscriptionQualityPreferenceFallsBackToBalanced() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(
            "future-quality-mode",
            forKey: "settings.transcriptionQualityMode"
        )

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertEqual(store.transcriptionQualityMode, .balanced)
    }

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

    func testSpeakerDiarizationDefaultsToAutomaticWhenPreferenceIsMissing() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = AppSettingsStore(defaults: defaults)

        XCTAssertTrue(store.isSpeakerDiarizationEnabled)
        XCTAssertFalse(store.localVoiceprintsEnabled, "Automatic diarization must not opt into identity matching")
    }

    func testExplicitlyDisabledSpeakerDiarizationSurvivesReload() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        store.isSpeakerDiarizationEnabled = false

        XCTAssertFalse(AppSettingsStore(defaults: defaults).isSpeakerDiarizationEnabled)
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

        store.isSpeakerDiarizationEnabled = false

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

        XCTAssertEqual(AppSettingsStore.defaultDeepSeekModel, "deepseek-flash")
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

    func testLegacyFlashModelSettingsMigrateWithoutChangingOtherPreferences() throws {
        for legacy in ["deepseek-v4-flash", "deepseek-v4-flash-vision-exp"] {
            let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            defaults.set(legacy, forKey: "settings.deepSeekModel")
            defaults.set(false, forKey: "settings.notionArchivingEnabled")
            defaults.set("https://www.notion.so/parent", forKey: "settings.notionParentPageURL")

            let store = AppSettingsStore(defaults: defaults)

            XCTAssertEqual(store.deepSeekModel, "deepseek-flash", legacy)
            XCTAssertEqual(defaults.string(forKey: "settings.deepSeekModel"), "deepseek-flash")
            XCTAssertEqual(AppSettingsStore(defaults: defaults).deepSeekModel, "deepseek-flash")
            XCTAssertFalse(store.isNotionArchivingEnabled)
            XCTAssertEqual(store.notionParentPageURL, "https://www.notion.so/parent")
        }
    }

    func testModelWritesCanonicalizeOnlyRetiredFlashAliases() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = AppSettingsStore(defaults: defaults)
        let cases = [
            (" deepseek-v4-flash \n", "deepseek-flash"),
            ("deepseek-v4-flash-vision-exp", "deepseek-flash"),
            ("deepseek-flash", "deepseek-flash"),
            ("deepseek-v4-pro", "deepseek-v4-pro"),
            ("deepseek-reasoner", "deepseek-reasoner"),
            ("custom-model", "custom-model"),
        ]

        for (input, expected) in cases {
            store.deepSeekModel = input

            XCTAssertEqual(store.deepSeekModel, expected)
            XCTAssertEqual(defaults.string(forKey: "settings.deepSeekModel"), expected)
            XCTAssertEqual(AppSettingsStore(defaults: defaults).deepSeekModel, expected)
        }
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

    func testFrequentSpeakerNamesNormalizeAndPersistAcrossInstances() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AppSettingsStore(defaults: defaults)

        store.frequentSpeakerNames = [
            " 张三 ",
            "张三",
            "ALICE",
            "alice",
            "",
            String(repeating: "人", count: 41),
        ]

        XCTAssertEqual(store.frequentSpeakerNames, ["张三", "ALICE"])
        XCTAssertEqual(
            AppSettingsStore(defaults: defaults).frequentSpeakerNames,
            ["张三", "ALICE"]
        )
    }

    func testRememberSpeakerNameAppendsOnlyNewValidName() throws {
        let suiteName = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AppSettingsStore(defaults: defaults)
        store.frequentSpeakerNames = ["张三"]

        store.rememberSpeakerName(" 李四 ")
        store.rememberSpeakerName("张三")
        store.rememberSpeakerName("   ")

        XCTAssertEqual(store.frequentSpeakerNames, ["张三", "李四"])
    }
}
