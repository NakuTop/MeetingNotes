import XCTest
@testable import MeetingNotes

final class NotionPageLinkParserTests: XCTestCase {
    func testParsesSluggedPlainAndHyphenatedPageIDs() throws {
        let expected = try XCTUnwrap(
            UUID(uuidString: "12345678-90ab-cdef-1234-567890abcdef")
        )

        XCTAssertEqual(
            NotionPageLinkParser.parse(
                "https://www.notion.so/My-Meeting-1234567890abcdef1234567890abcdef?pvs=4"
            ),
            expected
        )
        XCTAssertEqual(
            NotionPageLinkParser.parse(
                "https://notion.so/1234567890abcdef1234567890abcdef"
            ),
            expected
        )
        XCTAssertEqual(
            NotionPageLinkParser.parse(
                "https://www.notion.so/My-Meeting-12345678-90ab-cdef-1234-567890abcdef?source=copy_link"
            ),
            expected
        )
    }

    func testRejectsNonHTTPSLookalikeAndMissingPageID() {
        let invalidLinks = [
            "http://www.notion.so/1234567890abcdef1234567890abcdef",
            "https://notion.site/1234567890abcdef1234567890abcdef",
            "https://www.notion.so.evil.example/1234567890abcdef1234567890abcdef",
            "https://example.com/notion.so/1234567890abcdef1234567890abcdef",
            "https://www.notion.so/meeting-without-an-id",
            "not a URL"
        ]

        for link in invalidLinks {
            XCTAssertNil(NotionPageLinkParser.parse(link), link)
        }
    }
}
