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

struct MeetingTranscriptInput: Codable, Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let speakerLabel: String?

    init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        speakerLabel: String? = nil
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speakerLabel = speakerLabel
    }
}

struct MeetingBookmarkInput: Codable, Equatable, Sendable {
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
    case invalidDetailedMinutesJSON
    case inputTooLarge
    case invalidDiagnosticJSON
    case invalidDiagnosticExplanation
}

enum AudioDiagnosticExplanationSource: Sendable, Equatable {
    case deepSeek
    case localFallback
}

struct AudioDiagnosticExplanation: Sendable, Equatable {
    let issue: String
    let solution: String
    let source: AudioDiagnosticExplanationSource
}
