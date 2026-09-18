import Foundation
import XCTest
@testable import MeetingNotes

private struct VoiceprintTestKey: VoiceprintKeyProviding {
    var value = Data(repeating: 41, count: 32)
    var missing = false
    func key(createIfMissing: Bool) throws -> Data {
        if missing { throw VoiceprintError.storageUnavailable }
        return value
    }
}

final class EncryptedVoiceprintStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VoiceprintTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return directory
    }
    private var profiles: [LocalVoiceprintProfile] {
        [.init(id: UUID(), name: "仅用于测试的私密姓名", modelID: VoiceprintEmbedding.currentModelID,
               embedding: [Float](repeating: 0.0625, count: 256), speechSeconds: 5, createdAt: .now)]
    }

    func testEncryptedRoundTripPermissionsAndNoPlaintext() throws {
        let directory = try directory()
        let store = EncryptedVoiceprintStore(directory: directory, keys: VoiceprintTestKey())
        let original = profiles
        try store.save(original)
        let loaded = try store.load()
        XCTAssertEqual(loaded.first?.name, original.first?.name)
        XCTAssertEqual(loaded.first?.embedding, original.first?.embedding)
        let file = directory.appendingPathComponent("profiles-v1.aesgcm")
        let bytes = try Data(contentsOf: file)
        XCTAssertNil(bytes.range(of: Data(original[0].name.utf8)))
        XCTAssertNil(bytes.range(of: Data(VoiceprintEmbedding.currentModelID.utf8)))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["profiles-v1.aesgcm"])
    }

    func testTamperWrongOrMissingKeyFailWithoutOverwriting() throws {
        let directory = try directory()
        let store = EncryptedVoiceprintStore(directory: directory, keys: VoiceprintTestKey())
        try store.save(profiles)
        let file = directory.appendingPathComponent("profiles-v1.aesgcm")
        let original = try Data(contentsOf: file)
        XCTAssertThrowsError(try EncryptedVoiceprintStore(directory: directory,
            keys: VoiceprintTestKey(value: Data(repeating: 3, count: 32))).load())
        let missing = EncryptedVoiceprintStore(directory: directory, keys: VoiceprintTestKey(missing: true))
        XCTAssertThrowsError(try missing.load())
        XCTAssertThrowsError(try missing.save(profiles))
        XCTAssertEqual(try Data(contentsOf: file), original)
        var tampered = original
        tampered[tampered.count / 2] ^= 1
        try tampered.write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: file), tampered)
    }

    func testDeleteAllRemovesOnlyLibraryAndDoesNotRequireKey() throws {
        let directory = try directory()
        let store = EncryptedVoiceprintStore(directory: directory, keys: VoiceprintTestKey())
        try store.save(profiles)
        let neighbor = directory.appendingPathComponent("untouched-recording.txt")
        try Data("must remain".utf8).write(to: neighbor)
        try EncryptedVoiceprintStore(directory: directory, keys: VoiceprintTestKey(missing: true)).save([])
        XCTAssertTrue(try store.load().isEmpty)
        XCTAssertEqual(try String(contentsOf: neighbor, encoding: .utf8), "must remain")
    }
}
