import XCTest

@testable import MeetingNotes

final class OnlineSpeakerSourceReviewTests: XCTestCase {
    func testQuietAndInvalidSignalsDoNotInventSourceEvidence() {
        XCTAssertNil(
            OnlineSpeakerSourceReviewer.classify(
                microphone: Array(repeating: 0, count: 16_000)[...],
                system: Array(repeating: 0, count: 16_000)[...]))
        XCTAssertNil(
            OnlineSpeakerSourceReviewer.classify(
                microphone: [Float.nan][...], system: [Float(1)][...]))
    }

    func testMicrophoneAndSystemDominanceAreDistinctFromPersonalIdentity() {
        let signal = noise(seed: 42)
        let silence = Array(repeating: Float(0), count: signal.count)
        XCTAssertEqual(
            OnlineSpeakerSourceReviewer.classify(microphone: signal[...], system: silence[...]),
            .microphoneDominant)
        XCTAssertEqual(
            OnlineSpeakerSourceReviewer.classify(microphone: silence[...], system: signal[...]),
            .systemDominant)
    }

    func testDelayedScaledDuplicateIsOnlyAnEchoWarning() {
        let signal = noise(seed: 57)
        let delayed =
            Array(repeating: Float(0), count: 1_600) + signal.dropLast(1_600).map { $0 * 0.6 }
        XCTAssertEqual(
            OnlineSpeakerSourceReviewer.classify(microphone: signal[...], system: delayed[...]),
            .possibleEcho)
    }

    func testIndependentSimultaneousSignalsRemainMixed() {
        XCTAssertEqual(
            OnlineSpeakerSourceReviewer.classify(
                microphone: noise(seed: 3)[...], system: noise(seed: 937)[...]), .mixed)
    }

    func testReaderTimelineAlignmentAddsAdvisoryWithoutChangingTextIdentityOrTrack() async throws {
        let signal = noise(seed: 31)
        let draft = AttributedTranscriptDraft(
            transcript: .init(startTime: 0.25, endTime: 1, text: "保留已转录的文字"),
            speakerID: "speaker-2", source: .mixed, attributionStatus: .attributed)
        let reviewer = OnlineSpeakerSourceReviewer(
            reader: SourceReviewReader(
                microphone: [.init(samples: signal, startingAt: 0)],
                system: [.init(samples: Array(repeating: 0, count: 16_000), startingAt: 0.25)]))
        let result = try await reviewer.review(meetingID: UUID(), drafts: [draft])
        XCTAssertEqual(result.first?.sourceEvidence, .microphoneDominant)
        XCTAssertEqual(result.first?.transcript, draft.transcript)
        XCTAssertEqual(result.first?.speakerID, draft.speakerID)
        XCTAssertEqual(result.first?.source, .mixed)
        XCTAssertEqual(result.first?.attributionStatus, .attributed)
    }

    func testMissingTrackPreservesDiarizationAndNeverClaimsAReadSucceeded() async throws {
        let draft = AttributedTranscriptDraft(
            transcript: .init(startTime: 0, endTime: 1, text: "原文"), speakerID: "speaker-1",
            source: .mixed)
        let reviewer = OnlineSpeakerSourceReviewer(
            reader: SourceReviewReader(microphone: [], system: nil))
        let result = try await reviewer.review(meetingID: UUID(), drafts: [draft])
        XCTAssertEqual(result, [draft])
        XCTAssertNil(result.first?.sourceEvidence)
    }

    func testCancelledSourceReviewDoesNotSwallowCancellation() async {
        let reviewer = OnlineSpeakerSourceReviewer(reader: CancelledSourceReviewReader())
        do {
            _ = try await reviewer.review(
                meetingID: UUID(),
                drafts: [
                    .init(
                        transcript: .init(startTime: 0, endTime: 1, text: "保留"),
                        speakerID: "speaker-1", source: .mixed)
                ])
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func noise(seed: UInt64) -> [Float] {
        var state = seed
        return (0..<16_000).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return (Float((state >> 32) & 65_535) / 65_535 - 0.5) * 0.1
        }
    }
}

private struct SourceReviewReader: MeetingTrackAudioReading {
    let microphone: [MeetingAudioSampleChunk]
    let system: [MeetingAudioSampleChunk]?
    func chunks(meetingID: UUID, track: AudioTrack) async throws -> MeetingAudioSampleChunks {
        try Task.checkCancellation()
        switch track {
        case .microphone: return MeetingAudioSampleChunks(microphone)
        case .system:
            guard let system else { throw SpeakerDiarizationError.invalidSource }
            return MeetingAudioSampleChunks(system)
        default: throw SpeakerDiarizationError.invalidSource
        }
    }
}

private struct CancelledSourceReviewReader: MeetingTrackAudioReading {
    func chunks(meetingID: UUID, track: AudioTrack) async throws -> MeetingAudioSampleChunks {
        throw CancellationError()
    }
}
