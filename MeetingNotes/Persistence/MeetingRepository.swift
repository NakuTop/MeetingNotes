import Foundation
import SwiftData

enum MeetingRepositoryError: Error, Equatable, Sendable {
    case meetingNotFound(UUID)
    case invalidState(SpeakerProcessingState)
}

enum MeetingDocumentRepositoryError: Error, Equatable, Sendable {
    case missingDocument(MeetingDocumentKind)
    case missingArchiveCheckpoint
    case invalidMetadataArchiveCheckpoint
    case invalidArchiveRun(MeetingDocumentKind)
    case staleDocumentRevision(
        MeetingDocumentKind,
        expected: Int,
        actual: Int
    )
}

enum SpeakerNameRepositoryError: Error, Equatable, Sendable {
    case invalidDisplayName
    case speakerNotFound(String)
}

@MainActor
final class MeetingRepository {
    private let container: ModelContainer
    private let context: ModelContext
    private let contextSaver: @MainActor (ModelContext) throws -> Void
    private let detailedMinutesEncoder:
        (GeneratedDetailedMinutes) throws -> EncodedDetailedMinutes

    private static var schema: Schema {
        Schema([
            MeetingRecord.self,
            TranscriptRecord.self,
            SpeakerNameRecord.self,
            BookmarkRecord.self,
            SummaryRecord.self,
            DetailedMinutesRecord.self,
            ArchiveCheckpointRecord.self
        ])
    }

    init(
        container: ModelContainer,
        contextSaver: @escaping @MainActor (ModelContext) throws -> Void = {
            try $0.save()
        },
        detailedMinutesEncoder: @escaping
            (GeneratedDetailedMinutes) throws -> EncodedDetailedMinutes = {
                try DetailedMinutesRecord.encode($0)
            }
    ) {
        self.container = container
        context = ModelContext(container)
        self.contextSaver = contextSaver
        self.detailedMinutesEncoder = detailedMinutesEncoder
    }

    static func inMemory(
        contextSaver: @escaping @MainActor (ModelContext) throws -> Void = {
            try $0.save()
        },
        detailedMinutesEncoder: @escaping
            (GeneratedDetailedMinutes) throws -> EncodedDetailedMinutes = {
                try DetailedMinutesRecord.encode($0)
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
            contextSaver: contextSaver,
            detailedMinutesEncoder: detailedMinutesEncoder
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

    func speakerDisplayNames(meetingID: UUID) throws -> [String: String] {
        try meeting(id: meetingID).speakerDisplayNames
    }

    func setSpeakerDisplayName(
        meetingID: UUID,
        speakerID: String,
        displayName: String,
        now: Date = .now
    ) throws {
        guard let normalizedName = AppSettingsStore.normalizedSpeakerNames(
            [displayName]
        ).first else {
            throw SpeakerNameRepositoryError.invalidDisplayName
        }

        let meeting = try meeting(id: meetingID)
        let matchingTranscripts = meeting.transcripts.filter {
            $0.speakerID == speakerID
        }
        guard let evidenceStartTime = matchingTranscripts
            .map(\.startTime)
            .min(),
              let evidenceEndTime = matchingTranscripts
            .map(\.endTime)
            .max() else {
            throw SpeakerNameRepositoryError.speakerNotFound(speakerID)
        }

        let previousMeetingUpdatedAt = meeting.updatedAt
        if let record = meeting.speakerNames.first(where: {
            $0.speakerID == speakerID
        }) {
            let previous = SpeakerNameSnapshot(record)
            record.displayName = normalizedName
            record.evidenceStartTime = evidenceStartTime
            record.evidenceEndTime = evidenceEndTime
            record.updatedAt = now
            meeting.updatedAt = now
            do {
                try saveContext()
            } catch {
                previous.restore(record)
                meeting.updatedAt = previousMeetingUpdatedAt
                throw error
            }
        } else {
            let record = SpeakerNameRecord(
                speakerID: speakerID,
                displayName: normalizedName,
                evidenceStartTime: evidenceStartTime,
                evidenceEndTime: evidenceEndTime,
                createdAt: now,
                updatedAt: now,
                meeting: meeting
            )
            context.insert(record)
            meeting.speakerNames.append(record)
            meeting.updatedAt = now
            do {
                try saveContext()
            } catch {
                meeting.speakerNames.removeAll { $0 === record }
                context.delete(record)
                meeting.updatedAt = previousMeetingUpdatedAt
                throw error
            }
        }
    }

    func clearSpeakerDisplayName(
        meetingID: UUID,
        speakerID: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        let matches = meeting.speakerNames.filter {
            $0.speakerID == speakerID
        }
        guard !matches.isEmpty else { return }

        let previousMeetingUpdatedAt = meeting.updatedAt
        let snapshots = matches.map(SpeakerNameSnapshot.init)
        meeting.speakerNames.removeAll { $0.speakerID == speakerID }
        matches.forEach(context.delete)
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            for (record, snapshot) in zip(matches, snapshots) {
                context.insert(record)
                snapshot.restore(record)
                record.meeting = meeting
                meeting.speakerNames.append(record)
            }
            meeting.updatedAt = previousMeetingUpdatedAt
            throw error
        }
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
        let previousUpdatedAt = meeting.updatedAt

        if let summary = meeting.summary {
            let previous = SummarySnapshot(summary)
            try summary.update(
                overview: overview,
                keyPoints: keyPoints,
                decisions: decisions,
                actionItems: structuredActionItems,
                bookmarkInsights: bookmarkInsights,
                model: model,
                createdAt: createdAt
            )
            meeting.updatedAt = .now
            do {
                try saveContext()
            } catch {
                previous.restore(summary)
                meeting.updatedAt = previousUpdatedAt
                throw error
            }
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
            meeting.updatedAt = .now
            do {
                try saveContext()
            } catch {
                meeting.summary = nil
                context.delete(summary)
                meeting.updatedAt = previousUpdatedAt
                throw error
            }
        }
    }

    func saveDetailedMinutes(
        meetingID: UUID,
        generated: GeneratedDetailedMinutes,
        model: String,
        promptVersion: Int,
        createdAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        let encoded = try detailedMinutesEncoder(generated)
        let previousUpdatedAt = meeting.updatedAt

        if let minutes = meeting.detailedMinutes {
            let nextRevision = try MeetingDocumentRevision.next(
                after: minutes.contentRevision
            )
            let previous = DetailedMinutesSnapshot(minutes)
            minutes.overview = generated.overview
            minutes.sectionsData = encoded.sections
            minutes.decisionsData = encoded.decisions
            minutes.actionItemsData = encoded.actionItems
            minutes.openQuestionsData = encoded.openQuestions
            minutes.model = model
            minutes.promptVersion = promptVersion
            minutes.createdAt = createdAt
            minutes.contentRevision = nextRevision
            minutes.archiveState = .localOnly
            minutes.archivedContentRevision = nil
            minutes.lastArchiveErrorCode = nil
            meeting.updatedAt = .now
            do {
                try saveContext()
            } catch {
                previous.restore(minutes)
                meeting.updatedAt = previousUpdatedAt
                throw error
            }
        } else {
            let minutes = DetailedMinutesRecord(
                overview: generated.overview,
                sectionsData: encoded.sections,
                decisionsData: encoded.decisions,
                actionItemsData: encoded.actionItems,
                openQuestionsData: encoded.openQuestions,
                model: model,
                promptVersion: promptVersion,
                createdAt: createdAt,
                contentRevision: 1,
                meeting: meeting
            )
            context.insert(minutes)
            meeting.detailedMinutes = minutes
            meeting.updatedAt = .now
            do {
                try saveContext()
            } catch {
                meeting.detailedMinutes = nil
                context.delete(minutes)
                meeting.updatedAt = previousUpdatedAt
                throw error
            }
        }
    }

    func saveGeneratedSummary(
        meetingID: UUID,
        generated: GeneratedMeetingSummary,
        model: String,
        createdAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        let previousStateRawValue = meeting.stateRawValue
        let previousTitle = meeting.title
        let previousSuggestedTitle = meeting.suggestedTitle
        let previousUpdatedAt = meeting.updatedAt
        let existingSummary = meeting.summary
        let existingSnapshot = existingSummary.map(SummarySnapshot.init)

        do {
            if let summary = existingSummary {
                try summary.update(
                    overview: generated.overview,
                    keyPoints: generated.keyPoints,
                    decisions: generated.decisions,
                    actionItems: generated.actionItems,
                    bookmarkInsights: generated.bookmarkInsights,
                    model: model,
                    createdAt: createdAt
                )
            } else {
                let summary = SummaryRecord(
                    overview: generated.overview,
                    keyPoints: generated.keyPoints,
                    decisions: generated.decisions,
                    actionItems: generated.actionItems,
                    bookmarkInsights: generated.bookmarkInsights,
                    model: model,
                    createdAt: createdAt,
                    meeting: meeting
                )
                context.insert(summary)
                meeting.summary = summary
            }
            let suggestedTitle = generated.suggestedTitle.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !suggestedTitle.isEmpty {
                meeting.suggestedTitle = suggestedTitle
                if meeting.title == MeetingRecord.defaultTitle {
                    meeting.title = suggestedTitle
                }
            }
            meeting.state = .summaryReady
            meeting.updatedAt = .now
            try saveContext()
        } catch {
            if let existingSummary, let existingSnapshot {
                existingSnapshot.restore(existingSummary)
            } else if let inserted = meeting.summary {
                meeting.summary = nil
                context.delete(inserted)
            }
            meeting.stateRawValue = previousStateRawValue
            meeting.title = previousTitle
            meeting.suggestedTitle = previousSuggestedTitle
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
    }

    func saveGeneratedDetailedMinutes(
        meetingID: UUID,
        generated: GeneratedDetailedMinutes,
        model: String,
        promptVersion: Int,
        createdAt: Date = .now
    ) throws {
        let meeting = try meeting(id: meetingID)
        let encoded = try detailedMinutesEncoder(generated)
        let previousStateRawValue = meeting.stateRawValue
        let previousUpdatedAt = meeting.updatedAt
        let existingMinutes = meeting.detailedMinutes
        let existingSnapshot = existingMinutes.map(DetailedMinutesSnapshot.init)

        do {
            if let minutes = existingMinutes {
                let nextRevision = try MeetingDocumentRevision.next(
                    after: minutes.contentRevision
                )
                minutes.overview = generated.overview
                minutes.sectionsData = encoded.sections
                minutes.decisionsData = encoded.decisions
                minutes.actionItemsData = encoded.actionItems
                minutes.openQuestionsData = encoded.openQuestions
                minutes.model = model
                minutes.promptVersion = promptVersion
                minutes.createdAt = createdAt
                minutes.contentRevision = nextRevision
                minutes.archiveState = .localOnly
                minutes.archivedContentRevision = nil
                minutes.lastArchiveErrorCode = nil
            } else {
                let minutes = DetailedMinutesRecord(
                    overview: generated.overview,
                    sectionsData: encoded.sections,
                    decisionsData: encoded.decisions,
                    actionItemsData: encoded.actionItems,
                    openQuestionsData: encoded.openQuestions,
                    model: model,
                    promptVersion: promptVersion,
                    createdAt: createdAt,
                    contentRevision: 1,
                    meeting: meeting
                )
                context.insert(minutes)
                meeting.detailedMinutes = minutes
            }
            meeting.state = .summaryReady
            meeting.updatedAt = .now
            try saveContext()
        } catch {
            if let existingMinutes, let existingSnapshot {
                existingSnapshot.restore(existingMinutes)
            } else if let inserted = meeting.detailedMinutes {
                meeting.detailedMinutes = nil
                context.delete(inserted)
            }
            meeting.stateRawValue = previousStateRawValue
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
    }

    func updateDocumentArchiveState(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        archiveState: MeetingDocumentArchiveState,
        meetingState: RecordingState,
        errorCode: String? = nil
    ) throws {
        let meeting = try meeting(id: meetingID)
        let previousStateRawValue = meeting.stateRawValue
        let previousUpdatedAt = meeting.updatedAt

        switch kind {
        case .summary:
            guard let summary = meeting.summary else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            let snapshot = SummarySnapshot(summary)
            summary.archiveState = archiveState
            summary.lastArchiveErrorCode = errorCode
            if archiveState == .archived {
                summary.archivedContentRevision = summary.contentRevision
            } else if archiveState == .archiving {
                summary.archivedContentRevision = nil
            }
            meeting.state = meetingState
            meeting.updatedAt = .now
            do {
                try saveContext()
            } catch {
                snapshot.restore(summary)
                meeting.stateRawValue = previousStateRawValue
                meeting.updatedAt = previousUpdatedAt
                throw error
            }
        case .detailedMinutes:
            guard let minutes = meeting.detailedMinutes else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            let snapshot = DetailedMinutesSnapshot(minutes)
            minutes.archiveState = archiveState
            minutes.lastArchiveErrorCode = errorCode
            if archiveState == .archived {
                minutes.archivedContentRevision = minutes.contentRevision
            } else if archiveState == .archiving {
                minutes.archivedContentRevision = nil
            }
            meeting.state = meetingState
            meeting.updatedAt = .now
            do {
                try saveContext()
            } catch {
                snapshot.restore(minutes)
                meeting.stateRawValue = previousStateRawValue
                meeting.updatedAt = previousUpdatedAt
                throw error
            }
        }
    }

    func documentArchiveSnapshot(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) throws -> MeetingDocumentArchiveSnapshot {
        let meeting = try meeting(id: meetingID)
        switch kind {
        case .summary:
            guard let summary = meeting.summary else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            return MeetingDocumentArchiveSnapshot(
                meetingID: meetingID,
                kind: kind,
                archiveStateRawValue: summary.archiveStateRawValue,
                archivedContentRevision: summary.archivedContentRevision,
                lastArchiveErrorCode: summary.lastArchiveErrorCode,
                meetingState: meeting.state,
                meetingUpdatedAt: meeting.updatedAt
            )
        case .detailedMinutes:
            guard let minutes = meeting.detailedMinutes else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            return MeetingDocumentArchiveSnapshot(
                meetingID: meetingID,
                kind: kind,
                archiveStateRawValue: minutes.archiveStateRawValue,
                archivedContentRevision: minutes.archivedContentRevision,
                lastArchiveErrorCode: minutes.lastArchiveErrorCode,
                meetingState: meeting.state,
                meetingUpdatedAt: meeting.updatedAt
            )
        }
    }

    func restoreDocumentArchiveSnapshot(
        _ snapshot: MeetingDocumentArchiveSnapshot
    ) throws {
        let meeting = try meeting(id: snapshot.meetingID)
        let currentSnapshot = try documentArchiveSnapshot(
            meetingID: snapshot.meetingID,
            kind: snapshot.kind
        )
        applyDocumentArchiveSnapshot(snapshot, to: meeting)
        do {
            try saveContext()
        } catch {
            applyDocumentArchiveSnapshot(currentSnapshot, to: meeting)
            throw error
        }
    }

    func completeDocumentArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) throws {
        let meeting = try meeting(id: meetingID)
        let currentSnapshot = try documentArchiveSnapshot(
            meetingID: meetingID,
            kind: kind
        )
        switch kind {
        case .summary:
            guard let summary = meeting.summary else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            summary.archiveState = .archived
            summary.archivedContentRevision = summary.contentRevision
            summary.lastArchiveErrorCode = nil
        case .detailedMinutes:
            guard let minutes = meeting.detailedMinutes else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            minutes.archiveState = .archived
            minutes.archivedContentRevision = minutes.contentRevision
            minutes.lastArchiveErrorCode = nil
        }
        meeting.state = allExistingDocumentsAreArchived(meeting)
            ? .archived
            : .summaryReady
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            applyDocumentArchiveSnapshot(currentSnapshot, to: meeting)
            throw error
        }
    }

    private func applyDocumentArchiveSnapshot(
        _ snapshot: MeetingDocumentArchiveSnapshot,
        to meeting: MeetingRecord
    ) {
        switch snapshot.kind {
        case .summary:
            meeting.summary?.archiveStateRawValue =
                snapshot.archiveStateRawValue
            meeting.summary?.archivedContentRevision =
                snapshot.archivedContentRevision
            meeting.summary?.lastArchiveErrorCode =
                snapshot.lastArchiveErrorCode
        case .detailedMinutes:
            meeting.detailedMinutes?.archiveStateRawValue =
                snapshot.archiveStateRawValue
            meeting.detailedMinutes?.archivedContentRevision =
                snapshot.archivedContentRevision
            meeting.detailedMinutes?.lastArchiveErrorCode =
                snapshot.lastArchiveErrorCode
        }
        meeting.state = snapshot.meetingState
        meeting.updatedAt = snapshot.meetingUpdatedAt
    }

    private func allExistingDocumentsAreArchived(
        _ meeting: MeetingRecord
    ) -> Bool {
        let states = [
            meeting.summary?.archiveState,
            meeting.detailedMinutes?.archiveState,
        ].compactMap { $0 }
        return !states.isEmpty && states.allSatisfy { $0 == .archived }
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

    func initializeNotionArchivePage(
        meetingID: UUID,
        pageID: String,
        pageURL: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        let previousPageID = meeting.notionPageID
        let previousPageURL = meeting.notionPageURL
        let previousUpdatedAt = meeting.updatedAt
        let existingCheckpoint = meeting.archiveCheckpoint
        let checkpointSnapshot = existingCheckpoint.map(
            ArchiveCheckpointMutationSnapshot.init
        )
        let checkpoint: ArchiveCheckpointRecord
        if let existingCheckpoint {
            checkpoint = existingCheckpoint
        } else {
            checkpoint = ArchiveCheckpointRecord(
                notionPageID: pageID,
                nextSection: "metadata",
                nextBatchIndex: 0,
                meeting: meeting
            )
            context.insert(checkpoint)
            meeting.archiveCheckpoint = checkpoint
        }
        do {
            checkpoint.notionPageID = pageID
            checkpoint.nextSection = "metadata"
            checkpoint.nextBatchIndex = 0
            try checkpoint.setMetadataBlockIDs([])
            for kind in MeetingDocumentKind.allCases {
                try checkpoint.setBlockIDs([], for: kind)
                try checkpoint.setPendingRun(nil, for: kind)
            }
            checkpoint.updatedAt = .now
            meeting.notionPageID = pageID
            meeting.notionPageURL = pageURL
            meeting.updatedAt = .now
            try saveContext()
        } catch {
            meeting.notionPageID = previousPageID
            meeting.notionPageURL = previousPageURL
            meeting.updatedAt = previousUpdatedAt
            if let existingCheckpoint, let checkpointSnapshot {
                checkpointSnapshot.restore(existingCheckpoint)
            } else {
                meeting.archiveCheckpoint = nil
                context.delete(checkpoint)
            }
            throw error
        }
    }

    func resetNotionArchiveCheckpoint(
        meetingID: UUID,
        notionPageID: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        let previousPageID = meeting.notionPageID
        let previousUpdatedAt = meeting.updatedAt
        let existingCheckpoint = meeting.archiveCheckpoint
        let checkpointSnapshot = existingCheckpoint.map(
            ArchiveCheckpointMutationSnapshot.init
        )
        let checkpoint: ArchiveCheckpointRecord
        if let existingCheckpoint {
            checkpoint = existingCheckpoint
        } else {
            checkpoint = ArchiveCheckpointRecord(
                notionPageID: notionPageID,
                nextSection: "managed",
                nextBatchIndex: 0,
                meeting: meeting
            )
            context.insert(checkpoint)
            meeting.archiveCheckpoint = checkpoint
        }
        do {
            checkpoint.notionPageID = notionPageID
            checkpoint.nextSection = "managed"
            checkpoint.nextBatchIndex = 0
            try checkpoint.setMetadataBlockIDs([])
            for kind in MeetingDocumentKind.allCases {
                try checkpoint.setBlockIDs([], for: kind)
                try checkpoint.setPendingRun(nil, for: kind)
            }
            checkpoint.updatedAt = .now
            meeting.notionPageID = notionPageID
            meeting.updatedAt = .now
            try saveContext()
        } catch {
            meeting.notionPageID = previousPageID
            meeting.updatedAt = previousUpdatedAt
            if let existingCheckpoint, let checkpointSnapshot {
                checkpointSnapshot.restore(existingCheckpoint)
            } else {
                meeting.archiveCheckpoint = nil
                context.delete(checkpoint)
            }
            throw error
        }
    }

    func updateMeetingState(id: UUID, state: RecordingState) throws {
        let meeting = try meeting(id: id)
        let previousStateRawValue = meeting.stateRawValue
        let previousUpdatedAt = meeting.updatedAt
        meeting.state = state
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.stateRawValue = previousStateRawValue
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
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

    func beginSpeakerDiarizationRetry(meetingID: UUID) throws {
        let meeting = try meeting(id: meetingID)
        let previousState = meeting.speakerProcessingState
        let isInterruptedRetry = previousState == .processing
            && meeting.state
                .allowsInterruptedSpeakerDiarizationRetryRecovery
        guard previousState == .degraded
                || previousState == .completed
                || isInterruptedRetry else {
            throw MeetingRepositoryError.invalidState(previousState)
        }

        let previousRequested = meeting.speakerDiarizationRequestedBacking
        let previousStateRawValue = meeting.speakerProcessingStateRawValue
        let previousErrorCode = meeting.speakerProcessingErrorCode
        let previousUpdatedAt = meeting.updatedAt
        meeting.speakerDiarizationRequested = true
        meeting.speakerProcessingState = .processing
        meeting.speakerProcessingErrorCode = nil
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.speakerDiarizationRequestedBacking = previousRequested
            meeting.speakerProcessingStateRawValue = previousStateRawValue
            meeting.speakerProcessingErrorCode = previousErrorCode
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
    }

    func completeSpeakerDiarizationRetry(
        meetingID: UUID,
        drafts: [AttributedTranscriptDraft],
        sourceRevision: Int,
        speakerDisplayNames: [String: String] = [:]
    ) throws {
        let transactionContext = ModelContext(container)
        transactionContext.autosaveEnabled = false
        let meeting = try meeting(id: meetingID, in: transactionContext)
        guard meeting.speakerProcessingState == .processing else {
            throw MeetingRepositoryError.invalidState(
                meeting.speakerProcessingState
            )
        }

        let previousTranscripts = meeting.transcripts
        let previousSpeakerNames = meeting.speakerNames
        let previousStateRawValue = meeting.speakerProcessingStateRawValue
        let previousErrorCode = meeting.speakerProcessingErrorCode
        let previousUpdatedAt = meeting.updatedAt
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
        let now = Date.now
        let replacementSpeakerNames = speakerDisplayNames
            .sorted { $0.key < $1.key }
            .compactMap { speakerID, displayName -> SpeakerNameRecord? in
                guard let normalizedName = AppSettingsStore
                    .normalizedSpeakerNames([displayName]).first else {
                    return nil
                }
                let matching = replacements.filter {
                    $0.speakerID == speakerID
                }
                guard let evidenceStartTime = matching.map(\.startTime).min(),
                      let evidenceEndTime = matching.map(\.endTime).max() else {
                    return nil
                }
                return SpeakerNameRecord(
                    speakerID: speakerID,
                    displayName: normalizedName,
                    evidenceStartTime: evidenceStartTime,
                    evidenceEndTime: evidenceEndTime,
                    createdAt: now,
                    updatedAt: now
                )
            }

        replacements.forEach(transactionContext.insert)
        replacementSpeakerNames.forEach(transactionContext.insert)
        meeting.transcripts = replacements
        meeting.speakerNames = replacementSpeakerNames
        meeting.speakerProcessingState = .completed
        meeting.speakerProcessingErrorCode = nil
        meeting.updatedAt = .now
        previousTranscripts.forEach(transactionContext.delete)
        previousSpeakerNames.forEach(transactionContext.delete)
        do {
            try contextSaver(transactionContext)
        } catch {
            transactionContext.rollback()
            meeting.transcripts = previousTranscripts
            meeting.speakerNames = previousSpeakerNames
            meeting.speakerProcessingStateRawValue = previousStateRawValue
            meeting.speakerProcessingErrorCode = previousErrorCode
            meeting.updatedAt = previousUpdatedAt
            throw error
        }
    }

    func failSpeakerDiarizationRetry(
        meetingID: UUID,
        errorCode: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard meeting.speakerProcessingState == .processing else {
            throw MeetingRepositoryError.invalidState(
                meeting.speakerProcessingState
            )
        }

        let previousStateRawValue = meeting.speakerProcessingStateRawValue
        let previousErrorCode = meeting.speakerProcessingErrorCode
        let previousUpdatedAt = meeting.updatedAt
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode = errorCode
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            meeting.speakerProcessingStateRawValue = previousStateRawValue
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

    func documentContentRevision(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) throws -> Int {
        let meeting = try meeting(id: meetingID)
        switch kind {
        case .summary:
            guard let summary = meeting.summary else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            return summary.contentRevision
        case .detailedMinutes:
            guard let minutes = meeting.detailedMinutes else {
                throw MeetingDocumentRepositoryError.missingDocument(kind)
            }
            return minutes.contentRevision
        }
    }

    func beginDocumentArchiveRun(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        contentRevision: Int
    ) throws -> NotionDocumentArchiveRun {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint else {
            throw MeetingDocumentRepositoryError.missingArchiveCheckpoint
        }
        let actualRevision = try documentContentRevision(
            meetingID: meetingID,
            kind: kind
        )
        guard actualRevision == contentRevision else {
            throw MeetingDocumentRepositoryError.staleDocumentRevision(
                kind,
                expected: contentRevision,
                actual: actualRevision
            )
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let documentSnapshot = try documentArchiveSnapshot(
            meetingID: meetingID,
            kind: kind
        )

        let run: NotionDocumentArchiveRun
        if let existing = try checkpoint.pendingRun(for: kind),
           existing.contentRevision == contentRevision {
            run = existing
        } else {
            let existing = try checkpoint.pendingRun(for: kind)
            let staleIDs = Self.uniqueBlockIDs(
                try checkpoint.blockIDs(for: kind)
                    + (existing?.newBlockIDs ?? [])
                    + (existing?.oldBlockIDs ?? [])
            )
            run = NotionDocumentArchiveRun(
                contentRevision: contentRevision,
                oldBlockIDs: staleIDs
            )
            try checkpoint.setPendingRun(run, for: kind)
        }
        setDocumentArchiveStatus(
            meeting: meeting,
            kind: kind,
            state: .archiving,
            archivedRevision: documentSnapshot.archivedContentRevision,
            errorCode: nil
        )
        meeting.state = .summaryReady
        meeting.updatedAt = .now
        checkpoint.updatedAt = .now
        do {
            try saveContext()
            return run
        } catch {
            checkpointSnapshot.restore(checkpoint)
            applyDocumentArchiveSnapshot(documentSnapshot, to: meeting)
            throw error
        }
    }

    func recordDocumentArchiveBatch(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        contentRevision: Int,
        blockIDs: [String],
        nextBatchIndex: Int
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              var run = try checkpoint.pendingRun(for: kind),
              run.contentRevision == contentRevision,
              run.phase == .appending,
              nextBatchIndex == run.nextBatchIndex + 1 else {
            throw MeetingDocumentRepositoryError.invalidArchiveRun(kind)
        }
        let snapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let previousMeetingUpdatedAt = meeting.updatedAt
        run.newBlockIDs.append(contentsOf: blockIDs)
        run.nextBatchIndex = nextBatchIndex
        try checkpoint.setPendingRun(run, for: kind)
        checkpoint.updatedAt = .now
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            snapshot.restore(checkpoint)
            meeting.updatedAt = previousMeetingUpdatedAt
            throw error
        }
    }

    func recordMetadataArchiveBatch(
        meetingID: UUID,
        notionPageID: String,
        blockIDs: [String],
        nextBatchIndex: Int,
        batchCount: Int
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              checkpoint.notionPageID == notionPageID,
              checkpoint.nextSection == "metadata",
              nextBatchIndex == checkpoint.nextBatchIndex + 1,
              nextBatchIndex <= batchCount else {
            throw MeetingDocumentRepositoryError
                .invalidMetadataArchiveCheckpoint
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let previousMeetingUpdatedAt = meeting.updatedAt
        let previousIDs = try checkpoint.metadataBlockIDs
        try checkpoint.setMetadataBlockIDs(previousIDs + blockIDs)
        checkpoint.nextSection = nextBatchIndex == batchCount
            ? "managed"
            : "metadata"
        checkpoint.nextBatchIndex = nextBatchIndex == batchCount
            ? 0
            : nextBatchIndex
        checkpoint.updatedAt = .now
        meeting.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            meeting.updatedAt = previousMeetingUpdatedAt
            throw error
        }
    }

    func promoteDocumentArchiveRun(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        contentRevision: Int
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              var run = try checkpoint.pendingRun(for: kind),
              run.contentRevision == contentRevision,
              run.phase == .appending else {
            throw MeetingDocumentRepositoryError.invalidArchiveRun(kind)
        }
        let actualRevision = try documentContentRevision(
            meetingID: meetingID,
            kind: kind
        )
        guard actualRevision == contentRevision else {
            throw MeetingDocumentRepositoryError.staleDocumentRevision(
                kind,
                expected: contentRevision,
                actual: actualRevision
            )
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let documentSnapshot = try documentArchiveSnapshot(
            meetingID: meetingID,
            kind: kind
        )

        try checkpoint.setBlockIDs(run.newBlockIDs, for: kind)
        if run.oldBlockIDs.isEmpty {
            try checkpoint.setPendingRun(nil, for: kind)
        } else {
            run.phase = .cleaningUp
            try checkpoint.setPendingRun(run, for: kind)
        }
        setDocumentArchiveStatus(
            meeting: meeting,
            kind: kind,
            state: .archived,
            archivedRevision: contentRevision,
            errorCode: nil
        )
        meeting.state = allExistingDocumentsAreArchived(meeting)
            ? .archived
            : .summaryReady
        meeting.updatedAt = .now
        checkpoint.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            applyDocumentArchiveSnapshot(documentSnapshot, to: meeting)
            throw error
        }
    }

    func recordArchivedDocumentBlock(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        contentRevision: Int,
        blockID: String
    ) throws {
        let meeting = try meeting(id: meetingID)
        guard let checkpoint = meeting.archiveCheckpoint,
              var run = try checkpoint.pendingRun(for: kind),
              run.contentRevision == contentRevision,
              run.phase == .cleaningUp,
              run.oldBlockIDs.contains(blockID) else {
            throw MeetingDocumentRepositoryError.invalidArchiveRun(kind)
        }
        let checkpointSnapshot = ArchiveCheckpointMutationSnapshot(checkpoint)
        let documentSnapshot = try documentArchiveSnapshot(
            meetingID: meetingID,
            kind: kind
        )
        run.oldBlockIDs.removeAll { $0 == blockID }
        if run.oldBlockIDs.isEmpty {
            try checkpoint.setPendingRun(nil, for: kind)
            let actualRevision = try documentContentRevision(
                meetingID: meetingID,
                kind: kind
            )
            if actualRevision == contentRevision {
                setDocumentArchiveStatus(
                    meeting: meeting,
                    kind: kind,
                    state: .archived,
                    archivedRevision: contentRevision,
                    errorCode: nil
                )
                meeting.state = allExistingDocumentsAreArchived(meeting)
                    ? .archived
                    : .summaryReady
            }
        } else {
            try checkpoint.setPendingRun(run, for: kind)
        }
        meeting.updatedAt = .now
        checkpoint.updatedAt = .now
        do {
            try saveContext()
        } catch {
            checkpointSnapshot.restore(checkpoint)
            applyDocumentArchiveSnapshot(documentSnapshot, to: meeting)
            throw error
        }
    }

    private func setDocumentArchiveStatus(
        meeting: MeetingRecord,
        kind: MeetingDocumentKind,
        state: MeetingDocumentArchiveState,
        archivedRevision: Int?,
        errorCode: String?
    ) {
        switch kind {
        case .summary:
            meeting.summary?.archiveState = state
            meeting.summary?.archivedContentRevision = archivedRevision
            meeting.summary?.lastArchiveErrorCode = errorCode
        case .detailedMinutes:
            meeting.detailedMinutes?.archiveState = state
            meeting.detailedMinutes?.archivedContentRevision = archivedRevision
            meeting.detailedMinutes?.lastArchiveErrorCode = errorCode
        }
    }

    private static func uniqueBlockIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        return ids.filter { seen.insert($0).inserted }
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

private struct ArchiveCheckpointMutationSnapshot {
    let notionPageID: String
    let nextSection: String
    let nextBatchIndex: Int
    let metadataBlockIDsData: Data?
    let summaryBlockIDsData: Data?
    let detailedMinutesBlockIDsData: Data?
    let pendingKindRawValue: String?
    let pendingNewBlockIDsData: Data?
    let pendingOldBlockIDsData: Data?
    let pendingNextBatchIndex: Int?
    let pendingContentRevision: Int?
    let pendingPhaseRawValue: String?
    let pendingRunsData: Data?
    let updatedAt: Date

    init(_ checkpoint: ArchiveCheckpointRecord) {
        notionPageID = checkpoint.notionPageID
        nextSection = checkpoint.nextSection
        nextBatchIndex = checkpoint.nextBatchIndex
        metadataBlockIDsData = checkpoint.metadataBlockIDsData
        summaryBlockIDsData = checkpoint.summaryBlockIDsData
        detailedMinutesBlockIDsData = checkpoint.detailedMinutesBlockIDsData
        pendingKindRawValue = checkpoint.pendingKindRawValue
        pendingNewBlockIDsData = checkpoint.pendingNewBlockIDsData
        pendingOldBlockIDsData = checkpoint.pendingOldBlockIDsData
        pendingNextBatchIndex = checkpoint.pendingNextBatchIndex
        pendingContentRevision = checkpoint.pendingContentRevision
        pendingPhaseRawValue = checkpoint.pendingPhaseRawValue
        pendingRunsData = checkpoint.pendingRunsData
        updatedAt = checkpoint.updatedAt
    }

    func restore(_ checkpoint: ArchiveCheckpointRecord) {
        checkpoint.notionPageID = notionPageID
        checkpoint.nextSection = nextSection
        checkpoint.nextBatchIndex = nextBatchIndex
        checkpoint.metadataBlockIDsData = metadataBlockIDsData
        checkpoint.summaryBlockIDsData = summaryBlockIDsData
        checkpoint.detailedMinutesBlockIDsData = detailedMinutesBlockIDsData
        checkpoint.pendingKindRawValue = pendingKindRawValue
        checkpoint.pendingNewBlockIDsData = pendingNewBlockIDsData
        checkpoint.pendingOldBlockIDsData = pendingOldBlockIDsData
        checkpoint.pendingNextBatchIndex = pendingNextBatchIndex
        checkpoint.pendingContentRevision = pendingContentRevision
        checkpoint.pendingPhaseRawValue = pendingPhaseRawValue
        checkpoint.pendingRunsData = pendingRunsData
        checkpoint.updatedAt = updatedAt
    }
}

private struct SummarySnapshot {
    let overview: String
    let keyPointsData: Data
    let decisionsData: Data
    let actionItemsData: Data
    let bookmarkInsightsData: Data
    let model: String
    let createdAt: Date
    let contentRevisionBacking: Int?
    let archiveStateRawValue: String?
    let archivedContentRevision: Int?
    let lastArchiveErrorCode: String?

    init(_ summary: SummaryRecord) {
        overview = summary.overview
        keyPointsData = summary.keyPointsData
        decisionsData = summary.decisionsData
        actionItemsData = summary.actionItemsData
        bookmarkInsightsData = summary.bookmarkInsightsData
        model = summary.model
        createdAt = summary.createdAt
        contentRevisionBacking = summary.contentRevisionBacking
        archiveStateRawValue = summary.archiveStateRawValue
        archivedContentRevision = summary.archivedContentRevision
        lastArchiveErrorCode = summary.lastArchiveErrorCode
    }

    func restore(_ summary: SummaryRecord) {
        summary.overview = overview
        summary.keyPointsData = keyPointsData
        summary.decisionsData = decisionsData
        summary.actionItemsData = actionItemsData
        summary.bookmarkInsightsData = bookmarkInsightsData
        summary.model = model
        summary.createdAt = createdAt
        summary.contentRevisionBacking = contentRevisionBacking
        summary.archiveStateRawValue = archiveStateRawValue
        summary.archivedContentRevision = archivedContentRevision
        summary.lastArchiveErrorCode = lastArchiveErrorCode
    }
}

private struct DetailedMinutesSnapshot {
    let overview: String
    let sectionsData: Data
    let decisionsData: Data
    let actionItemsData: Data
    let openQuestionsData: Data
    let model: String
    let promptVersion: Int
    let createdAt: Date
    let contentRevisionBacking: Int?
    let archiveStateRawValue: String?
    let archivedContentRevision: Int?
    let lastArchiveErrorCode: String?

    init(_ minutes: DetailedMinutesRecord) {
        overview = minutes.overview
        sectionsData = minutes.sectionsData
        decisionsData = minutes.decisionsData
        actionItemsData = minutes.actionItemsData
        openQuestionsData = minutes.openQuestionsData
        model = minutes.model
        promptVersion = minutes.promptVersion
        createdAt = minutes.createdAt
        contentRevisionBacking = minutes.contentRevisionBacking
        archiveStateRawValue = minutes.archiveStateRawValue
        archivedContentRevision = minutes.archivedContentRevision
        lastArchiveErrorCode = minutes.lastArchiveErrorCode
    }

    func restore(_ minutes: DetailedMinutesRecord) {
        minutes.overview = overview
        minutes.sectionsData = sectionsData
        minutes.decisionsData = decisionsData
        minutes.actionItemsData = actionItemsData
        minutes.openQuestionsData = openQuestionsData
        minutes.model = model
        minutes.promptVersion = promptVersion
        minutes.createdAt = createdAt
        minutes.contentRevisionBacking = contentRevisionBacking
        minutes.archiveStateRawValue = archiveStateRawValue
        minutes.archivedContentRevision = archivedContentRevision
        minutes.lastArchiveErrorCode = lastArchiveErrorCode
    }
}

private struct SpeakerNameSnapshot {
    let speakerID: String
    let displayName: String
    let evidenceStartTime: TimeInterval
    let evidenceEndTime: TimeInterval
    let createdAt: Date
    let updatedAt: Date

    init(_ record: SpeakerNameRecord) {
        speakerID = record.speakerID
        displayName = record.displayName
        evidenceStartTime = record.evidenceStartTime
        evidenceEndTime = record.evidenceEndTime
        createdAt = record.createdAt
        updatedAt = record.updatedAt
    }

    func restore(_ record: SpeakerNameRecord) {
        record.speakerID = speakerID
        record.displayName = displayName
        record.evidenceStartTime = evidenceStartTime
        record.evidenceEndTime = evidenceEndTime
        record.createdAt = createdAt
        record.updatedAt = updatedAt
    }
}
