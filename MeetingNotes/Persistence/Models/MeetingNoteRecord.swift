import Foundation
import SwiftData

@Model
final class MeetingNoteRecord {
    @Attribute(.unique) var id: UUID
    var timestamp: TimeInterval
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var sequenceIndex: Int
    var meeting: MeetingRecord?

    init(
        id: UUID = UUID(),
        timestamp: TimeInterval,
        text: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        sequenceIndex: Int,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sequenceIndex = sequenceIndex
        self.meeting = meeting
    }
}
