import Foundation
import SwiftData

enum MeetingRepositoryError: Error, Equatable, Sendable {
    case meetingNotFound(UUID)
}

@MainActor
final class MeetingRepository {
    private let container: ModelContainer
    private let context: ModelContext

    private static var schema: Schema {
        Schema([
            MeetingRecord.self,
            TranscriptRecord.self,
            BookmarkRecord.self,
            SummaryRecord.self,
            ArchiveCheckpointRecord.self
        ])
    }

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
    }

    static func inMemory() throws -> MeetingRepository {
        let schema = Self.schema
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        return MeetingRepository(container: container)
    }

    static func persistent() throws -> MeetingRepository {
        let schema = Self.schema
        let configuration = ModelConfiguration(schema: schema)
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        return MeetingRepository(container: container)
    }

    @discardableResult
    func createMeeting(
        mode: MeetingMode,
        startedAt: Date,
        title: String = MeetingRecord.defaultTitle,
        audioManifestPath: String? = nil
    ) throws -> UUID {
        let meeting = MeetingRecord(
            title: title,
            mode: mode,
            state: .preparing,
            startedAt: startedAt,
            audioManifestPath: audioManifestPath,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        context.insert(meeting)
        try context.save()
        return meeting.id
    }

    func meetings() throws -> [MeetingRecord] {
        try context.fetch(FetchDescriptor<MeetingRecord>()).sorted(
            by: Self.meetingComesBefore
        )
    }

    func meeting(id: UUID) throws -> MeetingRecord {
        var descriptor = FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        guard let meeting = try context.fetch(descriptor).first else {
            throw MeetingRepositoryError.meetingNotFound(id)
        }
        return meeting
    }

    func setPinned(meetingID: UUID, pinnedAt: Date?) throws {
        let meeting = try meeting(id: meetingID)
        meeting.pinnedAt = pinnedAt
        meeting.updatedAt = .now
        try context.save()
    }

    func appendTranscript(
        meetingID: UUID,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        isFinal: Bool = true,
        speakerID: String? = nil,
        sourceRevision: Int = 0
    ) throws {
        let meeting = try meeting(id: meetingID)
        let transcript = TranscriptRecord(
            startTime: start,
            endTime: end,
            text: text,
            isFinal: isFinal,
            speakerID: speakerID,
            sourceRevision: sourceRevision,
            meeting: meeting
        )
        context.insert(transcript)
        meeting.updatedAt = .now
        try context.save()
    }

    func appendBookmark(
        meetingID: UUID,
        timestamp: TimeInterval,
        createdAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        let bookmark = BookmarkRecord(
            timestamp: timestamp,
            createdAt: createdAt,
            meeting: meeting
        )
        context.insert(bookmark)
        meeting.updatedAt = .now
        try context.save()
    }

    func saveSummary(
        meetingID: UUID,
        overview: String,
        keyPoints: [String],
        decisions: [String],
        actionItems: [String],
        bookmarkInsights: [String],
        model: String,
        createdAt: Date = .now
    ) throws {
        try saveSummary(
            meetingID: meetingID,
            overview: overview,
            keyPoints: keyPoints,
            decisions: decisions,
            structuredActionItems: actionItems.map {
                ActionItem(task: $0, owner: nil, dueDate: nil)
            },
            bookmarkInsights: bookmarkInsights,
            model: model,
            createdAt: createdAt
        )
    }

    func saveSummary(
        meetingID: UUID,
        overview: String,
        keyPoints: [String],
        decisions: [String],
        structuredActionItems: [ActionItem],
        bookmarkInsights: [String],
        model: String,
        createdAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)

        if let summary = meeting.summary {
            summary.update(
                overview: overview,
                keyPoints: keyPoints,
                decisions: decisions,
                actionItems: structuredActionItems,
                bookmarkInsights: bookmarkInsights,
                model: model,
                createdAt: createdAt
            )
        } else {
            let summary = SummaryRecord(
                overview: overview,
                keyPoints: keyPoints,
                decisions: decisions,
                actionItems: structuredActionItems,
                bookmarkInsights: bookmarkInsights,
                model: model,
                createdAt: createdAt,
                meeting: meeting
            )
            context.insert(summary)
            meeting.summary = summary
        }

        meeting.updatedAt = .now
        try context.save()
    }

    func applySuggestedTitle(
        meetingID: UUID,
        suggestedTitle: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        let trimmed = suggestedTitle.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return }
        meeting.suggestedTitle = trimmed
        if meeting.title == MeetingRecord.defaultTitle {
            meeting.title = trimmed
        }
        meeting.updatedAt = .now
        try context.save()
    }

    func setNotionPage(
        meetingID: UUID,
        pageID: String,
        pageURL: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        meeting.notionPageID = pageID
        meeting.notionPageURL = pageURL
        meeting.updatedAt = .now
        try context.save()
    }

    func updateMeetingState(id: UUID, state: RecordingState) throws {
        let meeting = try meeting(id: id)
        meeting.state = state
        meeting.updatedAt = .now
        try context.save()
    }

    func finalizeMeeting(
        id: UUID,
        endedAt: Date,
        activeDuration: TimeInterval
    ) throws {
        let meeting = try meeting(id: id)
        meeting.state = .ready
        meeting.endedAt = endedAt
        meeting.activeDuration = activeDuration
        meeting.updatedAt = endedAt
        try context.save()
    }

    func saveArchiveCheckpoint(
        meetingID: UUID,
        notionPageID: String,
        nextSection: String,
        nextBatchIndex: Int,
        updatedAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)

        if let checkpoint = meeting.archiveCheckpoint {
            checkpoint.notionPageID = notionPageID
            checkpoint.nextSection = nextSection
            checkpoint.nextBatchIndex = nextBatchIndex
            checkpoint.updatedAt = updatedAt
        } else {
            let checkpoint = ArchiveCheckpointRecord(
                notionPageID: notionPageID,
                nextSection: nextSection,
                nextBatchIndex: nextBatchIndex,
                updatedAt: updatedAt,
                meeting: meeting
            )
            context.insert(checkpoint)
            meeting.archiveCheckpoint = checkpoint
        }

        meeting.updatedAt = .now
        try context.save()
    }

    func deleteMeeting(id: UUID) throws {
        let meeting = try meeting(id: id)
        context.delete(meeting)
        try context.save()
    }

    func count<Model: PersistentModel>(_ model: Model.Type) throws -> Int {
        _ = model
        return try context.fetchCount(FetchDescriptor<Model>())
    }

    private static func meetingComesBefore(
        _ lhs: MeetingRecord,
        _ rhs: MeetingRecord
    ) -> Bool {
        switch (lhs.pinnedAt, rhs.pinnedAt) {
        case let (lhsPinnedAt?, rhsPinnedAt?) where lhsPinnedAt != rhsPinnedAt:
            return lhsPinnedAt > rhsPinnedAt
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }

        if lhs.startedAt != rhs.startedAt {
            return lhs.startedAt > rhs.startedAt
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt > rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
