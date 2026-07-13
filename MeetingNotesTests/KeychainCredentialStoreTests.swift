import XCTest
@testable import MeetingNotes

final class KeychainCredentialStoreTests: XCTestCase {
    func testSaveReadOverwriteDeleteAndMissingValue() throws {
        let service = "MeetingNotesTests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        defer {
            try? store.delete(.deepSeekAPIKey)
            try? store.delete(.notionToken)
        }

        XCTAssertNil(try store.value(for: .deepSeekAPIKey))
        XCTAssertNil(try store.value(for: .notionToken))

        try store.save("deepseek-first", for: .deepSeekAPIKey)
        try store.save("notion-secret", for: .notionToken)
        XCTAssertEqual(try store.value(for: .deepSeekAPIKey), "deepseek-first")
        XCTAssertEqual(try store.value(for: .notionToken), "notion-secret")

        try store.save("deepseek-replaced", for: .deepSeekAPIKey)
        XCTAssertEqual(try store.value(for: .deepSeekAPIKey), "deepseek-replaced")
        XCTAssertEqual(try store.value(for: .notionToken), "notion-secret")

        try store.delete(.deepSeekAPIKey)
        XCTAssertNil(try store.value(for: .deepSeekAPIKey))
        XCTAssertEqual(try store.value(for: .notionToken), "notion-secret")

        try store.delete(.deepSeekAPIKey)
        XCTAssertNil(try store.value(for: .deepSeekAPIKey))
    }

    func testDifferentServicesAreIsolated() throws {
        let first = KeychainCredentialStore(
            service: "MeetingNotesTests.\(UUID().uuidString)"
        )
        let second = KeychainCredentialStore(
            service: "MeetingNotesTests.\(UUID().uuidString)"
        )
        defer {
            try? first.delete(.deepSeekAPIKey)
            try? second.delete(.deepSeekAPIKey)
        }

        try first.save("first-secret", for: .deepSeekAPIKey)
        try second.save("second-secret", for: .deepSeekAPIKey)

        XCTAssertEqual(try first.value(for: .deepSeekAPIKey), "first-secret")
        XCTAssertEqual(try second.value(for: .deepSeekAPIKey), "second-secret")
    }

    func testCredentialMaskHidesShortValuesAndOnlyRevealsLastFour() {
        XCTAssertEqual(CredentialMask.mask(""), "")
        XCTAssertEqual(CredentialMask.mask("abc"), "•••")
        XCTAssertEqual(
            CredentialMask.mask("sk-12345678"),
            "•••••••5678"
        )
    }
}
