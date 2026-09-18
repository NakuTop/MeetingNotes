import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingSpeakerReviewTests: XCTestCase {
    private final class SaveSwitch { var fails = false }
    private func fixture(control: SaveSwitch? = nil) throws -> (MeetingRepository, UUID, [TranscriptRecord]) {
        enum Failure: Error { case save }
        let repository = try MeetingRepository.inMemory(contextSaver: {
            if control?.fails == true { throw Failure.save }; try $0.save()
        })
        let id = try repository.createMeeting(mode: .offline, startedAt: .now)
        for index in 0..<4 { try repository.appendTranscript(meetingID: id, start: Double(index * 5),
            end: Double(index * 5 + 4), text: "原文\(index)", speakerID: index == 3 ? "room-1" : nil) }
        let rows = try repository.transcripts(meetingID: id)
        for row in rows.prefix(3) {
            row.attributionStatus = .uncertain
            row.reviewHint = .init(candidateSpeakerID: "room-1", reason: .insufficientCoverage, coverage: 0.4, margin: 0.4)
        }
        try repository.updateMeetingState(id: id, state: .ready)
        return (repository, id, rows)
    }
    private func preview(_ repository: MeetingRepository, _ id: UUID) throws -> [SpeakerReviewRowSnapshot] {
        try XCTUnwrap(MeetingSpeakerReviewCatalog.make(meeting: repository.meeting(id: id)).groups.first).items.flatMap(\.rows)
    }
    func testBatchAppliesOnlyExplicitSelectionAndUndoRestoresWithoutTouchingText() throws {
        let (repository, id, rows) = try fixture()
        let selected = Array(try preview(repository, id).prefix(2))
        let receipt = try repository.assignSpeakerBatch(meetingID: id, preview: selected, speakerID: "room-1")
        XCTAssertTrue(rows.prefix(2).allSatisfy { $0.attributionStatus == .manuallyAssigned })
        XCTAssertNil(rows[2].speakerID)
        rows[0].text = "后续文字修改"
        try repository.undoSpeakerBatch(receipt)
        XCTAssertTrue(rows.prefix(3).allSatisfy { $0.speakerID == nil && $0.attributionStatus == .uncertain })
        XCTAssertEqual(rows[0].text, "后续文字修改")
        XCTAssertFalse(repository.canUndoSpeakerBatch(receipt))
    }
    func testStalePreviewAndCrossMeetingRowsCannotBeApplied() throws {
        let (repository, id, rows) = try fixture()
        let pending = try preview(repository, id)
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [rows[0].id], speakerID: "room-1")
        XCTAssertThrowsError(try repository.assignSpeakerBatch(meetingID: id, preview: pending, speakerID: "room-1"))
        let other = try repository.createMeeting(mode: .offline, startedAt: .now)
        XCTAssertThrowsError(try repository.assignSpeakerBatch(meetingID: other, preview: pending, speakerID: "room-1"))
        XCTAssertNil(rows[1].speakerID)
    }
    func testChangedCandidateRejectsEntireBatch() throws {
        let (repository, id, rows) = try fixture()
        let pending = try preview(repository, id)
        rows[1].reviewHint = .init(candidateSpeakerID: "room-9", reason: .acousticCandidate, basis: .meetingVoice)
        XCTAssertThrowsError(try repository.assignSpeakerBatch(meetingID: id, preview: pending, speakerID: "room-1"))
        XCTAssertTrue(rows.prefix(3).allSatisfy { $0.speakerID == nil })
    }
    func testLaterManualActionInvalidatesOldUndoEvenIfItUsesSameLabel() throws {
        let (repository, id, rows) = try fixture()
        let receipt = try repository.assignSpeakerBatch(meetingID: id, preview: preview(repository, id), speakerID: "room-1")
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [rows[0].id], speakerID: "room-1")
        XCTAssertFalse(repository.canUndoSpeakerBatch(receipt))
        XCTAssertThrowsError(try repository.undoSpeakerBatch(receipt))
    }
    func testSaveFailureRollsBackBatchAndUndo() throws {
        let control = SaveSwitch()
        let (repository, id, rows) = try fixture(control: control)
        let pending = try preview(repository, id)
        let revision = try repository.meeting(id: id).contentRevision
        control.fails = true
        XCTAssertThrowsError(try repository.assignSpeakerBatch(meetingID: id, preview: pending, speakerID: "room-1"))
        XCTAssertTrue(rows.prefix(3).allSatisfy { $0.speakerID == nil })
        XCTAssertEqual(try repository.meeting(id: id).contentRevision, revision)
        control.fails = false
        let receipt = try repository.assignSpeakerBatch(meetingID: id, preview: pending, speakerID: "room-1")
        let after = try repository.meeting(id: id).contentRevision
        control.fails = true
        XCTAssertThrowsError(try repository.undoSpeakerBatch(receipt))
        XCTAssertTrue(rows.prefix(3).allSatisfy { $0.attributionStatus == .manuallyAssigned })
        XCTAssertEqual(try repository.meeting(id: id).contentRevision, after)
        XCTAssertTrue(repository.canUndoSpeakerBatch(receipt))
    }
    func testCatalogNeverGroupsOverlapUnknownOrManualLabelsTogether() throws {
        let (repository, id, rows) = try fixture()
        rows[0].attributionStatus = .overlapping
        rows[1].reviewHint = nil
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [rows[2].id], speakerID: "room-1")
        let catalog = try MeetingSpeakerReviewCatalog.make(meeting: repository.meeting(id: id))
        XCTAssertTrue(catalog.groups.isEmpty)
        XCTAssertEqual(catalog.ungroupedCount, 2)
    }
    func testCandidateOnlySpeakerCanBeExplicitlyConfirmedAndReservedFromNewNumber() throws {
        let (repository, id, rows) = try fixture()
        rows[0].reviewHint = .init(candidateSpeakerID: "room-5", reason: .acousticCandidate, basis: .meetingVoice)
        XCTAssertEqual(ManualSpeakerAssignment.nextSpeakerID(records: rows, mode: .offline), "room-6")
        let group = try XCTUnwrap(MeetingSpeakerReviewCatalog.make(meeting: repository.meeting(id: id)).groups.first { $0.id == "room-5" })
        try repository.assignSpeakerBatch(meetingID: id, preview: group.items.flatMap(\.rows), speakerID: "room-5")
        XCTAssertEqual(rows[0].speakerID, "room-5")
    }
    func testDisplayCombinesAdjacentSameCandidateButNotDifferentOrMissingCandidates() throws {
        let (_, _, rows) = try fixture()
        rows[0].endTime = 5
        rows[1].endTime = 10
        rows[2].reviewHint = .init(candidateSpeakerID: "room-2", reason: .insufficientCoverage, coverage: 0.4, margin: 0.4)
        let turns = TranscriptDisplayPolicy.turns(from: rows, bookmarks: [])
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[0].transcriptIDs, [rows[0].id, rows[1].id])
        XCTAssertEqual(turns[0].attributionStatus, .uncertain)
        XCTAssertNil(turns[0].speakerID)
        rows[0].reviewHint = nil; rows[1].reviewHint = nil
        XCTAssertEqual(TranscriptDisplayPolicy.turns(from: rows, bookmarks: []).count, 4)
    }

    func testDisplayDoesNotMergeCandidatesAcrossNotesOrScreenshots() throws {
        let (_, _, rows) = try fixture()
        rows[0].endTime = 5
        let entries = TranscriptCorrectionResolver.resolve(transcripts: Array(rows.prefix(2)), corrections: [])
        XCTAssertEqual(TranscriptDisplayPolicy.turns(from: entries, bookmarks: []).count, 1)
        XCTAssertEqual(TranscriptDisplayPolicy.turns(from: entries, bookmarks: [], uncertainGroupingBoundaries: [4.5]).count, 2)
    }

    func testReplacementPersistsHintsAndInvalidatesOldReceipt() throws {
        let (repository, id, rows) = try fixture()
        let receipt = try repository.assignSpeakerBatch(meetingID: id, preview: Array(preview(repository, id).prefix(1)), speakerID: "room-1")
        let drafts = rows.map { row in
            AttributedTranscriptDraft(transcript: .init(startTime: row.startTime, endTime: row.endTime, text: row.text),
                speakerID: row.attributionStatus == .manuallyAssigned ? "room-1" : row.speakerID, source: row.source,
                attributionStatus: row.attributionStatus == .manuallyAssigned ? .attributed : row.attributionStatus,
                attributionOrigin: .init(startTime: row.startTime, endTime: row.endTime, text: row.text), reviewHint: row.reviewHint)
        }
        try repository.replaceTranscripts(meetingID: id, drafts: drafts, sourceRevision: 2)
        XCTAssertFalse(repository.canUndoSpeakerBatch(receipt))
        let replacement = try repository.transcripts(meetingID: id)
        XCTAssertNotNil(replacement[1].reviewHint)
        XCTAssertEqual(replacement[0].attributionStatus, .manuallyAssigned)
        XCTAssertEqual(replacement.map(\.text), rows.map(\.text))
    }
}
