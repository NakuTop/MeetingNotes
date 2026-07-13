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

    var keyPoints: [String] { Self.decode(keyPointsData) }
    var decisions: [String] { Self.decode(decisionsData) }
    var actionItems: [String] { Self.decode(actionItemsData) }
    var bookmarkInsights: [String] { Self.decode(bookmarkInsightsData) }

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

    private static func encode(_ value: [String]) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data("[]".utf8)
    }

    private static func decode(_ data: Data) -> [String] {
        (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
