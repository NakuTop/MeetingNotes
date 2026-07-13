import Foundation

enum CredentialKey: String, CaseIterable, Equatable, Sendable {
    case deepSeekAPIKey = "deepseek-api-key"
    case notionToken = "notion-token"
}

protocol CredentialStore: Sendable {
    func value(for key: CredentialKey) throws -> String?
    func save(_ value: String, for key: CredentialKey) throws
    func delete(_ key: CredentialKey) throws
}

enum CredentialMask {
    static func mask(_ value: String) -> String {
        guard value.count > 4 else {
            return String(repeating: "•", count: value.count)
        }

        return String(repeating: "•", count: value.count - 4)
            + value.suffix(4)
    }
}
