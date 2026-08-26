import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingExactReplacementTests: XCTestCase {
    func testPreviewCountsLiteralOccurrencesAcrossEverySupportedField()
        throws {
        let fixture = try makeFixture()
        let operation = MeetingExactReplacement(repository: fixture.repository)
        let meeting = try fixture.repository.meeting(id: fixture.meetingID)
        let revisionBeforePreview = meeting.contentRevision
        let updatedAtBeforePreview = meeting.updatedAt

        let preview = try operation.preview(
            meetingID: fixture.meetingID,
            old: "旧名",
            new: "新名"
        )

        XCTAssertEqual(
            preview,
            MeetingExactReplacementPreview(
                transcriptMatches: 4,
                speakerMatches: 2,
                summaryMatches: 10,
                detailedMinutesMatches: 11
            )
        )
        XCTAssertEqual(preview.totalMatches, 27)
        XCTAssertEqual(meeting.contentRevision, revisionBeforePreview)
        XCTAssertEqual(meeting.updatedAt, updatedAtBeforePreview)
        XCTAssertEqual(meeting.notionSyncState, .synced)
    }

    func testApplyReplacesEverySupportedFieldAndPreservesGeneratedText()
        throws {
        let fixture = try makeFixture()
        let operation = MeetingExactReplacement(repository: fixture.repository)
        let meeting = try fixture.repository.meeting(id: fixture.meetingID)
        let summary = try XCTUnwrap(meeting.summary)
        let minutes = try XCTUnwrap(meeting.detailedMinutes)
        let meetingRevision = meeting.contentRevision
        let summaryRevision = summary.contentRevision
        let minutesRevision = minutes.contentRevision
        let syncedRevision = meeting.notionSyncedContentRevision

        let applied = try operation.apply(
            meetingID: fixture.meetingID,
            old: "旧名",
            new: "新名"
        )

        XCTAssertEqual(applied.totalMatches, 27)
        XCTAssertEqual(
            try fixture.repository.canonicalTranscripts(
                meetingID: fixture.meetingID
            ).map(\.text),
            ["新名和新名发言", "人工新名、新名"]
        )
        XCTAssertEqual(
            try fixture.repository.transcripts(
                meetingID: fixture.meetingID
            ).map(\.text),
            ["旧名和旧名发言", "底层生成旧名"]
        )
        XCTAssertEqual(meeting.transcriptCorrections.count, 2)
        let existingCorrection = try XCTUnwrap(
            meeting.transcriptCorrections.first {
                $0.id == fixture.existingCorrectionID
            }
        )
        XCTAssertEqual(existingCorrection.originalText, "底层生成旧名")
        XCTAssertEqual(existingCorrection.replacementText, "人工新名、新名")
        let createdCorrection = try XCTUnwrap(
            meeting.transcriptCorrections.first {
                $0.id != fixture.existingCorrectionID
            }
        )
        XCTAssertEqual(createdCorrection.originalText, "旧名和旧名发言")
        XCTAssertEqual(createdCorrection.replacementText, "新名和新名发言")
        XCTAssertEqual(
            createdCorrection.transcriptIDs,
            [fixture.uncorrectedTranscriptID]
        )

        XCTAssertEqual(
            meeting.speakerDisplayNames,
            ["room-1": "新名新名", "room-2": "另一位"]
        )
        XCTAssertEqual(summary.overview, "新名概览新名")
        XCTAssertEqual(summary.keyPoints, ["新名重点", "新名和新名"])
        XCTAssertEqual(summary.decisions, ["新名决定"])
        XCTAssertEqual(
            summary.actionItemRecords,
            [
                ActionItem(
                    task: "新名任务新名",
                    owner: "新名负责人",
                    dueDate: "旧名截止"
                )
            ]
        )
        XCTAssertEqual(summary.bookmarkInsights, ["新名书签"])
        XCTAssertTrue(summary.isManuallyEdited)
        XCTAssertEqual(summary.contentRevision, summaryRevision + 1)
        XCTAssertEqual(summary.archiveState, .localOnly)
        XCTAssertNil(summary.archivedContentRevision)
        XCTAssertNil(summary.lastArchiveErrorCode)

        XCTAssertEqual(minutes.overview, "新名纪要")
        XCTAssertEqual(
            try minutes.sections,
            [
                DetailedMinutesSection(
                    title: "新名议题",
                    timeRange: "旧名-time",
                    speakers: ["新名", "其他新名"],
                    content: "新名讨论新名"
                )
            ]
        )
        XCTAssertEqual(try minutes.decisions, ["新名决定"])
        XCTAssertEqual(
            try minutes.actionItems,
            [
                ActionItem(
                    task: "新名任务",
                    owner: "新名负责人",
                    dueDate: "旧名截止"
                )
            ]
        )
        XCTAssertEqual(try minutes.openQuestions, ["新名问题新名"])
        XCTAssertTrue(minutes.isManuallyEdited)
        XCTAssertEqual(minutes.contentRevision, minutesRevision + 1)
        XCTAssertEqual(minutes.archiveState, .localOnly)
        XCTAssertNil(minutes.archivedContentRevision)
        XCTAssertNil(minutes.lastArchiveErrorCode)

        XCTAssertEqual(meeting.contentRevision, meetingRevision + 1)
        XCTAssertEqual(meeting.notionSyncState, .localOnly)
        XCTAssertEqual(meeting.notionSyncedContentRevision, syncedRevision)
        XCTAssertNil(meeting.notionSyncErrorCode)
    }

    func testReplacementNeverTouchesAnotherMeeting() throws {
        let repository = try MeetingRepository.inMemory()
        let target = try makeFixture(repository: repository)
        let otherID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 2_000)
        )
        try repository.appendTranscript(
            meetingID: otherID,
            start: 1,
            end: 2,
            text: "旧名他人会议",
            speakerID: "other-speaker"
        )
        try repository.setSpeakerDisplayName(
            meetingID: otherID,
            speakerID: "other-speaker",
            displayName: "旧名"
        )
        try repository.saveSummary(
            meetingID: otherID,
            overview: "旧名他人总结",
            keyPoints: [],
            decisions: [],
            actionItems: [String](),
            bookmarkInsights: [],
            model: "test"
        )
        let other = try repository.meeting(id: otherID)
        let otherRevision = other.contentRevision
        let otherUpdatedAt = other.updatedAt

        _ = try MeetingExactReplacement(repository: repository).apply(
            meetingID: target.meetingID,
            old: "旧名",
            new: "新名"
        )

        XCTAssertEqual(
            try repository.canonicalTranscripts(meetingID: otherID).map(\.text),
            ["旧名他人会议"]
        )
        XCTAssertEqual(other.speakerDisplayNames, ["other-speaker": "旧名"])
        XCTAssertEqual(other.summary?.overview, "旧名他人总结")
        XCTAssertEqual(other.contentRevision, otherRevision)
        XCTAssertEqual(other.updatedAt, otherUpdatedAt)
    }

    func testNoMatchDoesNotAdvanceRevision() throws {
        let fixture = try makeFixture()
        let meeting = try fixture.repository.meeting(id: fixture.meetingID)
        let summary = try XCTUnwrap(meeting.summary)
        let minutes = try XCTUnwrap(meeting.detailedMinutes)
        let meetingRevision = meeting.contentRevision
        let meetingUpdatedAt = meeting.updatedAt
        let summaryRevision = summary.contentRevision
        let minutesRevision = minutes.contentRevision
        let correctionCount = meeting.transcriptCorrections.count

        let result = try MeetingExactReplacement(
            repository: fixture.repository
        ).apply(
            meetingID: fixture.meetingID,
            old: "不存在",
            new: "也不存在"
        )

        XCTAssertEqual(result.totalMatches, 0)
        XCTAssertEqual(meeting.contentRevision, meetingRevision)
        XCTAssertEqual(meeting.updatedAt, meetingUpdatedAt)
        XCTAssertEqual(meeting.notionSyncState, .synced)
        XCTAssertEqual(summary.contentRevision, summaryRevision)
        XCTAssertEqual(summary.archiveState, .archived)
        XCTAssertFalse(summary.isManuallyEdited)
        XCTAssertEqual(minutes.contentRevision, minutesRevision)
        XCTAssertEqual(minutes.archiveState, .archived)
        XCTAssertFalse(minutes.isManuallyEdited)
        XCTAssertEqual(meeting.transcriptCorrections.count, correctionCount)
    }

    func testGeneratedTranscriptIDCollisionStillCreatesItsOwnCorrection()
        throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 3_000)
        )
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 1,
                        endTime: 2,
                        text: "旧名原始行"
                    ),
                    speakerID: "room-1",
                    source: .room
                ),
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 3,
                        endTime: 4,
                        text: "另一原始行"
                    ),
                    speakerID: "room-2",
                    source: .room
                )
            ],
            sourceRevision: 1
        )
        let transcripts = try repository.transcripts(meetingID: meetingID)
        let generated = try XCTUnwrap(transcripts.first)
        let corrected = try XCTUnwrap(transcripts.last)
        let meeting = try repository.meeting(id: meetingID)
        let collidingCorrection = TranscriptCorrectionRecord(
            id: generated.id,
            anchorStartTime: corrected.startTime,
            anchorEndTime: corrected.endTime,
            source: corrected.source,
            originalText: corrected.text,
            replacementText: "另一行的人工修正",
            transcriptIDs: [corrected.id],
            meeting: meeting
        )
        meeting.transcriptCorrections.append(collidingCorrection)
        try repository.updateMeetingState(id: meetingID, state: .ready)
        XCTAssertEqual(
            try repository.canonicalTranscripts(meetingID: meetingID).map(\.text),
            ["旧名原始行", "另一行的人工修正"]
        )

        _ = try MeetingExactReplacement(repository: repository).apply(
            meetingID: meetingID,
            old: "旧名",
            new: "新名"
        )

        XCTAssertEqual(
            try repository.canonicalTranscripts(meetingID: meetingID).map(\.text),
            ["新名原始行", "另一行的人工修正"]
        )
        XCTAssertEqual(meeting.transcriptCorrections.count, 2)
        XCTAssertEqual(
            collidingCorrection.replacementText,
            "另一行的人工修正"
        )
    }

    func testRejectsEmptySearchAndIdenticalReplacement() throws {
        let fixture = try makeFixture()
        let operation = MeetingExactReplacement(repository: fixture.repository)

        XCTAssertThrowsError(
            try operation.preview(
                meetingID: fixture.meetingID,
                old: "",
                new: "新名"
            )
        ) { error in
            XCTAssertEqual(
                error as? MeetingExactReplacementError,
                .emptySearchText
            )
        }
        XCTAssertThrowsError(
            try operation.apply(
                meetingID: fixture.meetingID,
                old: "旧名",
                new: "旧名"
            )
        ) { error in
            XCTAssertEqual(
                error as? MeetingExactReplacementError,
                .identicalSearchAndReplacement
            )
        }
    }

    private func makeFixture(
        repository: MeetingRepository? = nil
    ) throws -> ExactReplacementFixture {
        let repository = try repository ?? MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 1_000)
        )
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 1,
                        endTime: 2,
                        text: "旧名和旧名发言"
                    ),
                    speakerID: "room-1",
                    source: .room
                ),
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 3,
                        endTime: 4,
                        text: "底层生成旧名"
                    ),
                    speakerID: "room-2",
                    source: .room
                )
            ],
            sourceRevision: 1
        )
        let transcripts = try repository.transcripts(meetingID: meetingID)
        let uncorrected = try XCTUnwrap(transcripts.first)
        let corrected = try XCTUnwrap(transcripts.last)
        try repository.saveTranscriptCorrection(
            meetingID: meetingID,
            transcriptIDs: [corrected.id],
            anchorStartTime: corrected.startTime,
            anchorEndTime: corrected.endTime,
            source: corrected.source,
            originalText: corrected.text,
            replacementText: "人工旧名、旧名",
            now: Date(timeIntervalSince1970: 1_010)
        )
        let correctionID = try XCTUnwrap(
            repository.meeting(id: meetingID).transcriptCorrections.first?.id
        )
        try repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "room-1",
            displayName: "旧名旧名",
            now: Date(timeIntervalSince1970: 1_020)
        )
        try repository.setSpeakerDisplayName(
            meetingID: meetingID,
            speakerID: "room-2",
            displayName: "另一位",
            now: Date(timeIntervalSince1970: 1_020)
        )
        try repository.saveSummary(
            meetingID: meetingID,
            overview: "旧名概览旧名",
            keyPoints: ["旧名重点", "旧名和旧名"],
            decisions: ["旧名决定"],
            structuredActionItems: [
                ActionItem(
                    task: "旧名任务旧名",
                    owner: "旧名负责人",
                    dueDate: "旧名截止"
                )
            ],
            bookmarkInsights: ["旧名书签"],
            model: "test"
        )
        try repository.saveDetailedMinutes(
            meetingID: meetingID,
            generated: GeneratedDetailedMinutes(
                overview: "旧名纪要",
                sections: [
                    DetailedMinutesSection(
                        title: "旧名议题",
                        timeRange: "旧名-time",
                        speakers: ["旧名", "其他旧名"],
                        content: "旧名讨论旧名"
                    )
                ],
                decisions: ["旧名决定"],
                actionItems: [
                    ActionItem(
                        task: "旧名任务",
                        owner: "旧名负责人",
                        dueDate: "旧名截止"
                    )
                ],
                openQuestions: ["旧名问题旧名"]
            ),
            model: "test",
            promptVersion: 1
        )
        let meeting = try repository.meeting(id: meetingID)
        let summary = try XCTUnwrap(meeting.summary)
        let minutes = try XCTUnwrap(meeting.detailedMinutes)
        summary.archiveState = .archived
        summary.archivedContentRevision = summary.contentRevision
        summary.lastArchiveErrorCode = "old-summary-error"
        minutes.archiveState = .archived
        minutes.archivedContentRevision = minutes.contentRevision
        minutes.lastArchiveErrorCode = "old-minutes-error"
        meeting.notionSyncState = .synced
        meeting.notionSyncedContentRevision = meeting.contentRevision
        meeting.notionSyncErrorCode = "old-sync-error"
        try repository.updateMeetingState(id: meetingID, state: .summaryReady)

        return ExactReplacementFixture(
            repository: repository,
            meetingID: meetingID,
            uncorrectedTranscriptID: uncorrected.id,
            existingCorrectionID: correctionID
        )
    }
}

@MainActor
private struct ExactReplacementFixture {
    let repository: MeetingRepository
    let meetingID: UUID
    let uncorrectedTranscriptID: UUID
    let existingCorrectionID: UUID
}
