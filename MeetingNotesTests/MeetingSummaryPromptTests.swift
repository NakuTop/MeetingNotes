import XCTest
@testable import MeetingNotes

final class MeetingSummaryPromptTests: XCTestCase {
    func testPromptRequiresExactJSONAndForbidsInventedOwnersOrDates() {
        let input = MeetingSummaryInput(
            title: "周会",
            transcripts: [
                .init(startTime: 0, endTime: 5, text: "讨论路线图")
            ],
            bookmarks: [
                .init(timestamp: 3, excerpt: "重要决定")
            ]
        )

        let system = MeetingSummaryPrompt.systemMessage
        let user = MeetingSummaryPrompt.userMessage(for: input)

        XCTAssertTrue(system.contains("只输出 JSON"))
        XCTAssertTrue(system.contains("suggestedTitle"))
        XCTAssertTrue(system.contains("actionItems"))
        XCTAssertTrue(system.contains("owner"))
        XCTAssertTrue(system.contains("dueDate"))
        XCTAssertTrue(system.contains("null"))
        XCTAssertTrue(system.contains("不得捏造"))
        XCTAssertTrue(user.contains("讨论路线图"))
        XCTAssertTrue(user.contains("重要决定"))
    }

    func testChunkerPreservesOrderAndKeepsOversizedSegmentWhole() {
        let segments = [
            MeetingTranscriptInput(startTime: 0, endTime: 1, text: "12345"),
            MeetingTranscriptInput(startTime: 1, endTime: 2, text: "67890"),
            MeetingTranscriptInput(startTime: 2, endTime: 3, text: "oversized-value")
        ]
        let chunker = SummaryInputChunker(characterBudget: 10)

        let chunks = chunker.chunks(segments)

        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].map(\.text), ["12345", "67890"])
        XCTAssertEqual(chunks[1].map(\.text), ["oversized-value"])
        XCTAssertEqual(chunks.flatMap { $0 }, segments)
    }
}
