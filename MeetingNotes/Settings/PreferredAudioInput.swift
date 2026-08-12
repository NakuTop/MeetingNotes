import Foundation

struct PreferredAudioInput: Codable, Equatable, Sendable {
    enum Backend: String, Codable, Sendable, Equatable {
        case automatic
        case avFoundation
        case coreAudio
    }

    var backend: Backend
    var stableID: String?
    var legacyAVFoundationID: String?
    var coreAudioUID: String?

    init(
        backend: Backend = .automatic,
        stableID: String? = nil,
        legacyAVFoundationID: String? = nil,
        coreAudioUID: String? = nil
    ) {
        self.backend = backend
        self.stableID = stableID
        self.legacyAVFoundationID = legacyAVFoundationID
        self.coreAudioUID = coreAudioUID
    }

    static let automatic = PreferredAudioInput()

    var legacyDisplayID: String? {
        legacyAVFoundationID ?? stableID
    }
}

enum PreferredAudioInputPersistence {
    static let key = "settings.preferredAudioInput"
    static let legacyKey = "settings.preferredInputDeviceID"

    static func load(defaults: UserDefaults) -> PreferredAudioInput {
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode(
               PreferredAudioInput.self,
               from: data
           ) {
            return decoded
        }

        guard let legacy = trimmedLegacyID(defaults) else {
            return .automatic
        }
        let migrated = PreferredAudioInput(
            backend: .automatic,
            stableID: namespacedStableID(for: legacy),
            legacyAVFoundationID: legacy,
            coreAudioUID: nil
        )
        save(migrated, defaults: defaults)
        return migrated
    }

    static func save(
        _ value: PreferredAudioInput,
        defaults: UserDefaults
    ) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }

        if let legacyValue = value.legacyDisplayID,
           !legacyValue.trimmingCharacters(
               in: .whitespacesAndNewlines
           ).isEmpty {
            defaults.set(legacyValue, forKey: legacyKey)
        } else {
            defaults.removeObject(forKey: legacyKey)
        }
    }

    static func namespacedStableID(for legacyID: String) -> String {
        if legacyID.hasPrefix("avf:") || legacyID.hasPrefix("ca:") {
            return legacyID
        }
        return "avf:\(legacyID)"
    }

    private static func trimmedLegacyID(
        _ defaults: UserDefaults
    ) -> String? {
        guard let stored = defaults.string(forKey: legacyKey) else {
            return nil
        }
        let trimmed = stored.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return trimmed.isEmpty ? nil : trimmed
    }
}
