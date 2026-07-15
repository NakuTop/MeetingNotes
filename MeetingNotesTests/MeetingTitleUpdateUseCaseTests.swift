import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingTitleUpdateUseCaseTests: XCTestCase {
    func testBlankTitleIsRejectedWithoutCredentialRemoteOrLocalWrites() async throws {
        let meeting = makeMeeting(state: .ready)
        let repository = TitleRepositorySpy(meeting: meeting)
        let credentials = TitleCredentialStore(notionToken: "secret")
        let updater = RecordingNotionTitleUpdater()
        let useCase = makeUseCase(
            repository: repository,
            credentials: credentials,
            updater: updater
        )

        do {
            try await useCase.updateTitle(
                meetingID: meeting.id,
                title: "  \n\t "
            )
            XCTFail("Expected an empty-title error")
        } catch {
            XCTAssertEqual(error as? MeetingTitleUpdateError, .emptyTitle)
        }

        XCTAssertEqual(meeting.title, "旧标题")
        XCTAssertEqual(repository.updateTitles, [])
        XCTAssertEqual(credentials.readCount, 0)
        XCTAssertEqual(updater.updates, [])
    }

    func testUnarchivedMeetingUpdatesOnlyLocalTitle() async throws {
        let meeting = makeMeeting(state: .ready)
        let repository = TitleRepositorySpy(meeting: meeting)
        let credentials = TitleCredentialStore(notionToken: nil)
        let updater = RecordingNotionTitleUpdater()
        let useCase = makeUseCase(
            repository: repository,
            credentials: credentials,
            updater: updater
        )

        try await useCase.updateTitle(
            meetingID: meeting.id,
            title: "  本地新标题  "
        )

        XCTAssertEqual(meeting.title, "本地新标题")
        XCTAssertEqual(repository.updateTitles, ["本地新标题"])
        XCTAssertEqual(credentials.readCount, 0)
        XCTAssertEqual(updater.updates, [])
    }

    func testArchivedMeetingUpdatesNotionBeforeLocalPersistence() async throws {
        let recorder = TitleCallRecorder()
        let meeting = makeMeeting(
            state: .archived,
            notionPageID: "notion-page"
        )
        let repository = TitleRepositorySpy(
            meeting: meeting,
            recorder: recorder
        )
        let credentials = TitleCredentialStore(notionToken: "notion-token")
        let updater = RecordingNotionTitleUpdater(recorder: recorder)
        let useCase = makeUseCase(
            repository: repository,
            credentials: credentials,
            updater: updater
        )

        try await useCase.updateTitle(
            meetingID: meeting.id,
            title: "归档新标题"
        )

        XCTAssertEqual(
            recorder.calls,
            ["remote:notion-page:归档新标题", "local:归档新标题"]
        )
        XCTAssertEqual(
            updater.updates,
            [
                .init(
                    token: "notion-token",
                    pageID: "notion-page",
                    title: "归档新标题"
                )
            ]
        )
        XCTAssertEqual(meeting.title, "归档新标题")
    }

    func testSummaryReadyMeetingWithNotionPageUpdatesRemoteBeforeLocal() async throws {
        let recorder = TitleCallRecorder()
        let meeting = makeMeeting(
            state: .summaryReady,
            notionPageID: "  notion-page \n"
        )
        let repository = TitleRepositorySpy(
            meeting: meeting,
            recorder: recorder
        )
        let updater = RecordingNotionTitleUpdater(recorder: recorder)
        let useCase = makeUseCase(
            repository: repository,
            credentials: TitleCredentialStore(notionToken: "notion-token"),
            updater: updater
        )

        try await useCase.updateTitle(
            meetingID: meeting.id,
            title: " \n 阶段复盘 \t "
        )

        XCTAssertEqual(
            recorder.calls,
            ["remote:notion-page:阶段复盘", "local:阶段复盘"]
        )
        XCTAssertEqual(updater.updates.map(\.title), ["阶段复盘"])
        XCTAssertEqual(repository.updateTitles, ["阶段复盘"])
        XCTAssertEqual(meeting.title, "阶段复盘")
    }

    func testBusySummaryAndArchiveStatesRejectRenameWithoutSideEffects() async throws {
        for state in [RecordingState.summarizing, .archiving] {
            let meeting = makeMeeting(
                state: state,
                notionPageID: "notion-page"
            )
            let repository = TitleRepositorySpy(meeting: meeting)
            let credentials = TitleCredentialStore(
                notionToken: "notion-token"
            )
            let updater = RecordingNotionTitleUpdater()
            let useCase = makeUseCase(
                repository: repository,
                credentials: credentials,
                updater: updater
            )

            do {
                try await useCase.updateTitle(
                    meetingID: meeting.id,
                    title: "忙碌期间不允许改名"
                )
                XCTFail("Expected invalid state for \(state)")
            } catch {
                XCTAssertEqual(
                    error as? MeetingTitleUpdateError,
                    .invalidState(state)
                )
            }

            XCTAssertEqual(repository.updateTitles, [])
            XCTAssertEqual(credentials.readCount, 0)
            XCTAssertEqual(updater.updates, [])
            XCTAssertEqual(meeting.title, "旧标题")
        }
    }

    func testNotionFailurePreservesLocalTitleAndSpecificError() async throws {
        let meeting = makeMeeting(
            state: .archived,
            notionPageID: "notion-page"
        )
        let repository = TitleRepositorySpy(meeting: meeting)
        let updater = RecordingNotionTitleUpdater(
            errors: [NotionClientError.forbidden]
        )
        let useCase = makeUseCase(
            repository: repository,
            credentials: TitleCredentialStore(notionToken: "notion-token"),
            updater: updater
        )

        do {
            try await useCase.updateTitle(
                meetingID: meeting.id,
                title: "不应保存"
            )
            XCTFail("Expected a Notion error")
        } catch {
            XCTAssertEqual(
                error as? MeetingTitleUpdateError,
                .notion(.forbidden)
            )
        }

        XCTAssertEqual(meeting.title, "旧标题")
        XCTAssertEqual(repository.updateTitles, [])
    }

    func testRemoteFailureReleasesMeetingSoSameMeetingCanRetry() async throws {
        let meeting = makeMeeting(
            state: .archived,
            notionPageID: "notion-page"
        )
        let repository = TitleRepositorySpy(meeting: meeting)
        let updater = RecordingNotionTitleUpdater(
            errors: [NotionClientError.rateLimited]
        )
        let useCase = makeUseCase(
            repository: repository,
            credentials: TitleCredentialStore(notionToken: "notion-token"),
            updater: updater
        )

        do {
            try await useCase.updateTitle(
                meetingID: meeting.id,
                title: "第一次失败"
            )
            XCTFail("Expected a rate-limit error")
        } catch {
            XCTAssertEqual(
                error as? MeetingTitleUpdateError,
                .notion(.rateLimited)
            )
        }

        try await useCase.updateTitle(
            meetingID: meeting.id,
            title: "重试成功"
        )

        XCTAssertEqual(
            updater.updates.map(\.title),
            ["第一次失败", "重试成功"]
        )
        XCTAssertEqual(repository.updateTitles, ["重试成功"])
        XCTAssertEqual(meeting.title, "重试成功")
    }

    func testArchivedMeetingWithoutTokenDoesNotRenameLocally() async throws {
        let meeting = makeMeeting(
            state: .archived,
            notionPageID: "notion-page"
        )
        let repository = TitleRepositorySpy(meeting: meeting)
        let updater = RecordingNotionTitleUpdater()
        let useCase = makeUseCase(
            repository: repository,
            credentials: TitleCredentialStore(notionToken: " \n "),
            updater: updater
        )

        do {
            try await useCase.updateTitle(
                meetingID: meeting.id,
                title: "不应保存"
            )
            XCTFail("Expected a missing-credential error")
        } catch {
            XCTAssertEqual(
                error as? MeetingTitleUpdateError,
                .missingNotionCredential
            )
        }

        XCTAssertEqual(repository.updateTitles, [])
        XCTAssertEqual(updater.updates, [])
        XCTAssertEqual(meeting.title, "旧标题")
    }

    func testArchivedMeetingWithoutPageIDDoesNotRenameLocally() async throws {
        let meeting = makeMeeting(state: .archived, notionPageID: " \n ")
        let repository = TitleRepositorySpy(meeting: meeting)
        let updater = RecordingNotionTitleUpdater()
        let useCase = makeUseCase(
            repository: repository,
            credentials: TitleCredentialStore(notionToken: "notion-token"),
            updater: updater
        )

        do {
            try await useCase.updateTitle(
                meetingID: meeting.id,
                title: "不应保存"
            )
            XCTFail("Expected a missing-page error")
        } catch {
            XCTAssertEqual(error as? MeetingTitleUpdateError, .missingNotionPage)
        }

        XCTAssertEqual(repository.updateTitles, [])
        XCTAssertEqual(updater.updates, [])
        XCTAssertEqual(meeting.title, "旧标题")
    }

    func testLocalFailureCompensatesNotionOnceWithOldTitle() async throws {
        let recorder = TitleCallRecorder()
        let meeting = makeMeeting(
            state: .archived,
            notionPageID: "notion-page"
        )
        let originalTitle = meeting.title
        let originalUpdatedAt = meeting.updatedAt
        let repository = TitleRepositorySpy(
            meeting: meeting,
            recorder: recorder,
            updateError: TitleRepositorySpy.Failure.save
        )
        let updater = RecordingNotionTitleUpdater(recorder: recorder)
        let useCase = makeUseCase(
            repository: repository,
            credentials: TitleCredentialStore(notionToken: "notion-token"),
            updater: updater
        )

        do {
            try await useCase.updateTitle(
                meetingID: meeting.id,
                title: "远程已成功"
            )
            XCTFail("Expected a local-persistence error")
        } catch {
            XCTAssertEqual(error as? MeetingTitleUpdateError, .localUpdateFailed)
        }

        XCTAssertEqual(
            recorder.calls,
            [
                "remote:notion-page:远程已成功",
                "local:远程已成功",
                "remote:notion-page:旧标题"
            ]
        )
        XCTAssertEqual(meeting.title, originalTitle)
        XCTAssertEqual(meeting.updatedAt, originalUpdatedAt)
        XCTAssertEqual(updater.updates.map(\.title), ["远程已成功", "旧标题"])
        XCTAssertEqual(meeting.title, "旧标题")
    }

    func testCompensationUsesCapturedOldTitleIfLocalObjectMutatesBeforeFailure() async throws {
        let recorder = TitleCallRecorder()
        let meeting = makeMeeting(
            state: .archived,
            notionPageID: "notion-page"
        )
        let originalTitle = meeting.title
        let originalUpdatedAt = meeting.updatedAt
        let repository = TitleRepositorySpy(
            meeting: meeting,
            recorder: recorder,
            updateError: TitleRepositorySpy.Failure.save,
            mutateBeforeFailure: true
        )
        let updater = RecordingNotionTitleUpdater(recorder: recorder)
        let useCase = makeUseCase(
            repository: repository,
            credentials: TitleCredentialStore(notionToken: "notion-token"),
            updater: updater
        )

        do {
            try await useCase.updateTitle(
                meetingID: meeting.id,
                title: "对象内已变更"
            )
            XCTFail("Expected a local-persistence error")
        } catch {
            XCTAssertEqual(error as? MeetingTitleUpdateError, .localUpdateFailed)
        }

        XCTAssertEqual(
            recorder.calls,
            [
                "remote:notion-page:对象内已变更",
                "local:对象内已变更",
                "remote:notion-page:旧标题"
            ]
        )
        XCTAssertEqual(meeting.title, originalTitle)
        XCTAssertEqual(meeting.updatedAt, originalUpdatedAt)
    }

    func testCompensationFailureStillReportsLocalUpdateFailure() async throws {
        let meeting = makeMeeting(
            state: .archived,
            notionPageID: "notion-page"
        )
        let repository = TitleRepositorySpy(
            meeting: meeting,
            updateError: TitleRepositorySpy.Failure.save
        )
        let updater = CompensationFailingNotionTitleUpdater()
        let useCase = makeUseCase(
            repository: repository,
            credentials: TitleCredentialStore(notionToken: "notion-token"),
            updater: updater
        )

        do {
            try await useCase.updateTitle(
                meetingID: meeting.id,
                title: "新标题"
            )
            XCTFail("Expected a local-update error")
        } catch {
            XCTAssertEqual(error as? MeetingTitleUpdateError, .localUpdateFailed)
        }

        XCTAssertEqual(updater.titles, ["新标题", "旧标题"])
        XCTAssertEqual(repository.updateTitles, ["新标题"])
        XCTAssertEqual(meeting.title, "旧标题")
    }

    func testConcurrentRenameOfSameMeetingIsRejected() async throws {
        let meeting = makeMeeting(
            state: .archived,
            notionPageID: "notion-page"
        )
        let repository = TitleRepositorySpy(meeting: meeting)
        let remoteStarted = expectation(description: "remote update started")
        let updater = BlockingNotionTitleUpdater(
            startedExpectation: remoteStarted
        )
        let useCase = makeUseCase(
            repository: repository,
            credentials: TitleCredentialStore(notionToken: "notion-token"),
            updater: updater
        )

        let first = Task { @MainActor in
            try await useCase.updateTitle(
                meetingID: meeting.id,
                title: "第一个标题"
            )
        }
        await fulfillment(of: [remoteStarted], timeout: 1)

        do {
            try await useCase.updateTitle(
                meetingID: meeting.id,
                title: "第二个标题"
            )
            XCTFail("Expected an in-progress error")
        } catch {
            XCTAssertEqual(
                error as? MeetingTitleUpdateError,
                .operationInProgress
            )
        }

        updater.resume()
        try await first.value
        XCTAssertEqual(meeting.title, "第一个标题")
        XCTAssertEqual(repository.updateTitles, ["第一个标题"])
    }

    func testCanonicalTitleIsTrimmedAndLimitedIdenticallyRemotelyAndLocally() async throws {
        let meeting = makeMeeting(
            state: .archived,
            notionPageID: "notion-page"
        )
        let repository = TitleRepositorySpy(meeting: meeting)
        let updater = RecordingNotionTitleUpdater()
        let useCase = makeUseCase(
            repository: repository,
            credentials: TitleCredentialStore(notionToken: "notion-token"),
            updater: updater
        )
        let rawTitle = "  " + String(repeating: "长", count: 1_905) + " \n"
        let expected = String(repeating: "长", count: 1_900)

        try await useCase.updateTitle(
            meetingID: meeting.id,
            title: rawTitle
        )

        XCTAssertEqual(updater.updates.map(\.title), [expected])
        XCTAssertEqual(repository.updateTitles, [expected])
        XCTAssertEqual(meeting.title, expected)
    }

    private func makeUseCase(
        repository: TitleRepositorySpy,
        credentials: TitleCredentialStore,
        updater: any MeetingNotionTitleUpdating
    ) -> MeetingTitleUpdateUseCase {
        MeetingTitleUpdateUseCase(
            repository: repository,
            credentialStore: credentials,
            notionTitleUpdater: updater
        )
    }

    private func makeMeeting(
        state: RecordingState,
        notionPageID: String? = nil
    ) -> MeetingRecord {
        MeetingRecord(
            title: "旧标题",
            mode: .offline,
            state: state,
            startedAt: Date(timeIntervalSince1970: 100),
            notionPageID: notionPageID
        )
    }
}

@MainActor
private final class TitleCallRecorder {
    var calls: [String] = []
}

@MainActor
private final class TitleRepositorySpy: MeetingTitlePersisting {
    enum Failure: Error {
        case save
    }

    let meetingRecord: MeetingRecord
    private let recorder: TitleCallRecorder?
    private let updateError: Error?
    private let mutateBeforeFailure: Bool
    private(set) var updateTitles: [String] = []

    init(
        meeting: MeetingRecord,
        recorder: TitleCallRecorder? = nil,
        updateError: Error? = nil,
        mutateBeforeFailure: Bool = false
    ) {
        meetingRecord = meeting
        self.recorder = recorder
        self.updateError = updateError
        self.mutateBeforeFailure = mutateBeforeFailure
    }

    func meeting(id: UUID) throws -> MeetingRecord {
        guard id == meetingRecord.id else {
            throw MeetingRepositoryError.meetingNotFound(id)
        }
        return meetingRecord
    }

    func updateTitle(meetingID: UUID, title: String) throws {
        guard meetingID == meetingRecord.id else {
            throw MeetingRepositoryError.meetingNotFound(meetingID)
        }
        updateTitles.append(title)
        recorder?.calls.append("local:\(title)")
        if let updateError {
            let previousTitle = meetingRecord.title
            let previousUpdatedAt = meetingRecord.updatedAt
            if mutateBeforeFailure {
                meetingRecord.title = title
                meetingRecord.updatedAt = .distantFuture
            }
            meetingRecord.title = previousTitle
            meetingRecord.updatedAt = previousUpdatedAt
            throw updateError
        }
        meetingRecord.title = title
        meetingRecord.updatedAt = .now
    }
}

private final class TitleCredentialStore: CredentialStore, @unchecked Sendable {
    private let notionToken: String?
    private(set) var readCount = 0

    init(notionToken: String?) {
        self.notionToken = notionToken
    }

    func value(for key: CredentialKey) throws -> String? {
        readCount += 1
        return key == .notionToken ? notionToken : nil
    }

    func save(_ value: String, for key: CredentialKey) throws {
        _ = value
        _ = key
    }

    func delete(_ key: CredentialKey) throws {
        _ = key
    }
}

@MainActor
private final class RecordingNotionTitleUpdater: MeetingNotionTitleUpdating {
    struct Update: Equatable {
        let token: String
        let pageID: String
        let title: String
    }

    private let recorder: TitleCallRecorder?
    private var errors: [Error]
    private(set) var updates: [Update] = []

    init(
        recorder: TitleCallRecorder? = nil,
        errors: [Error] = []
    ) {
        self.recorder = recorder
        self.errors = errors
    }

    func updatePageTitle(
        token: String,
        pageID: String,
        title: String
    ) async throws {
        updates.append(.init(token: token, pageID: pageID, title: title))
        recorder?.calls.append("remote:\(pageID):\(title)")
        if !errors.isEmpty {
            throw errors.removeFirst()
        }
    }
}

@MainActor
private final class CompensationFailingNotionTitleUpdater:
    MeetingNotionTitleUpdating {
    private(set) var titles: [String] = []

    func updatePageTitle(
        token: String,
        pageID: String,
        title: String
    ) async throws {
        _ = token
        _ = pageID
        titles.append(title)
        if titles.count == 2 {
            throw NotionClientError.rateLimited
        }
    }
}

@MainActor
private final class BlockingNotionTitleUpdater: MeetingNotionTitleUpdating {
    private let startedExpectation: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?

    init(startedExpectation: XCTestExpectation) {
        self.startedExpectation = startedExpectation
    }

    func updatePageTitle(
        token: String,
        pageID: String,
        title: String
    ) async throws {
        _ = token
        _ = pageID
        _ = title
        startedExpectation.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
