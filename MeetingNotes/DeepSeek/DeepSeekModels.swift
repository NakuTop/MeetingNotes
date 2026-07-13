import Foundation

struct ActionItem: Codable, Equatable, Sendable {
    let task: String
    let owner: String?
    let dueDate: String?
}

struct GeneratedMeetingSummary: Codable, Equatable, Sendable {
    let suggestedTitle: String
    let overview: String
    let keyPoints: [String]
    let decisions: [String]
    let actionItems: [ActionItem]
    let bookmarkInsights: [String]
}

struct MeetingTranscriptInput: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

struct MeetingBookmarkInput: Equatable, Sendable {
    let timestamp: TimeInterval
    let excerpt: String
}

struct MeetingSummaryInput: Equatable, Sendable {
    let title: String
    let transcripts: [MeetingTranscriptInput]
    let bookmarks: [MeetingBookmarkInput]
}

enum DeepSeekClientError: Error, Equatable, Sendable {
    case unauthorized
    case rateLimited
    case server(Int)
    case http(Int)
    case timeout
    case transport
    case truncated
    case contentFiltered
    case serviceUnavailable
    case unexpectedFinishReason(String)
    case invalidResponse
    case invalidSummaryJSON
}
