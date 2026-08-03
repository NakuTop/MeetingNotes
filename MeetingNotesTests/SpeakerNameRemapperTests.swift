import XCTest
@testable import MeetingNotes

final class SpeakerNameRemapperTests: XCTestCase {
    func testExactHighOverlapMigratesNameToRenumberedSpeaker() {
        XCTAssertEqual(
            remap(
                old: [evidence("room-7", "张三", 0, 10, .room)],
                new: [draft("room-2", 0, 10, .room)]
            ),
            ["room-2": "张三"]
        )
    }

    func testTwoOldSpeakersMapUniquelyRegardlessOfInputOrder() {
        let old = [
            evidence("room-b", "李四", 5, 10, .room),
            evidence("room-a", "张三", 0, 5, .room),
        ]
        let new = [
            draft("room-2", 5, 10, .room),
            draft("room-1", 0, 5, .room),
        ]

        XCTAssertEqual(
            remap(old: old, new: new),
            ["room-1": "张三", "room-2": "李四"]
        )
        XCTAssertEqual(
            remap(old: old.reversed(), new: new.reversed()),
            ["room-1": "张三", "room-2": "李四"]
        )
    }

    func testCoverageBelowThresholdDoesNotGuess() {
        XCTAssertTrue(
            remap(
                old: [evidence("room-1", "张三", 0, 10, .room)],
                new: [draft("room-2", 0, 5.9, .room)]
            ).isEmpty
        )
    }

    func testWinnerMarginBelowThresholdDoesNotGuess() {
        XCTAssertTrue(
            remap(
                old: [evidence("room-1", "张三", 0, 10, .room)],
                new: [
                    draft("room-2", 0, 6, .room),
                    draft("room-3", 4.5, 10, .room),
                ]
            ).isEmpty
        )
    }

    func testCompetingOldNamesForOneNewSpeakerAreBothDiscarded() {
        XCTAssertTrue(
            remap(
                old: [
                    evidence("room-1", "张三", 0, 5, .room),
                    evidence("room-2", "李四", 5, 10, .room),
                ],
                new: [draft("room-9", 0, 10, .room)]
            ).isEmpty
        )
    }

    func testMicrophoneMeCannotBeMatchedToOverlappingSystemSpeaker() {
        XCTAssertEqual(
            remap(
                old: [evidence("me", "沈明昊", 0, 5, .microphone)],
                new: [
                    draft("remote-1", 0, 5, .system),
                    draft("me", 0, 5, .microphone),
                ]
            ),
            ["me": "沈明昊"]
        )
    }

    private func remap<S1: Sequence, S2: Sequence>(
        old: S1,
        new: S2
    ) -> [String: String]
    where S1.Element == SpeakerNameEvidence,
          S2.Element == AttributedTranscriptDraft {
        SpeakerNameRemapper().remap(
            oldNamedSpeakers: Array(old),
            newDrafts: Array(new)
        )
    }

    private func evidence(
        _ speakerID: String,
        _ name: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ source: TranscriptAudioSource
    ) -> SpeakerNameEvidence {
        SpeakerNameEvidence(
            speakerID: speakerID,
            displayName: name,
            intervals: [
                SpeakerNameEvidenceInterval(
                    startTime: start,
                    endTime: end,
                    source: source
                )
            ]
        )
    }

    private func draft(
        _ speakerID: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ source: TranscriptAudioSource
    ) -> AttributedTranscriptDraft {
        AttributedTranscriptDraft(
            transcript: TranscriptDraft(
                startTime: start,
                endTime: end,
                text: "发言"
            ),
            speakerID: speakerID,
            source: source
        )
    }
}
