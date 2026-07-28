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
    var sourceRawValue: String?
    var sourceRevision: Int
    var sequenceIndex: Int?
    var meeting: MeetingRecord?

    var source: TranscriptAudioSource {
        get {
            sourceRawValue.flatMap(TranscriptAudioSource.init)
                ?? .mixed
        }
        set {
            sourceRawValue = newValue.rawValue
        }
    }

    init(
        id: UUID = UUID(),
        startTime: TimeInterval,
        endTime: TimeInterval,
        text: String,
        isFinal: Bool,
        speakerID: String? = nil,
        sourceRawValue: String? = nil,
        sourceRevision: Int = 0,
        sequenceIndex: Int? = nil,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.isFinal = isFinal
        self.speakerID = speakerID
        self.sourceRawValue = sourceRawValue
        self.sourceRevision = sourceRevision
        self.sequenceIndex = sequenceIndex
        self.meeting = meeting
    }
}
