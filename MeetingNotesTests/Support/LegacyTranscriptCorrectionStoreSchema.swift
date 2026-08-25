import Foundation
import SwiftData

enum LegacyTranscriptCorrectionStoreSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version {
        Schema.Version(1, 0, 0)
    }

    static var models: [any PersistentModel.Type] {
        [
            MeetingRecord.self,
            TranscriptRecord.self,
            SpeakerNameRecord.self,
            BookmarkRecord.self,
            SummaryRecord.self,
            DetailedMinutesRecord.self,
            ArchiveCheckpointRecord.self
        ]
    }

    @Model
    final class MeetingRecord {
        @Attribute(.unique) var id: UUID
        var title: String
        var modeRawValue: String
        var stateRawValue: String
        var startedAt: Date
        var endedAt: Date?
        var activeDuration: TimeInterval
        var audioManifestPath: String?
        var createdAt: Date
        var updatedAt: Date
        var pinnedAt: Date?
        var suggestedTitle: String?
        var notionPageID: String?
        var notionPageURL: String?
        var lastErrorCode: String?
        var speakerDiarizationRequestedBacking: Bool?
        var speakerProcessingStateRawValue: String?
        var speakerProcessingErrorCode: String?

        @Relationship(deleteRule: .cascade, inverse: \TranscriptRecord.meeting)
        var transcripts: [TranscriptRecord] = []

        @Relationship(deleteRule: .cascade, inverse: \SpeakerNameRecord.meeting)
        var speakerNames: [SpeakerNameRecord] = []

        @Relationship(deleteRule: .cascade, inverse: \BookmarkRecord.meeting)
        var bookmarks: [BookmarkRecord] = []

        @Relationship(deleteRule: .cascade, inverse: \SummaryRecord.meeting)
        var summary: SummaryRecord?

        @Relationship(deleteRule: .cascade, inverse: \DetailedMinutesRecord.meeting)
        var detailedMinutes: DetailedMinutesRecord?

        @Relationship(deleteRule: .cascade, inverse: \ArchiveCheckpointRecord.meeting)
        var archiveCheckpoint: ArchiveCheckpointRecord?

        init(
            id: UUID,
            title: String,
            modeRawValue: String,
            stateRawValue: String,
            startedAt: Date,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.title = title
            self.modeRawValue = modeRawValue
            self.stateRawValue = stateRawValue
            self.startedAt = startedAt
            endedAt = nil
            activeDuration = 0
            audioManifestPath = nil
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            pinnedAt = nil
            suggestedTitle = nil
            notionPageID = nil
            notionPageURL = nil
            lastErrorCode = nil
            speakerDiarizationRequestedBacking = nil
            speakerProcessingStateRawValue = nil
            speakerProcessingErrorCode = nil
        }
    }

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

        init(
            id: UUID,
            startTime: TimeInterval,
            endTime: TimeInterval,
            text: String,
            isFinal: Bool,
            speakerID: String?,
            sourceRawValue: String?,
            sourceRevision: Int,
            sequenceIndex: Int?,
            meeting: MeetingRecord?
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

        init() {
            id = UUID()
            speakerID = ""
            displayName = ""
            evidenceStartTime = 0
            evidenceEndTime = 0
            createdAt = .distantPast
            updatedAt = .distantPast
            meeting = nil
        }
    }

    @Model
    final class BookmarkRecord {
        @Attribute(.unique) var id: UUID
        var timestamp: TimeInterval
        var createdAt: Date
        var meeting: MeetingRecord?

        init() {
            id = UUID()
            timestamp = 0
            createdAt = .distantPast
            meeting = nil
        }
    }

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
        var contentRevisionBacking: Int?
        var archiveStateRawValue: String?
        var archivedContentRevision: Int?
        var lastArchiveErrorCode: String?
        var meeting: MeetingRecord?

        init() {
            id = UUID()
            overview = ""
            keyPointsData = Data()
            decisionsData = Data()
            actionItemsData = Data()
            bookmarkInsightsData = Data()
            model = ""
            createdAt = .distantPast
            contentRevisionBacking = nil
            archiveStateRawValue = nil
            archivedContentRevision = nil
            lastArchiveErrorCode = nil
            meeting = nil
        }
    }

    @Model
    final class DetailedMinutesRecord {
        @Attribute(.unique) var id: UUID
        var overview: String
        var sectionsData: Data
        var decisionsData: Data
        var actionItemsData: Data
        var openQuestionsData: Data
        var model: String
        var promptVersion: Int
        var createdAt: Date
        var contentRevisionBacking: Int?
        var archiveStateRawValue: String?
        var archivedContentRevision: Int?
        var lastArchiveErrorCode: String?
        var meeting: MeetingRecord?

        init() {
            id = UUID()
            overview = ""
            sectionsData = Data()
            decisionsData = Data()
            actionItemsData = Data()
            openQuestionsData = Data()
            model = ""
            promptVersion = 0
            createdAt = .distantPast
            contentRevisionBacking = nil
            archiveStateRawValue = nil
            archivedContentRevision = nil
            lastArchiveErrorCode = nil
            meeting = nil
        }
    }

    @Model
    final class ArchiveCheckpointRecord {
        @Attribute(.unique) var id: UUID
        var notionPageID: String
        var nextSection: String
        var nextBatchIndex: Int
        var metadataBlockIDsData: Data?
        var summaryBlockIDsData: Data?
        var detailedMinutesBlockIDsData: Data?
        var pendingKindRawValue: String?
        var pendingNewBlockIDsData: Data?
        var pendingOldBlockIDsData: Data?
        var pendingNextBatchIndex: Int?
        var pendingContentRevision: Int?
        var pendingPhaseRawValue: String?
        var pendingRunsData: Data?
        var updatedAt: Date
        var meeting: MeetingRecord?

        init() {
            id = UUID()
            notionPageID = ""
            nextSection = ""
            nextBatchIndex = 0
            metadataBlockIDsData = nil
            summaryBlockIDsData = nil
            detailedMinutesBlockIDsData = nil
            pendingKindRawValue = nil
            pendingNewBlockIDsData = nil
            pendingOldBlockIDsData = nil
            pendingNextBatchIndex = nil
            pendingContentRevision = nil
            pendingPhaseRawValue = nil
            pendingRunsData = nil
            updatedAt = .distantPast
            meeting = nil
        }
    }
}
