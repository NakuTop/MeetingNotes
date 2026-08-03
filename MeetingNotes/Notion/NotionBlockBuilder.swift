import Foundation

struct NotionMeetingPageContent: Equatable, Sendable {
    let title: String
    let startedAt: Date
    let duration: TimeInterval
    let mode: MeetingMode
    let kind: MeetingDocumentKind
    let summary: GeneratedMeetingSummary?
    let detailedMinutes: GeneratedDetailedMinutes?
    let bookmarks: [MeetingBookmarkInput]
    let transcripts: [MeetingTranscriptInput]

    init(
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        mode: MeetingMode,
        kind: MeetingDocumentKind,
        summary: GeneratedMeetingSummary?,
        detailedMinutes: GeneratedDetailedMinutes?,
        bookmarks: [MeetingBookmarkInput],
        transcripts: [MeetingTranscriptInput]
    ) throws {
        if summary != nil, detailedMinutes != nil {
            throw NotionMeetingPageContentError.multipleDocuments
        }
        switch kind {
        case .summary:
            guard summary != nil, detailedMinutes == nil else {
                throw NotionMeetingPageContentError
                    .missingRequestedDocument(kind)
            }
        case .detailedMinutes:
            guard detailedMinutes != nil, summary == nil else {
                throw NotionMeetingPageContentError
                    .missingRequestedDocument(kind)
            }
        }
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.mode = mode
        self.kind = kind
        self.summary = summary
        self.detailedMinutes = detailedMinutes
        self.bookmarks = bookmarks
        self.transcripts = transcripts
    }
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
    let maximumRequestBodyBytes: Int

    init(
        maximumTextLength: Int = 1_900,
        maximumBlocksPerBatch: Int = 100,
        maximumRequestBodyBytes: Int = 480_000
    ) {
        self.maximumTextLength = min(1_900, max(2, maximumTextLength))
        self.maximumBlocksPerBatch = min(
            100,
            max(1, maximumBlocksPerBatch)
        )
        self.maximumRequestBodyBytes = min(
            480_000,
            max(1, maximumRequestBodyBytes)
        )
    }

    func blocks(for content: NotionMeetingPageContent) -> [NotionBlockDraft] {
        metadataBlocks(for: content) + documentBlocks(for: content)
    }

    func metadataBlocks(
        for content: NotionMeetingPageContent
    ) -> [NotionBlockDraft] {
        var result: [NotionBlockDraft] = []

        appendHeading("元信息", to: &result)
        append(
            kind: .paragraph,
            text: metadata(for: content),
            to: &result
        )
        return result
    }

    func documentBlocks(
        for content: NotionMeetingPageContent
    ) -> [NotionBlockDraft] {
        switch content.kind {
        case .summary:
            guard let summary = content.summary else {
                preconditionFailure(
                    "Validated summary content must contain its payload."
                )
            }
            return summaryBlocks(summary, content: content)
        case .detailedMinutes:
            guard let detailedMinutes = content.detailedMinutes else {
                preconditionFailure(
                    "Validated detailed-minutes content must contain its payload."
                )
            }
            return detailedMinutesBlocks(detailedMinutes)
        }
    }

    private func summaryBlocks(
        _ summary: GeneratedMeetingSummary,
        content: NotionMeetingPageContent
    ) -> [NotionBlockDraft] {
        var result: [NotionBlockDraft] = []

        appendHeading("摘要", to: &result)
        append(kind: .paragraph, text: summary.overview, to: &result)

        appendHeading("关键结论", to: &result)
        appendList(summary.keyPoints, to: &result)

        appendHeading("决定事项", to: &result)
        appendList(summary.decisions, to: &result)

        appendHeading("行动项", to: &result)
        appendList(
            summary.actionItems.map(actionItemText),
            to: &result
        )

        appendHeading("书签", to: &result)
        let bookmarkLines = content.bookmarks
            .sorted { $0.timestamp < $1.timestamp }
            .map { "[\(formatTime($0.timestamp))] \($0.excerpt)" }
        let insightLines = summary.bookmarkInsights.map {
            "AI 解读：\($0)"
        }
        appendList(bookmarkLines + insightLines, to: &result)

        appendHeading("完整转录", to: &result)
        let transcriptLines = content.transcripts
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.startTime != rhs.element.startTime {
                    return lhs.element.startTime < rhs.element.startTime
                }
                if lhs.element.endTime != rhs.element.endTime {
                    return lhs.element.endTime < rhs.element.endTime
                }
                return lhs.offset < rhs.offset
            }
            .map {
                let transcript = $0.element
                return "[\(formatTime(transcript.startTime))-\(formatTime(transcript.endTime))] \(transcript.text)"
            }
        appendList(transcriptLines, emptyKind: .paragraph, to: &result)

        return result
    }

    private func detailedMinutesBlocks(
        _ minutes: GeneratedDetailedMinutes
    ) -> [NotionBlockDraft] {
        var result: [NotionBlockDraft] = []

        appendHeading("完整纪要", to: &result)
        append(kind: .paragraph, text: minutes.overview, to: &result)

        appendHeading("议题章节", to: &result)
        if minutes.sections.isEmpty {
            append(kind: .paragraph, text: "无", to: &result)
        } else {
            for section in minutes.sections {
                append(
                    kind: .bulletedListItem,
                    text: sectionHeading(section),
                    to: &result
                )
                append(kind: .paragraph, text: section.content, to: &result)
            }
        }

        appendHeading("决定事项", to: &result)
        appendList(minutes.decisions, to: &result)

        appendHeading("行动项", to: &result)
        appendList(minutes.actionItems.map(actionItemText), to: &result)

        appendHeading("待确认问题", to: &result)
        appendList(minutes.openQuestions, to: &result)

        return result
    }

    func batches(
        for content: NotionMeetingPageContent
    ) -> [[NotionBlockDraft]] {
        batches(of: blocks(for: content))
    }

    func batches(
        of blocks: [NotionBlockDraft]
    ) -> [[NotionBlockDraft]] {
        var result: [[NotionBlockDraft]] = []
        var current: [NotionBlockDraft] = []

        for block in blocks {
            let singleBlock = [block]
            precondition(
                encodedPayloadSize(singleBlock) <= maximumRequestBodyBytes,
                "A single Notion block exceeds the configured request budget."
            )
            let candidate = current + singleBlock
            if candidate.count > maximumBlocksPerBatch
                || encodedPayloadSize(candidate) > maximumRequestBodyBytes {
                precondition(!current.isEmpty)
                result.append(current)
                current = singleBlock
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            result.append(current)
        }
        return result
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
        var current = ""
        var currentLength = 0

        func flushCurrent() {
            guard !current.isEmpty else { return }
            chunks.append(current)
            current = ""
            currentLength = 0
        }

        for character in text {
            let grapheme = String(character)
            let graphemeLength = grapheme.utf16.count
            if graphemeLength > maximumTextLength {
                flushCurrent()
                chunks.append(contentsOf: scalarChunks(of: grapheme))
            } else if currentLength + graphemeLength > maximumTextLength {
                flushCurrent()
                current = grapheme
                currentLength = graphemeLength
            } else {
                current.append(contentsOf: grapheme)
                currentLength += graphemeLength
            }
        }
        flushCurrent()
        return chunks
    }

    private func scalarChunks(of grapheme: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentLength = 0
        for scalar in grapheme.unicodeScalars {
            let fragment = String(scalar)
            let fragmentLength = fragment.utf16.count
            precondition(fragmentLength <= maximumTextLength)
            if currentLength + fragmentLength > maximumTextLength {
                chunks.append(current)
                current = fragment
                currentLength = fragmentLength
            } else {
                current.append(contentsOf: fragment)
                currentLength += fragmentLength
            }
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func encodedPayloadSize(_ blocks: [NotionBlockDraft]) -> Int {
        do {
            return try JSONEncoder().encode(
                NotionChildrenPayload(children: blocks)
            ).count
        } catch {
            preconditionFailure("Notion block payload encoding failed: \(error)")
        }
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

    private func sectionHeading(_ section: DetailedMinutesSection) -> String {
        var components = [section.title]
        if let timeRange = section.timeRange, !timeRange.isEmpty {
            components.append(timeRange)
        }
        if !section.speakers.isEmpty {
            components.append(section.speakers.joined(separator: "、"))
        }
        return components.joined(separator: "｜")
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

private struct NotionChildrenPayload: Encodable {
    let children: [NotionBlockDraft]
}
