import Foundation

enum MeetingDocumentsError: Error, Equatable, Sendable {
    case noFinalTranscript
    case missingDeepSeekCredential
    case missingNotionCredential
    case invalidNotionPageURL
    case missingLocalDocument(MeetingDocumentKind)
    case invalidGeneratedDocument(MeetingDocumentKind)
    case generationFailed(MeetingDocumentKind)
    case archiveFailed(MeetingDocumentKind)
    case localPersistenceFailed
    case operationInProgress
    case invalidState(RecordingState)
}

protocol MeetingDetailedMinutesGenerating: Sendable {
    func detailedMinutes(
        apiKey: String,
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedDetailedMinutes
}

struct LiveMeetingDetailedMinutesGenerator: MeetingDetailedMinutesGenerating {
    let httpClient: any HTTPClient

    func detailedMinutes(
        apiKey: String,
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedDetailedMinutes {
        try await DeepSeekClient(
            apiKey: apiKey,
            httpClient: httpClient
        ).detailedMinutes(input: input, model: model)
    }
}

@MainActor
protocol MeetingDocumentArchiving: AnyObject {
    func archive(
        token: String,
        meetingID: UUID,
        parentPageID: UUID,
        kind: MeetingDocumentKind
    ) async throws
    func sync(
        token: String,
        meetingID: UUID,
        parentPageID: UUID,
        content: NotionMeetingPageContent
    ) async throws
}

@MainActor
protocol MeetingDocumentManaging: AnyObject {
    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        replacingManualEdits: Bool
    ) async throws
    func retryArchive(meetingID: UUID, kind: MeetingDocumentKind) async throws
    func syncToNotion(meetingID: UUID) async throws
    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws
    func retryArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws
    func syncToNotion(
        meetingID: UUID,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws
}

@MainActor
extension MeetingDocumentManaging {
    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) async throws {
        try await generate(
            meetingID: meetingID,
            kind: kind,
            replacingManualEdits: false
        )
    }

    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws {
        onOperationChange(.generating(kind))
        try await generate(meetingID: meetingID, kind: kind)
    }

    func retryArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws {
        onOperationChange(.archiving(kind))
        try await retryArchive(meetingID: meetingID, kind: kind)
    }

    func syncToNotion(
        meetingID: UUID,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws {
        onOperationChange(.syncingNotion)
        try await syncToNotion(meetingID: meetingID)
    }
}

@MainActor
final class LegacyMeetingDocumentNotionArchiver: MeetingDocumentArchiving {
    private let repository: MeetingRepository
    private let archiver: any MeetingNotionArchiving

    init(
        repository: MeetingRepository,
        archiver: any MeetingNotionArchiving
    ) {
        self.repository = repository
        self.archiver = archiver
    }

    func archive(
        token: String,
        meetingID: UUID,
        parentPageID: UUID,
        kind: MeetingDocumentKind
    ) async throws {
        let meeting = try repository.meeting(id: meetingID)
        let inputs = MeetingDocumentInputBuilder.inputs(for: meeting)
        let timeline = MeetingNotionTimelineInputBuilder.inputs(for: meeting)
        let payload = try generatedDocument(for: meeting, kind: kind)
        _ = try await archiver.archive(
            token: token,
            meetingID: meetingID,
            parentPageID: parentPageID,
            content: try NotionMeetingPageContent(
                title: meeting.title,
                startedAt: meeting.startedAt,
                duration: meeting.activeDuration,
                mode: meeting.mode,
                kind: kind,
                summary: payload.summary,
                detailedMinutes: payload.detailedMinutes,
                bookmarks: inputs.bookmarks,
                transcripts: inputs.transcripts,
                userNotes: timeline.notes,
                screenshots: timeline.screenshots
            )
        )
    }

    func sync(
        token: String,
        meetingID: UUID,
        parentPageID: UUID,
        content: NotionMeetingPageContent
    ) async throws {
        _ = try await archiver.archive(
            token: token,
            meetingID: meetingID,
            parentPageID: parentPageID,
            content: content
        )
    }

    private func generatedDocument(
        for meeting: MeetingRecord,
        kind: MeetingDocumentKind
    ) throws -> (
        summary: GeneratedMeetingSummary?,
        detailedMinutes: GeneratedDetailedMinutes?
    ) {
        switch kind {
        case .summary:
            guard let summary = meeting.summary else {
                throw MeetingDocumentsError.missingLocalDocument(kind)
            }
            return (
                GeneratedMeetingSummary(
                    suggestedTitle: meeting.suggestedTitle ?? meeting.title,
                    overview: summary.overview,
                    keyPoints: summary.keyPoints,
                    decisions: summary.decisions,
                    actionItems: summary.actionItemRecords,
                    bookmarkInsights: summary.bookmarkInsights
                ),
                nil
            )
        case .detailedMinutes:
            guard let minutes = meeting.detailedMinutes else {
                throw MeetingDocumentsError.missingLocalDocument(kind)
            }
            return (
                nil,
                GeneratedDetailedMinutes(
                    overview: minutes.overview,
                    sections: try minutes.sections,
                    decisions: try minutes.decisions,
                    actionItems: try minutes.actionItems,
                    openQuestions: try minutes.openQuestions
                )
            )
        }
    }
}

@MainActor
final class MeetingDocumentsUseCase: MeetingDocumentManaging {
    static let archiveFailureCode = "notion_archive_failed"
    static let missingNotionCredentialCode = "missing_notion_credential"
    static let invalidNotionPageURLCode = "invalid_notion_page_url"
    static let syncFailureCode = "notion_sync_failed"
    static let detailedMinutesPromptVersion = 1

    private let repository: MeetingRepository
    private let credentialStore: any CredentialStore
    private let settingsStore: AppSettingsStore
    private let summaryGenerator: any MeetingSummaryGenerating
    private let detailedMinutesGenerator:
        any MeetingDetailedMinutesGenerating
    private let archiver: any MeetingDocumentArchiving
    private let operationGate: MeetingOperationGate
    private var pendingRecoveries: [UUID: PendingRecovery] = [:]

    private(set) var operation: MeetingDocumentOperation = .idle

    private enum PendingRecovery {
        case meetingState(RecordingState)
        case archive(MeetingDocumentArchiveSnapshot)
    }

    init(
        repository: MeetingRepository,
        credentialStore: any CredentialStore,
        settingsStore: AppSettingsStore,
        summaryGenerator: any MeetingSummaryGenerating,
        detailedMinutesGenerator: any MeetingDetailedMinutesGenerating,
        archiver: any MeetingDocumentArchiving,
        operationGate: MeetingOperationGate
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.settingsStore = settingsStore
        self.summaryGenerator = summaryGenerator
        self.detailedMinutesGenerator = detailedMinutesGenerator
        self.archiver = archiver
        self.operationGate = operationGate
    }

    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) async throws {
        try await generate(
            meetingID: meetingID,
            kind: kind,
            replacingManualEdits: false
        )
    }

    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        replacingManualEdits: Bool
    ) async throws {
        try await generate(
            meetingID: meetingID,
            kind: kind,
            replacingManualEdits: replacingManualEdits,
            onOperationChange: { _ in }
        )
    }

    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws {
        try await generate(
            meetingID: meetingID,
            kind: kind,
            replacingManualEdits: false,
            onOperationChange: onOperationChange
        )
    }

    func generate(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        replacingManualEdits: Bool,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws {
        try prepareForOperation(meetingID: meetingID)
        guard operationGate.acquire(.summarizeArchive, for: meetingID) else {
            throw MeetingDocumentsError.operationInProgress
        }
        operation = .generating(kind)
        onOperationChange(operation)
        defer {
            operation = .idle
            operationGate.release(.summarizeArchive, for: meetingID)
        }

        let meeting = try repository.meeting(id: meetingID)
        let stableState = try validatedStableState(meeting.state)
        let input = MeetingDocumentInputBuilder.inputs(for: meeting)
        guard !input.transcripts.isEmpty else {
            throw MeetingDocumentsError.noFinalTranscript
        }
        guard let apiKey = try nonemptyCredential(.deepSeekAPIKey) else {
            throw MeetingDocumentsError.missingDeepSeekCredential
        }
        let generationModel = settingsStore.deepSeekModel
        let observedMeetingContentRevision = meeting.contentRevision

        do {
            try repository.updateMeetingState(id: meetingID, state: .summarizing)
        } catch {
            throw MeetingDocumentsError.localPersistenceFailed
        }

        switch kind {
        case .summary:
            let generated: GeneratedMeetingSummary
            do {
                generated = try await summaryGenerator.summarize(
                    apiKey: apiKey,
                    input: MeetingSummaryInput(
                        title: meeting.title,
                        transcripts: input.transcripts,
                        bookmarks: input.bookmarks,
                        userNotes: input.userNotes
                    ),
                    model: generationModel
                )
            } catch {
                try restoreStableState(meetingID: meetingID, state: stableState)
                if Self.isCancellation(error) {
                    throw error
                }
                throw MeetingDocumentsError.generationFailed(kind)
            }
            guard Self.isValid(generated) else {
                try restoreStableState(meetingID: meetingID, state: stableState)
                throw MeetingDocumentsError.invalidGeneratedDocument(kind)
            }
            do {
                try repository.saveGeneratedSummary(
                    meetingID: meetingID,
                    generated: generated,
                    model: generationModel,
                    observedMeetingContentRevision:
                        observedMeetingContentRevision,
                    replacingManualEdits: replacingManualEdits
                )
            } catch {
                try restoreStableState(meetingID: meetingID, state: stableState)
                if let repositoryError =
                    error as? MeetingDocumentRepositoryError {
                    throw repositoryError
                }
                throw MeetingDocumentsError.localPersistenceFailed
            }
        case .detailedMinutes:
            let generated: GeneratedDetailedMinutes
            do {
                generated = try await detailedMinutesGenerator
                    .detailedMinutes(
                        apiKey: apiKey,
                        input: MeetingSummaryInput(
                            title: meeting.title,
                            transcripts: input.transcripts,
                            bookmarks: input.bookmarks,
                            userNotes: input.userNotes
                        ),
                        model: generationModel
                    )
            } catch {
                try restoreStableState(meetingID: meetingID, state: stableState)
                if Self.isCancellation(error) {
                    throw error
                }
                throw MeetingDocumentsError.generationFailed(kind)
            }
            guard Self.isValid(generated) else {
                try restoreStableState(meetingID: meetingID, state: stableState)
                throw MeetingDocumentsError.invalidGeneratedDocument(kind)
            }
            do {
                try repository.saveGeneratedDetailedMinutes(
                    meetingID: meetingID,
                    generated: generated,
                    model: generationModel,
                    promptVersion: Self.detailedMinutesPromptVersion,
                    observedMeetingContentRevision:
                        observedMeetingContentRevision,
                    replacingManualEdits: replacingManualEdits
                )
            } catch {
                try restoreStableState(meetingID: meetingID, state: stableState)
                if let repositoryError =
                    error as? MeetingDocumentRepositoryError {
                    throw repositoryError
                }
                throw MeetingDocumentsError.localPersistenceFailed
            }
        }

        // Generation is always a local operation. Notion synchronization is
        // intentionally started only by the user's explicit sync action.
    }

    func retryArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind
    ) async throws {
        try await retryArchive(
            meetingID: meetingID,
            kind: kind,
            onOperationChange: { _ in }
        )
    }

    func retryArchive(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws {
        guard settingsStore.isNotionArchivingEnabled else { return }
        try prepareForOperation(meetingID: meetingID)
        guard operationGate.acquire(.summarizeArchive, for: meetingID) else {
            throw MeetingDocumentsError.operationInProgress
        }
        operation = .archiving(kind)
        defer {
            operation = .idle
            operationGate.release(.summarizeArchive, for: meetingID)
        }

        let meeting = try repository.meeting(id: meetingID)
        _ = try validatedStableState(meeting.state)
        guard Self.hasDocument(meeting, kind: kind) else {
            throw MeetingDocumentsError.missingLocalDocument(kind)
        }
        try await archiveSavedDocument(
            meetingID: meetingID,
            kind: kind,
            onOperationChange: onOperationChange
        )
    }

    func syncToNotion(meetingID: UUID) async throws {
        try await syncToNotion(
            meetingID: meetingID,
            onOperationChange: { _ in }
        )
    }

    func syncToNotion(
        meetingID: UUID,
        onOperationChange: @escaping (MeetingDocumentOperation) -> Void
    ) async throws {
        guard settingsStore.isNotionArchivingEnabled else { return }
        try prepareForOperation(meetingID: meetingID)
        guard operationGate.acquire(.summarizeArchive, for: meetingID) else {
            throw MeetingDocumentsError.operationInProgress
        }
        operation = .syncingNotion
        onOperationChange(operation)
        defer {
            operation = .idle
            operationGate.release(.summarizeArchive, for: meetingID)
        }

        let meeting = try repository.meeting(id: meetingID)
        _ = try validatedStableState(meeting.state)
        let content = try notionPageContent(for: meeting)
        guard let notionToken = try nonemptyCredential(.notionToken) else {
            throw MeetingDocumentsError.missingNotionCredential
        }
        guard let parentPageID = NotionPageLinkParser.parse(
            settingsStore.notionParentPageURL
        ) else {
            throw MeetingDocumentsError.invalidNotionPageURL
        }

        let syncSnapshot: MeetingNotionSyncSnapshot
        do {
            syncSnapshot = try repository.beginNotionSync(
                meetingID: meetingID,
                contentRevision: content.contentRevision
            )
        } catch let error as MeetingDocumentRepositoryError {
            throw error
        } catch {
            throw MeetingDocumentsError.localPersistenceFailed
        }

        do {
            try await archiver.sync(
                token: notionToken,
                meetingID: meetingID,
                parentPageID: parentPageID,
                content: content
            )
        } catch {
            if Self.isCancellation(error) {
                try restoreNotionSyncSnapshot(syncSnapshot)
                throw error
            }
            do {
                try repository.failNotionSync(
                    meetingID: meetingID,
                    contentRevision: content.contentRevision,
                    errorCode: Self.syncFailureCode
                )
            } catch {
                throw MeetingDocumentsError.localPersistenceFailed
            }
            throw MeetingDocumentsError.archiveFailed(content.kind)
        }

        do {
            try repository.completeNotionSync(
                meetingID: meetingID,
                contentRevision: content.contentRevision
            )
        } catch {
            throw MeetingDocumentsError.localPersistenceFailed
        }
    }

    private func notionPageContent(
        for meeting: MeetingRecord
    ) throws -> NotionMeetingPageContent {
        let summary = meeting.summary.map {
            GeneratedMeetingSummary(
                suggestedTitle: meeting.suggestedTitle ?? meeting.title,
                overview: $0.overview,
                keyPoints: $0.keyPoints,
                decisions: $0.decisions,
                actionItems: $0.actionItemRecords,
                bookmarkInsights: $0.bookmarkInsights
            )
        }
        let detailedMinutes: GeneratedDetailedMinutes?
        if let minutes = meeting.detailedMinutes {
            detailedMinutes = GeneratedDetailedMinutes(
                overview: minutes.overview,
                sections: try minutes.sections,
                decisions: try minutes.decisions,
                actionItems: try minutes.actionItems,
                openQuestions: try minutes.openQuestions
            )
        } else {
            detailedMinutes = nil
        }
        guard summary != nil || detailedMinutes != nil else {
            throw MeetingDocumentsError.missingLocalDocument(.summary)
        }
        let inputs = MeetingDocumentInputBuilder.inputs(for: meeting)
        let timeline = MeetingNotionTimelineInputBuilder.inputs(for: meeting)
        return try NotionMeetingPageContent(
            title: meeting.title,
            startedAt: meeting.startedAt,
            duration: meeting.activeDuration,
            mode: meeting.mode,
            contentRevision: meeting.contentRevision,
            summary: summary,
            detailedMinutes: detailedMinutes,
            bookmarks: inputs.bookmarks,
            transcripts: inputs.transcripts,
            userNotes: timeline.notes,
            screenshots: timeline.screenshots
        )
    }

    private func restoreNotionSyncSnapshot(
        _ snapshot: MeetingNotionSyncSnapshot
    ) throws {
        do {
            try repository.restoreNotionSyncSnapshot(snapshot)
        } catch {
            throw MeetingDocumentsError.localPersistenceFailed
        }
    }

    private func archiveSavedDocument(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        onOperationChange: (MeetingDocumentOperation) -> Void
    ) async throws {
        operation = .archiving(kind)
        onOperationChange(operation)
        let archiveSnapshot: MeetingDocumentArchiveSnapshot
        do {
            archiveSnapshot = try repository.documentArchiveSnapshot(
                meetingID: meetingID,
                kind: kind
            )
        } catch {
            throw MeetingDocumentsError.missingLocalDocument(kind)
        }
        guard let notionToken = try nonemptyCredential(.notionToken) else {
            try markArchiveFailure(
                meetingID: meetingID,
                kind: kind,
                code: Self.missingNotionCredentialCode
            )
            throw MeetingDocumentsError.missingNotionCredential
        }
        guard let parentPageID = NotionPageLinkParser.parse(
            settingsStore.notionParentPageURL
        ) else {
            try markArchiveFailure(
                meetingID: meetingID,
                kind: kind,
                code: Self.invalidNotionPageURLCode
            )
            throw MeetingDocumentsError.invalidNotionPageURL
        }

        do {
            try repository.updateDocumentArchiveState(
                meetingID: meetingID,
                kind: kind,
                archiveState: .archiving,
                meetingState: .archiving
            )
        } catch let error as MeetingDocumentsError {
            throw error
        } catch {
            throw MeetingDocumentsError.localPersistenceFailed
        }

        do {
            try await archiver.archive(
                token: notionToken,
                meetingID: meetingID,
                parentPageID: parentPageID,
                kind: kind
            )
        } catch {
            if Self.isCancellation(error) {
                try restoreArchiveSnapshot(archiveSnapshot)
                throw error
            }
            try markArchiveFailure(
                meetingID: meetingID,
                kind: kind,
                code: Self.archiveFailureCode
            )
            throw MeetingDocumentsError.archiveFailed(kind)
        }

        do {
            try repository.completeDocumentArchive(
                meetingID: meetingID,
                kind: kind
            )
        } catch {
            try? markArchiveFailure(
                meetingID: meetingID,
                kind: kind,
                code: Self.archiveFailureCode
            )
            throw MeetingDocumentsError.localPersistenceFailed
        }
    }

    private func markArchiveFailure(
        meetingID: UUID,
        kind: MeetingDocumentKind,
        code: String
    ) throws {
        do {
            try repository.updateDocumentArchiveState(
                meetingID: meetingID,
                kind: kind,
                archiveState: .failed,
                meetingState: .summaryReady,
                errorCode: code
            )
        } catch {
            try? repository.updateMeetingState(
                id: meetingID,
                state: .summaryReady
            )
            throw MeetingDocumentsError.localPersistenceFailed
        }
    }

    private func restoreStableState(
        meetingID: UUID,
        state: RecordingState
    ) throws {
        try restore(
            .meetingState(state),
            meetingID: meetingID
        )
    }

    private func restoreArchiveSnapshot(
        _ snapshot: MeetingDocumentArchiveSnapshot
    ) throws {
        try restore(.archive(snapshot), meetingID: snapshot.meetingID)
    }

    private func prepareForOperation(meetingID: UUID) throws {
        guard operation == .idle,
              !operationGate.isActive(for: meetingID) else {
            throw MeetingDocumentsError.operationInProgress
        }
        try recoverPendingStateIfNeeded(meetingID: meetingID)
    }

    private func recoverPendingStateIfNeeded(meetingID: UUID) throws {
        guard let recovery = pendingRecoveries[meetingID] else { return }
        try restore(recovery, meetingID: meetingID)
    }

    private func restore(
        _ recovery: PendingRecovery,
        meetingID: UUID
    ) throws {
        for _ in 0..<2 {
            do {
                switch recovery {
                case .meetingState(let state):
                    try repository.updateMeetingState(
                        id: meetingID,
                        state: state
                    )
                case .archive(let snapshot):
                    try repository.restoreDocumentArchiveSnapshot(snapshot)
                }
                pendingRecoveries[meetingID] = nil
                return
            } catch {
                continue
            }
        }
        pendingRecoveries[meetingID] = recovery
        throw MeetingDocumentsError.localPersistenceFailed
    }

    private func validatedStableState(
        _ state: RecordingState
    ) throws -> RecordingState {
        switch state {
        case .ready, .summaryReady, .archived:
            return state
        case .summarizing, .archiving:
            throw MeetingDocumentsError.operationInProgress
        default:
            throw MeetingDocumentsError.invalidState(state)
        }
    }

    private func nonemptyCredential(_ key: CredentialKey) throws -> String? {
        guard let value = try credentialStore.value(for: key) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func hasDocument(
        _ meeting: MeetingRecord,
        kind: MeetingDocumentKind
    ) -> Bool {
        switch kind {
        case .summary:
            meeting.summary != nil
        case .detailedMinutes:
            meeting.detailedMinutes != nil
        }
    }

    private static func isValid(_ summary: GeneratedMeetingSummary) -> Bool {
        !summary.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
    }

    private static func isValid(_ minutes: GeneratedDetailedMinutes) -> Bool {
        !minutes.overview.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            && !minutes.sections.isEmpty
            && minutes.sections.allSatisfy {
                !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !$0.content.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        return (error as? URLError)?.code == .cancelled
    }
}

@MainActor
enum MeetingDocumentInputBuilder {
    static func inputs(
        for meeting: MeetingRecord
    ) -> (
        transcripts: [MeetingTranscriptInput],
        bookmarks: [MeetingBookmarkInput],
        userNotes: [MeetingUserNoteInput]
    ) {
        let canonicalTranscripts = TranscriptCorrectionResolver.resolve(
            transcripts: meeting.transcripts.filter(\.isFinal),
            corrections: meeting.transcriptCorrections
        )
        let customSpeakerNames = meeting.speakerDisplayNames
        let transcripts = canonicalTranscripts.compactMap {
            transcript -> MeetingTranscriptInput? in
            guard let text = TranscriptTextSanitizer.nonEmpty(
                transcript.text
            ) else {
                return nil
            }
            return MeetingTranscriptInput(
                startTime: transcript.startTime,
                endTime: transcript.endTime,
                text: text,
                speakerLabel: TranscriptSpeakerLabelPolicy.label(
                    speakerID: transcript.speakerID,
                    source: transcript.source,
                    customNames: customSpeakerNames
                )
            )
        }
        let bookmarks = meeting.bookmarks
            .sorted { $0.timestamp < $1.timestamp }
            .map { bookmark in
                let window = BookmarkWindow(bookmarkTime: bookmark.timestamp)
                let excerpt = transcripts
                    .filter {
                        window.intersects(
                            transcriptStart: $0.startTime,
                            transcriptEnd: $0.endTime
                        )
                    }
                    .map(\.text)
                    .joined(separator: " ")
                return MeetingBookmarkInput(
                    timestamp: bookmark.timestamp,
                    excerpt: excerpt
                )
            }
        let userNotes = meeting.notes
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element
                let right = rhs.element
                if left.timestamp != right.timestamp {
                    return left.timestamp < right.timestamp
                }
                if left.sequenceIndex != right.sequenceIndex {
                    return left.sequenceIndex < right.sequenceIndex
                }
                if left.id != right.id {
                    return left.id.uuidString < right.id.uuidString
                }
                return lhs.offset < rhs.offset
            }
            .compactMap { _, note -> MeetingUserNoteInput? in
                guard let text = TranscriptTextSanitizer.nonEmpty(
                    note.text
                ) else {
                    return nil
                }
                let timestamp = note.timestamp.isFinite
                    ? max(0, note.timestamp)
                    : 0
                return MeetingUserNoteInput(
                    timestamp: timestamp,
                    text: text
                )
            }
        return (transcripts, bookmarks, userNotes)
    }
}

@MainActor
enum MeetingNotionTimelineInputBuilder {
    static func inputs(
        for meeting: MeetingRecord
    ) -> (
        notes: [NotionTimelineNote],
        screenshots: [NotionTimelineScreenshot]
    ) {
        let notes = meeting.notes
            .sorted(by: noteComesBefore)
            .compactMap { note -> NotionTimelineNote? in
                guard let text = TranscriptTextSanitizer.nonEmpty(
                    note.text
                ) else {
                    return nil
                }
                return NotionTimelineNote(
                    id: note.id,
                    timestamp: note.timestamp,
                    text: text,
                    sequenceIndex: note.sequenceIndex
                )
            }
        let screenshots = meeting.screenshots
            .sorted(by: screenshotComesBefore)
            .map {
                NotionTimelineScreenshot(
                    id: $0.id,
                    timestamp: $0.timestamp,
                    sequenceIndex: $0.sequenceIndex
                )
            }
        return (notes, screenshots)
    }

    private static func noteComesBefore(
        _ lhs: MeetingNoteRecord,
        _ rhs: MeetingNoteRecord
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.sequenceIndex != rhs.sequenceIndex {
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func screenshotComesBefore(
        _ lhs: MeetingScreenshotRecord,
        _ rhs: MeetingScreenshotRecord
    ) -> Bool {
        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }
        if lhs.sequenceIndex != rhs.sequenceIndex {
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
