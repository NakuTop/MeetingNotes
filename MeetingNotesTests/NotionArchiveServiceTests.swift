import XCTest
import SwiftData
@testable import MeetingNotes

@MainActor
final class NotionArchiveServiceTests: XCTestCase {
    func testConcurrentServiceInstancesRejectSecondArchiveForSameMeeting() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "摘要")
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "existing-page",
            pageURL: "https://www.notion.so/existing-page"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "existing-page",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        let client = SuspendingNotionAPIClient()
        let firstService = NotionArchiveService(
            repository: repository,
            client: client
        )
        let secondService = NotionArchiveService(
            repository: repository,
            client: client
        )
        let content = try makeSummaryContent(overview: "摘要")
        let firstArchive = Task { @MainActor in
            try await firstService.archive(
                meetingID: meetingID,
                parentPageID: UUID(),
                content: content
            )
        }
        await client.waitUntilAppendStarts()
        var receivedError: Error?

        do {
            _ = try await secondService.archive(
                meetingID: meetingID,
                parentPageID: UUID(),
                content: content
            )
        } catch {
            receivedError = error
        }

        XCTAssertEqual(
            receivedError as? NotionArchiveServiceError,
            .archiveInProgress(meetingID)
        )
        let countBeforeRelease = await client.appendCallCount()
        XCTAssertEqual(countBeforeRelease, 1)
        await client.releaseAppend()
        _ = try await firstArchive.value
        let finalCount = await client.appendCallCount()
        XCTAssertEqual(finalCount, 1)
    }

    func testCancelledURLErrorIsControlFlowCancellationWithoutFailureMark() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "摘要")
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "existing-page",
            pageURL: "https://www.notion.so/existing-page"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "existing-page",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        let service = NotionArchiveService(
            repository: repository,
            client: CancelledNotionAPIClient()
        )

        do {
            _ = try await service.archive(
                meetingID: meetingID,
                parentPageID: UUID(),
                content: try makeSummaryContent(overview: "摘要")
            )
            XCTFail("Expected URL cancellation to become CancellationError")
        } catch is CancellationError {
            // Expected control-flow cancellation.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }

        let meeting = try repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.archiveState, .archiving)
        XCTAssertNil(meeting.summary?.lastArchiveErrorCode)
    }

    func testDocumentCheckpointRetriesLocallyWithoutRepeatingAppend() async throws {
        let failure = ArchiveSaveFailureController()
        let repository = try MeetingRepository.inMemory(
            contextSaver: failure.save
        )
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "摘要")
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "existing-page",
            pageURL: "https://www.notion.so/existing-page"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "existing-page",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        failure.arm(failingOn: [2])
        let client = RecordingNotionAPIClient()
        let service = NotionArchiveService(repository: repository, client: client)

        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: try makeSummaryContent(overview: "摘要")
        )

        let appendAttempts = await client.appendAttemptCount()
        XCTAssertEqual(appendAttempts, 1)
        let checkpoint = try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        )
        XCTAssertFalse(try checkpoint.blockIDs(for: .summary).isEmpty)
        XCTAssertNil(try checkpoint.pendingRun(for: .summary))
    }

    func testMetadataCheckpointRetriesLocallyWithoutRepeatingAppend() async throws {
        let failure = ArchiveSaveFailureController()
        let repository = try MeetingRepository.inMemory(
            contextSaver: failure.save
        )
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "摘要")
        failure.arm(failingOn: [2])
        let client = RecordingNotionAPIClient()
        let service = NotionArchiveService(repository: repository, client: client)

        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: try makeSummaryContent(overview: "摘要")
        )

        let appendAttempts = await client.appendAttemptCount()
        XCTAssertEqual(appendAttempts, 2)
        let checkpoint = try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        )
        XCTAssertEqual(
            try checkpoint.metadataBlockIDs,
            ["block-0-0", "block-0-1"]
        )
    }

    func testRepeatedDocumentCheckpointFailureDeletesUnpersistedBatch() async throws {
        let failure = ArchiveSaveFailureController()
        let repository = try MeetingRepository.inMemory(
            contextSaver: failure.save
        )
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "摘要")
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "existing-page",
            pageURL: "https://www.notion.so/existing-page"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "existing-page",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        failure.arm(failingOn: [2, 3])
        let client = RecordingNotionAPIClient()
        let service = NotionArchiveService(repository: repository, client: client)

        do {
            _ = try await service.archive(
                meetingID: meetingID,
                parentPageID: UUID(),
                content: try makeSummaryContent(overview: "摘要")
            )
            XCTFail("Expected repeated local persistence failure")
        } catch {
            XCTAssertEqual(error as? InjectedArchiveSaveError, .forced)
        }

        let appendCalls = await client.successfulAppendCalls()
        let expectedIDs = appendCalls[0].indices.map { "block-0-\($0)" }
        let appendAttempts = await client.appendAttemptCount()
        let cleanupAttempts = await client.archiveAttempts()
        XCTAssertEqual(appendAttempts, 1)
        XCTAssertEqual(cleanupAttempts, expectedIDs)
    }

    func testCorruptManagedIDsStopWithoutRemoteMutation() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "摘要")
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "existing-page",
            pageURL: "https://www.notion.so/existing-page"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "existing-page",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        ).summaryBlockIDsData = Data("not-json".utf8)
        let client = RecordingNotionAPIClient()
        let service = NotionArchiveService(repository: repository, client: client)

        do {
            _ = try await service.archive(
                meetingID: meetingID,
                parentPageID: UUID(),
                content: try makeSummaryContent(overview: "摘要")
            )
            XCTFail("Expected corrupt managed IDs to stop archiving")
        } catch {
            XCTAssertEqual(
                error as? ArchiveCheckpointCodingError,
                .invalidData("summaryBlockIDsData")
            )
        }

        let appendAttempts = await client.appendAttemptCount()
        let archiveAttempts = await client.archiveAttempts()
        XCTAssertEqual(appendAttempts, 0)
        XCTAssertTrue(archiveAttempts.isEmpty)
    }

    func testCorruptPendingRunStopsWithoutRemoteMutation() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "摘要")
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "existing-page",
            pageURL: "https://www.notion.so/existing-page"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "existing-page",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        let checkpoint = try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        )
        try checkpoint.setBlockIDs(["active"], for: .summary)
        checkpoint.pendingRunsData = Data("not-json".utf8)
        let client = RecordingNotionAPIClient()
        let service = NotionArchiveService(repository: repository, client: client)

        do {
            _ = try await service.archive(
                meetingID: meetingID,
                parentPageID: UUID(),
                content: try makeSummaryContent(overview: "摘要")
            )
            XCTFail("Expected corrupt pending data to stop archiving")
        } catch {
            XCTAssertEqual(
                error as? ArchiveCheckpointCodingError,
                .invalidData("pendingRunsData")
            )
        }

        let appendAttempts = await client.appendAttemptCount()
        let archiveAttempts = await client.archiveAttempts()
        XCTAssertEqual(appendAttempts, 0)
        XCTAssertTrue(archiveAttempts.isEmpty)
    }

    func testAppendFailureResumesDocumentWithoutDuplicatingConfirmedBatches() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "版本一")
        let content = try makeSummaryContent(overview: "版本一")
        let builder = NotionBlockBuilder(maximumBlocksPerBatch: 2)
        let client = RecordingNotionAPIClient(failOnAppendAttempts: [2])
        let service = NotionArchiveService(
            repository: repository,
            client: client,
            blockBuilder: builder
        )

        do {
            _ = try await service.archive(
                meetingID: meetingID,
                parentPageID: UUID(),
                content: content
            )
            XCTFail("Expected the second document batch to fail")
        } catch {
            XCTAssertEqual(error as? NotionClientError, .rateLimited)
        }

        let interrupted = try repository.meeting(id: meetingID)
        let checkpoint = try XCTUnwrap(interrupted.archiveCheckpoint)
        XCTAssertEqual(
            try checkpoint.pendingRun(for: .summary)?.nextBatchIndex,
            1
        )
        XCTAssertEqual(interrupted.summary?.archiveState, .failed)
        let firstDocumentBatch = Array(
            builder.documentBlocks(for: content).prefix(2)
        )

        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: content
        )

        let calls = await client.successfulAppendCalls()
        XCTAssertEqual(calls.filter { $0 == firstDocumentBatch }.count, 1)
        let createCallCount = await client.createCallCount()
        XCTAssertEqual(createCallCount, 1)
        let completed = try repository.meeting(id: meetingID)
        XCTAssertEqual(completed.summary?.archiveState, .archived)
        XCTAssertEqual(completed.summary?.archivedContentRevision, 1)
        XCTAssertNil(
            try completed.archiveCheckpoint?.pendingRun(for: .summary)
        )
        XCTAssertFalse(
            try completed.archiveCheckpoint?.blockIDs(for: .summary).isEmpty
                ?? true
        )
    }

    func testSummaryAndDetailedMinutesReusePageAndKeepIndependentManagedSections() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "摘要")
        try saveMinutes(in: repository, meetingID: meetingID, overview: "纪要")
        let client = RecordingNotionAPIClient()
        let service = NotionArchiveService(repository: repository, client: client)

        let summaryPage = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: try makeSummaryContent(overview: "摘要")
        )
        let summaryIDs = try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        ).blockIDs(for: .summary)
        let minutesPage = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: try makeMinutesContent(overview: "纪要")
        )

        let meeting = try repository.meeting(id: meetingID)
        let finalCheckpoint = try XCTUnwrap(meeting.archiveCheckpoint)
        XCTAssertEqual(summaryPage.id, minutesPage.id)
        let createCallCount = await client.createCallCount()
        XCTAssertEqual(createCallCount, 1)
        XCTAssertEqual(
            try finalCheckpoint.blockIDs(for: .summary),
            summaryIDs
        )
        XCTAssertFalse(
            try finalCheckpoint.blockIDs(for: .detailedMinutes).isEmpty
        )
        XCTAssertFalse(try finalCheckpoint.metadataBlockIDs.isEmpty)
        XCTAssertEqual(meeting.summary?.archiveState, .archived)
        XCTAssertEqual(meeting.detailedMinutes?.archiveState, .archived)
        let calls = await client.successfulAppendCalls()
        XCTAssertEqual(
            calls.flatMap { $0 }.filter { $0.text == "元信息" }.count,
            1
        )
    }

    func testReplacementPromotesNewSectionBeforeRetryingOldBlockCleanupOnly() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "旧摘要")
        let client = RecordingNotionAPIClient()
        let service = NotionArchiveService(repository: repository, client: client)
        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: try makeSummaryContent(overview: "旧摘要")
        )
        let oldIDs = try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        ).blockIDs(for: .summary)

        try saveSummary(in: repository, meetingID: meetingID, overview: "新摘要")
        await client.failNextArchiveCall()
        do {
            _ = try await service.archive(
                meetingID: meetingID,
                parentPageID: UUID(),
                content: try makeSummaryContent(overview: "新摘要")
            )
            XCTFail("Expected cleanup failure")
        } catch {
            XCTAssertEqual(error as? NotionClientError, .rateLimited)
        }

        let interrupted = try repository.meeting(id: meetingID)
        let checkpoint = try XCTUnwrap(interrupted.archiveCheckpoint)
        let newIDs = try checkpoint.blockIDs(for: .summary)
        XCTAssertFalse(newIDs.isEmpty)
        XCTAssertNotEqual(newIDs, oldIDs)
        XCTAssertEqual(
            try checkpoint.pendingRun(for: .summary)?.phase,
            .cleaningUp
        )
        XCTAssertEqual(
            try checkpoint.pendingRun(for: .summary)?.oldBlockIDs,
            oldIDs
        )
        XCTAssertEqual(interrupted.summary?.archivedContentRevision, 2)
        XCTAssertEqual(interrupted.summary?.archiveState, .failed)
        let appendCountBeforeRetry = await client.appendAttemptCount()

        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: try makeSummaryContent(overview: "新摘要")
        )

        let appendCountAfterRetry = await client.appendAttemptCount()
        let archivedIDs = await client.successfulArchiveIDs()
        XCTAssertEqual(appendCountAfterRetry, appendCountBeforeRetry)
        XCTAssertEqual(archivedIDs, oldIDs)
        let completed = try repository.meeting(id: meetingID)
        XCTAssertEqual(
            try completed.archiveCheckpoint?.blockIDs(for: .summary),
            newIDs
        )
        XCTAssertNil(
            try completed.archiveCheckpoint?.pendingRun(for: .summary)
        )
        XCTAssertEqual(completed.summary?.archiveState, .archived)
    }

    func testExplicitArchiveTransitionReplacesUnchangedManagedSection()
        async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(
            in: repository,
            meetingID: meetingID,
            overview: "未改变的摘要"
        )
        let client = RecordingNotionAPIClient()
        let service = NotionArchiveService(
            repository: repository,
            client: client
        )
        let content = try makeSummaryContent(overview: "未改变的摘要")
        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: content
        )
        let oldManagedIDs = try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        ).blockIDs(for: .summary)
        let firstAppendCount = await client.appendAttemptCount()

        try repository.updateDocumentArchiveState(
            meetingID: meetingID,
            kind: .summary,
            archiveState: .archiving,
            meetingState: .archiving
        )
        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: content
        )

        let secondAppendCount = await client.appendAttemptCount()
        let meeting = try repository.meeting(id: meetingID)
        let newManagedIDs = try XCTUnwrap(
            meeting.archiveCheckpoint
        ).blockIDs(for: .summary)
        let archivedIDs = await client.successfulArchiveIDs()
        XCTAssertGreaterThan(secondAppendCount, firstAppendCount)
        XCTAssertNotEqual(newManagedIDs, oldManagedIDs)
        XCTAssertTrue(Set(archivedIDs).isSuperset(of: oldManagedIDs))
        XCTAssertEqual(meeting.summary?.archiveState, .archived)
    }

    func testLegacyPageWithoutManagedIDsAppendsOnceAndNeverDeletesUnknownBlocks() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "旧页面摘要")
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "legacy-page",
            pageURL: "https://www.notion.so/legacy-page"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "legacy-page",
            nextSection: "complete",
            nextBatchIndex: 99
        )
        let client = RecordingNotionAPIClient()
        let service = NotionArchiveService(repository: repository, client: client)
        let content = try makeSummaryContent(overview: "旧页面摘要")

        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: content
        )
        let appendCount = await client.appendAttemptCount()
        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: content
        )

        let createCallCount = await client.createCallCount()
        let finalAppendCount = await client.appendAttemptCount()
        let archiveAttempts = await client.archiveAttempts()
        XCTAssertEqual(createCallCount, 0)
        XCTAssertEqual(finalAppendCount, appendCount)
        XCTAssertTrue(archiveAttempts.isEmpty)
        let calls = await client.successfulAppendCalls()
        XCTAssertFalse(calls.flatMap { $0 }.contains { $0.text == "元信息" })
        let meeting = try repository.meeting(id: meetingID)
        XCTAssertFalse(
            try meeting.archiveCheckpoint?.blockIDs(for: .summary).isEmpty
                ?? true
        )
    }

    func testMismatchedCheckpointPageResetsOldIDsWithoutDeletingThem() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "摘要")
        try saveMinutes(in: repository, meetingID: meetingID, overview: "纪要")
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "new-page",
            pageURL: "https://www.notion.so/new-page"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "old-page",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        let checkpoint = try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        )
        try checkpoint.setMetadataBlockIDs(["old-metadata"])
        try checkpoint.setBlockIDs(["old-summary"], for: .summary)
        try checkpoint.setBlockIDs(["old-minutes"], for: .detailedMinutes)
        try checkpoint.setPendingRun(
            NotionDocumentArchiveRun(contentRevision: 1),
            for: .detailedMinutes
        )
        let client = RecordingNotionAPIClient()
        let service = NotionArchiveService(repository: repository, client: client)

        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: try makeSummaryContent(overview: "摘要")
        )

        let archiveAttempts = await client.archiveAttempts()
        XCTAssertTrue(archiveAttempts.isEmpty)
        let reset = try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        )
        XCTAssertEqual(reset.notionPageID, "new-page")
        XCTAssertEqual(try reset.metadataBlockIDs, [])
        XCTAssertFalse(try reset.blockIDs(for: .summary).isEmpty)
        XCTAssertEqual(try reset.blockIDs(for: .detailedMinutes), [])
        XCTAssertNil(try reset.pendingRun(for: .detailedMinutes))
    }

    func testRegenerationAfterPartialAppendStartsNewRevisionWithoutMixingBlocks() async throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try makeMeeting(in: repository)
        try saveSummary(in: repository, meetingID: meetingID, overview: "旧内容")
        let builder = NotionBlockBuilder(maximumBlocksPerBatch: 2)
        let client = RecordingNotionAPIClient(failOnAppendAttempts: [2])
        let service = NotionArchiveService(
            repository: repository,
            client: client,
            blockBuilder: builder
        )
        do {
            _ = try await service.archive(
                meetingID: meetingID,
                parentPageID: UUID(),
                content: try makeSummaryContent(overview: "旧内容")
            )
        } catch {
            XCTAssertEqual(error as? NotionClientError, .rateLimited)
        }
        let partialIDs = try XCTUnwrap(
            repository.meeting(id: meetingID)
                .archiveCheckpoint?.pendingRun(for: .summary)
        ).newBlockIDs
        XCTAssertFalse(partialIDs.isEmpty)

        try saveSummary(in: repository, meetingID: meetingID, overview: "新内容")
        _ = try await service.archive(
            meetingID: meetingID,
            parentPageID: UUID(),
            content: try makeSummaryContent(overview: "新内容")
        )

        let completed = try repository.meeting(id: meetingID)
        let checkpoint = try XCTUnwrap(completed.archiveCheckpoint)
        XCTAssertTrue(
            Set(try checkpoint.blockIDs(for: .summary))
                .isDisjoint(with: partialIDs)
        )
        let archivedIDs = await client.successfulArchiveIDs()
        XCTAssertTrue(Set(archivedIDs).isSuperset(of: partialIDs))
        XCTAssertNil(try checkpoint.pendingRun(for: .summary))
        XCTAssertEqual(completed.summary?.archivedContentRevision, 2)
    }

    private func makeMeeting(in repository: MeetingRepository) throws -> UUID {
        try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1_000),
            title: "产品周会"
        )
    }

    private func saveSummary(
        in repository: MeetingRepository,
        meetingID: UUID,
        overview: String
    ) throws {
        try repository.saveGeneratedSummary(
            meetingID: meetingID,
            generated: GeneratedMeetingSummary(
                suggestedTitle: "产品周会",
                overview: overview,
                keyPoints: ["优先稳定性"],
                decisions: ["下周发布"],
                actionItems: [
                    .init(task: "准备发布", owner: "小王", dueDate: "下周一")
                ],
                bookmarkInsights: ["发布决定"]
            ),
            model: "test"
        )
    }

    private func saveMinutes(
        in repository: MeetingRepository,
        meetingID: UUID,
        overview: String
    ) throws {
        try repository.saveGeneratedDetailedMinutes(
            meetingID: meetingID,
            generated: GeneratedDetailedMinutes(
                overview: overview,
                sections: [
                    .init(
                        title: "路线图",
                        timeRange: "00:00-01:00",
                        speakers: ["我"],
                        content: "讨论路线图"
                    )
                ],
                decisions: ["下周发布"],
                actionItems: [],
                openQuestions: []
            ),
            model: "test",
            promptVersion: 1
        )
    }

    private func makeSummaryContent(
        overview: String
    ) throws -> NotionMeetingPageContent {
        try NotionMeetingPageContent(
            title: "产品周会",
            startedAt: Date(timeIntervalSince1970: 1_000),
            duration: 120,
            mode: .online,
            kind: .summary,
            summary: GeneratedMeetingSummary(
                suggestedTitle: "产品周会",
                overview: overview,
                keyPoints: ["优先稳定性"],
                decisions: ["下周发布"],
                actionItems: [
                    .init(task: "准备发布", owner: "小王", dueDate: "下周一")
                ],
                bookmarkInsights: ["发布决定"]
            ),
            detailedMinutes: nil,
            bookmarks: [.init(timestamp: 60, excerpt: "发布决定")],
            transcripts: [
                .init(startTime: 0, endTime: 5, text: "讨论路线图"),
                .init(startTime: 5, endTime: 10, text: "确认发布")
            ]
        )
    }

    private func makeMinutesContent(
        overview: String
    ) throws -> NotionMeetingPageContent {
        try NotionMeetingPageContent(
            title: "产品周会",
            startedAt: Date(timeIntervalSince1970: 1_000),
            duration: 120,
            mode: .online,
            kind: .detailedMinutes,
            summary: nil,
            detailedMinutes: GeneratedDetailedMinutes(
                overview: overview,
                sections: [
                    .init(
                        title: "路线图",
                        timeRange: "00:00-01:00",
                        speakers: ["我"],
                        content: "讨论路线图"
                    )
                ],
                decisions: ["下周发布"],
                actionItems: [],
                openQuestions: []
            ),
            bookmarks: [],
            transcripts: []
        )
    }
}

private actor RecordingNotionAPIClient: NotionAPIClient {
    private let page = NotionPageReference(
        id: "created-page-id",
        url: "https://www.notion.so/created-page-id"
    )
    private let failOnAppendAttempts: Set<Int>
    private var createCalls = 0
    private var appendAttempts = 0
    private var completedAppendCalls: [[NotionBlockDraft]] = []
    private var completedArchiveIDs: [String] = []
    private var attemptedArchiveIDs: [String] = []
    private var shouldFailNextArchive = false

    init(failOnAppendAttempts: Set<Int> = []) {
        self.failOnAppendAttempts = failOnAppendAttempts
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

    func createPage(
        parentPageID: UUID,
        title: String
    ) async throws -> NotionPageReference {
        _ = parentPageID
        _ = title
        createCalls += 1
        return page
    }

    func append(
        blocks: [NotionBlockDraft],
        to pageID: String
    ) async throws -> [String] {
        _ = pageID
        let attempt = appendAttempts
        appendAttempts += 1
        if failOnAppendAttempts.contains(attempt) {
            throw NotionClientError.rateLimited
        }
        completedAppendCalls.append(blocks)
        return blocks.indices.map { "block-\(attempt)-\($0)" }
    }

    func archiveBlock(id: String) async throws {
        attemptedArchiveIDs.append(id)
        if shouldFailNextArchive {
            shouldFailNextArchive = false
            throw NotionClientError.rateLimited
        }
        completedArchiveIDs.append(id)
    }

    func updatePageTitle(pageID: String, title: String) async throws {
        _ = pageID
        _ = title
    }

    func failNextArchiveCall() {
        shouldFailNextArchive = true
    }

    func createCallCount() -> Int { createCalls }
    func appendAttemptCount() -> Int { appendAttempts }
    func successfulAppendCalls() -> [[NotionBlockDraft]] {
        completedAppendCalls
    }
    func successfulArchiveIDs() -> [String] { completedArchiveIDs }
    func archiveAttempts() -> [String] { attemptedArchiveIDs }
}

private actor SuspendingNotionAPIClient: NotionAPIClient {
    private var appendCalls = 0
    private var appendStarted = false
    private var appendStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var appendRelease: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func testConnection(
        parentPageID: UUID
    ) async throws -> NotionConnectionResult {
        _ = parentPageID
        return NotionConnectionResult(
            userID: "bot",
            userName: nil,
            parentPage: NotionPageReference(id: "page", url: "page")
        )
    }

    func createPage(
        parentPageID: UUID,
        title: String
    ) async throws -> NotionPageReference {
        _ = parentPageID
        _ = title
        return NotionPageReference(id: "page", url: "page")
    }

    func append(
        blocks: [NotionBlockDraft],
        to pageID: String
    ) async throws -> [String] {
        _ = pageID
        appendCalls += 1
        appendStarted = true
        appendStartWaiters.forEach { $0.resume() }
        appendStartWaiters.removeAll()
        await withCheckedContinuation { continuation in
            if isReleased {
                continuation.resume()
            } else {
                appendRelease = continuation
            }
        }
        return blocks.indices.map { "suspended-\($0)" }
    }

    func archiveBlock(id: String) async throws { _ = id }

    func updatePageTitle(pageID: String, title: String) async throws {
        _ = pageID
        _ = title
    }

    func waitUntilAppendStarts() async {
        if appendStarted { return }
        await withCheckedContinuation { continuation in
            appendStartWaiters.append(continuation)
        }
    }

    func releaseAppend() {
        isReleased = true
        appendRelease?.resume()
        appendRelease = nil
    }

    func appendCallCount() -> Int { appendCalls }
}

private struct CancelledNotionAPIClient: NotionAPIClient {
    func testConnection(
        parentPageID: UUID
    ) async throws -> NotionConnectionResult {
        _ = parentPageID
        throw URLError(.cancelled)
    }

    func createPage(
        parentPageID: UUID,
        title: String
    ) async throws -> NotionPageReference {
        _ = parentPageID
        _ = title
        throw URLError(.cancelled)
    }

    func append(
        blocks: [NotionBlockDraft],
        to pageID: String
    ) async throws -> [String] {
        _ = blocks
        _ = pageID
        throw URLError(.cancelled)
    }

    func archiveBlock(id: String) async throws {
        _ = id
        throw URLError(.cancelled)
    }

    func updatePageTitle(pageID: String, title: String) async throws {
        _ = pageID
        _ = title
        throw URLError(.cancelled)
    }
}

private enum InjectedArchiveSaveError: Error, Equatable {
    case forced
}

@MainActor
private final class ArchiveSaveFailureController {
    private var attempts = 0
    private var failingAttempts: Set<Int> = []
    private var isArmed = false

    func arm(failingOn attempts: Set<Int>) {
        self.attempts = 0
        failingAttempts = attempts
        isArmed = true
    }

    func save(_ context: ModelContext) throws {
        if isArmed {
            attempts += 1
            if failingAttempts.contains(attempts) {
                throw InjectedArchiveSaveError.forced
            }
        }
        try context.save()
    }
}
