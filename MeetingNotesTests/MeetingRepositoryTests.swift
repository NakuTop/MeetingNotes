import XCTest
import SwiftData
@testable import MeetingNotes

@MainActor
final class MeetingRepositoryTests: XCTestCase {
    func testResetNotionArchiveCheckpointClearsEveryOldPageReference() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: .now
        )
        try saveBothDocuments(repository: repository, meetingID: meetingID)
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "new-page",
            pageURL: "https://www.notion.so/new-page"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "old-page",
            nextSection: "managed",
            nextBatchIndex: 7
        )
        let checkpoint = try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        )
        try checkpoint.setMetadataBlockIDs(["old-metadata"])
        try checkpoint.setBlockIDs(["old-summary"], for: .summary)
        try checkpoint.setBlockIDs(["old-minutes"], for: .detailedMinutes)
        try checkpoint.setPendingRun(
            NotionDocumentArchiveRun(
                contentRevision: 1,
                newBlockIDs: ["partial-summary"],
                oldBlockIDs: ["older-summary"],
                nextBatchIndex: 1
            ),
            for: .summary
        )
        try checkpoint.setPendingRun(
            NotionDocumentArchiveRun(contentRevision: 1),
            for: .detailedMinutes
        )

        try repository.resetNotionArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "new-page"
        )

        let reset = try XCTUnwrap(
            repository.meeting(id: meetingID).archiveCheckpoint
        )
        XCTAssertEqual(reset.notionPageID, "new-page")
        XCTAssertEqual(reset.nextSection, "managed")
        XCTAssertEqual(reset.nextBatchIndex, 0)
        XCTAssertEqual(try reset.metadataBlockIDs, [])
        XCTAssertEqual(try reset.blockIDs(for: .summary), [])
        XCTAssertEqual(try reset.blockIDs(for: .detailedMinutes), [])
        XCTAssertNil(try reset.pendingRun(for: .summary))
        XCTAssertNil(try reset.pendingRun(for: .detailedMinutes))
        XCTAssertNil(reset.pendingKindRawValue)
        XCTAssertNil(reset.pendingRunsData)
    }

    func testCorruptManagedBlockIDsThrowInsteadOfBecomingLegacyEmpty() {
        let checkpoint = ArchiveCheckpointRecord(
            notionPageID: "page",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        checkpoint.summaryBlockIDsData = Data("not-json".utf8)

        XCTAssertThrowsError(try checkpoint.blockIDs(for: .summary)) { error in
            XCTAssertEqual(
                error as? ArchiveCheckpointCodingError,
                .invalidData("summaryBlockIDsData")
            )
        }
    }

    func testCorruptPendingRunsThrowInsteadOfFallingBackToLegacyFields() {
        let checkpoint = ArchiveCheckpointRecord(
            notionPageID: "page",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        checkpoint.pendingRunsData = Data("not-json".utf8)
        checkpoint.pendingKindRawValue = MeetingDocumentKind.summary.rawValue
        checkpoint.pendingContentRevision = 1

        XCTAssertThrowsError(try checkpoint.pendingRun(for: .summary)) { error in
            XCTAssertEqual(
                error as? ArchiveCheckpointCodingError,
                .invalidData("pendingRunsData")
            )
        }
    }

    func testInitializeNotionArchivePageRollsBackPageAndCheckpointTogether() throws {
        let failure = RepositorySaveFailureSwitch()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                if failure.shouldFail {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let originalUpdatedAt = try repository.meeting(id: meetingID).updatedAt
        failure.shouldFail = true

        XCTAssertThrowsError(
            try repository.initializeNotionArchivePage(
                meetingID: meetingID,
                pageID: "new-page",
                pageURL: "https://www.notion.so/new-page"
            )
        ) { error in
            XCTAssertEqual(error as? InjectedRepositorySaveError, .forced)
        }

        let meeting = try repository.meeting(id: meetingID)
        XCTAssertNil(meeting.notionPageID)
        XCTAssertNil(meeting.notionPageURL)
        XCTAssertNil(meeting.archiveCheckpoint)
        XCTAssertEqual(meeting.updatedAt, originalUpdatedAt)
    }

    func testLegacyArchiveCheckpointDefaultsManagedFieldsToEmpty() throws {
        let checkpoint = ArchiveCheckpointRecord(
            notionPageID: "legacy-page",
            nextSection: "complete",
            nextBatchIndex: 7
        )

        XCTAssertNil(checkpoint.summaryBlockIDsData)
        XCTAssertNil(checkpoint.detailedMinutesBlockIDsData)
        XCTAssertNil(checkpoint.pendingKindRawValue)
        XCTAssertNil(checkpoint.pendingNewBlockIDsData)
        XCTAssertNil(checkpoint.pendingOldBlockIDsData)
        XCTAssertNil(checkpoint.pendingNextBatchIndex)
        XCTAssertEqual(try checkpoint.blockIDs(for: .summary), [])
        XCTAssertEqual(try checkpoint.blockIDs(for: .detailedMinutes), [])
        XCTAssertNil(try checkpoint.pendingRun(for: .summary))
        XCTAssertNil(try checkpoint.pendingRun(for: .detailedMinutes))
    }

    func testClearingLastPendingRunCannotBeRehydratedFromLegacyMirror() throws {
        let checkpoint = ArchiveCheckpointRecord(
            notionPageID: "page",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        try checkpoint.setPendingRun(
            NotionDocumentArchiveRun(contentRevision: 1),
            for: .summary
        )

        try checkpoint.setPendingRun(nil, for: .summary)

        XCTAssertNil(try checkpoint.pendingRun(for: .summary))
        XCTAssertNil(checkpoint.pendingRunsData)
        XCTAssertNil(checkpoint.pendingKindRawValue)
        XCTAssertNil(checkpoint.pendingContentRevision)
    }

    func testArchiveCheckpointKeepsIndependentPendingRunsAndPromotesOnlyRequestedKind()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: .now
        )
        try saveBothDocuments(repository: repository, meetingID: meetingID)
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "page-id",
            pageURL: "https://www.notion.so/page-id"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "page-id",
            nextSection: "managed",
            nextBatchIndex: 0
        )

        _ = try repository.beginDocumentArchiveRun(
            meetingID: meetingID,
            kind: .summary,
            contentRevision: 1
        )
        try repository.recordDocumentArchiveBatch(
            meetingID: meetingID,
            kind: .summary,
            contentRevision: 1,
            blockIDs: ["summary-new-1"],
            nextBatchIndex: 1
        )
        _ = try repository.beginDocumentArchiveRun(
            meetingID: meetingID,
            kind: .detailedMinutes,
            contentRevision: 1
        )
        try repository.recordDocumentArchiveBatch(
            meetingID: meetingID,
            kind: .detailedMinutes,
            contentRevision: 1,
            blockIDs: ["minutes-new-1"],
            nextBatchIndex: 1
        )

        var meeting = try repository.meeting(id: meetingID)
        var checkpoint = try XCTUnwrap(meeting.archiveCheckpoint)
        XCTAssertEqual(
            try checkpoint.pendingRun(for: .summary)?.newBlockIDs,
            ["summary-new-1"]
        )
        XCTAssertEqual(
            try checkpoint.pendingRun(for: .detailedMinutes)?.newBlockIDs,
            ["minutes-new-1"]
        )

        try repository.promoteDocumentArchiveRun(
            meetingID: meetingID,
            kind: .summary,
            contentRevision: 1
        )

        meeting = try repository.meeting(id: meetingID)
        checkpoint = try XCTUnwrap(meeting.archiveCheckpoint)
        XCTAssertEqual(try checkpoint.blockIDs(for: .summary), ["summary-new-1"])
        XCTAssertEqual(try checkpoint.blockIDs(for: .detailedMinutes), [])
        XCTAssertNil(try checkpoint.pendingRun(for: .summary))
        XCTAssertEqual(
            try checkpoint.pendingRun(for: .detailedMinutes)?.newBlockIDs,
            ["minutes-new-1"]
        )
        XCTAssertEqual(meeting.summary?.archiveState, .archived)
        XCTAssertEqual(meeting.summary?.archivedContentRevision, 1)
        XCTAssertEqual(meeting.detailedMinutes?.archiveState, .archiving)
        XCTAssertNil(meeting.detailedMinutes?.archivedContentRevision)
    }

    func testRegenerationStartsFreshRunWithoutMixingPartialOldBlocks() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.saveSummary(
            meetingID: meetingID,
            overview: "v1",
            keyPoints: [],
            decisions: [],
            actionItems: [String](),
            bookmarkInsights: [],
            model: "model"
        )
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "page-id",
            pageURL: "https://www.notion.so/page-id"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "page-id",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        _ = try repository.beginDocumentArchiveRun(
            meetingID: meetingID,
            kind: .summary,
            contentRevision: 1
        )
        try repository.recordDocumentArchiveBatch(
            meetingID: meetingID,
            kind: .summary,
            contentRevision: 1,
            blockIDs: ["partial-v1-a", "partial-v1-b"],
            nextBatchIndex: 1
        )
        try repository.saveSummary(
            meetingID: meetingID,
            overview: "v2",
            keyPoints: [],
            decisions: [],
            actionItems: [String](),
            bookmarkInsights: [],
            model: "model"
        )

        let run = try repository.beginDocumentArchiveRun(
            meetingID: meetingID,
            kind: .summary,
            contentRevision: 2
        )

        XCTAssertEqual(run.contentRevision, 2)
        XCTAssertEqual(run.newBlockIDs, [])
        XCTAssertEqual(run.nextBatchIndex, 0)
        XCTAssertEqual(run.oldBlockIDs, ["partial-v1-a", "partial-v1-b"])
    }

    func testArchiveBatchCheckpointRollsBackIDsIndexAndMeetingTimestampOnSaveFailure()
        throws {
        let failure = RepositorySaveFailureSwitch()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                if failure.shouldFail {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: .now
        )
        try repository.saveSummary(
            meetingID: meetingID,
            overview: "summary",
            keyPoints: [],
            decisions: [],
            actionItems: [String](),
            bookmarkInsights: [],
            model: "model"
        )
        try repository.setNotionPage(
            meetingID: meetingID,
            pageID: "page-id",
            pageURL: "https://www.notion.so/page-id"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: meetingID,
            notionPageID: "page-id",
            nextSection: "managed",
            nextBatchIndex: 0
        )
        _ = try repository.beginDocumentArchiveRun(
            meetingID: meetingID,
            kind: .summary,
            contentRevision: 1
        )
        let meeting = try repository.meeting(id: meetingID)
        let previousUpdatedAt = meeting.updatedAt
        failure.shouldFail = true

        XCTAssertThrowsError(
            try repository.recordDocumentArchiveBatch(
                meetingID: meetingID,
                kind: .summary,
                contentRevision: 1,
                blockIDs: ["must-roll-back"],
                nextBatchIndex: 1
            )
        ) { error in
            XCTAssertEqual(error as? InjectedRepositorySaveError, .forced)
        }

        XCTAssertEqual(
            try meeting.archiveCheckpoint?.pendingRun(for: .summary)?.newBlockIDs,
            []
        )
        XCTAssertEqual(
            try meeting.archiveCheckpoint?.pendingRun(for: .summary)?.nextBatchIndex,
            0
        )
        XCTAssertEqual(meeting.updatedAt, previousUpdatedAt)
    }

    func testDetailedMinutesCanBeSavedWithoutSummary() throws {
        var capturedContainer: ModelContainer?
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                capturedContainer = context.container
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let generated = makeDetailedMinutes(overview: "完整纪要概览")

        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: generated,
            model: "deepseek-chat",
            promptVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_100)
        )

        let reloadedRepository = MeetingRepository(
            container: try XCTUnwrap(capturedContainer)
        )
        let meeting = try reloadedRepository.meeting(id: meetingID)
        XCTAssertNil(meeting.summary)
        let minutes = try XCTUnwrap(meeting.detailedMinutes)
        XCTAssertEqual(minutes.overview, "完整纪要概览")
        XCTAssertEqual(try minutes.sections, generated.sections)
        XCTAssertEqual(try minutes.decisions, generated.decisions)
        XCTAssertEqual(try minutes.actionItems, generated.actionItems)
        XCTAssertEqual(try minutes.openQuestions, generated.openQuestions)
        XCTAssertEqual(minutes.archiveState, .localOnly)
        XCTAssertEqual(minutes.contentRevision, 1)
    }

    func testSummaryAndDetailedMinutesCoexistIndependently() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        try repository.saveSummary(
            meetingID: meetingID,
            overview: "重点总结",
            keyPoints: ["重点"],
            decisions: [],
            actionItems: [String](),
            bookmarkInsights: [],
            model: "deepseek-chat"
        )
        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: makeDetailedMinutes(overview: "完整纪要"),
            model: "deepseek-chat",
            promptVersion: 2
        )

        let meeting = try repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.summary?.overview, "重点总结")
        XCTAssertEqual(meeting.detailedMinutes?.overview, "完整纪要")
        XCTAssertEqual(meeting.summary?.contentRevision, 1)
        XCTAssertEqual(meeting.detailedMinutes?.contentRevision, 1)
    }

    func testReplacingDetailedMinutesPreservesSummaryIdentityContentAndState()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.saveSummary(
            meetingID: meetingID,
            overview: "不可变化的总结",
            keyPoints: ["重点"],
            decisions: ["决定"],
            actionItems: [],
            bookmarkInsights: [],
            model: "summary-model"
        )
        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: makeDetailedMinutes(overview: "旧纪要"),
            model: "old-model",
            promptVersion: 1
        )
        let meeting = try repository.meeting(id: meetingID)
        let summary = try XCTUnwrap(meeting.summary)
        summary.archiveState = .archived
        summary.archivedContentRevision = summary.contentRevision
        summary.lastArchiveErrorCode = "summary-marker"
        try repository.updateMeetingState(id: meetingID, state: meeting.state)
        let summaryRevision = summary.contentRevision

        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: makeDetailedMinutes(overview: "新纪要"),
            model: "new-model",
            promptVersion: 2
        )

        XCTAssertTrue(meeting.summary === summary)
        XCTAssertEqual(summary.overview, "不可变化的总结")
        XCTAssertEqual(summary.archiveState, .archived)
        XCTAssertEqual(summary.archivedContentRevision, summaryRevision)
        XCTAssertEqual(summary.lastArchiveErrorCode, "summary-marker")
        XCTAssertEqual(summary.contentRevision, summaryRevision)
        XCTAssertEqual(meeting.detailedMinutes?.overview, "新纪要")
        XCTAssertEqual(meeting.detailedMinutes?.contentRevision, 2)
    }

    func testFailedDetailedMinutesReplacementRestoresAllOldFieldsAndRelationship()
        throws {
        let failure = RepositorySaveFailureSwitch()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                if failure.shouldFail {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let oldGenerated = makeDetailedMinutes(overview: "旧纪要")
        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: oldGenerated,
            model: "old-model",
            promptVersion: 3,
            createdAt: Date(timeIntervalSince1970: 1_100)
        )
        let meeting = try repository.meeting(id: meetingID)
        let oldMinutes = try XCTUnwrap(meeting.detailedMinutes)
        oldMinutes.archiveState = .failed
        oldMinutes.archivedContentRevision = 7
        oldMinutes.lastArchiveErrorCode = "notion_timeout"
        try repository.updateMeetingState(id: meetingID, state: meeting.state)
        let oldUpdatedAt = meeting.updatedAt
        failure.shouldFail = true

        XCTAssertThrowsError(
            try repository.saveDetailedMinutes(
                meetingID: meetingID,
                generated: makeDetailedMinutes(overview: "不应留下的新纪要"),
                model: "new-model",
                promptVersion: 4,
                createdAt: Date(timeIntervalSince1970: 1_200)
            )
        ) { error in
            XCTAssertEqual(error as? InjectedRepositorySaveError, .forced)
        }

        XCTAssertTrue(meeting.detailedMinutes === oldMinutes)
        XCTAssertTrue(oldMinutes.meeting === meeting)
        XCTAssertEqual(oldMinutes.overview, "旧纪要")
        XCTAssertEqual(try oldMinutes.sections, oldGenerated.sections)
        XCTAssertEqual(try oldMinutes.actionItems, oldGenerated.actionItems)
        XCTAssertEqual(try oldMinutes.openQuestions, oldGenerated.openQuestions)
        XCTAssertEqual(oldMinutes.model, "old-model")
        XCTAssertEqual(oldMinutes.promptVersion, 3)
        XCTAssertEqual(oldMinutes.createdAt, Date(timeIntervalSince1970: 1_100))
        XCTAssertEqual(oldMinutes.contentRevision, 1)
        XCTAssertEqual(oldMinutes.archiveState, .failed)
        XCTAssertEqual(oldMinutes.archivedContentRevision, 7)
        XCTAssertEqual(oldMinutes.lastArchiveErrorCode, "notion_timeout")
        XCTAssertEqual(meeting.updatedAt, oldUpdatedAt)
    }

    func testFailedDetailedMinutesEncodingDoesNotMutateExistingRecord() throws {
        var shouldFailEncoding = false
        let repository = try MeetingRepository.inMemory(
            detailedMinutesEncoder: { generated in
                if shouldFailEncoding {
                    throw InjectedDetailedMinutesEncodingError.forced
                }
                return try DetailedMinutesRecord.encode(generated)
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let oldGenerated = makeDetailedMinutes(overview: "旧纪要")
        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: oldGenerated,
            model: "old-model",
            promptVersion: 1,
            createdAt: Date(timeIntervalSince1970: 1_100)
        )
        let meeting = try repository.meeting(id: meetingID)
        let oldMinutes = try XCTUnwrap(meeting.detailedMinutes)
        oldMinutes.archiveState = .archived
        oldMinutes.archivedContentRevision = 1
        oldMinutes.lastArchiveErrorCode = "archive-marker"
        try repository.updateMeetingState(id: meetingID, state: meeting.state)
        let oldUpdatedAt = meeting.updatedAt
        shouldFailEncoding = true

        XCTAssertThrowsError(
            try repository.saveDetailedMinutes(
                meetingID: meetingID,
                generated: makeDetailedMinutes(overview: "新纪要"),
                model: "new-model",
                promptVersion: 2
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedDetailedMinutesEncodingError,
                .forced
            )
        }

        XCTAssertTrue(meeting.detailedMinutes === oldMinutes)
        XCTAssertTrue(oldMinutes.meeting === meeting)
        XCTAssertEqual(oldMinutes.overview, "旧纪要")
        XCTAssertEqual(try oldMinutes.sections, oldGenerated.sections)
        XCTAssertEqual(oldMinutes.model, "old-model")
        XCTAssertEqual(oldMinutes.promptVersion, 1)
        XCTAssertEqual(oldMinutes.contentRevision, 1)
        XCTAssertEqual(oldMinutes.archiveState, .archived)
        XCTAssertEqual(oldMinutes.archivedContentRevision, 1)
        XCTAssertEqual(oldMinutes.lastArchiveErrorCode, "archive-marker")
        XCTAssertEqual(meeting.updatedAt, oldUpdatedAt)
    }

    func testSummaryRevisionOverflowThrowsWithoutMutatingExistingRecord()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        try repository.saveSummary(
            meetingID: meetingID,
            overview: "旧总结",
            keyPoints: ["旧重点"],
            decisions: ["旧决定"],
            structuredActionItems: [
                ActionItem(task: "旧任务", owner: "旧负责人", dueDate: "旧日期")
            ],
            bookmarkInsights: ["旧书签"],
            model: "old-summary-model",
            createdAt: Date(timeIntervalSince1970: 1_100)
        )
        let meeting = try repository.meeting(id: meetingID)
        let summary = try XCTUnwrap(meeting.summary)
        summary.contentRevisionBacking = Int.max
        summary.archiveState = .archived
        summary.archivedContentRevision = Int.max
        summary.lastArchiveErrorCode = "summary-archive-marker"
        try repository.updateMeetingState(id: meetingID, state: meeting.state)
        let oldOverview = summary.overview
        let oldKeyPointsData = summary.keyPointsData
        let oldDecisionsData = summary.decisionsData
        let oldActionItemsData = summary.actionItemsData
        let oldBookmarkInsightsData = summary.bookmarkInsightsData
        let oldModel = summary.model
        let oldCreatedAt = summary.createdAt
        let oldRevisionBacking = summary.contentRevisionBacking
        let oldArchiveStateRawValue = summary.archiveStateRawValue
        let oldArchivedRevision = summary.archivedContentRevision
        let oldArchiveError = summary.lastArchiveErrorCode
        let oldUpdatedAt = meeting.updatedAt

        XCTAssertThrowsError(
            try repository.saveSummary(
                meetingID: meetingID,
                overview: "不应留下的新总结",
                keyPoints: ["新重点"],
                decisions: ["新决定"],
                structuredActionItems: [
                    ActionItem(task: "新任务", owner: nil, dueDate: nil)
                ],
                bookmarkInsights: ["新书签"],
                model: "new-summary-model",
                createdAt: Date(timeIntervalSince1970: 1_200)
            )
        ) { error in
            XCTAssertEqual(error as? MeetingDocumentRevisionError, .overflow)
        }

        XCTAssertTrue(meeting.summary === summary)
        XCTAssertTrue(summary.meeting === meeting)
        XCTAssertEqual(summary.overview, oldOverview)
        XCTAssertEqual(summary.keyPointsData, oldKeyPointsData)
        XCTAssertEqual(summary.decisionsData, oldDecisionsData)
        XCTAssertEqual(summary.actionItemsData, oldActionItemsData)
        XCTAssertEqual(summary.bookmarkInsightsData, oldBookmarkInsightsData)
        XCTAssertEqual(summary.model, oldModel)
        XCTAssertEqual(summary.createdAt, oldCreatedAt)
        XCTAssertEqual(summary.contentRevisionBacking, oldRevisionBacking)
        XCTAssertEqual(summary.archiveStateRawValue, oldArchiveStateRawValue)
        XCTAssertEqual(summary.archivedContentRevision, oldArchivedRevision)
        XCTAssertEqual(summary.lastArchiveErrorCode, oldArchiveError)
        XCTAssertEqual(meeting.updatedAt, oldUpdatedAt)
    }

    func testDetailedMinutesRevisionOverflowThrowsWithoutMutatingExistingRecord()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: makeDetailedMinutes(overview: "旧纪要"),
            model: "old-minutes-model",
            promptVersion: 7,
            createdAt: Date(timeIntervalSince1970: 1_100)
        )
        let meeting = try repository.meeting(id: meetingID)
        let minutes = try XCTUnwrap(meeting.detailedMinutes)
        minutes.contentRevisionBacking = Int.max
        minutes.archiveState = .archived
        minutes.archivedContentRevision = Int.max
        minutes.lastArchiveErrorCode = "minutes-archive-marker"
        try repository.updateMeetingState(id: meetingID, state: meeting.state)
        let oldOverview = minutes.overview
        let oldSectionsData = minutes.sectionsData
        let oldDecisionsData = minutes.decisionsData
        let oldActionItemsData = minutes.actionItemsData
        let oldOpenQuestionsData = minutes.openQuestionsData
        let oldModel = minutes.model
        let oldPromptVersion = minutes.promptVersion
        let oldCreatedAt = minutes.createdAt
        let oldRevisionBacking = minutes.contentRevisionBacking
        let oldArchiveStateRawValue = minutes.archiveStateRawValue
        let oldArchivedRevision = minutes.archivedContentRevision
        let oldArchiveError = minutes.lastArchiveErrorCode
        let oldUpdatedAt = meeting.updatedAt

        XCTAssertThrowsError(
            try repository.saveDetailedMinutes(
                meetingID: meetingID,
                generated: makeDetailedMinutes(overview: "不应留下的新纪要"),
                model: "new-minutes-model",
                promptVersion: 8,
                createdAt: Date(timeIntervalSince1970: 1_200)
            )
        ) { error in
            XCTAssertEqual(error as? MeetingDocumentRevisionError, .overflow)
        }

        XCTAssertTrue(meeting.detailedMinutes === minutes)
        XCTAssertTrue(minutes.meeting === meeting)
        XCTAssertEqual(minutes.overview, oldOverview)
        XCTAssertEqual(minutes.sectionsData, oldSectionsData)
        XCTAssertEqual(minutes.decisionsData, oldDecisionsData)
        XCTAssertEqual(minutes.actionItemsData, oldActionItemsData)
        XCTAssertEqual(minutes.openQuestionsData, oldOpenQuestionsData)
        XCTAssertEqual(minutes.model, oldModel)
        XCTAssertEqual(minutes.promptVersion, oldPromptVersion)
        XCTAssertEqual(minutes.createdAt, oldCreatedAt)
        XCTAssertEqual(minutes.contentRevisionBacking, oldRevisionBacking)
        XCTAssertEqual(minutes.archiveStateRawValue, oldArchiveStateRawValue)
        XCTAssertEqual(minutes.archivedContentRevision, oldArchivedRevision)
        XCTAssertEqual(minutes.lastArchiveErrorCode, oldArchiveError)
        XCTAssertEqual(meeting.updatedAt, oldUpdatedAt)
    }

    func testRegeneratingOneDocumentResetsOnlyItsArchiveMetadata() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: .now
        )
        try repository.saveSummary(
            meetingID: meetingID,
            overview: "旧总结",
            keyPoints: [],
            decisions: [],
            actionItems: [],
            bookmarkInsights: [],
            model: "summary-model"
        )
        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: makeDetailedMinutes(overview: "旧纪要"),
            model: "minutes-model",
            promptVersion: 1
        )
        let meeting = try repository.meeting(id: meetingID)
        let summary = try XCTUnwrap(meeting.summary)
        let minutes = try XCTUnwrap(meeting.detailedMinutes)
        summary.archiveState = .archived
        summary.archivedContentRevision = summary.contentRevision
        summary.lastArchiveErrorCode = "summary-marker"
        minutes.archiveState = .failed
        minutes.archivedContentRevision = minutes.contentRevision
        minutes.lastArchiveErrorCode = "minutes-marker"
        try repository.updateMeetingState(id: meetingID, state: meeting.state)
        let summaryRevision = summary.contentRevision
        let minutesRevision = minutes.contentRevision

        try repository.saveSummary(
            meetingID: meetingID,
            overview: "新总结",
            keyPoints: ["新重点"],
            decisions: [],
            actionItems: [],
            bookmarkInsights: [],
            model: "summary-model"
        )

        XCTAssertEqual(summary.contentRevision, summaryRevision + 1)
        XCTAssertEqual(summary.archiveState, .localOnly)
        XCTAssertNil(summary.archivedContentRevision)
        XCTAssertNil(summary.lastArchiveErrorCode)
        XCTAssertEqual(minutes.contentRevision, minutesRevision)
        XCTAssertEqual(minutes.archiveState, .failed)
        XCTAssertEqual(minutes.archivedContentRevision, minutesRevision)
        XCTAssertEqual(minutes.lastArchiveErrorCode, "minutes-marker")
    }

    func testStartingExplicitArchiveClearsOnlySelectedArchivedRevision()
        throws {
        for kind in MeetingDocumentKind.allCases {
            let repository = try MeetingRepository.inMemory()
            let meetingID = try repository.createMeeting(
                mode: .online,
                startedAt: .now
            )
            try saveBothDocuments(
                repository: repository,
                meetingID: meetingID
            )
            try repository.completeDocumentArchive(
                meetingID: meetingID,
                kind: .summary
            )
            try repository.completeDocumentArchive(
                meetingID: meetingID,
                kind: .detailedMinutes
            )
            let meeting = try repository.meeting(id: meetingID)
            let summaryRevision = try XCTUnwrap(
                meeting.summary?.archivedContentRevision
            )
            let minutesRevision = try XCTUnwrap(
                meeting.detailedMinutes?.archivedContentRevision
            )

            try repository.updateDocumentArchiveState(
                meetingID: meetingID,
                kind: kind,
                archiveState: .archiving,
                meetingState: .archiving
            )

            switch kind {
            case .summary:
                XCTAssertNil(meeting.summary?.archivedContentRevision)
                XCTAssertEqual(
                    meeting.detailedMinutes?.archivedContentRevision,
                    minutesRevision
                )
            case .detailedMinutes:
                XCTAssertNil(
                    meeting.detailedMinutes?.archivedContentRevision
                )
                XCTAssertEqual(
                    meeting.summary?.archivedContentRevision,
                    summaryRevision
                )
            }
        }
    }

    func testRegeneratingDetailedMinutesLeavesSummaryArchiveMetadataUntouched()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.saveSummary(
            meetingID: meetingID,
            overview: "总结",
            keyPoints: [],
            decisions: [],
            actionItems: [],
            bookmarkInsights: [],
            model: "summary-model"
        )
        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: makeDetailedMinutes(overview: "旧纪要"),
            model: "minutes-model",
            promptVersion: 1
        )
        let meeting = try repository.meeting(id: meetingID)
        let summary = try XCTUnwrap(meeting.summary)
        let minutes = try XCTUnwrap(meeting.detailedMinutes)
        summary.archiveState = .failed
        summary.archivedContentRevision = summary.contentRevision
        summary.lastArchiveErrorCode = "summary-marker"
        minutes.archiveState = .archived
        minutes.archivedContentRevision = minutes.contentRevision
        minutes.lastArchiveErrorCode = "minutes-marker"
        try repository.updateMeetingState(id: meetingID, state: meeting.state)
        let summaryRevision = summary.contentRevision
        let minutesRevision = minutes.contentRevision

        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: makeDetailedMinutes(overview: "新纪要"),
            model: "minutes-model-v2",
            promptVersion: 2
        )

        XCTAssertEqual(minutes.contentRevision, minutesRevision + 1)
        XCTAssertEqual(minutes.archiveState, .localOnly)
        XCTAssertNil(minutes.archivedContentRevision)
        XCTAssertNil(minutes.lastArchiveErrorCode)
        XCTAssertEqual(summary.contentRevision, summaryRevision)
        XCTAssertEqual(summary.archiveState, .failed)
        XCTAssertEqual(summary.archivedContentRevision, summaryRevision)
        XCTAssertEqual(summary.lastArchiveErrorCode, "summary-marker")
    }

    func testLegacySummaryArchiveBackingFallsBackToLocalOnly() throws {
        let summary = SummaryRecord(
            overview: "旧总结",
            keyPoints: [],
            decisions: [],
            actionItems: [String](),
            bookmarkInsights: [],
            model: "legacy-model"
        )
        summary.archiveStateRawValue = nil
        summary.contentRevisionBacking = nil

        XCTAssertEqual(summary.archiveState, .localOnly)
        XCTAssertEqual(summary.contentRevision, 0)

        summary.archiveStateRawValue = "future-unknown-state"
        XCTAssertEqual(summary.archiveState, .localOnly)

        try summary.update(
            overview: "首次重新生成",
            keyPoints: [],
            decisions: [],
            actionItems: [String](),
            bookmarkInsights: [],
            model: "current-model",
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(summary.contentRevision, 1)
        XCTAssertEqual(summary.archiveState, .localOnly)
    }

    func testDetailedMinutesRejectCorruptedEncodedFields() throws {
        let record = try DetailedMinutesRecord(
            generated: makeDetailedMinutes(overview: "纪要"),
            model: "deepseek-chat",
            promptVersion: 1
        )
        record.sectionsData = Data("not-json".utf8)

        XCTAssertThrowsError(try record.sections)
    }

    func testTranscriptSourceFallsBackToMixedForNilAndUnknownValues() {
        let transcript = TranscriptRecord(
            startTime: 0,
            endTime: 1,
            text: "旧记录",
            isFinal: true
        )

        XCTAssertNil(transcript.sourceRawValue)
        XCTAssertEqual(transcript.source, .mixed)

        transcript.sourceRawValue = "legacy-unknown-source"

        XCTAssertEqual(transcript.source, .mixed)
    }

    func testLegacyNilSpeakerFieldsFallBackToSafeBusinessDefaults() {
        let meeting = MeetingRecord(
            title: "旧会议",
            mode: .offline,
            state: .ready,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        meeting.speakerDiarizationRequestedBacking = nil
        meeting.speakerProcessingStateRawValue = nil

        XCTAssertFalse(meeting.speakerDiarizationRequested)
        XCTAssertEqual(meeting.speakerProcessingState, .notRequested)

        meeting.speakerProcessingStateRawValue = "legacy-unknown-state"

        XCTAssertEqual(meeting.speakerProcessingState, .notRequested)
    }

    func testCreateMeetingDefaultsSpeakerProcessingToNotRequested() throws {
        let repository = try MeetingRepository.inMemory()

        let id = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertFalse(meeting.speakerDiarizationRequested)
        XCTAssertEqual(meeting.speakerDiarizationRequestedBacking, false)
        XCTAssertEqual(meeting.speakerProcessingState, .notRequested)
        XCTAssertEqual(
            meeting.speakerProcessingStateRawValue,
            SpeakerProcessingState.notRequested.rawValue
        )
        XCTAssertNil(meeting.speakerProcessingErrorCode)
    }

    func testCreateMeetingSnapshotsRequestedSpeakerDiarizationAsPending() throws {
        let repository = try MeetingRepository.inMemory()

        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1_000),
            speakerDiarizationRequested: true
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertTrue(meeting.speakerDiarizationRequested)
        XCTAssertEqual(meeting.speakerDiarizationRequestedBacking, true)
        XCTAssertEqual(meeting.speakerProcessingState, .pending)
        XCTAssertNil(meeting.speakerProcessingErrorCode)
    }

    func testMarkSpeakerProcessingStartedTransitionsRequestedMeeting()
        throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1_000),
            speakerDiarizationRequested: true
        )

        try repository.markSpeakerProcessingStarted(meetingID: id)

        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.speakerProcessingState, .processing)
        XCTAssertNil(meeting.speakerProcessingErrorCode)
    }

    func testMarkSpeakerProcessingStartedLeavesUnrequestedAndDegradedStates()
        throws {
        let repository = try MeetingRepository.inMemory()
        let unrequestedID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        let degradedID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 1_001),
            speakerDiarizationRequested: true
        )
        let degraded = try repository.meeting(id: degradedID)
        degraded.speakerProcessingState = .degraded
        degraded.speakerProcessingErrorCode =
            "source_track_write_failed_microphone"
        try repository.updateMeetingState(
            id: degradedID,
            state: degraded.state
        )

        try repository.markSpeakerProcessingStarted(meetingID: unrequestedID)
        try repository.markSpeakerProcessingStarted(meetingID: degradedID)

        let unrequested = try repository.meeting(id: unrequestedID)
        XCTAssertEqual(unrequested.speakerProcessingState, .notRequested)
        XCTAssertNil(unrequested.speakerProcessingErrorCode)
        XCTAssertEqual(degraded.speakerProcessingState, .degraded)
        XCTAssertEqual(
            degraded.speakerProcessingErrorCode,
            "source_track_write_failed_microphone"
        )
    }

    func testCreateAppendAndReloadCompleteMeeting() throws {
        let repository = try MeetingRepository.inMemory()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let summaryDate = Date(timeIntervalSince1970: 1_100)
        let checkpointDate = Date(timeIntervalSince1970: 1_200)

        let id = try repository.createMeeting(
            mode: .offline,
            startedAt: startedAt,
            title: "项目会议",
            audioManifestPath: "meetings/audio/manifest.json"
        )
        try repository.appendTranscript(
            meetingID: id,
            start: 0,
            end: 5,
            text: "项目开始",
            isFinal: true,
            sourceRevision: 2
        )
        try repository.appendBookmark(
            meetingID: id,
            timestamp: 4,
            createdAt: Date(timeIntervalSince1970: 1_004)
        )
        try repository.saveSummary(
            meetingID: id,
            overview: "确认启动计划",
            keyPoints: ["范围已确认"],
            decisions: ["今日启动"],
            actionItems: ["负责人准备排期"],
            bookmarkInsights: ["00:04 核心决定"],
            model: "deepseek-chat",
            createdAt: summaryDate
        )
        try repository.setNotionPage(
            meetingID: id,
            pageID: "page-id",
            pageURL: "https://www.notion.so/page-id"
        )
        try repository.saveArchiveCheckpoint(
            meetingID: id,
            notionPageID: "page-id",
            nextSection: "transcript",
            nextBatchIndex: 2,
            updatedAt: checkpointDate
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.title, "项目会议")
        XCTAssertEqual(meeting.mode, .offline)
        XCTAssertEqual(meeting.state, .preparing)
        XCTAssertEqual(meeting.startedAt, startedAt)
        XCTAssertEqual(meeting.audioManifestPath, "meetings/audio/manifest.json")
        XCTAssertEqual(meeting.notionPageID, "page-id")
        XCTAssertEqual(meeting.notionPageURL, "https://www.notion.so/page-id")

        let transcript = try XCTUnwrap(meeting.transcripts.first)
        XCTAssertEqual(transcript.startTime, 0, accuracy: 0.001)
        XCTAssertEqual(transcript.endTime, 5, accuracy: 0.001)
        XCTAssertEqual(transcript.text, "项目开始")
        XCTAssertTrue(transcript.isFinal)
        XCTAssertNil(transcript.speakerID)
        XCTAssertEqual(transcript.sourceRevision, 2)
        XCTAssertNil(transcript.sourceRawValue)
        XCTAssertEqual(transcript.source, .mixed)

        let bookmark = try XCTUnwrap(meeting.bookmarks.first)
        XCTAssertEqual(bookmark.timestamp, 4, accuracy: 0.001)

        let summary = try XCTUnwrap(meeting.summary)
        XCTAssertEqual(summary.overview, "确认启动计划")
        XCTAssertEqual(summary.keyPoints, ["范围已确认"])
        XCTAssertEqual(summary.decisions, ["今日启动"])
        XCTAssertEqual(summary.actionItems, ["负责人准备排期"])
        XCTAssertEqual(summary.bookmarkInsights, ["00:04 核心决定"])
        XCTAssertEqual(summary.model, "deepseek-chat")
        XCTAssertEqual(summary.createdAt, summaryDate)

        let checkpoint = try XCTUnwrap(meeting.archiveCheckpoint)
        XCTAssertEqual(checkpoint.notionPageID, "page-id")
        XCTAssertEqual(checkpoint.nextSection, "transcript")
        XCTAssertEqual(checkpoint.nextBatchIndex, 2)
        XCTAssertEqual(checkpoint.updatedAt, checkpointDate)
    }

    func testMeetingsPlaceMostRecentlyPinnedFirstThenSortUnpinnedByStartDate() throws {
        let repository = try MeetingRepository.inMemory()
        let oldestID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100),
            title: "最早会议"
        )
        let middleID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 200),
            title: "中间会议"
        )
        let newestID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 300),
            title: "最新会议"
        )

        try repository.setPinned(
            meetingID: newestID,
            pinnedAt: Date(timeIntervalSince1970: 1_000)
        )
        try repository.setPinned(
            meetingID: oldestID,
            pinnedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(
            try repository.meetings().map(\.id),
            [oldestID, newestID, middleID]
        )
        XCTAssertGreaterThan(
            try repository.meeting(id: oldestID).updatedAt,
            Date(timeIntervalSince1970: 100)
        )
    }

    func testClearingPinRestoresNormalMeetingOrder() throws {
        let repository = try MeetingRepository.inMemory()
        let olderID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let newerID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 200)
        )
        try repository.setPinned(
            meetingID: olderID,
            pinnedAt: Date(timeIntervalSince1970: 1_000)
        )

        try repository.setPinned(meetingID: olderID, pinnedAt: nil)

        XCTAssertEqual(try repository.meetings().map(\.id), [newerID, olderID])
        XCTAssertNil(try repository.meeting(id: olderID).pinnedAt)
        XCTAssertFalse(try repository.meeting(id: olderID).isPinned)
    }

    func testUpdatingTitlePersistsValueAndRefreshesUpdatedAt() throws {
        let repository = try MeetingRepository.inMemory()
        let startedAt = Date(timeIntervalSince1970: 100)
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: startedAt,
            title: "旧标题"
        )

        try repository.updateTitle(
            meetingID: meetingID,
            title: "新标题"
        )

        let meeting = try repository.meeting(id: meetingID)
        XCTAssertEqual(meeting.title, "新标题")
        XCTAssertGreaterThan(meeting.updatedAt, startedAt)
    }

    func testUpdateTitleRestoresRealRecordWhenInjectedSaveFails() throws {
        var saveAttempts = 0
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                saveAttempts += 1
                if saveAttempts == 2 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100),
            title: "旧标题"
        )
        let meeting = try repository.meeting(id: meetingID)
        let originalTitle = meeting.title
        let originalUpdatedAt = meeting.updatedAt

        XCTAssertThrowsError(
            try repository.updateTitle(
                meetingID: meetingID,
                title: "不应留在内存中"
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        let reloaded = try repository.meeting(id: meetingID)
        XCTAssertTrue(reloaded === meeting)
        XCTAssertEqual(reloaded.title, originalTitle)
        XCTAssertEqual(reloaded.updatedAt, originalUpdatedAt)
        XCTAssertEqual(saveAttempts, 2)
    }

    func testExistingInitializerAndNewRepositoryRecordsDefaultToUnpinned() throws {
        let existingStyleRecord = MeetingRecord(
            title: "旧记录",
            mode: .offline,
            state: .ready,
            startedAt: Date(timeIntervalSince1970: 50)
        )
        let repository = try MeetingRepository.inMemory()
        let newID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertNil(existingStyleRecord.pinnedAt)
        XCTAssertFalse(existingStyleRecord.isPinned)
        XCTAssertNil(try repository.meeting(id: newID).pinnedAt)
        XCTAssertFalse(try repository.meeting(id: newID).isPinned)
    }

    func testMeetingOrderUsesUUIDAsFinalDeterministicTieBreaker() throws {
        let repository = try MeetingRepository.inMemory()
        let timestamp = Date(timeIntervalSince1970: 100)
        let firstID = try repository.createMeeting(
            mode: .offline,
            startedAt: timestamp
        )
        let secondID = try repository.createMeeting(
            mode: .online,
            startedAt: timestamp
        )

        let expected = [firstID, secondID].sorted {
            $0.uuidString < $1.uuidString
        }

        XCTAssertEqual(try repository.meetings().map(\.id), expected)
    }

    func testFinalizingMeetingPersistsReadyStateEndAndActiveDuration() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let endedAt = Date(timeIntervalSince1970: 145)

        try repository.finalizeMeeting(
            id: id,
            endedAt: endedAt,
            activeDuration: 31
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.state, .ready)
        XCTAssertEqual(meeting.endedAt, endedAt)
        XCTAssertEqual(meeting.activeDuration, 31, accuracy: 0.001)
        XCTAssertEqual(meeting.updatedAt, endedAt)
    }

    func testInterruptedFinalizationPersistsRecoveryMarkersAtomically() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        try repository.updateMeetingState(id: id, state: .recording)
        let endedAt = Date(timeIntervalSince1970: 145)

        try repository.finalizeInterruptedMeeting(
            id: id,
            endedAt: endedAt,
            activeDuration: 31,
            lastErrorCode: "capture_interrupted"
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.state, .ready)
        XCTAssertEqual(meeting.endedAt, endedAt)
        XCTAssertEqual(meeting.activeDuration, 31, accuracy: 0.001)
        XCTAssertEqual(meeting.lastErrorCode, "capture_interrupted")
        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
        XCTAssertEqual(
            meeting.speakerProcessingErrorCode,
            "speaker_diarization_capture_interrupted"
        )
    }

    func testFinalizingMeetingAtomicallyPersistsSourceDegradation() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        let endedAt = Date(timeIntervalSince1970: 145)

        try repository.finalizeMeeting(
            id: id,
            endedAt: endedAt,
            activeDuration: 31,
            sourceDegradationErrorCode:
                "source_track_write_failed_microphone"
        )

        let meeting = try repository.meeting(id: id)
        XCTAssertEqual(meeting.state, .ready)
        XCTAssertEqual(meeting.endedAt, endedAt)
        XCTAssertEqual(meeting.activeDuration, 31, accuracy: 0.001)
        XCTAssertEqual(meeting.updatedAt, endedAt)
        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
        XCTAssertEqual(
            meeting.speakerProcessingErrorCode,
            "source_track_write_failed_microphone"
        )
    }

    func testFinalizingRequestedMeetingCompletesSpeakerProcessingAndClearsError()
        throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        try repository.markSpeakerProcessingStarted(meetingID: id)
        let meeting = try repository.meeting(id: id)
        meeting.speakerProcessingErrorCode = "stale_progress_error"

        try repository.finalizeMeeting(
            id: id,
            endedAt: Date(timeIntervalSince1970: 145),
            activeDuration: 31
        )

        XCTAssertEqual(meeting.speakerProcessingState, .completed)
        XCTAssertNil(meeting.speakerProcessingErrorCode)
    }

    func testFinalizingPreservesExistingSpeakerDegradationWithoutNewCode()
        throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: id)
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode =
            "source_track_write_failed_microphone"
        try repository.updateMeetingState(id: id, state: .finalizing)

        try repository.finalizeMeeting(
            id: id,
            endedAt: Date(timeIntervalSince1970: 145),
            activeDuration: 31
        )

        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
        XCTAssertEqual(
            meeting.speakerProcessingErrorCode,
            "source_track_write_failed_microphone"
        )
    }

    func testCompletedSpeakerFieldsRollBackWhenFinalMeetingSaveFails()
        throws {
        var saveAttempts = 0
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                saveAttempts += 1
                if saveAttempts == 3 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        try repository.markSpeakerProcessingStarted(meetingID: id)
        let meeting = try repository.meeting(id: id)
        meeting.speakerProcessingErrorCode = "prior_safe_error"

        XCTAssertThrowsError(
            try repository.finalizeMeeting(
                id: id,
                endedAt: Date(timeIntervalSince1970: 145),
                activeDuration: 31
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        XCTAssertEqual(meeting.state, .preparing)
        XCTAssertNil(meeting.endedAt)
        XCTAssertEqual(meeting.speakerProcessingState, .processing)
        XCTAssertEqual(
            meeting.speakerProcessingErrorCode,
            "prior_safe_error"
        )
        XCTAssertEqual(saveAttempts, 3)
    }

    func testAtomicFinalizationRestoresEveryFieldWhenSaveFails() throws {
        var saveAttempts = 0
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                saveAttempts += 1
                if saveAttempts == 2 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let startedAt = Date(timeIntervalSince1970: 100)
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: startedAt,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: id)
        let originalStateRawValue = meeting.stateRawValue
        let originalEndedAt = meeting.endedAt
        let originalActiveDuration = meeting.activeDuration
        let originalUpdatedAt = meeting.updatedAt
        let originalSpeakerStateRawValue =
            meeting.speakerProcessingStateRawValue
        let originalSpeakerErrorCode = meeting.speakerProcessingErrorCode

        XCTAssertThrowsError(
            try repository.finalizeMeeting(
                id: id,
                endedAt: Date(timeIntervalSince1970: 145),
                activeDuration: 31,
                sourceDegradationErrorCode:
                    "source_track_write_failed_microphone"
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        let reloaded = try repository.meeting(id: id)
        XCTAssertTrue(reloaded === meeting)
        XCTAssertEqual(reloaded.stateRawValue, originalStateRawValue)
        XCTAssertEqual(reloaded.endedAt, originalEndedAt)
        XCTAssertEqual(reloaded.activeDuration, originalActiveDuration)
        XCTAssertEqual(reloaded.updatedAt, originalUpdatedAt)
        XCTAssertEqual(
            reloaded.speakerProcessingStateRawValue,
            originalSpeakerStateRawValue
        )
        XCTAssertEqual(
            reloaded.speakerProcessingErrorCode,
            originalSpeakerErrorCode
        )
        XCTAssertEqual(saveAttempts, 2)
    }

    func testDegradationAdapterRestoresUpdatedAtWhenSaveFails() async throws {
        var saveAttempts = 0
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                saveAttempts += 1
                if saveAttempts == 2 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let id = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: id)
        let originalStateRawValue =
            meeting.speakerProcessingStateRawValue
        let originalErrorCode = meeting.speakerProcessingErrorCode
        let originalUpdatedAt = meeting.updatedAt
        let adapter = MeetingRepositoryLifecycleAdapter(
            repository: repository
        )

        do {
            try await adapter.markSpeakerProcessingDegraded(
                meetingID: id,
                errorCode: "source_track_write_failed_microphone"
            )
            XCTFail("Expected injected repository save failure")
        } catch {
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        let reloaded = try repository.meeting(id: id)
        XCTAssertEqual(
            reloaded.speakerProcessingStateRawValue,
            originalStateRawValue
        )
        XCTAssertEqual(reloaded.speakerProcessingErrorCode, originalErrorCode)
        XCTAssertEqual(reloaded.updatedAt, originalUpdatedAt)
        XCTAssertEqual(saveAttempts, 2)
    }

    func testReplaceTranscriptsPersistsAttributedFinalRevision() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "临时转录"
        )

        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 4,
                        endTime: 6,
                        text: "远端发言"
                    ),
                    speakerID: "remote",
                    source: .system
                ),
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 1,
                        endTime: 3,
                        text: "本地发言"
                    ),
                    speakerID: "me",
                    source: .microphone
                )
            ],
            sourceRevision: 7
        )

        let persistedMeeting = try repository.meeting(id: meetingID)
        let transcripts = persistedMeeting.transcripts.sorted {
            $0.startTime < $1.startTime
        }
        XCTAssertEqual(transcripts.count, 2)
        XCTAssertEqual(
            transcripts.map(\.text),
            ["本地发言", "远端发言"]
        )
        XCTAssertEqual(transcripts.map(\.speakerID), ["me", "remote"])
        XCTAssertEqual(transcripts.map(\.source), [.microphone, .system])
        XCTAssertEqual(transcripts.map(\.sourceRevision), [7, 7])
        XCTAssertTrue(transcripts.allSatisfy(\.isFinal))
        XCTAssertTrue(
            transcripts.allSatisfy { $0.meeting === persistedMeeting }
        )
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 2)
    }

    func testSpeakerDisplayNameIsNormalizedUpdatedAndClearedPerSpeaker()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 2,
            end: 3,
            text: "第一段",
            speakerID: "room-1"
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 6,
            end: 8,
            text: "第二段",
            speakerID: "room-1"
        )

        try repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "room-1",
            displayName: " 张三 ",
            now: Date(timeIntervalSince1970: 200)
        )

        var meeting = try repository.meeting(id: meetingID)
        var record = try XCTUnwrap(meeting.speakerNames.first)
        XCTAssertEqual(
            try repository.speakerDisplayNames(meetingID: meetingID),
            ["room-1": "张三"]
        )
        XCTAssertEqual(record.evidenceStartTime, 2)
        XCTAssertEqual(record.evidenceEndTime, 8)
        XCTAssertEqual(record.createdAt, Date(timeIntervalSince1970: 200))

        try repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "room-1",
            displayName: "张老师",
            now: Date(timeIntervalSince1970: 300)
        )

        meeting = try repository.meeting(id: meetingID)
        record = try XCTUnwrap(meeting.speakerNames.first)
        XCTAssertEqual(meeting.speakerNames.count, 1)
        XCTAssertEqual(record.displayName, "张老师")
        XCTAssertEqual(record.createdAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(record.updatedAt, Date(timeIntervalSince1970: 300))

        try repository.clearSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "room-1"
        )

        XCTAssertTrue(
            try repository.speakerDisplayNames(meetingID: meetingID).isEmpty
        )
        XCTAssertEqual(try repository.count(SpeakerNameRecord.self), 0)
    }

    func testSpeakerDisplayNameRejectsUnknownSpeakerAndCascadesWithMeeting()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )

        XCTAssertThrowsError(
            try repository.setSpeakerDisplayName(
                meetingID: meetingID,
                speakerID: "room-9",
                displayName: "不存在"
            )
        ) { error in
            XCTAssertEqual(
                error as? SpeakerNameRepositoryError,
                .speakerNotFound("room-9")
            )
        }

        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "发言",
            speakerID: "room-1"
        )
        try repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "room-1",
            displayName: "李四"
        )
        XCTAssertEqual(try repository.count(SpeakerNameRecord.self), 1)

        try repository.deleteMeeting(id: meetingID)

        XCTAssertEqual(try repository.count(SpeakerNameRecord.self), 0)
    }

    func testSpeakerDisplayNameUpdateRollsBackWhenSaveFails() throws {
        let failure = RepositorySaveFailureSwitch()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                if failure.shouldFail {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "发言",
            speakerID: "room-1"
        )
        try repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "room-1",
            displayName: "原姓名",
            now: Date(timeIntervalSince1970: 100)
        )
        let originalMeetingUpdatedAt = try repository.meeting(id: meetingID)
            .updatedAt
        failure.shouldFail = true

        XCTAssertThrowsError(
            try repository.setSpeakerDisplayName(
                meetingID: meetingID,
                speakerID: "room-1",
                displayName: "错误更新",
                now: Date(timeIntervalSince1970: 200)
            )
        ) { error in
            XCTAssertEqual(error as? InjectedRepositorySaveError, .forced)
        }

        let meeting = try repository.meeting(id: meetingID)
        let record = try XCTUnwrap(meeting.speakerNames.first)
        XCTAssertEqual(record.displayName, "原姓名")
        XCTAssertEqual(record.updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(meeting.updatedAt, originalMeetingUpdatedAt)
    }

    func testReplacementPersistsAssemblySequenceAcrossRepositoryReload() throws {
        var capturedContainer: ModelContainer?
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                capturedContainer = context.container
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let assembled = SpeakerTranscriptAssembler().assemble([
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 1,
                    endTime: 5,
                    text: "first"
                ),
                speakerID: "remote",
                source: .system
            ),
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 1,
                    endTime: 3,
                    text: "second"
                ),
                speakerID: "me",
                source: .microphone
            ),
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 1,
                    endTime: 4,
                    text: "third"
                ),
                speakerID: "room-1",
                source: .room
            )
        ])

        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: assembled,
            sourceRevision: 8
        )

        let sameRepositoryRecords = try repository.transcripts(
            meetingID: meetingID
        )
        XCTAssertEqual(
            sameRepositoryRecords.map(\.text),
            ["first", "second", "third"]
        )
        XCTAssertEqual(
            sameRepositoryRecords.map(\.sequenceIndex),
            [0, 1, 2]
        )

        let reloadedRepository = MeetingRepository(
            container: try XCTUnwrap(capturedContainer)
        )
        let reloadedRecords = try reloadedRepository.transcripts(
            meetingID: meetingID
        )
        XCTAssertEqual(
            reloadedRecords.map(\.text),
            ["first", "second", "third"]
        )
        XCTAssertEqual(reloadedRecords.map(\.sequenceIndex), [0, 1, 2])
    }

    func testReplacementReadSortsOutOfOrderDraftsChronologically() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )

        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 10,
                        endTime: 12,
                        text: "later"
                    ),
                    speakerID: "remote",
                    source: .system
                ),
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 1,
                        endTime: 2,
                        text: "earlier"
                    ),
                    speakerID: "me",
                    source: .microphone
                ),
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 5,
                        endTime: 6,
                        text: "middle"
                    ),
                    speakerID: "room-1",
                    source: .room
                )
            ],
            sourceRevision: 8
        )

        let records = try repository.transcripts(meetingID: meetingID)

        XCTAssertEqual(records.map(\.text), ["earlier", "middle", "later"])
        XCTAssertEqual(records.map(\.sequenceIndex), [1, 2, 0])
    }

    func testTranscriptReadTotallyOrdersMixedSequenceRows() throws {
        var capturedContext: ModelContext?
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                capturedContext = context
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        let meeting = try repository.meeting(id: meetingID)
        let records = [
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!,
                startTime: 1,
                endTime: 2,
                text: "same-legacy-long",
                isFinal: true,
                meeting: meeting
            ),
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                startTime: 1,
                endTime: 5,
                text: "same-indexed-one",
                isFinal: true,
                sequenceIndex: 1,
                meeting: meeting
            ),
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                startTime: 2,
                endTime: 3,
                text: "later-indexed-zero",
                isFinal: true,
                sequenceIndex: 0,
                meeting: meeting
            ),
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
                startTime: 1,
                endTime: 6,
                text: "same-indexed-zero",
                isFinal: true,
                sequenceIndex: 0,
                meeting: meeting
            ),
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
                startTime: 0,
                endTime: 1,
                text: "earliest-legacy",
                isFinal: true,
                meeting: meeting
            ),
            TranscriptRecord(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                startTime: 1,
                endTime: 1,
                text: "same-legacy-short",
                isFinal: true,
                meeting: meeting
            )
        ]
        let modelContext = try XCTUnwrap(capturedContext)
        records.forEach(modelContext.insert)
        meeting.transcripts = records
        try modelContext.save()

        let sortedRecords = try repository.transcripts(meetingID: meetingID)

        XCTAssertEqual(
            sortedRecords.map(\.text),
            [
                "earliest-legacy",
                "same-indexed-zero",
                "same-indexed-one",
                "same-legacy-short",
                "same-legacy-long",
                "later-indexed-zero"
            ]
        )
    }

    func testLegacyTranscriptsWithoutSequenceFallBackToChronology() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 5,
            end: 6,
            text: "later"
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 1,
            end: 2,
            text: "earlier"
        )

        let records = try repository.transcripts(meetingID: meetingID)

        XCTAssertEqual(records.map(\.text), ["earlier", "later"])
        XCTAssertTrue(records.allSatisfy { $0.sequenceIndex == nil })
    }

    func testReplaceTranscriptsRestoresExactPreviousStateWhenSaveFails() throws {
        var saveAttempts = 0
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                saveAttempts += 1
                if saveAttempts == 4 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 2,
            text: "旧转录一",
            isFinal: false,
            speakerID: "legacy-1",
            sourceRevision: 2
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 3,
            end: 5,
            text: "旧转录二",
            isFinal: true,
            speakerID: "legacy-2",
            sourceRevision: 3
        )
        let meeting = try repository.meeting(id: meetingID)
        let oldTranscripts = meeting.transcripts
        let oldMetadata = oldTranscripts.map(TranscriptMetadata.init)
        let oldUpdatedAt = meeting.updatedAt

        XCTAssertThrowsError(
            try repository.replaceTranscripts(
                meetingID: meetingID,
                drafts: [
                    AttributedTranscriptDraft(
                        transcript: TranscriptDraft(
                            startTime: 10,
                            endTime: 12,
                            text: "不应残留"
                        ),
                        speakerID: "remote",
                        source: .system
                    )
                ],
                sourceRevision: 9
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        let reloaded = try repository.meeting(id: meetingID)
        XCTAssertTrue(reloaded === meeting)
        XCTAssertEqual(reloaded.updatedAt, oldUpdatedAt)
        XCTAssertEqual(reloaded.transcripts.count, oldTranscripts.count)
        XCTAssertTrue(
            zip(reloaded.transcripts, oldTranscripts).allSatisfy(===)
        )
        XCTAssertEqual(
            reloaded.transcripts.map(TranscriptMetadata.init),
            oldMetadata
        )
        XCTAssertTrue(
            reloaded.transcripts.allSatisfy { $0.meeting === meeting }
        )
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 2)
        XCTAssertEqual(saveAttempts, 4)
    }

    func testReplaceTranscriptsFailurePreservesUnrelatedPendingInsertion() throws {
        var saveAttempts = 0
        var capturedContext: ModelContext?
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                capturedContext = context
                saveAttempts += 1
                if saveAttempts == 3 {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 100),
            title: "目标会议"
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 2,
            text: "旧转录",
            speakerID: "legacy",
            sourceRevision: 2
        )
        let meeting = try repository.meeting(id: meetingID)
        let oldTranscript = try XCTUnwrap(meeting.transcripts.first)
        let pendingMeetingID = UUID()
        let pendingMeeting = MeetingRecord(
            id: pendingMeetingID,
            title: "不相关的待保存会议",
            mode: .offline,
            state: .preparing,
            startedAt: Date(timeIntervalSince1970: 200)
        )
        try XCTUnwrap(capturedContext).insert(pendingMeeting)

        XCTAssertThrowsError(
            try repository.replaceTranscripts(
                meetingID: meetingID,
                drafts: [
                    AttributedTranscriptDraft(
                        transcript: TranscriptDraft(
                            startTime: 10,
                            endTime: 12,
                            text: "失败的新转录"
                        ),
                        speakerID: "remote",
                        source: .system
                    )
                ],
                sourceRevision: 9
            )
        ) { error in
            XCTAssertEqual(
                error as? InjectedRepositorySaveError,
                .forced
            )
        }

        try repository.appendBookmark(
            meetingID: meetingID,
            timestamp: 1
        )

        let reloaded = try XCTUnwrap(
            repository.meetings().first { $0.id == meetingID }
        )
        XCTAssertNotNil(
            try repository.meetings().first {
                $0.id == pendingMeetingID
            }
        )
        XCTAssertEqual(reloaded.transcripts.count, 1)
        let restoredTranscript = try XCTUnwrap(
            reloaded.transcripts.first
        )
        XCTAssertTrue(restoredTranscript === oldTranscript)
        XCTAssertEqual(restoredTranscript.text, "旧转录")
        XCTAssertTrue(restoredTranscript.meeting === reloaded)
        XCTAssertEqual(try repository.count(MeetingRecord.self), 2)
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 1)
        XCTAssertEqual(saveAttempts, 4)
    }

    func testDeletingMeetingCascadesToAllRelatedRecords() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .online, startedAt: .now)
        try repository.appendTranscript(
            meetingID: id,
            start: 0,
            end: 1,
            text: "测试"
        )
        try repository.appendBookmark(meetingID: id, timestamp: 0.5)
        try repository.saveSummary(
            meetingID: id,
            overview: "摘要",
            keyPoints: [],
            decisions: [],
            actionItems: [],
            bookmarkInsights: [],
            model: "deepseek-chat"
        )
        try repository.saveDetailedMinutes(
            meetingID: id,
            generated: makeDetailedMinutes(overview: "完整纪要"),
            model: "deepseek-chat",
            promptVersion: 1
        )
        try repository.saveArchiveCheckpoint(
            meetingID: id,
            notionPageID: "page-id",
            nextSection: "metadata",
            nextBatchIndex: 0
        )

        try repository.deleteMeeting(id: id)

        XCTAssertEqual(try repository.count(MeetingRecord.self), 0)
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 0)
        XCTAssertEqual(try repository.count(BookmarkRecord.self), 0)
        XCTAssertEqual(try repository.count(SummaryRecord.self), 0)
        XCTAssertEqual(try repository.count(DetailedMinutesRecord.self), 0)
        XCTAssertEqual(try repository.count(ArchiveCheckpointRecord.self), 0)
        XCTAssertThrowsError(try repository.meeting(id: id)) { error in
            XCTAssertEqual(error as? MeetingRepositoryError, .meetingNotFound(id))
        }
    }

    func testMissingMeetingWritesFailWithoutCreatingOrphans() throws {
        let repository = try MeetingRepository.inMemory()
        let missingID = UUID()

        XCTAssertThrowsError(
            try repository.appendTranscript(
                meetingID: missingID,
                start: 0,
                end: 1,
                text: "不应保存"
            )
        ) { error in
            XCTAssertEqual(error as? MeetingRepositoryError, .meetingNotFound(missingID))
        }
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 0)
    }

    func testBeginSpeakerDiarizationRetryAllowsDegradedAndCompletedMeetings()
        throws {
        let repository = try MeetingRepository.inMemory()
        let degradedID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let completedID = try repository.createMeeting(
            mode: .online,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let degraded = try repository.meeting(id: degradedID)
        degraded.speakerProcessingState = .degraded
        degraded.speakerProcessingErrorCode =
            "speaker_diarization_inference_failed"
        let completed = try repository.meeting(id: completedID)
        completed.speakerProcessingState = .completed
        try repository.updateMeetingState(id: degradedID, state: .ready)
        try repository.updateMeetingState(id: completedID, state: .ready)

        try repository.beginSpeakerDiarizationRetry(meetingID: degradedID)
        try repository.beginSpeakerDiarizationRetry(meetingID: completedID)

        XCTAssertEqual(degraded.speakerProcessingState, .processing)
        XCTAssertNil(degraded.speakerProcessingErrorCode)
        XCTAssertEqual(completed.speakerProcessingState, .processing)
        XCTAssertNil(completed.speakerProcessingErrorCode)
    }

    func testBeginSpeakerDiarizationRetryAllowsInterruptedProcessingInStableStates()
        throws {
        for state in [
            RecordingState.ready,
            .summaryReady,
            .archived,
        ] {
            let repository = try MeetingRepository.inMemory()
            let meetingID = try repository.createMeeting(
                mode: .offline,
                startedAt: .now,
                speakerDiarizationRequested: true
            )
            let meeting = try repository.meeting(id: meetingID)
            meeting.speakerProcessingState = .processing
            meeting.speakerProcessingErrorCode = "stale_error"
            try repository.updateMeetingState(id: meetingID, state: state)

            try repository.beginSpeakerDiarizationRetry(meetingID: meetingID)

            XCTAssertEqual(meeting.speakerProcessingState, .processing)
            XCTAssertNil(meeting.speakerProcessingErrorCode)
        }
    }

    func testBeginSpeakerDiarizationRetryRejectsProcessingInLiveStates()
        throws {
        let liveStates = RecordingState.allCases.filter {
            ![.ready, .summaryReady, .archived].contains($0)
        }
        for state in liveStates {
            let repository = try MeetingRepository.inMemory()
            let meetingID = try repository.createMeeting(
                mode: .offline,
                startedAt: .now,
                speakerDiarizationRequested: true
            )
            let meeting = try repository.meeting(id: meetingID)
            meeting.speakerProcessingState = .processing
            try repository.updateMeetingState(id: meetingID, state: state)

            XCTAssertThrowsError(
                try repository.beginSpeakerDiarizationRetry(
                    meetingID: meetingID
                )
            ) { error in
                XCTAssertEqual(
                    error as? MeetingRepositoryError,
                    .invalidState(.processing)
                )
            }
        }
    }

    func testRecordingStatesDefineInterruptedSpeakerRetryRecoveryBoundary() {
        XCTAssertEqual(
            RecordingState.allCases.filter(
                \.allowsInterruptedSpeakerDiarizationRetryRecovery
            ),
            [.ready, .summaryReady, .archived]
        )
    }

    func testBeginSpeakerDiarizationRetryRejectsInvalidStateAndMissingMeeting()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )

        XCTAssertThrowsError(
            try repository.beginSpeakerDiarizationRetry(meetingID: meetingID)
        ) { error in
            XCTAssertEqual(
                error as? MeetingRepositoryError,
                .invalidState(.pending)
            )
        }
        let missingID = UUID()
        XCTAssertThrowsError(
            try repository.beginSpeakerDiarizationRetry(meetingID: missingID)
        ) { error in
            XCTAssertEqual(
                error as? MeetingRepositoryError,
                .meetingNotFound(missingID)
            )
        }
    }

    func testBeginSpeakerDiarizationRetryRestoresEveryFieldWhenSaveFails()
        throws {
        let failure = RepositorySaveFailureSwitch()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                if failure.shouldFail {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode = "prior_error"
        try repository.updateMeetingState(id: meetingID, state: .ready)
        let priorUpdatedAt = meeting.updatedAt
        failure.shouldFail = true

        XCTAssertThrowsError(
            try repository.beginSpeakerDiarizationRetry(meetingID: meetingID)
        ) { error in
            XCTAssertEqual(error as? InjectedRepositorySaveError, .forced)
        }

        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
        XCTAssertEqual(meeting.speakerProcessingErrorCode, "prior_error")
        XCTAssertEqual(meeting.updatedAt, priorUpdatedAt)
    }

    func testCompleteSpeakerDiarizationRetryAtomicallyReplacesTranscriptsAndStatus()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .online,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "old",
            speakerID: "remote",
            sourceRevision: 1
        )
        try repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "remote",
            displayName: "旧姓名"
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        try repository.updateMeetingState(id: meetingID, state: .ready)
        try repository.beginSpeakerDiarizationRetry(meetingID: meetingID)

        try repository.completeSpeakerDiarizationRetry(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 2,
                        endTime: 3,
                        text: "new"
                    ),
                    speakerID: "remote-1",
                    source: .system
                )
            ],
            sourceRevision: 2,
            speakerDisplayNames: ["remote-1": "新姓名"]
        )

        let reloaded = try repository.meeting(id: meetingID)
        XCTAssertEqual(reloaded.speakerProcessingState, .completed)
        XCTAssertNil(reloaded.speakerProcessingErrorCode)
        XCTAssertEqual(reloaded.transcripts.map(\.text), ["new"])
        XCTAssertEqual(reloaded.transcripts.map(\.speakerID), ["remote-1"])
        XCTAssertEqual(reloaded.transcripts.map(\.source), [.system])
        XCTAssertEqual(reloaded.transcripts.map(\.sourceRevision), [2])
        XCTAssertEqual(reloaded.speakerDisplayNames, ["remote-1": "新姓名"])
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 1)
        XCTAssertEqual(try repository.count(SpeakerNameRecord.self), 1)
    }

    func testCompleteSpeakerDiarizationRetryLeavesOriginalGraphWhenSaveFails()
        throws {
        let failure = RepositorySaveFailureSwitch()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                if failure.shouldFail {
                    failure.capturedMeeting = try context.fetch(
                        FetchDescriptor<MeetingRecord>()
                    ).first
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        try repository.appendTranscript(
            meetingID: meetingID,
            start: 0,
            end: 1,
            text: "old",
            speakerID: "room-old",
            sourceRevision: 1
        )
        try repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "room-old",
            displayName: "原姓名"
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        meeting.speakerProcessingErrorCode = "prior_error"
        try repository.updateMeetingState(id: meetingID, state: .ready)
        try repository.beginSpeakerDiarizationRetry(meetingID: meetingID)
        let originalTranscript = try XCTUnwrap(meeting.transcripts.first)
        let originalUpdatedAt = meeting.updatedAt
        failure.shouldFail = true

        XCTAssertThrowsError(
            try repository.completeSpeakerDiarizationRetry(
                meetingID: meetingID,
                drafts: [
                    AttributedTranscriptDraft(
                        transcript: .init(
                            startTime: 2,
                            endTime: 3,
                            text: "new"
                        ),
                        speakerID: "room-1",
                        source: .room
                    )
                ],
                sourceRevision: 2,
                speakerDisplayNames: ["room-1": "错误迁移"]
            )
        ) { error in
            XCTAssertEqual(error as? InjectedRepositorySaveError, .forced)
        }

        let reloaded = try repository.meeting(id: meetingID)
        XCTAssertEqual(reloaded.speakerProcessingState, .processing)
        XCTAssertNil(reloaded.speakerProcessingErrorCode)
        XCTAssertEqual(reloaded.updatedAt, originalUpdatedAt)
        XCTAssertEqual(reloaded.transcripts.count, 1)
        XCTAssertTrue(reloaded.transcripts.first === originalTranscript)
        XCTAssertEqual(reloaded.transcripts.first?.text, "old")
        XCTAssertEqual(reloaded.speakerDisplayNames, ["room-old": "原姓名"])
        XCTAssertEqual(try repository.count(TranscriptRecord.self), 1)
        XCTAssertEqual(try repository.count(SpeakerNameRecord.self), 1)
        let transactionMeeting = try XCTUnwrap(failure.capturedMeeting)
        XCTAssertEqual(
            transactionMeeting.speakerProcessingState,
            .processing
        )
        XCTAssertNil(transactionMeeting.speakerProcessingErrorCode)
        XCTAssertEqual(transactionMeeting.transcripts.map(\.text), ["old"])
        XCTAssertEqual(
            transactionMeeting.speakerDisplayNames,
            ["room-old": "原姓名"]
        )
    }

    func testFailSpeakerDiarizationRetryPersistsStableCodeAndRollsBackOnSaveError()
        throws {
        let failure = RepositorySaveFailureSwitch()
        let repository = try MeetingRepository.inMemory(
            contextSaver: { context in
                if failure.shouldFail {
                    throw InjectedRepositorySaveError.forced
                }
                try context.save()
            }
        )
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: .now,
            speakerDiarizationRequested: true
        )
        let meeting = try repository.meeting(id: meetingID)
        meeting.speakerProcessingState = .degraded
        try repository.updateMeetingState(id: meetingID, state: .ready)
        try repository.beginSpeakerDiarizationRetry(meetingID: meetingID)

        try repository.failSpeakerDiarizationRetry(
            meetingID: meetingID,
            errorCode: "speaker_diarization_inference_failed"
        )
        XCTAssertEqual(meeting.speakerProcessingState, .degraded)
        XCTAssertEqual(
            meeting.speakerProcessingErrorCode,
            "speaker_diarization_inference_failed"
        )

        try repository.beginSpeakerDiarizationRetry(meetingID: meetingID)
        let priorUpdatedAt = meeting.updatedAt
        failure.shouldFail = true
        XCTAssertThrowsError(
            try repository.failSpeakerDiarizationRetry(
                meetingID: meetingID,
                errorCode: "speaker_diarization_conversion_failed"
            )
        ) { error in
            XCTAssertEqual(error as? InjectedRepositorySaveError, .forced)
        }
        XCTAssertEqual(meeting.speakerProcessingState, .processing)
        XCTAssertNil(meeting.speakerProcessingErrorCode)
        XCTAssertEqual(meeting.updatedAt, priorUpdatedAt)
    }
}

@MainActor
private func saveBothDocuments(
    repository: MeetingRepository,
    meetingID: UUID
) throws {
    try repository.saveSummary(
        meetingID: meetingID,
        overview: "重点总结",
        keyPoints: [],
        decisions: [],
        actionItems: [String](),
        bookmarkInsights: [],
        model: "model"
    )
    try repository.saveDetailedMinutes(
        meetingID: meetingID,
        generated: makeDetailedMinutes(overview: "完整纪要"),
        model: "model",
        promptVersion: 1
    )
}

private func makeDetailedMinutes(
    overview: String
) -> GeneratedDetailedMinutes {
    GeneratedDetailedMinutes(
        overview: overview,
        sections: [
            DetailedMinutesSection(
                title: "议题一",
                timeRange: "00:00-05:00",
                speakers: ["我", "远端 1"],
                content: "围绕议题进行提炼后的讨论记录。"
            )
        ],
        decisions: ["采用方案一"],
        actionItems: [
            ActionItem(task: "整理排期", owner: "我", dueDate: "周五")
        ],
        openQuestions: ["预算是否需要追加"]
    )
}

private enum InjectedRepositorySaveError: Error, Equatable {
    case forced
}

private enum InjectedDetailedMinutesEncodingError: Error, Equatable {
    case forced
}

@MainActor
private final class RepositorySaveFailureSwitch {
    var shouldFail = false
    var capturedMeeting: MeetingRecord?
}

private struct TranscriptMetadata: Equatable {
    let id: UUID
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
    let isFinal: Bool
    let speakerID: String?
    let sourceRevision: Int
    let sourceRawValue: String?
    let sequenceIndex: Int?

    init(_ transcript: TranscriptRecord) {
        id = transcript.id
        startTime = transcript.startTime
        endTime = transcript.endTime
        text = transcript.text
        isFinal = transcript.isFinal
        speakerID = transcript.speakerID
        sourceRevision = transcript.sourceRevision
        sourceRawValue = transcript.sourceRawValue
        sequenceIndex = transcript.sequenceIndex
    }
}
