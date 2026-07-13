import Foundation
import Security

enum CredentialStoreError: Error, Equatable, Sendable {
    case invalidStoredData
    case unexpectedStatus(OSStatus)
}

struct KeychainCredentialStore: CredentialStore, Sendable {
    static let defaultService = "com.shenminghao.MeetingNotes.credentials"

    private let service: String

    init(service: String = defaultService) {
        self.service = service
    }

    func value(for key: CredentialKey) throws -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.invalidStoredData
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    func save(_ value: String, for key: CredentialKey) throws {
        let data = Data(value.utf8)
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(for: key) as CFDictionary,
            updateAttributes as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery(for: key)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] =
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.unexpectedStatus(addStatus)
            }
        default:
            throw CredentialStoreError.unexpectedStatus(updateStatus)
        }
    }

    func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(for key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}
