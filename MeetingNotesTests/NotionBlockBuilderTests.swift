import XCTest
@testable import MeetingNotes

final class NotionBlockBuilderTests: XCTestCase {
    func testSummaryKindContainsSummaryAndExistingTranscriptSections() throws {
        let content = try makeSummaryContent()

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

    func testSummaryKindDoesNotContainDetailedMinutes() throws {
        let blocks = NotionBlockBuilder().blocks(for: try makeSummaryContent())

        XCTAssertFalse(blocks.contains { $0.text.contains("完整纪要") })
        XCTAssertFalse(blocks.contains { $0.text.contains("待确认问题") })
        XCTAssertFalse(blocks.contains { $0.text.contains("独立议题深度内容") })
    }

    func testDetailedMinutesKindContainsMinutesAndSharedCanonicalFields() throws {
        let content = try makeDetailedContent()

        let blocks = NotionBlockBuilder().blocks(for: content)
        let allText = blocks.map(\.text).joined(separator: "\n")

        XCTAssertTrue(allText.contains("深度提炼的会议概况"))
        XCTAssertTrue(allText.contains("独立议题"))
        XCTAssertTrue(allText.contains("00:10-05:20"))
        XCTAssertTrue(allText.contains("我、远端发言人 1"))
        XCTAssertTrue(allText.contains("独立议题深度内容"))
        XCTAssertTrue(allText.contains("完整纪要决定"))
        XCTAssertTrue(allText.contains("完整纪要行动项"))
        XCTAssertTrue(allText.contains("完整纪要待确认问题"))
        XCTAssertFalse(allText.contains("精简摘要概览"))
        XCTAssertFalse(allText.contains("精简摘要关键点"))
        XCTAssertFalse(allText.contains("精简摘要书签洞察"))
        XCTAssertFalse(blocks.contains { $0.kind == .heading2 && $0.text == "摘要" })
        XCTAssertTrue(blocks.contains { $0.kind == .heading2 && $0.text == "书签" })
        XCTAssertTrue(blocks.contains { $0.kind == .heading2 && $0.text == "完整转录" })
    }

    func testBuilderAcceptsEitherSingleDocumentKind() throws {
        let builder = NotionBlockBuilder()
        let summaryContent = try makeSummaryContent()
        let detailedContent = try makeDetailedContent()

        let summarySection = builder.documentBlocks(for: summaryContent)
        let detailedSection = builder.documentBlocks(for: detailedContent)

        XCTAssertEqual(summaryContent.documentKinds, [.summary])
        XCTAssertEqual(detailedContent.documentKinds, [.detailedMinutes])
        XCTAssertEqual(
            builder.blocks(for: summaryContent),
            builder.metadataBlocks(for: summaryContent) + summarySection
        )
        XCTAssertEqual(
            builder.blocks(for: detailedContent),
            builder.metadataBlocks(for: detailedContent) + detailedSection
        )
        XCTAssertTrue(summarySection.contains { $0.text == "摘要" })
        XCTAssertFalse(summarySection.contains { $0.text == "完整纪要" })
        XCTAssertTrue(detailedSection.contains { $0.text == "完整纪要" })
        XCTAssertFalse(detailedSection.contains { $0.text == "摘要" })
    }

    func testPageContentRequiresAtLeastOneLocalDocument() {
        XCTAssertThrowsError(
            try makeContent(summary: nil, detailedMinutes: nil)
        ) { error in
            XCTAssertEqual(
                error as? NotionMeetingPageContentError,
                .missingLocalDocument
            )
        }
    }

    func testDecodedPageContentAlsoRequiresAtLeastOneLocalDocument()
        throws {
        let validData = try JSONEncoder().encode(makeSummaryContent())
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        object["summary"] = NSNull()
        object["detailedMinutes"] = NSNull()
        let invalidData = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                NotionMeetingPageContent.self,
                from: invalidData
            )
        ) { error in
            XCTAssertEqual(
                error as? NotionMeetingPageContentError,
                .missingLocalDocument
            )
        }
    }

    func testCanonicalPageBuildsSummaryMinutesAndSharedContentOnce() throws {
        let content = try makeContent(
            summary: conciseSummary,
            detailedMinutes: detailedMinutes,
            transcripts: [
                .init(
                    startTime: 2,
                    endTime: 5,
                    text: "采用最终方案",
                    speakerLabel: "张三"
                )
            ]
        )

        let blocks = NotionBlockBuilder().blocks(for: content)
        let headings = blocks
            .filter { $0.kind == .heading2 }
            .map(\.text)

        XCTAssertEqual(content.documentKinds, [.summary, .detailedMinutes])
        XCTAssertEqual(headings.filter { $0 == "元信息" }.count, 1)
        XCTAssertEqual(headings.filter { $0 == "摘要" }.count, 1)
        XCTAssertEqual(headings.filter { $0 == "完整纪要" }.count, 1)
        XCTAssertEqual(headings.filter { $0 == "书签" }.count, 1)
        XCTAssertEqual(headings.filter { $0 == "完整转录" }.count, 1)
        XCTAssertTrue(blocks.contains { $0.text.contains("精简摘要概览") })
        XCTAssertTrue(blocks.contains { $0.text.contains("深度提炼的会议概况") })
        XCTAssertTrue(blocks.contains { $0.text.contains("负责人") })
        XCTAssertTrue(
            blocks.contains {
                $0.text.contains("张三") && $0.text.contains("采用最终方案")
            }
        )

        let encoded = try JSONEncoder().encode(content)
        XCTAssertEqual(
            try JSONDecoder().decode(
                NotionMeetingPageContent.self,
                from: encoded
            ),
            content
        )
    }

    func testLongMinutesParagraphsRespectNotionTextAndBatchLimits() throws {
        let grapheme = "👩‍💻"
        let longText = String(repeating: "会", count: 8)
            + grapheme
            + String(repeating: "议", count: 9)
        let minutes = GeneratedDetailedMinutes(
            overview: longText,
            sections: [
                .init(
                    title: "超长议题",
                    timeRange: nil,
                    speakers: [],
                    content: longText
                )
            ],
            decisions: [longText],
            actionItems: [],
            openQuestions: []
        )
        let content = try makeContent(
            summary: nil,
            detailedMinutes: minutes
        )
        let builder = NotionBlockBuilder(
            maximumTextLength: 7,
            maximumBlocksPerBatch: 3
        )

        let blocks = builder.blocks(for: content)
        let batches = builder.batches(for: content)

        XCTAssertTrue(blocks.allSatisfy { $0.text.utf16.count <= 7 })
        XCTAssertTrue(batches.allSatisfy { !$0.isEmpty && $0.count <= 3 })
        XCTAssertEqual(batches.flatMap { $0 }, blocks)
        XCTAssertGreaterThanOrEqual(
            blocks.map(\.text).joined().components(separatedBy: longText).count - 1,
            3
        )
        XCTAssertTrue(blocks.contains { $0.text.contains(grapheme) })
    }

    func testCompositeEmojiChunksRespectUTF16BudgetAndReassembleExactly() throws {
        let compositeEmoji = "👨🏽‍💻🏳️‍🌈"
        let oversizedGrapheme = "👩🏽‍💻" + String(
            repeating: "\u{200D}👨🏿",
            count: 12
        )
        XCTAssertEqual(oversizedGrapheme.count, 1)
        XCTAssertGreaterThan(oversizedGrapheme.utf16.count, 32)
        let longText = String(repeating: compositeEmoji, count: 300)
            + oversizedGrapheme
            + String(repeating: compositeEmoji, count: 300)
        let content = try makeSummaryContent(overview: longText)

        let summaryBlocks = NotionBlockBuilder(maximumTextLength: 32)
            .blocks(for: content)
            .drop { !($0.kind == .heading2 && $0.text == "摘要") }
            .dropFirst()
            .prefix { $0.kind != .heading2 }

        XCTAssertGreaterThan(summaryBlocks.count, 1)
        XCTAssertTrue(summaryBlocks.allSatisfy { $0.text.utf16.count <= 32 })
        XCTAssertEqual(summaryBlocks.map(\.text).joined(), longText)
        XCTAssertEqual(
            summaryBlocks.map(\.text).joined().unicodeScalars.map(\.value),
            longText.unicodeScalars.map(\.value)
        )
    }

    func testBatchesRespectEncodedPayloadByteLimitWithoutLosingBlocks() throws {
        let transcripts = (0..<24).map { index in
            MeetingTranscriptInput(
                startTime: TimeInterval(index),
                endTime: TimeInterval(index + 1),
                text: String(repeating: "\"👩‍💻\\会议", count: 5)
            )
        }
        let content = try makeSummaryContent(transcripts: transcripts)
        let maximumPayloadBytes = 650
        let builder = NotionBlockBuilder(
            maximumBlocksPerBatch: 100,
            maximumRequestBodyBytes: maximumPayloadBytes
        )

        let blocks = builder.blocks(for: content)
        let batches = builder.batches(for: content)

        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 100 })
        XCTAssertTrue(
            try batches.allSatisfy {
                try encodedPayloadSize($0) <= maximumPayloadBytes
            }
        )
        XCTAssertEqual(batches.flatMap { $0 }, blocks)
    }

    func testTranscriptTiesPreserveInputOrder() throws {
        let transcripts = ["第三", "第一", "第二"].map {
            MeetingTranscriptInput(startTime: 10, endTime: 12, text: $0)
        }
        let content = try makeSummaryContent(transcripts: transcripts)

        let transcriptBlocks = NotionBlockBuilder().documentBlocks(for: content)
            .drop { !($0.kind == .heading2 && $0.text == "完整转录") }
            .dropFirst()

        XCTAssertEqual(
            transcriptBlocks.map(\.text),
            ["[00:10-00:12] 第三", "[00:10-00:12] 第一", "[00:10-00:12] 第二"]
        )
    }

    func testConfiguredLimitsCannotExceedNotionSafetyCaps() throws {
        let escapedText = String(repeating: "\u{0001}", count: 1_900)
        let transcripts = (0..<205).map { index in
            MeetingTranscriptInput(
                startTime: TimeInterval(index),
                endTime: TimeInterval(index + 1),
                text: escapedText
            )
        }
        let content = try makeSummaryContent(
            overview: String(repeating: "会", count: 2_000),
            transcripts: transcripts
        )
        let builder = NotionBlockBuilder(
            maximumTextLength: 10_000,
            maximumBlocksPerBatch: 1_000,
            maximumRequestBodyBytes: 1_000_000
        )

        let blocks = builder.blocks(for: content)
        let batches = builder.batches(for: content)

        XCTAssertTrue(blocks.allSatisfy { $0.text.utf16.count <= 1_900 })
        XCTAssertTrue(batches.allSatisfy { $0.count <= 100 })
        XCTAssertTrue(
            try batches.allSatisfy { try encodedPayloadSize($0) <= 480_000 }
        )
        XCTAssertEqual(batches.flatMap { $0 }, blocks)
    }

    func testBatchesContainAtMostOneHundredBlocksWithoutChangingOrder() throws {
        let transcripts = (0..<205).map { index in
            MeetingTranscriptInput(
                startTime: TimeInterval(index),
                endTime: TimeInterval(index + 1),
                text: "转录 \(index)"
            )
        }
        let content = try makeSummaryContent(transcripts: transcripts)
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

    func testImageBlockEncodingReferencesOnlyNotionFileUploadID() throws {
        let uploadID = "43833259-72ae-404e-8441-b6577f3159b4"
        let block = NotionBlockDraft.image(fileUploadID: uploadID)

        let data = try JSONEncoder().encode(block)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(block.kind, .image)
        XCTAssertEqual(block.text, "")
        XCTAssertEqual(json["object"] as? String, "block")
        XCTAssertEqual(json["type"] as? String, "image")
        let image = try XCTUnwrap(json["image"] as? [String: Any])
        XCTAssertEqual(image["type"] as? String, "file_upload")
        XCTAssertEqual((image["caption"] as? [Any])?.count, 0)
        let fileUpload = try XCTUnwrap(
            image["file_upload"] as? [String: String]
        )
        XCTAssertEqual(fileUpload, ["id": uploadID])
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("file://"))
        XCTAssertFalse(encoded.contains("/Users/"))
        XCTAssertFalse(encoded.contains("external"))
        XCTAssertFalse(encoded.contains("url"))
    }

    func testTimelineOrdersNotesAndUploadedScreenshotsByTimestamp()
        throws {
        let earlyNoteID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let screenshotID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        let lateNoteID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000003"
        )!
        let content = try makeContent(
            summary: conciseSummary,
            detailedMinutes: nil,
            userNotes: [
                .init(
                    id: lateNoteID,
                    timestamp: 15,
                    text: "后一条笔记",
                    sequenceIndex: 1
                ),
                .init(
                    id: earlyNoteID,
                    timestamp: 5,
                    text: "先一条笔记",
                    sequenceIndex: 0
                )
            ],
            screenshots: [
                .init(
                    id: screenshotID,
                    timestamp: 10,
                    sequenceIndex: 0,
                    fileUploadID: "notion-upload-id"
                )
            ]
        )

        let blocks = NotionBlockBuilder().documentBlocks(for: content)
        let timelineStart = try XCTUnwrap(
            blocks.firstIndex {
                $0.kind == .heading2 && $0.text == "会议时间轴"
            }
        )
        let timeline = [blocks[timelineStart]] + blocks
            .dropFirst(timelineStart + 1)
            .prefix { $0.kind != .heading2 }

        XCTAssertEqual(timeline.first?.text, "会议时间轴")
        XCTAssertEqual(
            timeline.dropFirst().map(\.kind),
            [.bulletedListItem, .paragraph, .image, .bulletedListItem]
        )
        XCTAssertEqual(
            timeline.dropFirst().map(\.text),
            [
                "[00:05] 笔记：先一条笔记",
                "[00:10] 截图",
                "",
                "[00:15] 笔记：后一条笔记"
            ]
        )
        let imageBlock = try XCTUnwrap(
            timeline.first { $0.kind == .image }
        )
        let imageData = try JSONEncoder().encode(imageBlock)
        XCTAssertTrue(
            String(data: imageData, encoding: .utf8)?
                .contains("notion-upload-id") == true
        )
    }

    func testOldPageSnapshotDecodesMissingTimelineFieldsAsEmpty() throws {
        let current = try makeSummaryContent()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(current)
            ) as? [String: Any]
        )
        object.removeValue(forKey: "userNotes")
        object.removeValue(forKey: "screenshots")

        let decoded = try JSONDecoder().decode(
            NotionMeetingPageContent.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.userNotes, [])
        XCTAssertEqual(decoded.screenshots, [])
    }

    private func makeSummaryContent(
        overview: String = "确认了下一阶段路线图。",
        transcripts: [MeetingTranscriptInput] = [
            .init(startTime: 0, endTime: 3, text: "开始讨论路线图")
        ]
    ) throws -> NotionMeetingPageContent {
        try makeContent(
            summary: GeneratedMeetingSummary(
                suggestedTitle: "产品路线图周会",
                overview: overview,
                keyPoints: ["优先稳定性", "精简摘要关键点"],
                decisions: ["下周发布"],
                actionItems: [
                    .init(task: "准备发布", owner: "小王", dueDate: "下周一")
                ],
                bookmarkInsights: ["精简摘要书签洞察"]
            ),
            detailedMinutes: nil,
            transcripts: transcripts
        )
    }

    private func makeDetailedContent() throws -> NotionMeetingPageContent {
        try makeContent(
            summary: nil,
            detailedMinutes: detailedMinutes
        )
    }

    private func makeContent(
        summary: GeneratedMeetingSummary?,
        detailedMinutes: GeneratedDetailedMinutes?,
        transcripts: [MeetingTranscriptInput] = [],
        userNotes: [NotionTimelineNote] = [],
        screenshots: [NotionTimelineScreenshot] = []
    ) throws -> NotionMeetingPageContent {
        try NotionMeetingPageContent(
            title: "产品周会",
            startedAt: Date(timeIntervalSince1970: 0),
            duration: 125,
            mode: .online,
            contentRevision: 7,
            summary: summary,
            detailedMinutes: detailedMinutes,
            bookmarks: [.init(timestamp: 65, excerpt: "发布决定")],
            transcripts: transcripts,
            userNotes: userNotes,
            screenshots: screenshots
        )
    }

    private var conciseSummary: GeneratedMeetingSummary {
        GeneratedMeetingSummary(
            suggestedTitle: "精简摘要标题",
            overview: "精简摘要概览",
            keyPoints: ["精简摘要关键点"],
            decisions: ["精简摘要决定"],
            actionItems: [],
            bookmarkInsights: ["精简摘要书签洞察"]
        )
    }

    private var detailedMinutes: GeneratedDetailedMinutes {
        GeneratedDetailedMinutes(
            overview: "深度提炼的会议概况",
            sections: [
                .init(
                    title: "独立议题",
                    timeRange: "00:10-05:20",
                    speakers: ["我", "远端发言人 1"],
                    content: "独立议题深度内容"
                )
            ],
            decisions: ["完整纪要决定"],
            actionItems: [
                .init(task: "完整纪要行动项", owner: "负责人", dueDate: "明天")
            ],
            openQuestions: ["完整纪要待确认问题"]
        )
    }

    private func encodedPayloadSize(
        _ blocks: [NotionBlockDraft]
    ) throws -> Int {
        try JSONEncoder().encode(ChildrenPayload(children: blocks)).count
    }

    private struct ChildrenPayload: Encodable {
        let children: [NotionBlockDraft]
    }
}
