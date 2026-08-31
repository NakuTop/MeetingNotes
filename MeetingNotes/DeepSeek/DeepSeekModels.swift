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

struct MeetingUserNoteInput: Codable, Equatable, Sendable {
    let timestamp: TimeInterval
    let text: String
}

struct MeetingSummaryInput: Equatable, Sendable {
    let title: String
    let transcripts: [MeetingTranscriptInput]
    let bookmarks: [MeetingBookmarkInput]
    let userNotes: [MeetingUserNoteInput]

    init(
        title: String,
        transcripts: [MeetingTranscriptInput],
        bookmarks: [MeetingBookmarkInput],
        userNotes: [MeetingUserNoteInput] = []
    ) {
        self.title = title
        self.transcripts = transcripts
        self.bookmarks = bookmarks
        self.userNotes = userNotes
    }
}

enum MeetingUserNoteInputPolicy {
    static func ordered(
        _ notes: [MeetingUserNoteInput]
    ) -> [MeetingUserNoteInput] {
        notes.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp == rhs.element.timestamp {
                return lhs.offset < rhs.offset
            }
            return lhs.element.timestamp < rhs.element.timestamp
        }.map(\.element)
    }

    static func partition(
        _ notes: [MeetingUserNoteInput],
        across transcriptChunks: [[MeetingTranscriptInput]]
    ) -> [[MeetingUserNoteInput]] {
        var result = Array(
            repeating: [MeetingUserNoteInput](),
            count: transcriptChunks.count
        )
        let ranges = transcriptChunks.map { chunk -> ClosedRange<TimeInterval>? in
            guard let lower = chunk.map(\.startTime).min(),
                  let upper = chunk.map(\.endTime).max() else {
                return nil
            }
            return min(lower, upper)...max(lower, upper)
        }
        for note in ordered(notes) {
            guard let index = ranges.firstIndex(where: {
                $0?.contains(note.timestamp) == true
            }) else {
                continue
            }
            result[index].append(note)
        }
        return result
    }
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
