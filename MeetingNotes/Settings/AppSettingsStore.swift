import Foundation
import Observation

@Observable
final class AppSettingsStore:
    SpeakerDiarizationPreferenceReading,
    @unchecked Sendable {
    static let defaultDeepSeekModel = "deepseek-v4-flash"

    private enum Key {
        static let deepSeekModel = "settings.deepSeekModel"
        static let notionParentPageURL = "settings.notionParentPageURL"
        static let notionArchivingEnabled = "settings.notionArchivingEnabled"
        static let speakerDiarizationEnabled =
            "settings.speakerDiarizationEnabled"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var deepSeekModel: String {
        get {
            guard let stored = defaults.string(forKey: Key.deepSeekModel),
                  !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.defaultDeepSeekModel
            }
            return stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Key.deepSeekModel)
            } else {
                defaults.set(trimmed, forKey: Key.deepSeekModel)
            }
        }
    }

    var notionParentPageURL: String {
        get { defaults.string(forKey: Key.notionParentPageURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.notionParentPageURL) }
    }

    var isNotionArchivingEnabled: Bool {
        get {
            access(keyPath: \AppSettingsStore.isNotionArchivingEnabled)
            guard defaults.object(forKey: Key.notionArchivingEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Key.notionArchivingEnabled)
        }
        set {
            withMutation(keyPath: \AppSettingsStore.isNotionArchivingEnabled) {
                defaults.set(newValue, forKey: Key.notionArchivingEnabled)
            }
        }
    }

    var isSpeakerDiarizationEnabled: Bool {
        get {
            access(keyPath: \AppSettingsStore.isSpeakerDiarizationEnabled)
            return defaults.bool(forKey: Key.speakerDiarizationEnabled)
        }
        set {
            withMutation(keyPath: \AppSettingsStore.isSpeakerDiarizationEnabled) {
                defaults.set(newValue, forKey: Key.speakerDiarizationEnabled)
            }
        }
    }
}
