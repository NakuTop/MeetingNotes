import Foundation
import SwiftData

@Model
final class TranscriptCorrectionRecord {
    @Attribute(.unique) var id: UUID
    var anchorStartTime: TimeInterval
    var anchorEndTime: TimeInterval
    var sourceRawValue: String
    var originalText: String
    var replacementText: String
    var transcriptIDsData: Data
    var createdAt: Date
    var updatedAt: Date
    var meeting: MeetingRecord?

    var source: TranscriptAudioSource {
        get { TranscriptAudioSource(rawValue: sourceRawValue) ?? .mixed }
        set { sourceRawValue = newValue.rawValue }
    }

    var transcriptIDs: [UUID] {
        get {
            (try? JSONDecoder().decode([UUID].self, from: transcriptIDsData))
                ?? []
        }
        set {
            transcriptIDsData = Self.encodeTranscriptIDs(newValue)
        }
    }

    init(
        id: UUID = UUID(),
        anchorStartTime: TimeInterval,
        anchorEndTime: TimeInterval,
        source: TranscriptAudioSource,
        originalText: String,
        replacementText: String,
        transcriptIDs: [UUID],
        createdAt: Date = .now,
        updatedAt: Date = .now,
        meeting: MeetingRecord? = nil
    ) {
        self.id = id
        self.anchorStartTime = anchorStartTime
        self.anchorEndTime = anchorEndTime
        sourceRawValue = source.rawValue
        self.originalText = originalText
        self.replacementText = replacementText
        transcriptIDsData = Self.encodeTranscriptIDs(transcriptIDs)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.meeting = meeting
    }

    private static func encodeTranscriptIDs(_ transcriptIDs: [UUID]) -> Data {
        (try? JSONEncoder().encode(transcriptIDs)) ?? Data("[]".utf8)
    }
}
