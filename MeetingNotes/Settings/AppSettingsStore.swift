import Foundation

final class AppSettingsStore: @unchecked Sendable {
    static let defaultDeepSeekModel = "deepseek-v4-flash"

    private enum Key {
        static let deepSeekModel = "settings.deepSeekModel"
        static let notionParentPageURL = "settings.notionParentPageURL"
    }

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
}
