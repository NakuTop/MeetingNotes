import Foundation
import SwiftData

enum MeetingMode: String, Codable, CaseIterable, Equatable, Sendable {
    case offline
    case online
}

enum SpeakerProcessingState: String, Codable, Equatable, Sendable {
    case notRequested
    case pending
    case processing
    case completed
    case degraded
}

@Model
final class MeetingRecord {
    static let defaultTitle = "未命名会议"

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
    var contentRevisionBacking: Int?
    var notionSyncedContentRevision: Int?
    var notionSyncStateRawValue: String?
    var notionSyncErrorCode: String?
    var speakerDiarizationRequestedBacking: Bool?
    var speakerProcessingStateRawValue: String?
    var speakerProcessingErrorCode: String?

    @Relationship(deleteRule: .cascade, inverse: \TranscriptRecord.meeting)
    var transcripts: [TranscriptRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \TranscriptCorrectionRecord.meeting)
    var transcriptCorrections: [TranscriptCorrectionRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \SpeakerNameRecord.meeting)
    var speakerNames: [SpeakerNameRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \BookmarkRecord.meeting)
    var bookmarks: [BookmarkRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \MeetingNoteRecord.meeting)
    var notes: [MeetingNoteRecord] = []

    @Relationship(
        deleteRule: .cascade,
        inverse: \MeetingScreenshotRecord.meeting
    )
    var screenshots: [MeetingScreenshotRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \SummaryRecord.meeting)
    var summary: SummaryRecord?

    @Relationship(deleteRule: .cascade, inverse: \DetailedMinutesRecord.meeting)
    var detailedMinutes: DetailedMinutesRecord?

    @Relationship(deleteRule: .cascade, inverse: \ArchiveCheckpointRecord.meeting)
    var archiveCheckpoint: ArchiveCheckpointRecord?

    var mode: MeetingMode {
        get { MeetingMode(rawValue: modeRawValue) ?? .offline }
        set { modeRawValue = newValue.rawValue }
    }

    var state: RecordingState {
        get { RecordingState(rawValue: stateRawValue) ?? .idle }
        set { stateRawValue = newValue.rawValue }
    }

    var isPinned: Bool {
        pinnedAt != nil
    }

    var contentRevision: Int {
        get { max(0, contentRevisionBacking ?? 0) }
        set { contentRevisionBacking = max(0, newValue) }
    }

    var notionSyncState: MeetingNotionSyncState {
        get {
            notionSyncStateRawValue
                .flatMap(MeetingNotionSyncState.init(rawValue:))
                ?? .localOnly
        }
        set { notionSyncStateRawValue = newValue.rawValue }
    }

    var speakerDiarizationRequested: Bool {
        get { speakerDiarizationRequestedBacking ?? false }
        set { speakerDiarizationRequestedBacking = newValue }
    }

    var speakerProcessingState: SpeakerProcessingState {
        get {
            speakerProcessingStateRawValue.flatMap(SpeakerProcessingState.init)
                ?? .notRequested
        }
        set {
            speakerProcessingStateRawValue = newValue.rawValue
        }
    }

    var speakerDisplayNames: [String: String] {
        speakerNames
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt < $1.updatedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
            .reduce(into: [:]) { result, record in
                result[record.speakerID] = record.displayName
            }
    }

    init(
        id: UUID = UUID(),
        title: String,
        mode: MeetingMode,
        state: RecordingState,
        startedAt: Date,
        endedAt: Date? = nil,
        activeDuration: TimeInterval = 0,
        audioManifestPath: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        pinnedAt: Date? = nil,
        suggestedTitle: String? = nil,
        notionPageID: String? = nil,
        notionPageURL: String? = nil,
        lastErrorCode: String? = nil,
        speakerDiarizationRequested: Bool = false,
        speakerProcessingState: SpeakerProcessingState? = nil,
        speakerProcessingErrorCode: String? = nil
    ) {
        self.id = id
        self.title = title
        modeRawValue = mode.rawValue
        stateRawValue = state.rawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.activeDuration = activeDuration
        self.audioManifestPath = audioManifestPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.pinnedAt = pinnedAt
        self.suggestedTitle = suggestedTitle
        self.notionPageID = notionPageID
        self.notionPageURL = notionPageURL
        self.lastErrorCode = lastErrorCode
        contentRevisionBacking = 0
        notionSyncedContentRevision = nil
        notionSyncStateRawValue = MeetingNotionSyncState.localOnly.rawValue
        notionSyncErrorCode = nil
        self.speakerDiarizationRequested = speakerDiarizationRequested
        self.speakerProcessingState = speakerProcessingState
            ?? (speakerDiarizationRequested ? .pending : .notRequested)
        self.speakerProcessingErrorCode = speakerProcessingErrorCode
    }
}
