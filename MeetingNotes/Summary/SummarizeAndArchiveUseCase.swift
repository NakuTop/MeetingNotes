import Foundation

enum SummarizeAndArchiveError: Error, Equatable, Sendable {
    case noFinalTranscript
    case missingDeepSeekCredential
    case missingNotionCredential
    case invalidNotionPageURL
    case missingLocalSummary
    case summaryFailed
    case archiveFailed
    case localPersistenceFailed
    case operationInProgress
    case invalidState(RecordingState)
}

protocol MeetingSummaryGenerating: Sendable {
    func summarize(
        apiKey: String,
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedMeetingSummary
}

struct LiveMeetingSummaryGenerator: MeetingSummaryGenerating {
    let httpClient: any HTTPClient

    func summarize(
        apiKey: String,
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedMeetingSummary {
        try await DeepSeekClient(
            apiKey: apiKey,
            httpClient: httpClient
        ).summarize(input: input, model: model)
    }
}

@MainActor
protocol MeetingNotionArchiving: AnyObject {
    func archive(
        token: String,
        meetingID: UUID,
        parentPageID: UUID,
        content: NotionMeetingPageContent
    ) async throws -> NotionPageReference
}

@MainActor
final class LiveMeetingNotionArchiver: MeetingNotionArchiving {
    private let repository: MeetingRepository
    private let httpClient: any HTTPClient

    init(repository: MeetingRepository, httpClient: any HTTPClient) {
        self.repository = repository
        self.httpClient = httpClient
    }

    func archive(
        token: String,
        meetingID: UUID,
        parentPageID: UUID,
        content: NotionMeetingPageContent
    ) async throws -> NotionPageReference {
        try await NotionArchiveService(
            repository: repository,
            client: NotionClient(token: token, httpClient: httpClient)
        ).archive(
            meetingID: meetingID,
            parentPageID: parentPageID,
            content: content
        )
    }
}

@MainActor
protocol SummarizeAndArchiving: AnyObject {
    func execute(meetingID: UUID) async throws
    func execute(
        meetingID: UUID,
        onProgress: @escaping (RecordingState) -> Void
    ) async throws
}

extension SummarizeAndArchiving {
    func execute(
        meetingID: UUID,
        onProgress: @escaping (RecordingState) -> Void
    ) async throws {
        _ = onProgress
        try await execute(meetingID: meetingID)
    }
}

@MainActor
final class SummarizeAndArchiveUseCase: SummarizeAndArchiving {
    private let repository: MeetingRepository
    private let credentialStore: any CredentialStore
    private let settingsStore: AppSettingsStore
    private let summaryGenerator: any MeetingSummaryGenerating
    private let notionArchiver: any MeetingNotionArchiving
    private var processingMeetingIDs: Set<UUID> = []

    init(
        repository: MeetingRepository,
        credentialStore: any CredentialStore,
        settingsStore: AppSettingsStore,
        summaryGenerator: any MeetingSummaryGenerating,
        notionArchiver: any MeetingNotionArchiving
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.settingsStore = settingsStore
        self.summaryGenerator = summaryGenerator
        self.notionArchiver = notionArchiver
    }

    func execute(meetingID: UUID) async throws {
        try await execute(meetingID: meetingID) { _ in }
    }

    func execute(
        meetingID: UUID,
        onProgress: @escaping (RecordingState) -> Void
    ) async throws {
        guard processingMeetingIDs.insert(meetingID).inserted else {
            throw SummarizeAndArchiveError.operationInProgress
        }
        defer { processingMeetingIDs.remove(meetingID) }

        let meeting = try repository.meeting(id: meetingID)
        switch meeting.state {
        case .archived:
            onProgress(.archived)
            return
        case .summarizing, .archiving:
            throw SummarizeAndArchiveError.operationInProgress
        case .summaryReady:
            onProgress(.summaryReady)
            try await archiveExistingSummary(
                meetingID: meetingID,
                onProgress: onProgress
            )
        case .ready:
            if meeting.summary == nil {
                try await generateSummary(
                    meetingID: meetingID,
                    onProgress: onProgress
                )
            } else {
                try repository.updateMeetingState(
                    id: meetingID,
                    state: .summaryReady
                )
                onProgress(.summaryReady)
            }
            try await archiveExistingSummary(
                meetingID: meetingID,
                onProgress: onProgress
            )
        default:
            throw SummarizeAndArchiveError.invalidState(meeting.state)
        }
    }

    private func generateSummary(
        meetingID: UUID,
        onProgress: (RecordingState) -> Void
    ) async throws {
        let meeting = try repository.meeting(id: meetingID)
        let content = contentInputs(for: meeting)
        guard !content.transcripts.isEmpty else {
            throw SummarizeAndArchiveError.noFinalTranscript
        }
        guard let apiKey = try nonemptyCredential(.deepSeekAPIKey) else {
            throw SummarizeAndArchiveError.missingDeepSeekCredential
        }

        try repository.updateMeetingState(id: meetingID, state: .summarizing)
        onProgress(.summarizing)
        let generated: GeneratedMeetingSummary
        do {
            generated = try await summaryGenerator.summarize(
                apiKey: apiKey,
                input: MeetingSummaryInput(
                    title: meeting.title,
                    transcripts: content.transcripts,
                    bookmarks: content.bookmarks
                ),
                model: settingsStore.deepSeekModel
            )
        } catch {
            try? repository.updateMeetingState(id: meetingID, state: .ready)
            onProgress(.ready)
            throw SummarizeAndArchiveError.summaryFailed
        }

        do {
            try repository.saveSummary(
                meetingID: meetingID,
                overview: generated.overview,
                keyPoints: generated.keyPoints,
                decisions: generated.decisions,
                structuredActionItems: generated.actionItems,
                bookmarkInsights: generated.bookmarkInsights,
                model: settingsStore.deepSeekModel
            )
            try repository.applySuggestedTitle(
                meetingID: meetingID,
                suggestedTitle: generated.suggestedTitle
            )
            try repository.updateMeetingState(
                id: meetingID,
                state: .summaryReady
            )
            onProgress(.summaryReady)
        } catch {
            try? repository.updateMeetingState(id: meetingID, state: .ready)
            onProgress(.ready)
            throw SummarizeAndArchiveError.localPersistenceFailed
        }
    }

    private func archiveExistingSummary(
        meetingID: UUID,
        onProgress: (RecordingState) -> Void
    ) async throws {
        guard let notionToken = try nonemptyCredential(.notionToken) else {
            throw SummarizeAndArchiveError.missingNotionCredential
        }
        guard let parentPageID = NotionPageLinkParser.parse(
            settingsStore.notionParentPageURL
        ) else {
            throw SummarizeAndArchiveError.invalidNotionPageURL
        }

        let meeting = try repository.meeting(id: meetingID)
        guard let localSummary = meeting.summary else {
            throw SummarizeAndArchiveError.missingLocalSummary
        }
        let content = contentInputs(for: meeting)
        let generatedSummary = GeneratedMeetingSummary(
            suggestedTitle: meeting.suggestedTitle ?? meeting.title,
            overview: localSummary.overview,
            keyPoints: localSummary.keyPoints,
            decisions: localSummary.decisions,
            actionItems: localSummary.actionItemRecords,
            bookmarkInsights: localSummary.bookmarkInsights
        )
        let pageContent = NotionMeetingPageContent(
            title: meeting.title,
            startedAt: meeting.startedAt,
            duration: meeting.activeDuration,
            mode: meeting.mode,
            summary: generatedSummary,
            bookmarks: content.bookmarks,
            transcripts: content.transcripts
        )

        try repository.updateMeetingState(id: meetingID, state: .archiving)
        onProgress(.archiving)
        do {
            _ = try await notionArchiver.archive(
                token: notionToken,
                meetingID: meetingID,
                parentPageID: parentPageID,
                content: pageContent
            )
            try repository.updateMeetingState(id: meetingID, state: .archived)
            onProgress(.archived)
        } catch {
            try? repository.updateMeetingState(
                id: meetingID,
                state: .summaryReady
            )
            onProgress(.summaryReady)
            throw SummarizeAndArchiveError.archiveFailed
        }
    }

    private func contentInputs(
        for meeting: MeetingRecord
    ) -> (
        transcripts: [MeetingTranscriptInput],
        bookmarks: [MeetingBookmarkInput]
    ) {
        let finalTranscripts = meeting.transcripts
            .filter {
                $0.isFinal
                    && !$0.text.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
            }
            .sorted {
                if $0.startTime == $1.startTime {
                    return $0.endTime < $1.endTime
                }
                return $0.startTime < $1.startTime
            }
        let transcripts = finalTranscripts.map {
            MeetingTranscriptInput(
                startTime: $0.startTime,
                endTime: $0.endTime,
                text: $0.text
            )
        }
        let bookmarks = meeting.bookmarks
            .sorted { $0.timestamp < $1.timestamp }
            .map { bookmark in
                let window = BookmarkWindow(bookmarkTime: bookmark.timestamp)
                let excerpt = finalTranscripts
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
        return (transcripts, bookmarks)
    }

    private func nonemptyCredential(
        _ key: CredentialKey
    ) throws -> String? {
        guard let value = try credentialStore.value(for: key) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
