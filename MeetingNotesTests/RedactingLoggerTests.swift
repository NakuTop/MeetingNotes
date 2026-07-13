import XCTest
@testable import MeetingNotes

final class RedactingLoggerTests: XCTestCase {
    func testMessageContainsOnlyWhitelistedMetadataAndDropsQuery() {
        let logger = RedactingLogger(
            subsystem: "MeetingNotesTests",
            category: "Networking"
        )
        let requestID = UUID()
        let message = logger.message(
            for: NetworkLogEvent(
                requestID: requestID,
                statusCode: 401,
                path: "/v1/models?authorization=Bearer-super-secret",
                errorCategory: .unauthorized
            )
        )

        XCTAssertTrue(message.contains(requestID.uuidString))
        XCTAssertTrue(message.contains("status=401"))
        XCTAssertTrue(message.contains("path=/v1/models"))
        XCTAssertTrue(message.contains("error=unauthorized"))
        XCTAssertFalse(message.contains("authorization"))
        XCTAssertFalse(message.contains("Bearer"))
        XCTAssertFalse(message.contains("super-secret"))
    }

    func testMessageHandlesMissingOptionalMetadata() {
        let logger = RedactingLogger(
            subsystem: "MeetingNotesTests",
            category: "Networking"
        )
        let message = logger.message(
            for: NetworkLogEvent(
                requestID: UUID(),
                statusCode: nil,
                path: "https://api.example.com/v1/chat/completions#secret-fragment",
                errorCategory: nil
            )
        )

        XCTAssertTrue(message.contains("path=/v1/chat/completions"))
        XCTAssertTrue(message.contains("status=none"))
        XCTAssertTrue(message.contains("error=none"))
        XCTAssertFalse(message.contains("secret-fragment"))
        XCTAssertFalse(message.contains("api.example.com"))
    }
}
