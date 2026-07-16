import Foundation

enum MeetingTitlePolicy {
    static let maximumLength = 1_900

    static func canonicalize(_ title: String) -> String {
        String(
            title.trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(maximumLength)
        )
    }
}

enum MeetingTitleUpdateError: Error, Equatable, Sendable {
    case emptyTitle
    case operationInProgress
    case missingNotionCredential
    case missingNotionPage
    case credentialAccessFailed
    case notion(NotionClientError)
    case localUpdateFailed
    case invalidState(RecordingState)
}

@MainActor
protocol MeetingTitleUpdating: AnyObject {
    func updateTitle(meetingID: UUID, title: String) async throws
}

@MainActor
protocol MeetingTitlePersisting: AnyObject {
    func meeting(id: UUID) throws -> MeetingRecord
    func updateTitle(meetingID: UUID, title: String) throws
}

extension MeetingRepository: MeetingTitlePersisting {}

@MainActor
protocol MeetingNotionTitleUpdating: AnyObject {
    func updatePageTitle(
        token: String,
        pageID: String,
        title: String
    ) async throws
}

@MainActor
final class LiveMeetingNotionTitleUpdater: MeetingNotionTitleUpdating {
    private let httpClient: any HTTPClient

    init(httpClient: any HTTPClient) {
        self.httpClient = httpClient
    }

    func updatePageTitle(
        token: String,
        pageID: String,
        title: String
    ) async throws {
        try await NotionClient(
            token: token,
            httpClient: httpClient
        ).updatePageTitle(pageID: pageID, title: title)
    }
}

@MainActor
final class NoopMeetingNotionTitleUpdater: MeetingNotionTitleUpdating {
    func updatePageTitle(
        token: String,
        pageID: String,
        title: String
    ) async throws {
        _ = token
        _ = pageID
        _ = title
    }
}

@MainActor
final class MeetingTitleUpdateUseCase: MeetingTitleUpdating {
    private let repository: any MeetingTitlePersisting
    private let credentialStore: any CredentialStore
    private let notionTitleUpdater: any MeetingNotionTitleUpdating
    private let operationGate: MeetingOperationGate

    init(
        repository: any MeetingTitlePersisting,
        credentialStore: any CredentialStore,
        notionTitleUpdater: any MeetingNotionTitleUpdating,
        operationGate: MeetingOperationGate
    ) {
        self.repository = repository
        self.credentialStore = credentialStore
        self.notionTitleUpdater = notionTitleUpdater
        self.operationGate = operationGate
    }

    func updateTitle(meetingID: UUID, title: String) async throws {
        guard operationGate.acquire(.rename, for: meetingID) else {
            throw MeetingTitleUpdateError.operationInProgress
        }
        defer { operationGate.release(.rename, for: meetingID) }
        try Task.checkCancellation()

        let canonicalTitle = MeetingTitlePolicy.canonicalize(title)
        guard !canonicalTitle.isEmpty else {
            throw MeetingTitleUpdateError.emptyTitle
        }

        let meeting: MeetingRecord
        do {
            meeting = try repository.meeting(id: meetingID)
        } catch {
            throw MeetingTitleUpdateError.localUpdateFailed
        }
        let previousTitle = meeting.title

        switch meeting.state {
        case .summarizing, .archiving:
            throw MeetingTitleUpdateError.invalidState(meeting.state)
        default:
            break
        }

        guard let pageID = nonempty(meeting.notionPageID) else {
            if meeting.state == .archived {
                throw MeetingTitleUpdateError.missingNotionPage
            }
            try updateLocalTitle(
                meetingID: meetingID,
                title: canonicalTitle
            )
            return
        }
        let token: String
        do {
            guard let storedToken = try credentialStore.value(for: .notionToken),
                  let canonicalToken = nonempty(storedToken) else {
                throw MeetingTitleUpdateError.missingNotionCredential
            }
            token = canonicalToken
        } catch let error as MeetingTitleUpdateError {
            throw error
        } catch {
            throw MeetingTitleUpdateError.credentialAccessFailed
        }

        do {
            try await notionTitleUpdater.updatePageTitle(
                token: token,
                pageID: pageID,
                title: canonicalTitle
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            await restoreNotionTitle(
                token: token,
                pageID: pageID,
                title: previousTitle
            )
            throw CancellationError()
        } catch let error as NotionClientError {
            throw MeetingTitleUpdateError.notion(error)
        } catch {
            throw MeetingTitleUpdateError.notion(.transport)
        }

        let refreshedMeeting: MeetingRecord
        do {
            refreshedMeeting = try repository.meeting(id: meetingID)
        } catch {
            await restoreNotionTitle(
                token: token,
                pageID: pageID,
                title: previousTitle
            )
            throw MeetingTitleUpdateError.localUpdateFailed
        }
        switch refreshedMeeting.state {
        case .summarizing, .archiving:
            await restoreNotionTitle(
                token: token,
                pageID: pageID,
                title: previousTitle
            )
            throw MeetingTitleUpdateError.invalidState(refreshedMeeting.state)
        default:
            break
        }

        do {
            try repository.updateTitle(
                meetingID: meetingID,
                title: canonicalTitle
            )
        } catch {
            await restoreNotionTitle(
                token: token,
                pageID: pageID,
                title: previousTitle
            )
            throw MeetingTitleUpdateError.localUpdateFailed
        }
    }

    private func restoreNotionTitle(
        token: String,
        pageID: String,
        title: String
    ) async {
        let updater = notionTitleUpdater
        await Task { @MainActor in
            try? await updater.updatePageTitle(
                token: token,
                pageID: pageID,
                title: title
            )
        }.value
    }

    private func updateLocalTitle(meetingID: UUID, title: String) throws {
        do {
            try repository.updateTitle(meetingID: meetingID, title: title)
        } catch {
            throw MeetingTitleUpdateError.localUpdateFailed
        }
    }

    private func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
