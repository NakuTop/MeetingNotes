import XCTest
@testable import MeetingNotes

final class SpeakerIntervalAssignerTests: XCTestCase {
    func testAssignsSpeakerWithGreatestOverlap() {
        let drafts = [
            TranscriptDraft(startTime: 1, endTime: 5, text: "重点"),
        ]
        let intervals = [
            SpeakerInterval(
                rawSpeakerID: "short",
                startTime: 1,
                endTime: 2
            ),
            SpeakerInterval(
                rawSpeakerID: "long",
                startTime: 2,
                endTime: 5
            ),
        ]

        let assigned = SpeakerIntervalAssigner().assign(
            drafts,
            intervals: intervals,
            speakerPrefix: "remote",
            source: .system
        )

        XCTAssertEqual(assigned.map(\.speakerID), ["remote-1"])
        XCTAssertEqual(assigned.map(\.source), [.system])
    }

    func testBreaksEqualOverlapTiesByIntervalTimelineThenRawID() {
        let draft = TranscriptDraft(
            startTime: 2,
            endTime: 4,
            text: "平局"
        )
        let intervals = [
            SpeakerInterval(
                rawSpeakerID: "zeta",
                startTime: 3,
                endTime: 5
            ),
            SpeakerInterval(
                rawSpeakerID: "beta",
                startTime: 1,
                endTime: 3
            ),
            SpeakerInterval(
                rawSpeakerID: "alpha",
                startTime: 1,
                endTime: 3
            ),
        ]

        let assigned = SpeakerIntervalAssigner().assign(
            [draft],
            intervals: intervals,
            speakerPrefix: "remote",
            source: .system
        )

        XCTAssertEqual(assigned.map(\.speakerID), ["remote-1"])
        XCTAssertEqual(
            SpeakerIntervalAssigner().assignedRawSpeakerIDs(
                [draft],
                intervals: intervals
            ),
            ["alpha"]
        )
    }

    func testNoOverlapFallsBackToNearestInterval() {
        let drafts = [
            TranscriptDraft(startTime: 10, endTime: 11, text: "间隔"),
        ]
        let intervals = [
            SpeakerInterval(
                rawSpeakerID: "far",
                startTime: 0,
                endTime: 1
            ),
            SpeakerInterval(
                rawSpeakerID: "near",
                startTime: 12,
                endTime: 13
            ),
        ]

        let rawIDs = SpeakerIntervalAssigner().assignedRawSpeakerIDs(
            drafts,
            intervals: intervals
        )

        XCTAssertEqual(rawIDs, ["near"])
    }

    func testNumbersRawSpeakersByFirstTranscriptAppearance() {
        let drafts = [
            TranscriptDraft(startTime: 0, endTime: 1, text: "B 先说"),
            TranscriptDraft(startTime: 1, endTime: 2, text: "A 后说"),
            TranscriptDraft(startTime: 2, endTime: 3, text: "B 再说"),
        ]
        let intervals = [
            SpeakerInterval(
                rawSpeakerID: "raw-a",
                startTime: 1,
                endTime: 2
            ),
            SpeakerInterval(
                rawSpeakerID: "raw-b",
                startTime: 0,
                endTime: 1
            ),
            SpeakerInterval(
                rawSpeakerID: "raw-b",
                startTime: 2,
                endTime: 3
            ),
        ]

        let assigned = SpeakerIntervalAssigner().assign(
            drafts,
            intervals: intervals,
            speakerPrefix: "remote",
            source: .system
        )

        XCTAssertEqual(
            assigned.map(\.speakerID),
            ["remote-1", "remote-2", "remote-1"]
        )
    }

    func testUsesRemoteAndRoomPrefixesWithoutSharingNumbering() {
        let drafts = [
            TranscriptDraft(startTime: 0, endTime: 1, text: "第一位"),
            TranscriptDraft(startTime: 1, endTime: 2, text: "第二位"),
        ]
        let intervals = [
            SpeakerInterval(
                rawSpeakerID: "speaker-b",
                startTime: 0,
                endTime: 1
            ),
            SpeakerInterval(
                rawSpeakerID: "speaker-a",
                startTime: 1,
                endTime: 2
            ),
        ]
        let assigner = SpeakerIntervalAssigner()

        let online = assigner.assign(
            drafts,
            intervals: intervals,
            speakerPrefix: "remote",
            source: .system
        )
        let offline = assigner.assign(
            drafts,
            intervals: intervals,
            speakerPrefix: "room",
            source: .room
        )

        XCTAssertEqual(
            online.map(\.speakerID),
            ["remote-1", "remote-2"]
        )
        XCTAssertEqual(
            offline.map(\.speakerID),
            ["room-1", "room-2"]
        )
        XCTAssertEqual(offline.map(\.source), [.room, .room])
    }

    func testIgnoresInvalidIntervalsBeforeDeterministicSelection() {
        let draft = TranscriptDraft(
            startTime: 1,
            endTime: 2,
            text: "有效说话人"
        )
        let intervals = [
            SpeakerInterval(
                rawSpeakerID: "invalid",
                startTime: .nan,
                endTime: 2
            ),
            SpeakerInterval(
                rawSpeakerID: "valid",
                startTime: 1,
                endTime: 2
            ),
        ]

        let rawIDs = SpeakerIntervalAssigner().assignedRawSpeakerIDs(
            [draft],
            intervals: intervals
        )

        XCTAssertEqual(rawIDs, ["valid"])
    }
}
