import XCTest
@testable import MeetingNotes

final class TranscriptSpeakerDisplayPolicyTests: XCTestCase {
    func testKnownSpeakerIDsMapToLocalizedBadges() {
        XCTAssertEqual(
            TranscriptSpeakerDisplayPolicy.badge(
                speakerID: "me",
                source: .microphone
            ),
            TranscriptSpeakerBadge(
                label: "我",
                paletteIndex: 0,
                isLocalUser: true
            )
        )
        XCTAssertEqual(
            TranscriptSpeakerDisplayPolicy.badge(
                speakerID: "remote",
                source: .system
            ),
            TranscriptSpeakerBadge(
                label: "远端",
                paletteIndex: 0,
                isLocalUser: false
            )
        )
        XCTAssertEqual(
            TranscriptSpeakerDisplayPolicy.badge(
                speakerID: "remote-2",
                source: .system
            ),
            TranscriptSpeakerBadge(
                label: "远端 2",
                paletteIndex: 1,
                isLocalUser: false
            )
        )
        XCTAssertEqual(
            TranscriptSpeakerDisplayPolicy.badge(
                speakerID: "room-3",
                source: .room
            ),
            TranscriptSpeakerBadge(
                label: "说话人 3",
                paletteIndex: 2,
                isLocalUser: false
            )
        )
    }

    func testNumberedSpeakerPaletteIndexesAreStableAndBounded() {
        let first = TranscriptSpeakerDisplayPolicy.badge(
            speakerID: "remote-8",
            source: .system
        )
        let repeated = TranscriptSpeakerDisplayPolicy.badge(
            speakerID: "remote-8",
            source: .system
        )
        let room = TranscriptSpeakerDisplayPolicy.badge(
            speakerID: "room-8",
            source: .room
        )

        XCTAssertEqual(first?.paletteIndex, 1)
        XCTAssertEqual(repeated?.paletteIndex, first?.paletteIndex)
        XCTAssertEqual(room?.paletteIndex, first?.paletteIndex)
    }

    func testUnknownAndMixedTranscriptsDoNotShowMisleadingBadges() {
        XCTAssertNil(
            TranscriptSpeakerDisplayPolicy.badge(
                speakerID: nil,
                source: .mixed
            )
        )
        XCTAssertNil(
            TranscriptSpeakerDisplayPolicy.badge(
                speakerID: "unknown",
                source: .system
            )
        )
        XCTAssertNil(
            TranscriptSpeakerDisplayPolicy.badge(
                speakerID: "remote-2",
                source: .mixed
            )
        )
        XCTAssertNil(
            TranscriptSpeakerDisplayPolicy.badge(
                speakerID: "me",
                source: .system
            )
        )
    }

    @MainActor
    func testDisplayEntriesCarryPersistedSpeakerIdentityAndSource() throws {
        let transcript = TranscriptRecord(
            startTime: 2,
            endTime: 3,
            text: "你好",
            isFinal: true,
            speakerID: "remote-2",
            sourceRawValue: TranscriptAudioSource.system.rawValue
        )

        let entry = try XCTUnwrap(
            TranscriptDisplayPolicy.entries(from: [transcript]).first
        )

        XCTAssertEqual(entry.speakerID, "remote-2")
        XCTAssertEqual(entry.source, .system)
    }
}
