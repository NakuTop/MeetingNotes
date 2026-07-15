import Foundation
import SwiftData

enum MeetingMode: String, Codable, CaseIterable, Equatable, Sendable {
    case offline
    case online
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

    @Relationship(deleteRule: .cascade, inverse: \TranscriptRecord.meeting)
    var transcripts: [TranscriptRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \BookmarkRecord.meeting)
    var bookmarks: [BookmarkRecord] = []

    @Relationship(deleteRule: .cascade, inverse: \SummaryRecord.meeting)
    var summary: SummaryRecord?

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
        lastErrorCode: String? = nil
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
    }
}
