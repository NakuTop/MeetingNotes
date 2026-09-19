import Foundation
import Observation

@Observable
final class AppSettingsStore {
    static let defaultDeepSeekModel = DeepSeekModelName.flash

    private enum Key {
        static let deepSeekModel = "settings.deepSeekModel"
        static let notionParentPageURL = "settings.notionParentPageURL"
        static let notionArchivingEnabled = "settings.notionArchivingEnabled"
        static let transcriptionQualityMode =
            "settings.transcriptionQualityMode"
        static let speakerDiarizationEnabled =
            "settings.speakerDiarizationEnabled"
        static let frequentSpeakerNames =
            "settings.frequentSpeakerNames"
        static let localVoiceprintsEnabled = "settings.localVoiceprintsEnabled"
        static let preferredInputDeviceID =
            "settings.preferredInputDeviceID"
        static let preferredOutputDeviceID =
            "settings.preferredOutputDeviceID"
    }

    @ObservationIgnored
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.string(forKey: Key.deepSeekModel) {
            let canonical = DeepSeekModelName.canonical(stored)
            if canonical != stored {
                defaults.set(canonical, forKey: Key.deepSeekModel)
            }
        }
    }

    var localVoiceprintsEnabled: Bool {
        get {
            access(keyPath: \AppSettingsStore.localVoiceprintsEnabled)
            return defaults.bool(forKey: Key.localVoiceprintsEnabled)
        }
        set {
            withMutation(keyPath: \AppSettingsStore.localVoiceprintsEnabled) {
                defaults.set(newValue, forKey: Key.localVoiceprintsEnabled)
            }
        }
    }

    var deepSeekModel: String {
        get {
            guard let stored = defaults.string(forKey: Key.deepSeekModel),
                  !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return Self.defaultDeepSeekModel
            }
            return DeepSeekModelName.canonical(stored)
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Key.deepSeekModel)
            } else {
                defaults.set(
                    DeepSeekModelName.canonical(trimmed),
                    forKey: Key.deepSeekModel
                )
            }
        }
    }

    var notionParentPageURL: String {
        get { defaults.string(forKey: Key.notionParentPageURL) ?? "" }
        set { defaults.set(newValue, forKey: Key.notionParentPageURL) }
    }

    var transcriptionQualityMode: TranscriptionQualityMode {
        get {
            access(keyPath: \AppSettingsStore.transcriptionQualityMode)
            guard let stored = defaults.string(
                forKey: Key.transcriptionQualityMode
            ) else {
                return .balanced
            }
            return TranscriptionQualityMode(rawValue: stored) ?? .balanced
        }
        set {
            withMutation(keyPath: \AppSettingsStore.transcriptionQualityMode) {
                defaults.set(
                    newValue.rawValue,
                    forKey: Key.transcriptionQualityMode
                )
            }
        }
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
            // Missing preference opts into the automatic local workflow; an
            // existing explicit opt-out must survive updates unchanged.
            guard defaults.object(forKey: Key.speakerDiarizationEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Key.speakerDiarizationEnabled)
        }
        set {
            withMutation(keyPath: \AppSettingsStore.isSpeakerDiarizationEnabled) {
                defaults.set(newValue, forKey: Key.speakerDiarizationEnabled)
            }
        }
    }

    var frequentSpeakerNames: [String] {
        get {
            access(keyPath: \AppSettingsStore.frequentSpeakerNames)
            return Self.normalizedSpeakerNames(
                defaults.stringArray(forKey: Key.frequentSpeakerNames) ?? []
            )
        }
        set {
            withMutation(keyPath: \AppSettingsStore.frequentSpeakerNames) {
                defaults.set(
                    Self.normalizedSpeakerNames(newValue),
                    forKey: Key.frequentSpeakerNames
                )
            }
        }
    }

    func rememberSpeakerName(_ name: String) {
        frequentSpeakerNames = frequentSpeakerNames + [name]
    }

    static func normalizedSpeakerNames(_ names: [String]) -> [String] {
        var normalized: [String] = []
        for name in names {
            let trimmed = name.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !trimmed.isEmpty, trimmed.count <= 40 else { continue }
            guard !normalized.contains(where: {
                $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
            }) else { continue }
            normalized.append(trimmed)
        }
        return normalized
    }

    var preferredInputDeviceID: String? {
        get {
            access(keyPath: \AppSettingsStore.preferredInputDeviceID)
            return preferredAudioInput.legacyDisplayID
        }
        set {
            withMutation(keyPath: \AppSettingsStore.preferredInputDeviceID) {
                let trimmed = newValue?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                preferredAudioInput = PreferredAudioInput(
                    backend: .automatic,
                    stableID: trimmed,
                    legacyAVFoundationID: trimmed,
                    coreAudioUID: nil
                )
            }
        }
    }

    var preferredAudioInput: PreferredAudioInput {
        get {
            access(keyPath: \AppSettingsStore.preferredAudioInput)
            return PreferredAudioInputPersistence.load(defaults: defaults)
        }
        set {
            withMutation(keyPath: \AppSettingsStore.preferredAudioInput) {
                PreferredAudioInputPersistence.save(
                    newValue,
                    defaults: defaults
                )
            }
        }
    }

    var preferredOutputDeviceID: String? {
        get {
            access(keyPath: \AppSettingsStore.preferredOutputDeviceID)
            return preferredDeviceID(forKey: Key.preferredOutputDeviceID)
        }
        set {
            withMutation(keyPath: \AppSettingsStore.preferredOutputDeviceID) {
                setPreferredDeviceID(
                    newValue,
                    forKey: Key.preferredOutputDeviceID
                )
            }
        }
    }

    private func preferredDeviceID(forKey key: String) -> String? {
        guard let stored = defaults.string(forKey: key) else {
            return nil
        }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func setPreferredDeviceID(_ id: String?, forKey key: String) {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(trimmed, forKey: key)
    }
}
