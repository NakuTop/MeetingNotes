import XCTest
@testable import MeetingNotes

final class LiveSpeakerAttributionTests: XCTestCase {
    func testStableSpeakerIDsAcrossBatchesAndAbsoluteTimestamps() async throws {
        let queue = LiveSpeakerAttributionQueue(engine: LiveSpeakerEchoEngine(), mode: .online)
        var iterator = await queue.updates().makeAsyncIterator()
        await queue.enqueue(samples: [Float](repeating: 1, count: 16_000), startingAt: 0)
        let first = await iterator.next()
        await queue.enqueue(samples: [Float](repeating: 2, count: 16_000), startingAt: 1)
        let second = await iterator.next()
        await queue.enqueue(samples: [Float](repeating: 1, count: 16_000), startingAt: 2)
        let third = await iterator.next()
        XCTAssertEqual(first?.intervals.first?.rawSpeakerID, "speaker-1")
        XCTAssertEqual(second?.intervals.first?.rawSpeakerID, "speaker-2")
        XCTAssertEqual(third?.intervals.first?.rawSpeakerID, "speaker-1")
        XCTAssertEqual(third?.startTime, 2)
        XCTAssertEqual(third?.endTime, 3)
        XCTAssertEqual(third?.source, .mixed)
        await queue.cancel()
    }

    func testCancellationFinishesConsumerWithoutWaitingForLateEngine() async {
        let engine = BlockingLiveSpeakerEngine()
        let queue = LiveSpeakerAttributionQueue(engine: engine, mode: .offline)
        var iterator = await queue.updates().makeAsyncIterator()
        await queue.enqueue(samples: [1], startingAt: 0)
        await engine.waitUntilStarted()
        await queue.cancel()
        let result = await iterator.next()
        XCTAssertNil(result)
        await engine.finish()
        await queue.enqueue(samples: [2], startingAt: 1)
        let later = await iterator.next()
        XCTAssertNil(later)
    }

    func testSlowEngineKeepsOnlyBoundedRecentPreviewChunks() async {
        let engine = BlockingLiveSpeakerEngine()
        let queue = LiveSpeakerAttributionQueue(engine: engine, mode: .offline, maximumPendingChunks: 2)
        var iterator = await queue.updates().makeAsyncIterator()
        await queue.enqueue(samples: [1], startingAt: 0)
        await engine.waitUntilStarted()
        for time in 1...5 { await queue.enqueue(samples: [1], startingAt: Double(time)) }
        await engine.finish()
        let first = await iterator.next()
        let second = await iterator.next()
        let third = await iterator.next()
        XCTAssertEqual([first?.startTime, second?.startTime, third?.startTime], [0, 4, 5])
        await queue.cancel()
    }
}

private struct LiveSpeakerEchoEngine: LiveSpeakerAnalyzing {
    func analyze(samples: [Float], startingAt: TimeInterval) async throws -> [SpeakerInterval] {
        [.init(rawSpeakerID: String(samples[0]), startTime: startingAt,
               endTime: startingAt + Double(samples.count) / 16_000)]
    }
}

private actor BlockingLiveSpeakerEngine: LiveSpeakerAnalyzing {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func analyze(samples: [Float], startingAt: TimeInterval) async throws -> [SpeakerInterval] {
        if !started {
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
            await withCheckedContinuation { release = $0 }
        }
        return [.init(rawSpeakerID: "one", startTime: startingAt, endTime: startingAt + 1)]
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func finish() { release?.resume(); release = nil }
}

@MainActor
final class LiveSpeakerPersistenceTests: XCTestCase {
    func testSpeakerBatchChangesOnlyLabelsAndPreservesEditedTextAndRowIdentity() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .online, startedAt: .now, speakerDiarizationRequested: true)
        try repository.updateMeetingState(id: id, state: .recording)
        try repository.appendTranscript(meetingID: id, start: 0, end: 1, text: "原文")
        let record = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        let originalID = record.id
        try repository.saveTranscriptCorrection(meetingID: id, transcriptIDs: [originalID],
            anchorStartTime: 0, anchorEndTime: 1, source: .mixed, originalText: "原文", replacementText: "我改好的文字")
        try repository.applyLiveSpeakerBatch(meetingID: id, batch: batch(0, speaker: "speaker-1"))
        let after = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        XCTAssertEqual(after.id, originalID)
        XCTAssertEqual(after.text, "原文")
        XCTAssertEqual(after.speakerID, "speaker-1")
        XCTAssertEqual(after.source, .mixed)
        XCTAssertEqual(try repository.meeting(id: id).state, .recording)
        let meeting = try repository.meeting(id: id)
        let corrected = TranscriptCorrectionResolver.resolve(transcripts: meeting.transcripts, corrections: meeting.transcriptCorrections)
        XCTAssertEqual(corrected.map(\.text), ["我改好的文字"])
        XCTAssertEqual(corrected.map(\.speakerID), ["speaker-1"])
    }

    func testFinalCalibrationRemapsLiveSpeakerNamesAndPreservesManualCorrection() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .online, startedAt: .now, speakerDiarizationRequested: true)
        try repository.appendTranscript(meetingID: id, start: 0, end: 1, text: "原文", speakerID: "speaker-5")
        let original = try XCTUnwrap(repository.transcripts(meetingID: id).first)
        try repository.setSpeakerDisplayName(meetingID: id, speakerID: "speaker-5", displayName: "张老师")
        try repository.saveTranscriptCorrection(meetingID: id, transcriptIDs: [original.id],
            anchorStartTime: 0, anchorEndTime: 1, source: .mixed, originalText: "原文", replacementText: "手动修正")
        try repository.replaceTranscripts(meetingID: id,
            drafts: [.init(transcript: .init(startTime: 0, endTime: 1, text: "原文"), speakerID: "speaker-1", source: .mixed)],
            sourceRevision: 1)
        XCTAssertEqual(try repository.speakerDisplayNames(meetingID: id), ["speaker-1": "张老师"])
        let meeting = try repository.meeting(id: id)
        let corrected = TranscriptCorrectionResolver.resolve(transcripts: meeting.transcripts, corrections: meeting.transcriptCorrections)
        XCTAssertEqual(corrected.map(\.text), ["手动修正"])
        XCTAssertEqual(corrected.map(\.speakerID), ["speaker-1"])
    }

    func testDelayedTranscriptionUsesExistingSpeakerIntervalsAndNewMeetingIsIsolated() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .offline, startedAt: .now, speakerDiarizationRequested: true)
        try repository.updateMeetingState(id: id, state: .recording)
        try repository.applyLiveSpeakerBatch(meetingID: id, batch: batch(0, speaker: "room-1", source: .room))
        try repository.appendTranscript(meetingID: id, start: 0, end: 1, text: "迟到文字")
        XCTAssertEqual(try repository.transcripts(meetingID: id).first?.speakerID, "room-1")
        let second = try repository.createMeeting(mode: .offline, startedAt: .now, speakerDiarizationRequested: true)
        try repository.appendTranscript(meetingID: second, start: 0, end: 1, text: "另一场")
        XCTAssertNil(try repository.transcripts(meetingID: second).first?.speakerID)
        repository.endLiveSpeakerAttribution(meetingID: id)
        try repository.appendTranscript(meetingID: id, start: 0, end: 1, text: "结束后")
        XCTAssertNil(try repository.transcripts(meetingID: id).first(where: { $0.text == "结束后" })?.speakerID)
    }

    func testLateBatchAfterStopCannotChangeFinalSpeakerLabels() throws {
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .online, startedAt: .now, speakerDiarizationRequested: true)
        try repository.appendTranscript(meetingID: id, start: 0, end: 1, text: "最终文字", speakerID: "speaker-7")
        try repository.updateMeetingState(id: id, state: .finalizing)
        try repository.applyLiveSpeakerBatch(meetingID: id, batch: batch(0, speaker: "speaker-1"))
        XCTAssertEqual(try repository.transcripts(meetingID: id).first?.speakerID, "speaker-7")
    }

    private func batch(_ start: Double, speaker: String, source: TranscriptAudioSource = .mixed) -> LiveSpeakerBatch {
        LiveSpeakerBatch(startTime: start, endTime: start + 1, source: source,
            intervals: [.init(rawSpeakerID: speaker, startTime: start, endTime: start + 1)])
    }
}
