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
    var wordTimingsData: Data?
    var attributionStatusRawValue: String?
    var speakerSourceEvidenceRawValue: String?
    var meeting: MeetingRecord?

    var words: [TranscriptWordTiming] {
        get { wordTimingsData.flatMap { try? JSONDecoder().decode([TranscriptWordTiming].self, from: $0) } ?? [] }
        set { wordTimingsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue) }
    }

    var attributionStatus: SpeakerAttributionStatus? {
        get { attributionStatusRawValue.flatMap(SpeakerAttributionStatus.init(rawValue:)) }
        set { attributionStatusRawValue = newValue?.rawValue }
    }

    var sourceEvidence: SpeakerSourceEvidence? {
        get { speakerSourceEvidenceRawValue.flatMap(SpeakerSourceEvidence.init(rawValue:)) }
        set { speakerSourceEvidenceRawValue = newValue?.rawValue }
    }

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
        words: [TranscriptWordTiming] = [],
        attributionStatus: SpeakerAttributionStatus? = nil,
        sourceEvidence: SpeakerSourceEvidence? = nil,
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
        wordTimingsData = words.isEmpty ? nil : try? JSONEncoder().encode(words)
        attributionStatusRawValue = attributionStatus?.rawValue
        speakerSourceEvidenceRawValue = sourceEvidence?.rawValue
        self.meeting = meeting
    }
}
