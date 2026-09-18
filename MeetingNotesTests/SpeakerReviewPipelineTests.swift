import XCTest
@testable import MeetingNotes

private struct ReviewPipelineReader: MeetingTrackAudioReading {
    func chunks(meetingID: UUID, track: AudioTrack) async throws -> MeetingAudioSampleChunks {
        throw SpeakerDiarizationError.inferenceFailed // No Whisper readback is allowed in speaker-only review.
    }
}

private actor ReviewPipelineDiarizer: SpeakerDiarizing {
    var spans: [SpeakerReviewSpan] = []
    var count: SpeakerCountConstraint?
    func diarize(source: MeetingAudioSource) async throws -> [SpeakerInterval] { throw SpeakerDiarizationError.inferenceFailed }
    func analyze(source: MeetingAudioSource, speakerCount: SpeakerCountConstraint,
                 reviewSpans: [SpeakerReviewSpan]) async throws -> SpeakerDiarizationAnalysis {
        spans = reviewSpans; count = speakerCount
        return .init(intervals: [.init(rawSpeakerID: "a", startTime: 0, endTime: 0.4)], refinements: [
            .init(span: .init(start: 0, end: 2), intervals: [.init(rawSpeakerID: "local", startTime: 0, endTime: 2)],
                  matches: ["local": .init(rawSpeakerID: "a", isStrong: false)])])
    }
    func recorded() -> ([SpeakerReviewSpan], SpeakerCountConstraint?) { (spans, count) }
}

private actor ReviewPipelineEngine: DiarizationEngine {
    let invalid: Bool
    let cancel: Bool
    var spans: [SpeakerReviewSpan] = []
    var fileURL: URL?
    init(invalid: Bool = false, cancel: Bool = false) { self.invalid = invalid; self.cancel = cancel }
    func prepareModels(directory: URL) async throws {}
    func process(audioSource: DiarizationDiskAudioSource, audioLoadingSeconds: TimeInterval) async throws -> [SpeakerInterval] {
        throw SpeakerDiarizationError.inferenceFailed
    }
    func analyze(audioSource: DiarizationDiskAudioSource, audioLoadingSeconds: TimeInterval,
                 speakerCount: SpeakerCountConstraint, reviewSpans: [SpeakerReviewSpan]) async throws -> SpeakerDiarizationAnalysis {
        spans = reviewSpans; fileURL = audioSource.fileURL
        if cancel { throw CancellationError() }
        return .init(intervals: [.init(rawSpeakerID: "a", startTime: 0, endTime: 1)], refinements: [
            .init(span: .init(start: 0, end: invalid ? 40 : 2), intervals: [.init(rawSpeakerID: "local", startTime: 0, endTime: 1)],
                  matches: ["local": .init(rawSpeakerID: "a", isStrong: true)])])
    }
    func recorded() -> ([SpeakerReviewSpan], URL?) { (spans, fileURL) }
}

final class SpeakerReviewPipelineTests: DiarizationAdapterTestCase {
    func testDiskAdapterForwardsSpansReturnsRefinementsAndCleansTemporaryAudio() async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(root: root, segmentSamples: [[Float](repeating: 0.1, count: 96_000)], segmentStartTimes: [0])
        let engine = ReviewPipelineEngine()
        let diarizer = makeDiarizer(root: root, sourceLoader: DiarizationAdapterTestSourceLoader(source: source),
                                   engine: engine, converter: DiarizationAdapterTestConverter())
        let spans = [SpeakerReviewSpan(start: 0, end: 1)]
        let result = try await diarizer.analyze(source: source, speakerCount: .exact(4), reviewSpans: spans)
        XCTAssertEqual(result.refinements.count, 1)
        let recorded = await engine.recorded()
        XCTAssertEqual(recorded.0, spans)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(recorded.1).path))
    }

    func testInvalidLocalRegionFailsValidationAndCleansDisk() async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(root: root, segmentSamples: [[Float](repeating: 0.1, count: 96_000)], segmentStartTimes: [0])
        let engine = ReviewPipelineEngine(invalid: true)
        let diarizer = makeDiarizer(root: root, sourceLoader: DiarizationAdapterTestSourceLoader(source: source),
                                   engine: engine, converter: DiarizationAdapterTestConverter())
        do { _ = try await diarizer.analyze(source: source, speakerCount: .automatic, reviewSpans: [.init(start: 0, end: 1)])
            XCTFail("Expected validation failure")
        } catch { XCTAssertEqual(error as? SpeakerDiarizationError, .resultValidationFailed) }
        let recorded = await engine.recorded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(recorded.1).path))
    }

    func testCancellationDuringReviewPropagatesAndCleansDisk() async throws {
        let root = try makeTemporaryRoot()
        let source = try makeSource(root: root, segmentSamples: [[Float](repeating: 0.1, count: 96_000)], segmentStartTimes: [0])
        let engine = ReviewPipelineEngine(cancel: true)
        let diarizer = makeDiarizer(root: root, sourceLoader: DiarizationAdapterTestSourceLoader(source: source),
                                   engine: engine, converter: DiarizationAdapterTestConverter())
        do { _ = try await diarizer.analyze(source: source, speakerCount: .automatic, reviewSpans: [.init(start: 0, end: 1)])
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let recorded = await engine.recorded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(recorded.1).path))
    }

    func testFinalizerRequestsMeasuredWordSpansAndPreservesReviewHints() async throws {
        let root = try makeTemporaryRoot()
        let id = UUID()
        let source = try makeSource(root: root, segmentSamples: [[Float](repeating: 0.1, count: 96_000)],
                                    segmentStartTimes: [0], meetingID: id)
        let diarizer = ReviewPipelineDiarizer()
        let finalizer = SpeakerAwareTranscriptFinalizer(reader: ReviewPipelineReader(),
            sourceLoader: DiarizationAdapterTestSourceLoader(source: source), diarizer: diarizer)
        let words: [TranscriptWordTiming] = [.init(text: "原文", startTime: 0, endTime: 1), .init(text: "不变", startTime: 1, endTime: 2)]
        let result = await finalizer.finalize(meetingID: id, mode: .offline, diarizationRequested: true,
            provisional: [.init(startTime: 0, endTime: 2, text: "原文不变", words: words)])
        guard case let .replacement(drafts, _) = result else { return XCTFail("Expected speaker-only replacement") }
        XCTAssertEqual(drafts.map { $0.transcript.text }.joined(), "原文不变")
        XCTAssertEqual(drafts.flatMap { $0.transcript.words }, words)
        XCTAssertTrue(drafts.allSatisfy { $0.reviewHint?.basis == .meetingVoice && $0.speakerID == "room-1" && $0.attributionStatus == .inferred })
        let recorded = await diarizer.recorded()
        XCTAssertEqual(recorded.0, [.init(start: 0, end: 1), .init(start: 1, end: 2)])
    }

    @MainActor
    func testRetryPreservesCandidateEvidenceThroughPersistence() async throws {
        let root = try makeTemporaryRoot()
        let repository = try MeetingRepository.inMemory()
        let id = try repository.createMeeting(mode: .offline, startedAt: .now, speakerDiarizationRequested: true)
        try repository.appendTranscript(meetingID: id, start: 0, end: 2, text: "不重跑识别")
        try repository.updateMeetingState(id: id, state: .ready)
        try repository.meeting(id: id).speakerProcessingState = .completed
        let source = try makeSource(root: root, segmentSamples: [[Float](repeating: 0.1, count: 96_000)],
                                    segmentStartTimes: [0], meetingID: id)
        let diarizer = ReviewPipelineDiarizer()
        let retry = SpeakerDiarizationRetryUseCase(repository: repository,
            sourceLoader: DiarizationAdapterTestSourceLoader(source: source), diarizer: diarizer, operationGate: MeetingOperationGate())
        try await retry.retry(meetingID: id)
        let rows = try repository.transcripts(meetingID: id)
        XCTAssertEqual(rows.map(\.text), ["不重跑识别"])
        XCTAssertEqual(rows.first?.reviewHint?.basis, .meetingVoice)
        XCTAssertEqual(rows.first?.speakerID, "room-1")
        XCTAssertEqual(rows.first?.attributionStatus, .inferred)
        XCTAssertEqual(try MeetingSpeakerReviewCatalog.make(meeting: repository.meeting(id: id)).groups.count, 0)
    }
}
