import Foundation

struct NotionMeetingPageContent: Codable, Equatable, Sendable {
    let title: String
    let startedAt: Date
    let duration: TimeInterval
    let mode: MeetingMode
    let contentRevision: Int
    let summary: GeneratedMeetingSummary?
    let detailedMinutes: GeneratedDetailedMinutes?
    let bookmarks: [MeetingBookmarkInput]
    let transcripts: [MeetingTranscriptInput]
    let userNotes: [NotionTimelineNote]
    let screenshots: [NotionTimelineScreenshot]

    private enum CodingKeys: String, CodingKey {
        case title
        case startedAt
        case duration
        case mode
        case contentRevision
        case summary
        case detailedMinutes
        case bookmarks
        case transcripts
        case userNotes
        case screenshots
    }

    var documentKinds: [MeetingDocumentKind] {
        var result: [MeetingDocumentKind] = []
        if summary != nil { result.append(.summary) }
        if detailedMinutes != nil { result.append(.detailedMinutes) }
        return result
    }

    var kind: MeetingDocumentKind {
        summary != nil ? .summary : .detailedMinutes
    }

    init(
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        mode: MeetingMode,
        contentRevision: Int,
        summary: GeneratedMeetingSummary?,
        detailedMinutes: GeneratedDetailedMinutes?,
        bookmarks: [MeetingBookmarkInput],
        transcripts: [MeetingTranscriptInput],
        userNotes: [NotionTimelineNote] = [],
        screenshots: [NotionTimelineScreenshot] = []
    ) throws {
        guard summary != nil || detailedMinutes != nil else {
            throw NotionMeetingPageContentError.missingLocalDocument
        }
        self.title = title
        self.startedAt = startedAt
        self.duration = duration
        self.mode = mode
        self.contentRevision = max(0, contentRevision)
        self.summary = summary
        self.detailedMinutes = detailedMinutes
        self.bookmarks = bookmarks
        self.transcripts = transcripts
        self.userNotes = userNotes
        self.screenshots = screenshots
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            title: container.decode(String.self, forKey: .title),
            startedAt: container.decode(Date.self, forKey: .startedAt),
            duration: container.decode(TimeInterval.self, forKey: .duration),
            mode: container.decode(MeetingMode.self, forKey: .mode),
            contentRevision: container.decode(
                Int.self,
                forKey: .contentRevision
            ),
            summary: container.decodeIfPresent(
                GeneratedMeetingSummary.self,
                forKey: .summary
            ),
            detailedMinutes: container.decodeIfPresent(
                GeneratedDetailedMinutes.self,
                forKey: .detailedMinutes
            ),
            bookmarks: container.decode(
                [MeetingBookmarkInput].self,
                forKey: .bookmarks
            ),
            transcripts: container.decode(
                [MeetingTranscriptInput].self,
                forKey: .transcripts
            ),
            userNotes: container.decodeIfPresent(
                [NotionTimelineNote].self,
                forKey: .userNotes
            ) ?? [],
            screenshots: container.decodeIfPresent(
                [NotionTimelineScreenshot].self,
                forKey: .screenshots
            ) ?? []
        )
    }

    init(
        title: String,
        startedAt: Date,
        duration: TimeInterval,
        mode: MeetingMode,
        kind: MeetingDocumentKind,
        summary: GeneratedMeetingSummary?,
        detailedMinutes: GeneratedDetailedMinutes?,
        bookmarks: [MeetingBookmarkInput],
        transcripts: [MeetingTranscriptInput],
        userNotes: [NotionTimelineNote] = [],
        screenshots: [NotionTimelineScreenshot] = []
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
        try self.init(
            title: title,
            startedAt: startedAt,
            duration: duration,
            mode: mode,
            contentRevision: 0,
            summary: summary,
            detailedMinutes: detailedMinutes,
            bookmarks: bookmarks,
            transcripts: transcripts,
            userNotes: userNotes,
            screenshots: screenshots
        )
    }

    func replacingScreenshots(
        with screenshots: [NotionTimelineScreenshot]
    ) throws -> NotionMeetingPageContent {
        try NotionMeetingPageContent(
            title: title,
            startedAt: startedAt,
            duration: duration,
            mode: mode,
            contentRevision: contentRevision,
            summary: summary,
            detailedMinutes: detailedMinutes,
            bookmarks: bookmarks,
            transcripts: transcripts,
            userNotes: userNotes,
            screenshots: screenshots
        )
    }
}

struct NotionTimelineNote: Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: TimeInterval
    let text: String
    let sequenceIndex: Int

    init(
        id: UUID,
        timestamp: TimeInterval,
        text: String,
        sequenceIndex: Int
    ) {
        self.id = id
        self.timestamp = timestamp.isFinite ? max(0, timestamp) : 0
        self.text = text
        self.sequenceIndex = max(0, sequenceIndex)
    }
}

struct NotionTimelineScreenshot: Codable, Equatable, Sendable {
    let id: UUID
    let timestamp: TimeInterval
    let sequenceIndex: Int
    let fileUploadID: String?

    init(
        id: UUID,
        timestamp: TimeInterval,
        sequenceIndex: Int,
        fileUploadID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp.isFinite ? max(0, timestamp) : 0
        self.sequenceIndex = max(0, sequenceIndex)
        self.fileUploadID = fileUploadID
    }

    func uploaded(fileID: String) -> NotionTimelineScreenshot {
        NotionTimelineScreenshot(
            id: id,
            timestamp: timestamp,
            sequenceIndex: sequenceIndex,
            fileUploadID: fileID
        )
    }
}

enum NotionBlockKind: String, Codable, Equatable, Sendable {
    case heading2 = "heading_2"
    case paragraph
    case bulletedListItem = "bulleted_list_item"
    case image
}

struct NotionBlockDraft: Encodable, Equatable, Sendable {
    private let content: Content

    var kind: NotionBlockKind {
        switch content {
        case .text(let kind, _): kind
        case .image: .image
        }
    }

    var text: String {
        switch content {
        case .text(_, let text): text
        case .image: ""
        }
    }

    init(kind: NotionBlockKind, text: String) {
        if kind == .image {
            content = .image(fileUploadID: text)
        } else {
            content = .text(kind: kind, text: text)
        }
    }

    static func image(fileUploadID: String) -> NotionBlockDraft {
        NotionBlockDraft(
            content: .image(
                fileUploadID: fileUploadID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        )
    }

    private init(content: Content) {
        self.content = content
    }

    private enum Content: Equatable, Sendable {
        case text(kind: NotionBlockKind, text: String)
        case image(fileUploadID: String)
    }

    private enum CodingKeys: String, CodingKey {
        case object
        case type
        case heading2 = "heading_2"
        case paragraph
        case bulletedListItem = "bulleted_list_item"
        case image
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("block", forKey: .object)
        try container.encode(kind.rawValue, forKey: .type)
        switch content {
        case .text(let kind, let text):
            let payload = RichTextPayload(richText: [.plain(text)])
            switch kind {
            case .heading2:
                try container.encode(payload, forKey: .heading2)
            case .paragraph:
                try container.encode(payload, forKey: .paragraph)
            case .bulletedListItem:
                try container.encode(payload, forKey: .bulletedListItem)
            case .image:
                break
            }
        case .image(let fileUploadID):
            try container.encode(
                ImagePayload(
                    caption: [],
                    type: "file_upload",
                    fileUpload: .init(id: fileUploadID)
                ),
                forKey: .image
            )
        }
    }
}

private struct ImagePayload: Encodable {
    let caption: [NotionRichText]
    let type: String
    let fileUpload: FileUpload

    private enum CodingKeys: String, CodingKey {
        case caption
        case type
        case fileUpload = "file_upload"
    }

    struct FileUpload: Encodable {
        let id: String
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
        var result: [NotionBlockDraft] = []
        if let summary = content.summary {
            result.append(contentsOf: summaryBlocks(summary))
        }
        if let detailedMinutes = content.detailedMinutes {
            result.append(contentsOf: detailedMinutesBlocks(detailedMinutes))
        }
        result.append(contentsOf: sharedMeetingBlocks(for: content))
        return result
    }

    private func summaryBlocks(
        _ summary: GeneratedMeetingSummary
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

        return result
    }

    private func sharedMeetingBlocks(
        for content: NotionMeetingPageContent
    ) -> [NotionBlockDraft] {
        var result: [NotionBlockDraft] = []

        result.append(contentsOf: timelineBlocks(for: content))

        appendHeading("书签", to: &result)
        let bookmarkLines = content.bookmarks
            .sorted { $0.timestamp < $1.timestamp }
            .map { "[\(formatTime($0.timestamp))] \($0.excerpt)" }
        let insightLines = content.summary?.bookmarkInsights.map {
            "AI 解读：\($0)"
        } ?? []
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
                let speaker = transcript.speakerLabel.map { "\($0)：" } ?? ""
                return "[\(formatTime(transcript.startTime))-\(formatTime(transcript.endTime))] \(speaker)\(transcript.text)"
            }
        appendList(transcriptLines, emptyKind: .paragraph, to: &result)
        return result
    }

    private func timelineBlocks(
        for content: NotionMeetingPageContent
    ) -> [NotionBlockDraft] {
        var events = content.userNotes.compactMap {
            TimelineEvent.note($0)
        }
        events.append(contentsOf: content.screenshots.compactMap {
            guard let fileUploadID = $0.fileUploadID?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !fileUploadID.isEmpty else {
                return nil
            }
            return TimelineEvent.screenshot(
                $0.uploaded(fileID: fileUploadID)
            )
        })
        events.sort(by: TimelineEvent.comesBefore)
        guard !events.isEmpty else { return [] }

        var result: [NotionBlockDraft] = []
        appendHeading("会议时间轴", to: &result)
        for event in events {
            switch event {
            case .note(let note):
                append(
                    kind: .bulletedListItem,
                    text: "[\(formatTime(note.timestamp))] 笔记：\(note.text)",
                    to: &result
                )
            case .screenshot(let screenshot):
                append(
                    kind: .paragraph,
                    text: "[\(formatTime(screenshot.timestamp))] 截图",
                    to: &result
                )
                if let fileUploadID = screenshot.fileUploadID {
                    result.append(.image(fileUploadID: fileUploadID))
                }
            }
        }
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

private enum TimelineEvent {
    case note(NotionTimelineNote)
    case screenshot(NotionTimelineScreenshot)

    private var timestamp: TimeInterval {
        switch self {
        case .note(let note): note.timestamp
        case .screenshot(let screenshot): screenshot.timestamp
        }
    }

    private var sequenceIndex: Int {
        switch self {
        case .note(let note): note.sequenceIndex
        case .screenshot(let screenshot): screenshot.sequenceIndex
        }
    }

    private var kindRank: Int {
        switch self {
        case .note: 0
        case .screenshot: 1
        }
    }

    private var id: UUID {
        switch self {
        case .note(let note): note.id
        case .screenshot(let screenshot): screenshot.id
        }
    }

    static func comesBefore(_ lhs: TimelineEvent, _ rhs: TimelineEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.sequenceIndex != rhs.sequenceIndex {
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        if lhs.kindRank != rhs.kindRank {
            return lhs.kindRank < rhs.kindRank
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

private struct NotionChildrenPayload: Encodable {
    let children: [NotionBlockDraft]
}
