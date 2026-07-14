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
    ) {
        self.overview = overview
        keyPointsData = Self.encode(keyPoints)
        decisionsData = Self.encode(decisions)
        actionItemsData = Self.encode(actionItems)
        bookmarkInsightsData = Self.encode(bookmarkInsights)
        self.model = model
        self.createdAt = createdAt
    }

    func update(
        overview: String,
        keyPoints: [String],
        decisions: [String],
        actionItems: [ActionItem],
        bookmarkInsights: [String],
        model: String,
        createdAt: Date
    ) {
        self.overview = overview
        keyPointsData = Self.encode(keyPoints)
        decisionsData = Self.encode(decisions)
        actionItemsData = Self.encode(actionItems)
        bookmarkInsightsData = Self.encode(bookmarkInsights)
        self.model = model
        self.createdAt = createdAt
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
