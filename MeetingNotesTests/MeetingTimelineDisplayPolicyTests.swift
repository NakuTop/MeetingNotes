import XCTest
@testable import MeetingNotes

@MainActor
final class MeetingTimelineDisplayPolicyTests: XCTestCase {
    func testMixedEventsSortByTimestampThenSequenceAndStableIdentity() {
        let transcriptID = fixedUUID("00000000-0000-0000-0000-000000000003")
        let earlierScreenshotID = fixedUUID(
            "00000000-0000-0000-0000-000000000001"
        )
        let laterScreenshotID = fixedUUID(
            "00000000-0000-0000-0000-000000000004"
        )
        let sameSequenceEarlierID = fixedUUID(
            "00000000-0000-0000-0000-000000000000"
        )
        let noteID = fixedUUID("00000000-0000-0000-0000-000000000002")
        let turn = TranscriptDisplayTurn(
            canonicalEntryID: transcriptID,
            correctionID: nil,
            transcriptIDs: [transcriptID],
            startTime: 3,
            endTime: 4,
            text: "转录",
            speakerID: "room-1",
            source: .room,
            isHighlighted: false
        )
        let notes = [
            MeetingNoteRecord(
                id: noteID,
                timestamp: 3,
                text: "笔记",
                sequenceIndex: 1
            ),
        ]
        let screenshots = [
            MeetingScreenshotRecord(
                id: laterScreenshotID,
                timestamp: 3,
                relativePath: "meeting/screenshots/later.png",
                pixelWidth: 100,
                pixelHeight: 80,
                byteCount: 10,
                sequenceIndex: 2
            ),
            MeetingScreenshotRecord(
                id: earlierScreenshotID,
                timestamp: 1,
                relativePath: "meeting/screenshots/earlier.png",
                pixelWidth: 100,
                pixelHeight: 80,
                byteCount: 10,
                sequenceIndex: 0
            ),
            MeetingScreenshotRecord(
                id: sameSequenceEarlierID,
                timestamp: 3,
                relativePath: "meeting/screenshots/same-sequence.png",
                pixelWidth: 100,
                pixelHeight: 80,
                byteCount: 10,
                sequenceIndex: 2
            ),
        ]

        let items = MeetingTimelineDisplayPolicy.items(
            transcriptTurns: [turn],
            notes: notes,
            screenshots: screenshots
        )

        XCTAssertEqual(
            items.map(\.id),
            [
                earlierScreenshotID,
                transcriptID,
                noteID,
                sameSequenceEarlierID,
                laterScreenshotID,
            ]
        )
        XCTAssertEqual(items.map(\.timestamp), [1, 3, 3, 3, 3])
    }

    func testNoteOnlyMeetingProducesVisibleTimelineItem() {
        let noteID = UUID()
        let items = MeetingTimelineDisplayPolicy.items(
            transcriptTurns: [],
            notes: [
                MeetingNoteRecord(
                    id: noteID,
                    timestamp: 7.5,
                    text: "只有笔记也要显示",
                    sequenceIndex: 0
                ),
            ],
            screenshots: []
        )

        XCTAssertEqual(items.count, 1)
        guard case let .note(note) = items[0] else {
            return XCTFail("Expected a note timeline item")
        }
        XCTAssertEqual(note.id, noteID)
        XCTAssertEqual(note.timestamp, 7.5)
        XCTAssertEqual(note.text, "只有笔记也要显示")
    }

    private func fixedUUID(_ value: String) -> UUID {
        UUID(uuidString: value)!
    }
}
