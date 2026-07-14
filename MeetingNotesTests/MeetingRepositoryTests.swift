import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingRepositoryTests: XCTestCase {
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

    func testMeetingListIsNewestFirst() throws {
        let repository = try MeetingRepository.inMemory()
        let olderID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100),
            title: "早期会议"
        )
        let newerID = try repository.createMeeting(
            mode: .online,
            startedAt: Date(timeIntervalSince1970: 200),
            title: "近期会议"
        )

        XCTAssertEqual(try repository.meetings().map(\.id), [newerID, olderID])
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
}
