import Foundation
import SwiftData

@Model
final class SpeakerNameRecord {
    @Attribute(.unique) var id: UUID
    var speakerID: String
    var displayName: String
    var evidenceStartTime: TimeInterval
    var evidenceEndTime: TimeInterval
    var createdAt: Date
    var updatedAt: Date
    var meeting: MeetingRecord?

    init(
        id: UUID = UUID(),
        speakerID: String,
        displayName: String,
        evidenceStartTime: TimeInterval,
        evidenceEndTime: TimeInterval,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.speakerID = speakerID
        self.displayName = displayName
        self.evidenceStartTime = evidenceStartTime
        self.evidenceEndTime = evidenceEndTime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.meeting = meeting
    }
}
