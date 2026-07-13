import Foundation
import SwiftData

@Model
final class TranscriptRecord {
    @Attribute(.unique) var id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String
    var isFinal: Bool
    var speakerID: String?
    var sourceRevision: Int
    var meeting: MeetingRecord?

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        isFinal: Bool,
        speakerID: String? = nil,
        sourceRevision: Int = 0,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isFinal = isFinal
        self.speakerID = speakerID
        self.sourceRevision = sourceRevision
        self.meeting = meeting
    }
}
