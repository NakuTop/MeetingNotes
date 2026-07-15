import Foundation

final class EphemeralCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(
        deepSeekAPIKey: String? = nil,
        notionToken: String? = nil
    ) {
        var values: [String: String] = [:]
        values[CredentialKey.deepSeekAPIKey.rawValue] = deepSeekAPIKey
        values[CredentialKey.notionToken.rawValue] = notionToken
        self.values = values
    }

    func value(for key: CredentialKey) throws -> String? {
        lock.withLock { values[key.rawValue] }
    }

    func save(_ value: String, for key: CredentialKey) throws {
        lock.withLock { values[key.rawValue] = value }
    }

    func delete(_ key: CredentialKey) throws {
        lock.withLock { values[key.rawValue] = nil }
    }
}
