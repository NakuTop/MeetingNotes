import XCTest
@testable import MeetingNotes

final class NotionBlockBuilderTests: XCTestCase {
    func testBuildsMeetingSectionsInRequiredOrder() {
        let content = NotionMeetingPageContent(
            title: "产品周会",
            startedAt: Date(timeIntervalSince1970: 0),
            duration: 125,
            mode: .online,
            summary: GeneratedMeetingSummary(
                suggestedTitle: "产品路线图周会",
                overview: "确认了下一阶段路线图。",
                keyPoints: ["优先稳定性"],
                decisions: ["下周发布"],
                actionItems: [
                    .init(task: "准备发布", owner: "小王", dueDate: "下周一")
                ],
                bookmarkInsights: ["发布决定"]
            ),
            bookmarks: [
                .init(timestamp: 65, excerpt: "发布决定")
            ],
            transcripts: [
                .init(startTime: 0, endTime: 3, text: "开始讨论路线图")
            ]
        )

        let blocks = NotionBlockBuilder().blocks(for: content)
        let headings = blocks
            .filter { $0.kind == .heading2 }
            .map(\.text)

        XCTAssertEqual(
            headings,
            ["元信息", "摘要", "关键结论", "决定事项", "行动项", "书签", "完整转录"]
        )
        XCTAssertTrue(blocks.contains { $0.text.contains("产品周会") })
        XCTAssertTrue(blocks.contains { $0.text.contains("在线会议") })
        XCTAssertTrue(blocks.contains { $0.text.contains("确认了下一阶段路线图") })
        XCTAssertTrue(blocks.contains { $0.text.contains("小王") && $0.text.contains("下周一") })
        XCTAssertTrue(blocks.contains { $0.text.contains("01:05") && $0.text.contains("发布决定") })
        XCTAssertTrue(blocks.contains { $0.text.contains("开始讨论路线图") })
    }

    func testSplitsAtWholeGraphemesAndCapsEveryRichTextAt1900Characters() {
        let grapheme = "👩‍💻"
        let longText = String(repeating: "会", count: 1_899)
            + grapheme
            + String(repeating: "议", count: 1_901)
        let content = makeContent(overview: longText)

        let summaryBlocks = NotionBlockBuilder().blocks(for: content)
            .drop { !($0.kind == .heading2 && $0.text == "摘要") }
            .dropFirst()
            .prefix { $0.kind != .heading2 }

        XCTAssertGreaterThan(summaryBlocks.count, 1)
        XCTAssertTrue(summaryBlocks.allSatisfy { $0.text.count <= 1_900 })
        XCTAssertEqual(summaryBlocks.map(\.text).joined(), longText)
        XCTAssertTrue(summaryBlocks.contains { $0.text.contains(grapheme) })
    }

    func testBatchesContainAtMostOneHundredBlocksWithoutChangingOrder() {
        let transcripts = (0..<205).map { index in
            MeetingTranscriptInput(
                startTime: TimeInterval(index),
                endTime: TimeInterval(index + 1),
                text: "转录 \(index)"
            )
        }
        let content = makeContent(transcripts: transcripts)
        let builder = NotionBlockBuilder()

        let blocks = builder.blocks(for: content)
        let batches = builder.batches(for: content)

        XCTAssertGreaterThan(batches.count, 2)
        XCTAssertTrue(batches.allSatisfy { !$0.isEmpty && $0.count <= 100 })
        XCTAssertEqual(batches.flatMap { $0 }, blocks)
    }

    func testBlockEncodingMatchesNotionRichTextShape() throws {
        let block = NotionBlockDraft(kind: .bulletedListItem, text: "行动项")

        let data = try JSONEncoder().encode(block)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["object"] as? String, "block")
        XCTAssertEqual(json["type"] as? String, "bulleted_list_item")
        let payload = try XCTUnwrap(json["bulleted_list_item"] as? [String: Any])
        let richText = try XCTUnwrap(payload["rich_text"] as? [[String: Any]])
        let text = try XCTUnwrap(richText.first?["text"] as? [String: String])
        XCTAssertEqual(text["content"], "行动项")
    }

    private func makeContent(
        overview: String = "摘要",
        transcripts: [MeetingTranscriptInput] = []
    ) -> NotionMeetingPageContent {
        NotionMeetingPageContent(
            title: "测试会议",
            startedAt: Date(timeIntervalSince1970: 0),
            duration: 60,
            mode: .offline,
            summary: GeneratedMeetingSummary(
                suggestedTitle: "测试会议",
                overview: overview,
                keyPoints: [],
                decisions: [],
                actionItems: [],
                bookmarkInsights: []
            ),
            bookmarks: [],
            transcripts: transcripts
        )
    }
}
