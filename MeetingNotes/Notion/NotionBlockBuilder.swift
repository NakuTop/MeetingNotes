import Foundation

struct NotionMeetingPageContent: Equatable, Sendable {
    let title: String
    let startedAt: Date
    let duration: TimeInterval
    let mode: MeetingMode
    let summary: GeneratedMeetingSummary
    let bookmarks: [MeetingBookmarkInput]
    let transcripts: [MeetingTranscriptInput]
}

enum NotionBlockKind: String, Codable, Equatable, Sendable {
    case heading2 = "heading_2"
    case paragraph
    case bulletedListItem = "bulleted_list_item"
}

struct NotionBlockDraft: Encodable, Equatable, Sendable {
    let kind: NotionBlockKind
    let text: String

    private enum CodingKeys: String, CodingKey {
        case object
        case type
        case heading2 = "heading_2"
        case paragraph
        case bulletedListItem = "bulleted_list_item"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("block", forKey: .object)
        try container.encode(kind.rawValue, forKey: .type)
        let payload = RichTextPayload(richText: [.plain(text)])
        switch kind {
        case .heading2:
            try container.encode(payload, forKey: .heading2)
        case .paragraph:
            try container.encode(payload, forKey: .paragraph)
        case .bulletedListItem:
            try container.encode(payload, forKey: .bulletedListItem)
        }
    }
}

private struct RichTextPayload: Encodable {
    let richText: [NotionRichText]

    private enum CodingKeys: String, CodingKey {
        case richText = "rich_text"
    }
}

private struct NotionRichText: Encodable {
    let type: String
    let text: TextContent

    static func plain(_ content: String) -> NotionRichText {
        NotionRichText(type: "text", text: TextContent(content: content))
    }

    struct TextContent: Encodable {
        let content: String
    }
}

struct NotionBlockBuilder: Sendable {
    let maximumTextLength: Int
    let maximumBlocksPerBatch: Int

    init(
        maximumTextLength: Int = 1_900,
        maximumBlocksPerBatch: Int = 100
    ) {
        self.maximumTextLength = max(1, maximumTextLength)
        self.maximumBlocksPerBatch = max(1, maximumBlocksPerBatch)
    }

    func blocks(for content: NotionMeetingPageContent) -> [NotionBlockDraft] {
        var result: [NotionBlockDraft] = []

        appendHeading("元信息", to: &result)
        append(
            kind: .paragraph,
            text: metadata(for: content),
            to: &result
        )

        appendHeading("摘要", to: &result)
        append(kind: .paragraph, text: content.summary.overview, to: &result)

        appendHeading("关键结论", to: &result)
        appendList(content.summary.keyPoints, to: &result)

        appendHeading("决定事项", to: &result)
        appendList(content.summary.decisions, to: &result)

        appendHeading("行动项", to: &result)
        appendList(
            content.summary.actionItems.map(actionItemText),
            to: &result
        )

        appendHeading("书签", to: &result)
        let bookmarkLines = content.bookmarks
            .sorted { $0.timestamp < $1.timestamp }
            .map { "[\(formatTime($0.timestamp))] \($0.excerpt)" }
        let insightLines = content.summary.bookmarkInsights.map {
            "AI 解读：\($0)"
        }
        appendList(bookmarkLines + insightLines, to: &result)

        appendHeading("完整转录", to: &result)
        let transcriptLines = content.transcripts
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.endTime < rhs.endTime
                }
                return lhs.startTime < rhs.startTime
            }
            .map {
                "[\(formatTime($0.startTime))-\(formatTime($0.endTime))] \($0.text)"
            }
        appendList(transcriptLines, emptyKind: .paragraph, to: &result)

        return result
    }

    func batches(
        for content: NotionMeetingPageContent
    ) -> [[NotionBlockDraft]] {
        let allBlocks = blocks(for: content)
        return stride(from: 0, to: allBlocks.count, by: maximumBlocksPerBatch)
            .map { start in
                let end = min(start + maximumBlocksPerBatch, allBlocks.count)
                return Array(allBlocks[start..<end])
            }
    }

    private func appendHeading(
        _ text: String,
        to blocks: inout [NotionBlockDraft]
    ) {
        append(kind: .heading2, text: text, to: &blocks)
    }

    private func appendList(
        _ values: [String],
        emptyKind: NotionBlockKind = .bulletedListItem,
        to blocks: inout [NotionBlockDraft]
    ) {
        guard !values.isEmpty else {
            append(kind: emptyKind, text: "无", to: &blocks)
            return
        }
        for value in values {
            append(kind: .bulletedListItem, text: value, to: &blocks)
        }
    }

    private func append(
        kind: NotionBlockKind,
        text: String,
        to blocks: inout [NotionBlockDraft]
    ) {
        for chunk in chunks(of: text.isEmpty ? "无" : text) {
            blocks.append(NotionBlockDraft(kind: kind, text: chunk))
        }
    }

    private func chunks(of text: String) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(
                start,
                offsetBy: maximumTextLength,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }

    private func metadata(for content: NotionMeetingPageContent) -> String {
        let mode = content.mode == .online ? "在线会议" : "线下会议"
        return """
        标题：\(content.title)
        开始时间：\(ISO8601DateFormatter().string(from: content.startedAt))
        有效时长：\(formatTime(content.duration))
        模式：\(mode)
        """
    }

    private func actionItemText(_ item: ActionItem) -> String {
        let owner = item.owner ?? "未指定"
        let dueDate = item.dueDate ?? "未指定"
        return "\(item.task)｜负责人：\(owner)｜截止：\(dueDate)"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainder = totalSeconds % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}
