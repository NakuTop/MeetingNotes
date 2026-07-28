import Foundation
import SwiftData

enum MeetingRepositoryError: Error, Equatable, Sendable {
    case meetingNotFound(UUID)
}

@MainActor
final class MeetingRepository {
    private let container: ModelContainer
    private let context: ModelContext
    private let contextSaver: @MainActor (ModelContext) throws -> Void

    private static var schema: Schema {
        Schema([
            MeetingRecord.self,
            TranscriptRecord.self,
            BookmarkRecord.self,
            SummaryRecord.self,
            ArchiveCheckpointRecord.self
        ])
    }

    init(
        container: ModelContainer,
        contextSaver: @escaping @MainActor (ModelContext) throws -> Void = {
            try $0.save()
        }
    ) {
        self.container = container
        context = ModelContext(container)
        self.contextSaver = contextSaver
    }

    static func inMemory(
        contextSaver: @escaping @MainActor (ModelContext) throws -> Void = {
            try $0.save()
        }
    ) throws -> MeetingRepository {
        let schema = Self.schema
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true
        )
        let container = try ModelContainer(
            for: schema,
            configurations: [configuration]
        )
        return MeetingRepository(
            container: container,
            contextSaver: contextSaver
        )
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
        id: UUID = UUID(),
        mode: MeetingMode,
        startedAt: Date,
        title: String = MeetingRecord.defaultTitle,
        audioManifestPath: String? = nil,
        speakerDiarizationRequested: Bool = false
    ) throws -> UUID {
        let meeting = MeetingRecord(
            id: id,
            title: title,
            mode: mode,
            state: .preparing,
            startedAt: startedAt,
            audioManifestPath: audioManifestPath,
            createdAt: startedAt,
            updatedAt: startedAt,
            speakerDiarizationRequested: speakerDiarizationRequested
        )
        context.insert(meeting)
        try saveContext()
        return meeting.id
    }

    func meetings() throws -> [MeetingRecord] {
        try context.fetch(FetchDescriptor<MeetingRecord>()).sorted(
            by: Self.meetingComesBefore
        )
    }

    func meeting(id: UUID) throws -> MeetingRecord {
        try meeting(id: id, in: context)
    }

    func transcripts(meetingID: UUID) throws -> [TranscriptRecord] {
        try meeting(id: meetingID).transcripts.sorted(
            by: Self.transcriptComesBefore
        )
    }

    private func meeting(
        id: UUID,
        in modelContext: ModelContext
    ) throws -> MeetingRecord {
        var descriptor = FetchDescriptor<MeetingRecord>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1

        guard let meeting = try modelContext.fetch(descriptor).first else {
            throw MeetingRepositoryError.meetingNotFound(id)
        }
        return meeting
    }

    func setPinned(meetingID: UUID, pinnedAt: Date?) throws {
        let meeting = try meeting(id: meetingID)
        meeting.pinnedAt = pinnedAt
        meeting.updatedAt = .now
        try saveContext()
    }

    func updateTitle(meetingID: UUID, title: String) throws {
        let meeting = try meeting(id: meetingID)
        let previousTitle = meeting.title
        let previousUpdatedAt = meeting.updatedAt
        meeting.title = title
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.title = previousTitle
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
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
        try saveContext()
    }

    func replaceTranscripts(
        meetingID: UUID,
        drafts: [AttributedTranscriptDraft],
        sourceRevision: Int
    ) throws {
        let replacementContext = ModelContext(container)
        replacementContext.autosaveEnabled = false
        let meeting = try meeting(
            id: meetingID,
            in: replacementContext
        )
        let previousTranscripts = meeting.transcripts
        let replacements = drafts.enumerated().map { sequenceIndex, draft in
            TranscriptRecord(
                startTime: draft.transcript.startTime,
                endTime: draft.transcript.endTime,
                text: draft.transcript.text,
                isFinal: true,
                speakerID: draft.speakerID,
                sourceRawValue: draft.source.rawValue,
                sourceRevision: sourceRevision,
                sequenceIndex: sequenceIndex
            )
        }

        replacements.forEach(replacementContext.insert)
        meeting.transcripts = replacements
        meeting.updatedAt = .now
        previousTranscripts.forEach(replacementContext.delete)
        try contextSaver(replacementContext)
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
        try saveContext()
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
        try saveContext()
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
        try saveContext()
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
        try saveContext()
    }

    func updateMeetingState(id: UUID, state: RecordingState) throws {
        let meeting = try meeting(id: id)
        meeting.state = state
        meeting.updatedAt = .now
        try saveContext()
    }

    func markSpeakerProcessingStarted(meetingID: UUID) throws {
        let meeting = try meeting(id: meetingID)
        guard meeting.speakerDiarizationRequested,
              meeting.speakerProcessingState == .pending else {
            return
        }
        let previousStateRawValue =
            meeting.speakerProcessingStateRawValue
        let previousErrorCode = meeting.speakerProcessingErrorCode
        let previousUpdatedAt = meeting.updatedAt
        meeting.speakerProcessingState = .processing
        meeting.speakerProcessingErrorCode = nil
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.speakerProcessingStateRawValue =
                previousStateRawValue
            meeting.speakerProcessingErrorCode = previousErrorCode
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
    }

    func finalizeMeeting(
        id: UUID,
        endedAt: Date,
        activeDuration: TimeInterval,
        sourceDegradationErrorCode: String? = nil
    ) throws {
        let meeting = try meeting(id: id)
        let previousStateRawValue = meeting.stateRawValue
        let previousEndedAt = meeting.endedAt
        let previousActiveDuration = meeting.activeDuration
        let previousUpdatedAt = meeting.updatedAt
        let previousSpeakerProcessingStateRawValue =
            meeting.speakerProcessingStateRawValue
        let previousSpeakerProcessingErrorCode =
            meeting.speakerProcessingErrorCode
        meeting.state = .ready
        meeting.endedAt = endedAt
        meeting.activeDuration = activeDuration
        meeting.updatedAt = endedAt
        if let sourceDegradationErrorCode {
            meeting.speakerProcessingState = .degraded
            meeting.speakerProcessingErrorCode =
                sourceDegradationErrorCode
        } else if meeting.speakerProcessingState != .degraded,
                  meeting.speakerDiarizationRequested {
            meeting.speakerProcessingState = .completed
            meeting.speakerProcessingErrorCode = nil
        }
        do {
            try saveContext()
        } catch {
            meeting.stateRawValue = previousStateRawValue
            meeting.endedAt = previousEndedAt
            meeting.activeDuration = previousActiveDuration
            meeting.updatedAt = previousUpdatedAt
            meeting.speakerProcessingStateRawValue =
                previousSpeakerProcessingStateRawValue
            meeting.speakerProcessingErrorCode =
                previousSpeakerProcessingErrorCode
            throw error
        }
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
        try saveContext()
    }

    func deleteMeeting(id: UUID) throws {
        let meeting = try meeting(id: id)
        context.delete(meeting)
        try saveContext()
    }

    func count<Model: PersistentModel>(_ model: Model.Type) throws -> Int {
        _ = model
        return try context.fetchCount(FetchDescriptor<Model>())
    }

    private func saveContext() throws {
        try contextSaver(context)
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

    private static func transcriptComesBefore(
        _ lhs: TranscriptRecord,
        _ rhs: TranscriptRecord
    ) -> Bool {
        if lhs.startTime != rhs.startTime {
            return lhs.startTime < rhs.startTime
        }
        switch (lhs.sequenceIndex, rhs.sequenceIndex) {
        case let (lhsSequence?, rhsSequence?)
            where lhsSequence != rhsSequence:
            return lhsSequence < rhsSequence
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            break
        }
        if lhs.endTime != rhs.endTime {
            return lhs.endTime < rhs.endTime
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
