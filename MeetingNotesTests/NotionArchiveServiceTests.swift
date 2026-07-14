import XCTest
@testable import MeetingNotes

@MainActor
final class NotionArchiveServiceTests: XCTestCase {
    func testFailureCheckpointsAndRetryContinuesSamePageWithoutDuplicateConfirmedBatches() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1_000),
            title: "产品周会"
        )
        let blockBuilder = NotionBlockBuilder(maximumBlocksPerBatch: 2)
        let content = makeContent()
        let expectedBatches = blockBuilder.batches(for: content)
        XCTAssertGreaterThan(expectedBatches.count, 2)
        let client = RecordingNotionAPIClient(failOnAppendAttempt: 1)
        let service = NotionArchiveService(
            repository: repository,
            client: client,
            blockBuilder: blockBuilder
        )

        do {
            _ = try await service.archive(
                meetingID: meetingID,
                parentPageID: UUID(),
                content: content
            )
            XCTFail("Expected simulated second-batch failure")
        } catch {
            XCTAssertEqual(error as? NotionClientError, .rateLimited)
        }

        let interruptedMeeting = try repository.meeting(id: meetingID)
        XCTAssertEqual(interruptedMeeting.notionPageID, "created-page-id")
        XCTAssertEqual(
            interruptedMeeting.notionPageURL,
            "https://www.notion.so/created-page-id"
        )
        let interruptedCheckpoint = try XCTUnwrap(
            interruptedMeeting.archiveCheckpoint
        )
        XCTAssertEqual(interruptedCheckpoint.notionPageID, "created-page-id")
        XCTAssertEqual(interruptedCheckpoint.nextSection, "blocks")
        XCTAssertEqual(interruptedCheckpoint.nextBatchIndex, 1)

        let page = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: content
        )

        XCTAssertEqual(page.id, "created-page-id")
        let createCallsAfterRetry = await client.createCallCount()
        let createdTitles = await client.createdTitles()
        let successfulBatches = await client.successfulBatches()
        XCTAssertEqual(createCallsAfterRetry, 1)
        XCTAssertEqual(createdTitles, [content.title])
        XCTAssertEqual(successfulBatches, expectedBatches)
        let completedMeeting = try repository.meeting(id: meetingID)
        XCTAssertEqual(completedMeeting.archiveCheckpoint?.nextSection, "complete")
        XCTAssertEqual(
            completedMeeting.archiveCheckpoint?.nextBatchIndex,
            expectedBatches.count
        )

        let appendAttemptsBeforeNoOp = await client.appendAttemptCount()
        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: content
        )
        let finalCreateCalls = await client.createCallCount()
        let finalAppendAttempts = await client.appendAttemptCount()
        XCTAssertEqual(finalCreateCalls, 1)
        XCTAssertEqual(finalAppendAttempts, appendAttemptsBeforeNoOp)
    }

    private func makeContent() -> NotionMeetingPageContent {
        NotionMeetingPageContent(
            title: "产品周会",
            startedAt: Date(timeIntervalSince1970: 1_000),
            duration: 120,
            mode: .online,
            summary: GeneratedMeetingSummary(
                suggestedTitle: "产品路线图周会",
                overview: "确认路线图。",
                keyPoints: ["优先稳定性"],
                decisions: ["下周发布"],
                actionItems: [
                    .init(task: "准备发布", owner: "小王", dueDate: "下周一")
                ],
                bookmarkInsights: ["发布决定"]
            ),
            bookmarks: [.init(timestamp: 60, excerpt: "发布决定")],
            transcripts: [
                .init(startTime: 0, endTime: 5, text: "讨论路线图"),
                .init(startTime: 5, endTime: 10, text: "确认发布")
            ]
        )
    }
}

private actor RecordingNotionAPIClient: NotionAPIClient {
    private let page = NotionPageReference(
        id: "created-page-id",
        url: "https://www.notion.so/created-page-id"
    )
    private let failOnAppendAttempt: Int?
    private var createCalls = 0
    private var pageTitles: [String] = []
    private var appendAttempts = 0
    private var completedBatches: [[NotionBlockDraft]] = []

    init(failOnAppendAttempt: Int? = nil) {
        self.failOnAppendAttempt = failOnAppendAttempt
    }

    func testConnection(
        parentPageID: UUID
    ) async throws -> NotionConnectionResult {
        _ = parentPageID
        return NotionConnectionResult(
            userID: "bot-id",
            userName: "Meeting Bot",
            parentPage: page
        )
    }

    func createPage(parentPageID: UUID, title: String) async throws -> NotionPageReference {
        _ = parentPageID
        createCalls += 1
        pageTitles.append(title)
        return page
    }

    func append(blocks: [NotionBlockDraft], to pageID: String) async throws {
        XCTAssertEqual(pageID, page.id)
        let attempt = appendAttempts
        appendAttempts += 1
        if attempt == failOnAppendAttempt {
            throw NotionClientError.rateLimited
        }
        completedBatches.append(blocks)
    }

    func createCallCount() -> Int {
        createCalls
    }

    func createdTitles() -> [String] {
        pageTitles
    }

    func appendAttemptCount() -> Int {
        appendAttempts
    }

    func successfulBatches() -> [[NotionBlockDraft]] {
        completedBatches
    }
}
