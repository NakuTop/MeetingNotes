import Foundation
import XCTest
@testable import MeetingNotes

@MainActor
final class SummarizeAndArchiveUseCaseTests: XCTestCase {
    func testRejectsMeetingWithoutFinalTranscriptBeforeCallingServices() async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.makeReadyMeeting()
        try fixture.repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 2,
            text: "临时结果",
            isFinal: false
        )

        await XCTAssertThrowsErrorAsync(
            try await fixture.useCase.execute(meetingID: meetingID)
        ) { error in
            XCTAssertEqual(
                error as? SummarizeAndArchiveError,
                .noFinalTranscript
            )
        }

        let generatorCalls = await fixture.generator.callCount()
        XCTAssertEqual(generatorCalls, 0)
        XCTAssertEqual(fixture.archiver.callCount, 0)
        XCTAssertEqual(try fixture.repository.meeting(id: meetingID).state, .ready)
    }

    func testSavesSummaryBeforeNotionAndAppliesSuggestedTitleToDefaultOnly() async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.makeReadyMeeting()
        try fixture.addFinalTranscript(to: meetingID)

        try await fixture.useCase.execute(meetingID: meetingID)

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.title, "项目启动会")
        XCTAssertEqual(meeting.suggestedTitle, "项目启动会")
        XCTAssertEqual(meeting.summary?.overview, "确认启动计划")
        XCTAssertEqual(meeting.summary?.actionItemRecords, [
            ActionItem(task: "准备排期", owner: "小王", dueDate: "周五")
        ])
        XCTAssertEqual(meeting.state, .archived)
        XCTAssertTrue(fixture.archiver.observedLocalSummaryBeforeArchive)
    }

    func testSuggestedTitleDoesNotOverwriteUserEditedTitle() async throws {
        let fixture = try makeFixture()
        let meetingID = try fixture.makeReadyMeeting(title: "我的自定义标题")
        try fixture.addFinalTranscript(to: meetingID)

        try await fixture.useCase.execute(meetingID: meetingID)

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.title, "我的自定义标题")
        XCTAssertEqual(meeting.suggestedTitle, "项目启动会")
        XCTAssertEqual(fixture.archiver.archivedTitles, ["我的自定义标题"])
    }

    func testDeepSeekFailureRestoresReadyAndNeverCallsNotion() async throws {
        let fixture = try makeFixture(
            generatorResult: .failure(DeepSeekClientError.unauthorized)
        )
        let meetingID = try fixture.makeReadyMeeting()
        try fixture.addFinalTranscript(to: meetingID)

        await XCTAssertThrowsErrorAsync(
            try await fixture.useCase.execute(meetingID: meetingID)
        ) { error in
            XCTAssertEqual(
                error as? SummarizeAndArchiveError,
                .summaryFailed
            )
        }

        let meeting = try fixture.repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.state, .ready)
        XCTAssertNil(meeting.summary)
        XCTAssertEqual(fixture.archiver.callCount, 0)
    }

    func testNotionFailureKeepsSummaryReadyAndRetryDoesNotCallDeepSeekAgain() async throws {
        let fixture = try makeFixture(
            archiveResults: [
                .failure(NotionClientError.rateLimited),
                .success(
                    NotionPageReference(
                        id: "page-id",
                        url: "https://www.notion.so/page-id"
                    )
                )
            ]
        )
        let meetingID = try fixture.makeReadyMeeting()
        try fixture.addFinalTranscript(to: meetingID)

        await XCTAssertThrowsErrorAsync(
            try await fixture.useCase.execute(meetingID: meetingID)
        ) { error in
            XCTAssertEqual(
                error as? SummarizeAndArchiveError,
                .archiveFailed
            )
        }

        XCTAssertEqual(
            try fixture.repository.meeting(id: meetingID).state,
            .summaryReady
        )
        let callsAfterFailure = await fixture.generator.callCount()
        XCTAssertEqual(callsAfterFailure, 1)

        try await fixture.useCase.execute(meetingID: meetingID)

        let callsAfterRetry = await fixture.generator.callCount()
        XCTAssertEqual(callsAfterRetry, 1)
        XCTAssertEqual(fixture.archiver.callCount, 2)
        XCTAssertEqual(
            try fixture.repository.meeting(id: meetingID).state,
            .archived
        )
    }

    func testConcurrentExecutionForSameMeetingIsRejected() async throws {
        let blockingGenerator = BlockingSummaryGenerator()
        let fixture = try makeFixture(generator: blockingGenerator)
        let meetingID = try fixture.makeReadyMeeting()
        try fixture.addFinalTranscript(to: meetingID)

        let first = Task {
            try await fixture.useCase.execute(meetingID: meetingID)
        }
        await blockingGenerator.waitUntilStarted()

        await XCTAssertThrowsErrorAsync(
            try await fixture.useCase.execute(meetingID: meetingID)
        ) { error in
            XCTAssertEqual(
                error as? SummarizeAndArchiveError,
                .operationInProgress
            )
        }

        await blockingGenerator.finish(with: Self.summary)
        try await first.value
        let generatorCalls = await blockingGenerator.callCount()
        XCTAssertEqual(generatorCalls, 1)
    }

    private func makeFixture(
        generatorResult: Result<GeneratedMeetingSummary, Error>? = nil,
        archiveResults: [Result<NotionPageReference, Error>] = [
            .success(
                NotionPageReference(
                    id: "page-id",
                    url: "https://www.notion.so/page-id"
                )
            )
        ],
        generator: (any MeetingSummaryGenerating)? = nil
    ) throws -> Fixture {
        let repository = try MeetingRepository.inMemory()
        let credentials = UseCaseCredentialStore()
        try credentials.save("deepseek-key", for: .deepSeekAPIKey)
        try credentials.save("notion-token", for: .notionToken)
        let suiteName = "SummarizeAndArchiveTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let settings = AppSettingsStore(defaults: defaults)
        settings.deepSeekModel = "deepseek-chat"
        settings.notionParentPageURL =
            "https://www.notion.so/Parent-1234567890abcdef1234567890abcdef"
        let generatorSpy = SummaryGeneratorSpy(
            result: generatorResult ?? .success(Self.summary)
        )
        let selectedGenerator = generator ?? generatorSpy
        let archiver = NotionArchiverSpy(
            repository: repository,
            results: archiveResults
        )
        let useCase = SummarizeAndArchiveUseCase(
            repository: repository,
            credentialStore: credentials,
            settingsStore: settings,
            summaryGenerator: selectedGenerator,
            notionArchiver: archiver
        )
        return Fixture(
            repository: repository,
            generator: generatorSpy,
            archiver: archiver,
            useCase: useCase
        )
    }

    private static let summary = GeneratedMeetingSummary(
        suggestedTitle: "项目启动会",
        overview: "确认启动计划",
        keyPoints: ["下周启动"],
        decisions: ["按计划执行"],
        actionItems: [
            ActionItem(task: "准备排期", owner: "小王", dueDate: "周五")
        ],
        bookmarkInsights: ["核心决定"]
    )

    @MainActor
    private struct Fixture {
        let repository: MeetingRepository
        let generator: SummaryGeneratorSpy
        let archiver: NotionArchiverSpy
        let useCase: SummarizeAndArchiveUseCase

        func makeReadyMeeting(title: String = "未命名会议") throws -> UUID {
            let id = try repository.createMeeting(
                mode: .offline,
                startedAt: Date(timeIntervalSince1970: 1_000),
                title: title
            )
            try repository.finalizeMeeting(
                id: id,
                endedAt: Date(timeIntervalSince1970: 1_120),
                activeDuration: 120
            )
            return id
        }

        func addFinalTranscript(to meetingID: UUID) throws {
            try repository.appendTranscript(
                meetingID: meetingID,
                start: 0,
                end: 5,
                text: "确认下周启动",
                isFinal: true
            )
            try repository.appendBookmark(
                meetingID: meetingID,
                timestamp: 3
            )
        }
    }
}

private final class UseCaseCredentialStore: CredentialStore, @unchecked Sendable {
    private var values: [CredentialKey: String] = [:]

    func value(for key: CredentialKey) throws -> String? { values[key] }
    func save(_ value: String, for key: CredentialKey) throws {
        values[key] = value
    }
    func delete(_ key: CredentialKey) throws { values[key] = nil }
}

private actor SummaryGeneratorSpy: MeetingSummaryGenerating {
    private let result: Result<GeneratedMeetingSummary, Error>
    private var calls = 0

    init(result: Result<GeneratedMeetingSummary, Error>) {
        self.result = result
    }

    func summarize(
        apiKey: String,
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedMeetingSummary {
        _ = apiKey
        _ = input
        _ = model
        calls += 1
        return try result.get()
    }

    func callCount() -> Int { calls }
}

@MainActor
private final class NotionArchiverSpy: MeetingNotionArchiving {
    private let repository: MeetingRepository
    private var results: [Result<NotionPageReference, Error>]
    private(set) var callCount = 0
    private(set) var observedLocalSummaryBeforeArchive = false
    private(set) var archivedTitles: [String] = []

    init(
        repository: MeetingRepository,
        results: [Result<NotionPageReference, Error>]
    ) {
        self.repository = repository
        self.results = results
    }

    func archive(
        token: String,
        meetingID: UUID,
        parentPageID: UUID,
        content: NotionMeetingPageContent
    ) async throws -> NotionPageReference {
        _ = token
        _ = parentPageID
        callCount += 1
        archivedTitles.append(content.title)
        let meeting = try repository.meeting(id: meetingID)
        observedLocalSummaryBeforeArchive = meeting.summary != nil
        guard !results.isEmpty else {
            throw NotionClientError.transport
        }
        let result = results.removeFirst()
        let page = try result.get()
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: page.id,
            pageURL: page.url
        )
        return page
    }
}

private actor BlockingSummaryGenerator: MeetingSummaryGenerating {
    private var calls = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation:
        CheckedContinuation<GeneratedMeetingSummary, Error>?

    func summarize(
        apiKey: String,
        input: MeetingSummaryInput,
        model: String
    ) async throws -> GeneratedMeetingSummary {
        _ = apiKey
        _ = input
        _ = model
        calls += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return try await withCheckedThrowingContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish(with summary: GeneratedMeetingSummary) {
        resultContinuation?.resume(returning: summary)
        resultContinuation = nil
    }

    func callCount() -> Int { calls }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
