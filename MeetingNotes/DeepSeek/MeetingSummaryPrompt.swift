import Foundation

enum MeetingSummaryPrompt {
    static let systemMessage = """
    你是严谨的会议记录助手。只输出 JSON 对象，不得输出 Markdown 或额外解释。
    JSON 必须严格包含以下字段：
    {
      "suggestedTitle": "string",
      "overview": "string",
      "keyPoints": ["string"],
      "decisions": ["string"],
      "actionItems": [{"task": "string", "owner": "string|null", "dueDate": "string|null"}],
      "bookmarkInsights": ["string"]
    }
    仅根据输入内容总结，不得捏造决定、负责人或日期。负责人或日期未明确时，owner 或 dueDate 必须为 null。
    """

    static func userMessage(for input: MeetingSummaryInput) -> String {
        let bookmarkText = input.bookmarks.isEmpty
            ? "无"
            : input.bookmarks.map {
                "[\(format($0.timestamp))] \($0.excerpt)"
            }.joined(separator: "\n")
        let transcriptText = input.transcripts.isEmpty
            ? "无"
            : input.transcripts.map {
                "[\(format($0.startTime))-\(format($0.endTime))] \($0.text)"
            }.joined(separator: "\n")

        return """
        会议标题：\(input.title)

        书签摘录：
        \(bookmarkText)

        完整转录：
        \(transcriptText)
        """
    }

    static func aggregationMessage(
        partialSummaries: [GeneratedMeetingSummary],
        title: String,
        bookmarks: [MeetingBookmarkInput]
    ) throws -> String {
        let data = try JSONEncoder().encode(partialSummaries)
        guard let partialJSON = String(data: data, encoding: .utf8) else {
            throw DeepSeekClientError.invalidResponse
        }
        let bookmarkText = bookmarks.isEmpty
            ? "无"
            : bookmarks.map {
                "[\(format($0.timestamp))] \($0.excerpt)"
            }.joined(separator: "\n")

        return """
        会议标题：\(title)

        以下是按时间顺序生成的局部摘要。请去重合并，仍严格输出系统消息指定的 JSON 对象：
        \(partialJSON)

        全局书签摘录：
        \(bookmarkText)
        """
    }

    private static func format(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", seconds)
    }
}

struct SummaryInputChunker: Equatable, Sendable {
    let characterBudget: Int

    init(characterBudget: Int = 80_000) {
        self.characterBudget = max(1, characterBudget)
    }

    func chunks(
        _ segments: [MeetingTranscriptInput]
    ) -> [[MeetingTranscriptInput]] {
        var result: [[MeetingTranscriptInput]] = []
        var current: [MeetingTranscriptInput] = []
        var currentCount = 0

        for segment in segments {
            let segmentCount = segment.text.count
            if !current.isEmpty,
               currentCount + segmentCount > characterBudget {
                result.append(current)
                current = []
                currentCount = 0
            }
            current.append(segment)
            currentCount += segmentCount
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}
