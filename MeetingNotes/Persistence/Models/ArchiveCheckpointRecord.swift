import Foundation
import SwiftData

@Model
final class ArchiveCheckpointRecord {
    @Attribute(.unique) var id: UUID
    var notionPageID: String
    var nextSection: String
    var nextBatchIndex: Int
    var updatedAt: Date
    var meeting: MeetingRecord?

    init(
        id: UUID = UUID(),
        notionPageID: String,
        nextSection: String,
        nextBatchIndex: Int,
        updatedAt: Date = .now,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.notionPageID = notionPageID
        self.nextSection = nextSection
        self.nextBatchIndex = nextBatchIndex
        self.updatedAt = updatedAt
        self.meeting = meeting
    }
}
