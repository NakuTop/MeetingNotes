import XCTest
@testable import MeetingNotes

final class SpeakerReviewEvidenceTests: XCTestCase {
    private let draft = TranscriptDraft(startTime: 10, endTime: 12, text: "保留原文")
    private func interval(_ id: String, _ start: Double, _ end: Double) -> SpeakerInterval {
        .init(rawSpeakerID: id, startTime: start, endTime: end)
    }
    private func assigned(_ global: [SpeakerInterval], _ local: [SpeakerRefinedRegion] = []) -> AttributedTranscriptDraft {
        SpeakerIntervalAssigner().assign([draft], intervals: global, speakerPrefix: "room", source: .room, refinements: local)[0]
    }
    private func region(_ id: String = "a", strong: Bool = true, overlap: Bool = false) -> SpeakerRefinedRegion {
        .init(span: .init(start: 8, end: 16), intervals:
            [interval("local", 10, 12)] + (overlap ? [interval("unmatched", 10, 12)] : []),
            matches: ["local": .init(rawSpeakerID: id, isStrong: strong)])
    }

    func testMissingCoverageAssignsCandidateButDoesNotClaimConfidence() {
        let value = assigned([interval("a", 10, 10.8)])
        XCTAssertEqual(value.speakerID, "room-1")
        XCTAssertEqual(value.attributionStatus, .inferred)
        XCTAssertEqual(value.reviewHint?.candidateSpeakerID, "room-1")
        XCTAssertEqual(value.reviewHint?.reason, .insufficientCoverage)
        XCTAssertTrue(value.reviewHint?.canGroupForReview == true)
        XCTAssertEqual(value.transcript, draft)
    }
    func testNoSpeechAndInvalidTimingHaveNoBatchCandidate() {
        XCTAssertEqual(assigned([]).reviewHint?.reason, .missingSpeech)
        XCTAssertFalse(assigned([]).reviewHint?.canGroupForReview ?? true)
        XCTAssertEqual(SpeakerEvidenceIndex([]).evidence(start: .nan, end: 1).hint?.reason, .invalidTiming)
    }
    func testCompetingSpeakersCannotJoinBulkSuggestion() {
        let value = assigned([interval("a", 10, 11), interval("b", 11, 12)])
        XCTAssertEqual(value.speakerID, "room-1")
        XCTAssertEqual(value.reviewHint?.reason, .competingSpeakers)
        XCTAssertFalse(value.reviewHint?.canGroupForReview ?? true)
    }
    func testStrongLocalEvidenceFillsOnlyUncertainSpan() {
        let value = assigned([interval("a", 10, 10.8)], [region()])
        XCTAssertEqual(value.speakerID, "room-1")
        XCTAssertEqual(value.attributionStatus, .attributed)
        XCTAssertEqual(value.transcript, draft)
    }
    func testWeakAcousticMatchIsAssignedAsAnEstimate() {
        let value = assigned([], [region(strong: false)])
        XCTAssertEqual(value.speakerID, "room-1")
        XCTAssertEqual(value.reviewHint?.basis, .meetingVoice)
        XCTAssertEqual(value.reviewHint?.candidateSpeakerID, "room-1")
    }
    func testRefinementCannotOverwriteCertainOrOverlappingGlobalResult() {
        XCTAssertEqual(assigned([interval("a", 10, 12)], [region("b")]).attributionStatus, .attributed)
        let overlap = assigned([interval("a", 10, 12), interval("b", 10, 12)], [region()])
        XCTAssertEqual(overlap.speakerID, "room-1")
        XCTAssertEqual(overlap.attributionStatus, .overlapping)
    }
    func testUnmatchedLocalVoiceStillPreventsConfidence() {
        let value = assigned([], [region(overlap: true)])
        XCTAssertEqual(value.speakerID, "room-1")
        XCTAssertEqual(value.attributionStatus, .overlapping)
    }
    func testConflictingWindowsDoNotPromoteFirstWindowToConfidence() {
        let value = assigned([], [region("a"), region("b")])
        XCTAssertEqual(value.speakerID, "room-1")
        XCTAssertNil(value.reviewHint?.candidateSpeakerID)
    }
    func testLocalEvidenceDisagreeingWithGlobalRetainsAlternativeEvidence() {
        let value = assigned([interval("a", 10, 10.8)], [region("b")])
        XCTAssertEqual(value.speakerID, "room-1")
        XCTAssertNotNil(value.reviewHint?.alternativeSpeakerID)
        XCTAssertFalse(value.reviewHint?.canGroupForReview ?? true)
    }
    func testUnmatchedSecondWindowCannotBeDiscardedToClaimConfidence() {
        let other = SpeakerRefinedRegion(span: .init(start: 8, end: 16),
            intervals: [interval("different", 10, 12)], matches: [:])
        let value = assigned([], [region(), other])
        XCTAssertEqual(value.speakerID, "room-1")
        XCTAssertEqual(value.attributionStatus, .inferred)
    }
    func testCandidateOnlySpeakerDoesNotRenumberAlreadyAttributedPeople() {
        let drafts = [TranscriptDraft(startTime: 0, endTime: 2, text: "待复核"), draft]
        let values = SpeakerIntervalAssigner().assign(drafts, intervals: [interval("b", 0, 0.8), interval("a", 10, 12)],
            speakerPrefix: "room", source: .room)
        XCTAssertEqual(values[1].speakerID, "room-1")
        XCTAssertEqual(values[0].reviewHint?.candidateSpeakerID, "room-2")
    }
    func testWindowBudgetAndTimelineBounds() {
        let spans = (0..<3000).map { SpeakerReviewSpan(start: Double($0 * 5), end: Double($0 * 5 + 1)) }
        let windows = SpeakerReviewWindowPlanner.windows(spans: spans, intervals: [], duration: 15_000)
        XCTAssertFalse(windows.isEmpty)
        XCTAssertLessThanOrEqual(windows.count, 12)
        XCTAssertLessThanOrEqual(windows.reduce(0) { $0 + $1.end - $1.start }, 120)
        XCTAssertTrue(windows.allSatisfy { $0.start >= 0 && $0.end <= 15_000 && $0.end - $0.start <= 20 })
    }
    func testWindowPlannerSkipsConfidentAndOverlapSpans() {
        let windows = SpeakerReviewWindowPlanner.windows(spans: [.init(start: 0, end: 1), .init(start: 4, end: 5)],
            intervals: [interval("a", 0, 8), interval("b", 4, 5)], duration: 8)
        XCTAssertTrue(windows.isEmpty)
    }
    func testReferenceEligibilityExcludesOverlapAndLowQualityWithoutDoubleCounting() {
        let segments: [SpeakerReferenceSegment] = [
            .init(interval: interval("a", 0, 6), quality: 0.9),
            .init(interval: interval("b", 1, 6), quality: 0.9),
            .init(interval: interval("c", 6, 12), quality: 0.2),
            .init(interval: interval("d", 12, 18), quality: 0.9),
            .init(interval: interval("e", 18, 21), quality: 0.9),
            .init(interval: interval("e", 18, 21), quality: 0.9)]
        XCTAssertEqual(MeetingSpeakerReferencePolicy.eligibleIDs(segments), ["d"])
    }
    func testReferenceMatcherRejectsAmbiguityAndInvalidVectors() {
        var a = [Float](repeating: 0, count: 256); a[0] = 1
        XCTAssertEqual(MeetingSpeakerReferenceMatcher.match(a, against: ["a": a])?.isStrong, true)
        XCTAssertNil(MeetingSpeakerReferenceMatcher.match(a, against: ["a": a, "b": a]))
        XCTAssertNil(MeetingSpeakerReferenceMatcher.match([.nan], against: ["a": a]))
        var weak = a; weak[0] = 0.8; weak[1] = 0.6
        XCTAssertEqual(MeetingSpeakerReferenceMatcher.match(weak, against: ["a": a])?.isStrong, false)
    }
    func testHintRoundTripAndConsensusFailClosedForDifferentCandidates() throws {
        let hint = SpeakerReviewHint(candidateSpeakerID: "room-1", reason: .insufficientCoverage, coverage: 0.4, margin: 0.4)
        XCTAssertEqual(try JSONDecoder().decode(SpeakerReviewHint.self, from: JSONEncoder().encode(hint)), hint)
        XCTAssertNil(SpeakerReviewHint.consensus([hint, nil]))
        XCTAssertNil(SpeakerReviewHint.consensus([hint, .init(candidateSpeakerID: "room-2", reason: .insufficientCoverage)]))
    }
    func testWordTextAndTimingsAreConservedDuringRefinement() {
        let text = "第一句，第二句。"
        let words: [TranscriptWordTiming] = [.init(text: "第一句，", startTime: 10, endTime: 11),
                                             .init(text: "第二句。", startTime: 11, endTime: 12)]
        let input = TranscriptDraft(startTime: 10, endTime: 12, text: text, words: words)
        let values = SpeakerIntervalAssigner().assign([input], intervals: [], speakerPrefix: "room", source: .room,
            refinements: [region()])
        XCTAssertEqual(values.map { $0.transcript.text }.joined(), text)
        XCTAssertEqual(values.flatMap { $0.transcript.words }, words)
    }
}
