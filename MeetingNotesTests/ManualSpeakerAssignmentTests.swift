import XCTest
import SwiftData
@testable import MeetingNotes

@MainActor
final class ManualSpeakerAssignmentTests: XCTestCase {
    private final class SaveSwitch { var fails = false }
    private func fixture() throws -> (MeetingRepository, UUID, [TranscriptRecord]) {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .offline, startedAt: .now, speakerDiarizationRequested: true)
        for index in 0..<3 {
            try repository.appendTranscript(meetingID: id, start: Double(index * 5),
                end: Double(index * 5 + 4), text: "保留原文\(index)", speakerID: index == 2 ? "room-1" : nil)
        }
        let rows = try repository.transcripts(meetingID: id)
        for row in rows { row.source = .room; row.attributionStatus = row.speakerID == nil ? .uncertain : .attributed }
        try repository.updateMeetingState(id: id, state: .recording)
        return (repository, id, rows)
    }

    func testAssigningUnknownChangesOnlySelectedRowsAndRestoresAutomatic() throws {
        let (repository, id, rows) = try fixture()
        let revision = try repository.meeting(id: id).contentRevision
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [rows[0].id], speakerID: "room-1")
        XCTAssertEqual(rows[0].speakerID, "room-1")
        XCTAssertEqual(rows[0].attributionStatus, .manuallyAssigned)
        XCTAssertNil(rows[1].speakerID)
        XCTAssertEqual(rows[1].attributionStatus, .uncertain)
        XCTAssertGreaterThan(try repository.meeting(id: id).contentRevision, revision)
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [rows[0].id], speakerID: nil)
        XCTAssertNil(rows[0].speakerID)
        XCTAssertEqual(rows[0].attributionStatus, .uncertain)
        XCTAssertEqual(rows.map(\.text), ["保留原文0", "保留原文1", "保留原文2"])
    }

    func testCreateNewSpeakerDoesNotRenameExistingPeople() throws {
        let (repository, id, rows) = try fixture()
        let created = try repository.assignSpeaker(meetingID: id, transcriptIDs: [rows[0].id], speakerID: nil, createNew: true)
        XCTAssertEqual(created, "room-2")
        XCTAssertEqual(rows[2].speakerID, "room-1")
    }

    func testStaleOrCrossMeetingSelectionAndUnknownSpeakerFailClosed() throws {
        let (repository, id, rows) = try fixture()
        for ids in [[], [UUID()], [rows[0].id, UUID()]] {
            XCTAssertThrowsError(try repository.assignSpeaker(meetingID: id, transcriptIDs: ids, speakerID: "room-1"))
        }
        XCTAssertThrowsError(try repository.assignSpeaker(meetingID: id, transcriptIDs: [rows[0].id], speakerID: "room-999"))
        XCTAssertNil(rows[0].speakerID)
    }

    func testLiveBatchCannotOverwriteHumanAssignment() throws {
        let (repository, id, rows) = try fixture()
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [rows[0].id], speakerID: "room-1")
        try repository.applyLiveSpeakerBatch(meetingID: id, batch: .init(startTime: 0, endTime: 15,
            source: .room, intervals: [.init(rawSpeakerID: "room-9", startTime: 0, endTime: 15)]))
        XCTAssertEqual(rows[0].speakerID, "room-1")
        XCTAssertEqual(rows[0].attributionStatus, .manuallyAssigned)
        XCTAssertEqual(rows[1].speakerID, "room-9")
    }

    func testRecalibrationPreservesManualLabelNameTextAndWordTimings() throws {
        for retry in [false, true] {
            let (repository, id, rows) = try fixture()
            rows[0].words = [.init(text: rows[0].text, startTime: 0, endTime: 4)]
            let oldWords = rows[0].words
            try repository.assignSpeaker(meetingID: id, transcriptIDs: [rows[0].id], speakerID: nil, createNew: true)
            try repository.setSpeakerDisplayName(meetingID: id, speakerID: "room-2", displayName: "用户确认姓名")
            let drafts = rows.map { row in
                AttributedTranscriptDraft(transcript: .init(startTime: row.startTime, endTime: row.endTime,
                    text: row.text, words: row.words), speakerID: "room-2", source: .room,
                    attributionStatus: .attributed,
                    attributionOrigin: .init(startTime: row.startTime, endTime: row.endTime, text: row.text))
            }
            if retry {
                try repository.meeting(id: id).speakerProcessingState = .completed
                try repository.updateMeetingState(id: id, state: .ready)
                try repository.beginSpeakerDiarizationRetry(meetingID: id)
                try repository.completeSpeakerDiarizationRetry(meetingID: id, drafts: drafts, sourceRevision: 2)
            } else {
                try repository.replaceTranscripts(meetingID: id, drafts: drafts, sourceRevision: 2)
            }
            let result = try repository.transcripts(meetingID: id)
            XCTAssertEqual(result[0].speakerID, "room-2")
            XCTAssertEqual(result[0].attributionStatus, .manuallyAssigned)
            XCTAssertEqual(result[0].words, oldWords)
            XCTAssertNotEqual(result[1].speakerID, "room-2", "An unrelated cluster must not reuse a protected ID")
            XCTAssertEqual(try repository.speakerDisplayNames(meetingID: id)["room-2"], "用户确认姓名")
            XCTAssertEqual(result.map(\.text), ["保留原文0", "保留原文1", "保留原文2"])
        }
    }

    func testUntraceableReplacementCannotDeleteManualLabels() throws {
        let (repository, id, rows) = try fixture()
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [rows[0].id], speakerID: "room-1")
        XCTAssertThrowsError(try repository.replaceTranscripts(meetingID: id, drafts: [
            .init(transcript: .init(startTime: 0, endTime: 15, text: "不同来源"), speakerID: "room-9", source: .room)
        ], sourceRevision: 2))
        XCTAssertEqual(try repository.transcripts(meetingID: id).count, 3)
        XCTAssertEqual(try repository.transcripts(meetingID: id).first?.speakerID, "room-1")
    }

    func testSaveFailureRollsBackAssignmentAndRevision() throws {
        enum Failure: Error { case save }
        let control = SaveSwitch()
        let repository = try MeetingRepository.inMemory(contextSaver: {
            if control.fails { throw Failure.save }; try $0.save()
        })
        let id = try repository.createMeeting(mode: .offline, startedAt: .now)
        try repository.appendTranscript(meetingID: id, start: 0, end: 5, text: "原文")
        let row = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        let revision = try repository.meeting(id: id).contentRevision
        control.fails = true
        XCTAssertThrowsError(try repository.assignSpeaker(meetingID: id, transcriptIDs: [row.id], speakerID: nil, createNew: true))
        XCTAssertNil(row.speakerID)
        XCTAssertNil(row.attributionStatus)
        XCTAssertEqual(try repository.meeting(id: id).contentRevision, revision)
    }

    func testLiveNewClusterCannotReuseHumanNumberAndLateTranscriptsUseStableMapping() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .offline, startedAt: .now, speakerDiarizationRequested: true)
        try repository.updateMeetingState(id: id, state: .recording)
        repository.beginLiveSpeakerAttribution(meetingID: id, mode: .offline)
        try repository.appendTranscript(meetingID: id, start: 0, end: 5, text: "人工识别")
        let row = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [row.id], speakerID: nil, createNew: true)
        XCTAssertEqual(row.speakerID, "room-2", "Temporary room-1 is already visible; a new person needs another number")
        try repository.applyLiveSpeakerBatch(meetingID: id, batch: .init(startTime: 0, endTime: 10,
            source: .room, intervals: [.init(rawSpeakerID: "room-2", startTime: 0, endTime: 10)]))
        try repository.appendTranscript(meetingID: id, start: 5, end: 10, text: "迟到转录")
        let rows = try repository.transcripts(meetingID: id)
        XCTAssertEqual(rows.map(\.speakerID), ["room-2", "room-3"])
        try repository.applyLiveSpeakerBatch(meetingID: id, batch: .init(startTime: 10, endTime: 20,
            source: .room, intervals: [.init(rawSpeakerID: "room-2", startTime: 10, endTime: 15),
                                       .init(rawSpeakerID: "room-3", startTime: 15, endTime: 20)]))
        try repository.appendTranscript(meetingID: id, start: 10, end: 15, text: "再次发言")
        try repository.appendTranscript(meetingID: id, start: 15, end: 20, text: "新自动编号")
        XCTAssertEqual(try repository.transcripts(meetingID: id).map(\.speakerID), ["room-2", "room-3", "room-3", "room-4"])
    }

    func testManualAssignmentAndAutomaticFallbackSurviveDiskReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ManualSpeaker-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema([MeetingRecord.self, TranscriptRecord.self, TranscriptCorrectionRecord.self,
            SpeakerNameRecord.self, BookmarkRecord.self, MeetingNoteRecord.self, MeetingScreenshotRecord.self,
            SummaryRecord.self, DetailedMinutesRecord.self, ArchiveCheckpointRecord.self])
        let configuration = ModelConfiguration(schema: schema,
            url: directory.appendingPathComponent("test.store"), cloudKitDatabase: .none)
        let id = UUID()
        try autoreleasepool {
            let repository = MeetingRepository(container: try ModelContainer(for: schema, configurations: [configuration]))
            try repository.createMeeting(id: id, mode: .offline, startedAt: .now)
            try repository.appendTranscript(meetingID: id, start: 0, end: 5, text: "磁盘原文", speakerID: "room-1")
            let row = try XCTUnwrap(repository.transcripts(meetingID: id).first)
            try repository.assignSpeaker(meetingID: id, transcriptIDs: [row.id], speakerID: nil,
                createNew: true, displayName: "人工姓名")
        }
        let repository = MeetingRepository(container: try ModelContainer(for: schema, configurations: [configuration]))
        let row = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        XCTAssertEqual(row.speakerID, "room-2")
        XCTAssertEqual(row.attributionStatus, .manuallyAssigned)
        XCTAssertEqual(row.automaticSpeakerID, "room-1")
        XCTAssertEqual(try repository.speakerDisplayNames(meetingID: id)["room-2"], "人工姓名")
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [row.id], speakerID: nil)
        XCTAssertEqual(row.speakerID, "room-1")
        XCTAssertNil(row.attributionStatus)
        XCTAssertEqual(row.text, "磁盘原文")
    }
}
