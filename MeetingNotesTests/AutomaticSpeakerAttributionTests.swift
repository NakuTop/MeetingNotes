import XCTest
import SwiftData
@testable import MeetingNotes

final class AutomaticSpeakerAttributionTests: XCTestCase {
    func testEveryUtteranceGetsAnIdentityIncludingGapsTiesAndOverlap() {
        let drafts = (0..<8).map { TranscriptDraft(startTime: Double($0), endTime: Double($0 + 1), text: "句\($0)") }
        let intervals: [SpeakerInterval] = [
            .init(rawSpeakerID: "a", startTime: 1, endTime: 1.1),
            .init(rawSpeakerID: "b", startTime: 2, endTime: 2.5),
            .init(rawSpeakerID: "a", startTime: 2.5, endTime: 3),
            .init(rawSpeakerID: "b", startTime: 4, endTime: 6),
            .init(rawSpeakerID: "a", startTime: 4, endTime: 5),
        ]
        let result = SpeakerIntervalAssigner().assign(drafts, intervals: intervals, speakerPrefix: "room", source: .room)
        XCTAssertEqual(result.count, drafts.count)
        XCTAssertTrue(result.allSatisfy { $0.speakerID != nil })
        XCTAssertEqual(result.map(\.transcript), drafts)
        XCTAssertTrue(result.contains { $0.attributionStatus == .inferred })
        XCTAssertTrue(result.contains { $0.attributionStatus == .overlapping })
        XCTAssertFalse(result.contains { TranscriptSpeakerLabelPolicy.label(speakerID: $0.speakerID,
            source: $0.source, attributionStatus: $0.attributionStatus)?.contains("待确认") == true })
    }

    func testNoModelEvidenceUsesOneTemporaryIdentityNotANewPersonPerSentence() {
        let drafts = (0..<20).map { TranscriptDraft(startTime: Double($0), endTime: Double($0 + 1), text: "原句\($0)") }
        let result = SpeakerIntervalAssigner().assign(drafts, intervals: [], speakerPrefix: "room", source: .room)
        XCTAssertEqual(Set(result.compactMap(\.speakerID)), ["room-1"])
        XCTAssertTrue(result.allSatisfy { $0.attributionStatus == .inferred })
        XCTAssertEqual(result.map(\.transcript), drafts)
    }

    func testAcousticCandidateWinsOverNeighborAndTracksNeverBorrowIdentities() {
        let entries = [entry(0, 1, "room-2", .room), entry(1, 2, nil, .room, candidate: "room-3"),
                       entry(2, 3, nil, .system), entry(3, 4, nil, .microphone), entry(4, 5, nil, .room)]
        let result = AutomaticSpeakerAttribution.complete(entries)
        XCTAssertEqual(result.map(\.speakerID), ["room-2", "room-3", "remote-1", "me", "room-3"])
        XCTAssertEqual(result.map(\.text), entries.map(\.text))
        XCTAssertEqual(result.map(\.id), entries.map(\.id))
    }

    func testTieRetainsPreviousVoiceButClearShortInterjectionStillChangesSpeaker() {
        let index = SpeakerEvidenceIndex([.init(rawSpeakerID: "a", startTime: 0, endTime: 1),
                                          .init(rawSpeakerID: "b", startTime: 1, endTime: 2)])
        XCTAssertEqual(index.bestEffortSpeaker(start: 0, end: 2, preferring: "b"), "b")
        XCTAssertEqual(index.bestEffortSpeaker(start: 0, end: 0.1, preferring: "b"), "a")
    }

    func testNearestEvidenceIsDeterministicAndStrictEvidenceRemainsHonest() {
        let index = SpeakerEvidenceIndex([.init(rawSpeakerID: "a", startTime: 0, endTime: 1),
                                          .init(rawSpeakerID: "b", startTime: 10, endTime: 11)])
        XCTAssertNil(index.evidence(start: 8, end: 9).rawSpeakerID)
        XCTAssertEqual(index.bestEffortSpeaker(start: 8, end: 9), "b")
        XCTAssertEqual(index.bestEffortSpeaker(start: 2, end: 3), "a")
        XCTAssertNil(index.bestEffortSpeaker(start: .nan, end: 3))
    }

    @MainActor
    func testNeighboringSpeakerTurnsMergeAcrossConfidenceAndPauseWithoutLosingIDs() {
        var a = entry(0, 1, "room-1", .room)
        var b = entry(15, 16, "room-1", .room)
        a.attributionStatus = .attributed; b.attributionStatus = .inferred
        let turns = TranscriptDisplayPolicy.turns(from: [a, b, entry(16, 17, "room-2", .room)], bookmarks: [])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].transcriptIDs, [a.id, b.id])
        XCTAssertEqual(turns[0].text, "\(a.text) \(b.text)")
        XCTAssertEqual(turns[0].attributionStatus, .inferred)
        XCTAssertEqual(turns[0].endTime, 16)
        XCTAssertEqual(TranscriptDisplayPolicy.turns(from: [a, b], bookmarks: [], uncertainGroupingBoundaries: [10]).count, 2)
        XCTAssertEqual(TranscriptDisplayPolicy.turns(from: [a, b], bookmarks: [],
            preservingDraftTargets: [.init(entry: a)]).count, 2, "Do not extend an active undo/edit target")
    }

    @MainActor
    func testLegacyUnassignedRowsAreEditableAndRenameableWithoutChangingOriginalText() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .offline, startedAt: .now)
        try repository.appendTranscript(meetingID: id, start: 0, end: 1, text: "旧录音原文")
        let row = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        let entry = try XCTUnwrap(repository.canonicalTranscripts(meetingID: id).first)
        let speaker = try XCTUnwrap(entry.speakerID)
        XCTAssertEqual(entry.attributionStatus, .inferred)
        XCTAssertNil(row.speakerID, "Opening legacy content must not mutate stored evidence")
        try repository.setSpeakerDisplayName(meetingID: id, speakerID: speaker, displayName: "测试姓名")
        try repository.assignSpeaker(meetingID: id, transcriptIDs: [row.id], speakerID: speaker)
        XCTAssertEqual(row.attributionStatus, .manuallyAssigned)
        XCTAssertEqual(row.text, "旧录音原文")
        XCTAssertEqual(try repository.speakerDisplayNames(meetingID: id)[speaker], "测试姓名")
    }

    @MainActor
    func testLiveSentenceHasTemporaryLabelBeforeModelAndCalibratesWithoutReplacingRow() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .offline, startedAt: .now, speakerDiarizationRequested: true)
        try repository.updateMeetingState(id: id, state: .recording)
        repository.beginLiveSpeakerAttribution(meetingID: id, mode: .offline)
        try repository.appendTranscript(meetingID: id, start: 0, end: 1, text: "即时发言")
        let row = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        XCTAssertEqual(row.speakerID, "room-1")
        XCTAssertEqual(row.attributionStatus, .inferred)
        try repository.applyLiveSpeakerBatch(meetingID: id, batch: .init(startTime: 0, endTime: 1,
            source: .room, intervals: [.init(rawSpeakerID: "room-2", startTime: 0, endTime: 1)]))
        XCTAssertEqual(try repository.transcripts(meetingID: id).first?.id, row.id)
        XCTAssertEqual(row.speakerID, "room-2")
        XCTAssertEqual(row.attributionStatus, .attributed)
        XCTAssertEqual(row.text, "即时发言")
    }

    @MainActor
    func testNewManualSpeakerDoesNotRenumberOrRelabelUntouchedLegacySentences() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .offline, startedAt: .now)
        for i in 0..<2 { try repository.appendTranscript(meetingID: id, start: Double(i), end: Double(i + 1), text: "句\(i)") }
        let before = try repository.canonicalTranscripts(meetingID: id)
        let first = try XCTUnwrap(before.first)
        let selected = try repository.assignSpeaker(meetingID: id, transcriptIDs: first.transcriptIDs, speakerID: nil, createNew: true)
        let after = try repository.canonicalTranscripts(meetingID: id)
        XCTAssertNotEqual(selected, before[1].speakerID)
        XCTAssertEqual(after[0].speakerID, selected)
        XCTAssertEqual(after[1].speakerID, before[1].speakerID, "A scoped manual correction must not become neighbor-inference evidence")
        XCTAssertEqual(after.map(\.text), before.map(\.text))
    }

    @MainActor
    func testOverlapKeepsEvidenceWhileShowingOneDominantSpeakerForLegacyAndLiveRows() throws {
        var legacy = entry(0, 1, nil, .room, candidate: "room-2")
        legacy.attributionStatus = .overlapping
        let completed = AutomaticSpeakerAttribution.complete([legacy])
        XCTAssertEqual(completed.first?.speakerID, "room-2")
        XCTAssertEqual(completed.first?.attributionStatus, .overlapping)
        let drafts = AutomaticSpeakerAttribution.complete([AttributedTranscriptDraft(
            transcript: .init(startTime: 0, endTime: 1, text: "原句"), speakerID: nil, source: .room,
            attributionStatus: .overlapping)])
        XCTAssertEqual(drafts.first?.speakerID, "room-1")
        XCTAssertEqual(drafts.first?.attributionStatus, .overlapping)

        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .offline, startedAt: .now, speakerDiarizationRequested: true)
        try repository.updateMeetingState(id: id, state: .recording)
        repository.beginLiveSpeakerAttribution(meetingID: id, mode: .offline)
        try repository.appendTranscript(meetingID: id, start: 0, end: 1, text: "同时发言")
        try repository.applyLiveSpeakerBatch(meetingID: id, batch: .init(startTime: 0, endTime: 1,
            source: .room, intervals: [.init(rawSpeakerID: "room-1", startTime: 0, endTime: 1),
                                      .init(rawSpeakerID: "room-2", startTime: 0, endTime: 0.7)]))
        let row = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        XCTAssertEqual(row.speakerID, "room-1")
        XCTAssertEqual(row.attributionStatus, .overlapping)
        try repository.appendTranscript(meetingID: id, start: 0.1, end: 0.5, text: "晚到的文字")
        XCTAssertTrue(try repository.transcripts(meetingID: id).allSatisfy { $0.attributionStatus == .overlapping })
    }

    @MainActor
    func testFailedLiveBatchRollsBackLabelStatusRevisionAndCachedEvidence() throws {
        enum Failure: Error { case save }
        var failSave = false
        let repository = try MeetingRepository.inMemory(contextSaver: {
            if failSave { throw Failure.save }; try $0.save()
        })
        let id = try repository.createMeeting(mode: .offline, startedAt: .now, speakerDiarizationRequested: true)
        try repository.updateMeetingState(id: id, state: .recording)
        repository.beginLiveSpeakerAttribution(meetingID: id, mode: .offline)
        try repository.appendTranscript(meetingID: id, start: 0, end: 1, text: "首句")
        let row = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        let revision = try repository.meeting(id: id).contentRevision
        let batch = LiveSpeakerBatch(startTime: 0, endTime: 1, source: .room,
            intervals: [.init(rawSpeakerID: "room-2", startTime: 0, endTime: 1)])
        failSave = true
        XCTAssertThrowsError(try repository.applyLiveSpeakerBatch(meetingID: id, batch: batch))
        XCTAssertEqual(row.speakerID, "room-1")
        XCTAssertEqual(row.attributionStatus, .inferred)
        XCTAssertEqual(try repository.meeting(id: id).contentRevision, revision)
        failSave = false
        try repository.appendTranscript(meetingID: id, start: 0.2, end: 0.8, text: "晚到文字")
        XCTAssertTrue(try repository.transcripts(meetingID: id).allSatisfy { $0.speakerID == "room-1" },
            "A rejected batch must not leak its cached evidence into a late transcript")
        try repository.applyLiveSpeakerBatch(meetingID: id, batch: batch)
        XCTAssertTrue(try repository.transcripts(meetingID: id).allSatisfy {
            $0.speakerID == "room-2" && $0.attributionStatus == .attributed
        }, "The same batch must remain retryable after rollback")
    }

    func testFourHourIndexHandlesThirtyThousandSentenceLookupsWithNoMissingIdentity() {
        let intervals = (0..<3_000).map { SpeakerInterval(rawSpeakerID: "room-\($0 % 5 + 1)",
            startTime: Double($0) * 4.8, endTime: Double($0) * 4.8 + 4) }
        let index = SpeakerEvidenceIndex(intervals)
        let clock = ContinuousClock()
        let start = clock.now
        var count = 0
        for i in 0..<30_000 {
            let time = Double(i % 3_000) * 4.8 + 4.1
            if index.bestEffortSpeaker(start: time, end: time + 0.2) != nil { count += 1 }
        }
        let elapsed = clock.now - start
        print("SPEAKER_INDEX_BENCHMARK lookups=30000 elapsed=\(elapsed)")
        XCTAssertEqual(count, 30_000)
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    private func entry(_ start: Double, _ end: Double, _ id: String?, _ source: TranscriptAudioSource,
                       candidate: String? = nil) -> CanonicalTranscriptEntry {
        let uuid = UUID()
        return .init(id: uuid, transcriptIDs: [uuid], startTime: start, endTime: end, text: "原句\(start)",
            speakerID: id, source: source, isManuallyEdited: false,
            reviewHint: candidate.map { .init(candidateSpeakerID: $0, reason: .acousticCandidate) })
    }
}
