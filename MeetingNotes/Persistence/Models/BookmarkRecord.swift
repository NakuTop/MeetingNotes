import Foundation
import SwiftData

@Model
final class BookmarkRecord {
    @Attribute(.unique) var id: UUID
    var timestamp: TimeInterval
    var createdAt: Date
    var meeting: MeetingRecord?

    init(
        id: UUID = UUID(),
        timestamp: TimeInterval,
        createdAt: Date = .now,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.createdAt = createdAt
        self.meeting = meeting
    }
}
