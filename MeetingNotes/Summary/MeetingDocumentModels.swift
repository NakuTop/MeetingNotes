import Foundation

enum MeetingDocumentKind: String, CaseIterable, Equatable, Sendable {
    case summary
    case detailedMinutes
}

enum NotionMeetingPageContentError: Error, Equatable, Sendable {
    case missingRequestedDocument(MeetingDocumentKind)
    case multipleDocuments
}

enum MeetingDocumentOperation: Equatable, Sendable {
    case idle
    case generating(MeetingDocumentKind)
    case archiving(MeetingDocumentKind)
}

struct MeetingDocumentArchiveSnapshot: Equatable, Sendable {
    let meetingID: UUID
    let kind: MeetingDocumentKind
    let archiveStateRawValue: String?
    let archivedContentRevision: Int?
    let lastArchiveErrorCode: String?
    let meetingState: RecordingState
    let meetingUpdatedAt: Date
}

enum MeetingDocumentArchiveState: String, Equatable, Sendable {
    case localOnly
    case archiving
    case archived
    case failed
}

enum MeetingDocumentRevisionError: Error, Equatable, Sendable {
    case overflow
}

enum MeetingDocumentRevision {
    static func next(after revision: Int) throws -> Int {
        let (nextRevision, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else {
            throw MeetingDocumentRevisionError.overflow
        }
        return nextRevision
    }
}

struct DetailedMinutesSection: Codable, Equatable, Sendable {
    let title: String
    let timeRange: String?
    let speakers: [String]
    let content: String
}

struct GeneratedDetailedMinutes: Codable, Equatable, Sendable {
    let overview: String
    let sections: [DetailedMinutesSection]
    let decisions: [String]
    let actionItems: [ActionItem]
    let openQuestions: [String]
}
