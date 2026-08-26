import Foundation
import SwiftData

@Model
final class SummaryRecord {
    @Attribute(.unique) var id: UUID
    var overview: String
    var keyPointsData: Data
    var decisionsData: Data
    var actionItemsData: Data
    var bookmarkInsightsData: Data
    var model: String
    var createdAt: Date
    var contentRevisionBacking: Int?
    var archiveStateRawValue: String?
    var archivedContentRevision: Int?
    var lastArchiveErrorCode: String?
    var isManuallyEditedBacking: Bool?
    var meeting: MeetingRecord?

    var keyPoints: [String] { Self.decodeStrings(keyPointsData) }
    var decisions: [String] { Self.decodeStrings(decisionsData) }
    var actionItemRecords: [ActionItem] {
        if let records = Self.decode([ActionItem].self, from: actionItemsData) {
            return records
        }
        return Self.decodeStrings(actionItemsData).map {
            ActionItem(task: $0, owner: nil, dueDate: nil)
        }
    }
    var actionItems: [String] { actionItemRecords.map(\.task) }
    var bookmarkInsights: [String] { Self.decodeStrings(bookmarkInsightsData) }

    var contentRevision: Int {
        get { max(0, contentRevisionBacking ?? 0) }
        set { contentRevisionBacking = max(0, newValue) }
    }

    var archiveState: MeetingDocumentArchiveState {
        get {
            archiveStateRawValue
                .flatMap(MeetingDocumentArchiveState.init(rawValue:))
                ?? .localOnly
        }
        set { archiveStateRawValue = newValue.rawValue }
    }

    var isManuallyEdited: Bool {
        get { isManuallyEditedBacking ?? false }
        set { isManuallyEditedBacking = newValue }
    }

    init(
        id: UUID = UUID(),
        overview: String,
        keyPoints: [String],
        decisions: [String],
        actionItems: [String],
        bookmarkInsights: [String],
        model: String,
        createdAt: Date = .now,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.overview = overview
        keyPointsData = Self.encode(keyPoints)
        decisionsData = Self.encode(decisions)
        actionItemsData = Self.encode(actionItems)
        bookmarkInsightsData = Self.encode(bookmarkInsights)
        self.model = model
        self.createdAt = createdAt
        contentRevisionBacking = 1
        archiveStateRawValue = MeetingDocumentArchiveState.localOnly.rawValue
        archivedContentRevision = nil
        lastArchiveErrorCode = nil
        isManuallyEditedBacking = false
        self.meeting = meeting
    }

    init(
        id: UUID = UUID(),
        overview: String,
        keyPoints: [String],
        decisions: [String],
        actionItems: [ActionItem],
        bookmarkInsights: [String],
        model: String,
        createdAt: Date = .now,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.overview = overview
        keyPointsData = Self.encode(keyPoints)
        decisionsData = Self.encode(decisions)
        actionItemsData = Self.encode(actionItems)
        bookmarkInsightsData = Self.encode(bookmarkInsights)
        self.model = model
        self.createdAt = createdAt
        contentRevisionBacking = 1
        archiveStateRawValue = MeetingDocumentArchiveState.localOnly.rawValue
        archivedContentRevision = nil
        lastArchiveErrorCode = nil
        isManuallyEditedBacking = false
        self.meeting = meeting
    }

    func update(
        overview: String,
        keyPoints: [String],
        decisions: [String],
        actionItems: [String],
        bookmarkInsights: [String],
        model: String,
        createdAt: Date
    ) throws {
        let nextRevision = try MeetingDocumentRevision.next(
            after: contentRevision
        )
        self.overview = overview
        keyPointsData = Self.encode(keyPoints)
        decisionsData = Self.encode(decisions)
        actionItemsData = Self.encode(actionItems)
        bookmarkInsightsData = Self.encode(bookmarkInsights)
        self.model = model
        self.createdAt = createdAt
        markRegenerated(contentRevision: nextRevision)
    }

    func update(
        overview: String,
        keyPoints: [String],
        decisions: [String],
        actionItems: [ActionItem],
        bookmarkInsights: [String],
        model: String,
        createdAt: Date
    ) throws {
        let nextRevision = try MeetingDocumentRevision.next(
            after: contentRevision
        )
        self.overview = overview
        keyPointsData = Self.encode(keyPoints)
        decisionsData = Self.encode(decisions)
        actionItemsData = Self.encode(actionItems)
        bookmarkInsightsData = Self.encode(bookmarkInsights)
        self.model = model
        self.createdAt = createdAt
        markRegenerated(contentRevision: nextRevision)
    }

    private func markRegenerated(contentRevision: Int) {
        self.contentRevision = contentRevision
        isManuallyEdited = false
        archiveState = .localOnly
        archivedContentRevision = nil
        lastArchiveErrorCode = nil
    }

    private static func encode<Value: Encodable>(_ value: Value) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("[]".utf8)
    }

    private static func decodeStrings(_ data: Data) -> [String] {
        decode([String].self, from: data) ?? []
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) -> Value? {
        try? JSONDecoder().decode(type, from: data)
    }
}
