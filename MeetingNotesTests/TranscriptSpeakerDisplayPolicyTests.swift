import XCTest
@testable import MeetingNotes

final class TranscriptSpeakerDisplayPolicyTests: XCTestCase {
    func testSemanticLabelPolicyExactlyMatchesEverySupportedCurrentRule() {
        XCTAssertEqual(
            TranscriptSpeakerLabelPolicy.label(
                speakerID: "me",
                source: .microphone
            ),
            "我"
        )
        XCTAssertEqual(
            TranscriptSpeakerLabelPolicy.label(
                speakerID: "remote",
                source: .system
            ),
            "远端"
        )
        XCTAssertEqual(
            TranscriptSpeakerLabelPolicy.label(
                speakerID: "remote-2",
                source: .system
            ),
            "远端 2"
        )
        XCTAssertEqual(
            TranscriptSpeakerLabelPolicy.label(
                speakerID: "room-3",
                source: .room
            ),
            "说话人 3"
        )
    }

    func testCustomSpeakerNameOverridesSemanticAndNumberedLabels() {
        let names = [
            "me": "沈明昊",
            "remote-2": "张老师",
            "raw-provider-id": "产品负责人",
        ]

        XCTAssertEqual(
            TranscriptSpeakerLabelPolicy.label(
                speakerID: "me",
                source: .microphone,
                customNames: names
            ),
            "沈明昊"
        )
        XCTAssertEqual(
            TranscriptSpeakerLabelPolicy.label(
                speakerID: "remote-2",
                source: .system,
                customNames: names
            ),
            "张老师"
        )
        XCTAssertEqual(
            TranscriptSpeakerLabelPolicy.label(
                speakerID: "raw-provider-id",
                source: .system,
                customNames: names
            ),
            "产品负责人"
        )
        XCTAssertNil(
            TranscriptSpeakerLabelPolicy.label(
                speakerID: nil,
                source: .mixed,
                customNames: names
            )
        )
    }

    func testSpeakerBadgeUsesCustomNameWithoutChangingStableIdentityStyle() {
        XCTAssertEqual(
            TranscriptSpeakerDisplayPolicy.badge(
                speakerID: "remote-2",
                source: .system,
                customNames: ["remote-2": "张老师"]
            ),
            TranscriptSpeakerBadge(
                label: "张老师",
                paletteIndex: 1,
                isLocalUser: false
            )
        )
    }

    func testSemanticLabelPolicyRejectsEveryUnsupportedCurrentRule() {
        let unsupported: [(String?, TranscriptAudioSource)] = [
            (nil, .mixed),
            ("unknown", .system),
            ("remote-2", .mixed),
            ("me", .system),
            ("remote-0", .system),
            ("room--1", .room),
            ("room-1", .microphone)
        ]

        for (speakerID, source) in unsupported {
            XCTAssertNil(
                TranscriptSpeakerLabelPolicy.label(
                    speakerID: speakerID,
                    source: source
                )
            )
        }
    }

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

    @MainActor
    func testTranscriptDisplayUsesCanonicalCorrectedText() throws {
        let generatedID = UUID()
        let correctionID = UUID()
        let canonical = CanonicalTranscriptEntry(
            id: correctionID,
            transcriptIDs: [generatedID],
            startTime: 2,
            endTime: 4,
            text: "手动修正后的文字",
            speakerID: "room-2",
            source: .room,
            isManuallyEdited: true
        )

        let entry = try XCTUnwrap(
            TranscriptDisplayPolicy.entries(from: [canonical]).first
        )

        XCTAssertEqual(entry.id, correctionID)
        XCTAssertEqual(entry.transcriptIDs, [generatedID])
        XCTAssertEqual(entry.text, "手动修正后的文字")
        XCTAssertEqual(entry.speakerID, "room-2")
        XCTAssertEqual(entry.source, .room)
    }

    @MainActor
    func testMeetingDetailProjectionIncludesPersistedCorrections() throws {
        let repository = try MeetingRepository.inMemory()
        let meetingID = try repository.createMeeting(
            mode: .offline,
            startedAt: Date(timeIntervalSince1970: 100)
        )
        try repository.replaceTranscripts(
            meetingID: meetingID,
            drafts: [
                AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: 2,
                        endTime: 4,
                        text: "生成文字"
                    ),
                    speakerID: "room-2",
                    source: .room
                )
            ],
            sourceRevision: 1
        )
        let transcriptID = try XCTUnwrap(
            repository.transcripts(meetingID: meetingID).first?.id
        )
        try repository.saveTranscriptCorrection(
            meetingID: meetingID,
            transcriptIDs: [transcriptID],
            anchorStartTime: 2,
            anchorEndTime: 4,
            source: .room,
            originalText: "生成文字",
            replacementText: "详情页手动修正文字"
        )
        let meeting = try repository.meeting(id: meetingID)

        let projected = MeetingDetailTranscriptProjection.entries(
            for: meeting
        )
        let displayed = try XCTUnwrap(
            TranscriptDisplayPolicy.entries(from: projected).first
        )

        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(displayed.text, "详情页手动修正文字")
        XCTAssertEqual(displayed.transcriptIDs, [transcriptID])
    }

    @MainActor
    func testAdjacentSameSpeakerEntriesBecomeOneOrderedTurn() throws {
        let firstID = UUID()
        let secondID = UUID()
        let transcripts = [
            TranscriptRecord(
                id: firstID,
                startTime: 0,
                endTime: 2,
                text: " 第一段 ",
                isFinal: true,
                speakerID: "room-1",
                sourceRawValue: TranscriptAudioSource.room.rawValue
            ),
            TranscriptRecord(
                id: secondID,
                startTime: 5,
                endTime: 7,
                text: "第二段",
                isFinal: true,
                speakerID: "room-1",
                sourceRawValue: TranscriptAudioSource.room.rawValue
            ),
        ]

        let turns = TranscriptDisplayPolicy.turns(
            from: transcripts,
            bookmarks: []
        )

        let turn = try XCTUnwrap(turns.first)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turn.transcriptIDs, [firstID, secondID])
        XCTAssertEqual(turn.text, "第一段 第二段")
        XCTAssertEqual(turn.startTime, 0)
        XCTAssertEqual(turn.endTime, 7)
        XCTAssertEqual(transcripts.map(\.text), [" 第一段 ", "第二段"])
    }

    @MainActor
    func testTurnBoundariesRespectSpeakerGapNilIdentityAndBookmarks() {
        let transcripts = [
            makeTranscript(start: 0, end: 1, speakerID: "room-1"),
            makeTranscript(start: 2, end: 3, speakerID: "room-2"),
            makeTranscript(start: 10, end: 11, speakerID: "room-2"),
            makeTranscript(start: 12, end: 13, speakerID: nil),
            makeTranscript(start: 14, end: 15, speakerID: nil),
            makeTranscript(start: 29, end: 30, speakerID: "room-3"),
            makeTranscript(start: 34, end: 35, speakerID: "room-3"),
        ]
        let bookmark = BookmarkRecord(timestamp: 0)

        let turns = TranscriptDisplayPolicy.turns(
            from: transcripts,
            bookmarks: [bookmark]
        )

        XCTAssertEqual(turns.count, 7)
        XCTAssertEqual(turns.map(\.isHighlighted), [
            true, true, true, true, true, true, false,
        ])
    }

    @MainActor
    private func makeTranscript(
        start: TimeInterval,
        end: TimeInterval,
        speakerID: String?
    ) -> TranscriptRecord {
        TranscriptRecord(
            startTime: start,
            endTime: end,
            text: "\(start)",
            isFinal: true,
            speakerID: speakerID,
            sourceRawValue: TranscriptAudioSource.room.rawValue
        )
    }
}
