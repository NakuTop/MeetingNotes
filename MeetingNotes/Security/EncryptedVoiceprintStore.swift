import CryptoKit
import Foundation
import Security
import Darwin

protocol VoiceprintKeyProviding: Sendable {
    func key(createIfMissing: Bool) throws -> Data
}

struct VoiceprintKeychainKey: VoiceprintKeyProviding {
    let service: String

    func key(createIfMissing: Bool) throws -> Data {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "local-voiceprint-encryption-v1",
            kSecAttrSynchronizable as String: false
        ]
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound, createIfMissing else { throw VoiceprintError.storageUnavailable }
        let data = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var addition = base
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(addition as CFDictionary, nil)
        if added == errSecDuplicateItem { return try key(createIfMissing: false) }
        guard added == errSecSuccess else { throw VoiceprintError.storageUnavailable }
        return data
    }
}

struct EncryptedVoiceprintStore: VoiceprintStoring {
    let directory: URL
    let keys: any VoiceprintKeyProviding
    private var file: URL { directory.appendingPathComponent("profiles-v1.aesgcm") }
    private static let context = Data("MeetingNotes.local-voiceprints.v1".utf8)

    private struct Archive: Codable {
        var schemaVersion = 1
        let profiles: [LocalVoiceprintProfile]
    }

    func load() throws -> [LocalVoiceprintProfile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        do {
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 2_000_000 else { throw VoiceprintError.storageUnavailable }
            let key = SymmetricKey(data: try keys.key(createIfMissing: false))
            let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
            let plain = try AES.GCM.open(box, using: key, authenticating: Self.context)
            let archive = try JSONDecoder().decode(Archive.self, from: plain)
            guard archive.schemaVersion == 1, archive.profiles.count <= 64 else {
                throw VoiceprintError.storageUnavailable
            }
            return archive.profiles
        } catch { throw VoiceprintError.storageUnavailable }
    }

    func save(_ profiles: [LocalVoiceprintProfile]) throws {
        guard profiles.count <= 64 else { throw VoiceprintError.libraryFull }
        if profiles.isEmpty {
            // Remove this library file only; meeting audio and confirmed names
            // are separate user data. The device-local random key contains no profile.
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.removeItem(at: file)
            }
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            var location = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            let key = SymmetricKey(data: try keys.key(createIfMissing: true))
            let plain = try JSONEncoder().encode(Archive(profiles: profiles))
            let sealed = try AES.GCM.seal(plain, using: key, authenticating: Self.context)
            guard let data = sealed.combined else { throw VoiceprintError.storageUnavailable }
            // Set permissions before atomic replacement, so every failure
            // leaves the previous library intact. Only ciphertext touches disk.
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            guard rename(temporary.path, file.path) == 0 else { throw VoiceprintError.storageUnavailable }
        } catch { throw VoiceprintError.storageUnavailable }
    }
}
