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
    private let operationGate: MeetingOperationGate
    private let documentsUseCase: MeetingDocumentsUseCase

    init(
        repository: MeetingRepository,
        credentialStore: any CredentialStore,
        settingsStore: AppSettingsStore,
        summaryGenerator: any MeetingSummaryGenerating,
        notionArchiver: any MeetingNotionArchiving,
        operationGate: MeetingOperationGate,
        documentsUseCase: MeetingDocumentsUseCase? = nil
    ) {
        self.repository = repository
        self.operationGate = operationGate
        self.documentsUseCase = documentsUseCase
            ?? MeetingDocumentsUseCase(
                repository: repository,
                credentialStore: credentialStore,
                settingsStore: settingsStore,
                summaryGenerator: summaryGenerator,
                detailedMinutesGenerator:
                    LiveMeetingDetailedMinutesGenerator(
                        httpClient: URLSessionHTTPClient()
                    ),
                archiver: LegacyMeetingDocumentNotionArchiver(
                    repository: repository,
                    archiver: notionArchiver
                ),
                operationGate: operationGate
            )
    }

    func execute(meetingID: UUID) async throws {
        try await execute(meetingID: meetingID) { _ in }
    }

    func execute(
        meetingID: UUID,
        onProgress: @escaping (RecordingState) -> Void
    ) async throws {
        let meeting = try repository.meeting(id: meetingID)
        switch meeting.state {
        case .archived:
            onProgress(.archived)
            return
        case .summarizing, .archiving:
            throw SummarizeAndArchiveError.operationInProgress
        case .summaryReady:
            onProgress(.summaryReady)
            return
        case .ready:
            if meeting.summary != nil {
                onProgress(.summaryReady)
                guard operationGate.acquire(
                    .summarizeArchive,
                    for: meetingID
                ) else {
                    throw SummarizeAndArchiveError.operationInProgress
                }
                defer {
                    operationGate.release(
                        .summarizeArchive,
                        for: meetingID
                    )
                }
                do {
                    try repository.updateMeetingState(
                        id: meetingID,
                        state: .summaryReady
                    )
                } catch {
                    throw SummarizeAndArchiveError.localPersistenceFailed
                }
                return
            }
            onProgress(.summarizing)
            do {
                try await documentsUseCase.generate(
                    meetingID: meetingID,
                    kind: .summary
                )
                onProgress(
                    try repository.meeting(id: meetingID).state
                )
            } catch {
                onProgress(
                    (try? repository.meeting(id: meetingID).state) ?? .ready
                )
                throw Self.legacyError(error)
            }
        default:
            throw SummarizeAndArchiveError.invalidState(meeting.state)
        }
    }

    private static func legacyError(_ error: Error) -> Error {
        guard let error = error as? MeetingDocumentsError else {
            return error
        }
        return switch error {
        case .noFinalTranscript:
            SummarizeAndArchiveError.noFinalTranscript
        case .missingDeepSeekCredential:
            SummarizeAndArchiveError.missingDeepSeekCredential
        case .missingNotionCredential:
            SummarizeAndArchiveError.missingNotionCredential
        case .invalidNotionPageURL:
            SummarizeAndArchiveError.invalidNotionPageURL
        case .missingLocalDocument:
            SummarizeAndArchiveError.missingLocalSummary
        case .invalidGeneratedDocument, .generationFailed:
            SummarizeAndArchiveError.summaryFailed
        case .archiveFailed:
            SummarizeAndArchiveError.archiveFailed
        case .localPersistenceFailed:
            SummarizeAndArchiveError.localPersistenceFailed
        case .operationInProgress:
            SummarizeAndArchiveError.operationInProgress
        case .invalidState(let state):
            SummarizeAndArchiveError.invalidState(state)
        }
    }

}
