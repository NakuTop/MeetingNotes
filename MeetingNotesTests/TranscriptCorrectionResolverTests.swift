import XCTest
@testable import MeetingNotes

@MainActor
final class TranscriptCorrectionResolverTests: XCTestCase {
    func testMeetingWithoutCorrectionsUsesGeneratedTranscriptText() {
        let earlierID = uuid("00000000-0000-0000-0000-000000000001")
        let laterID = uuid("00000000-0000-0000-0000-000000000002")
        let transcripts = [
            transcript(
                id: laterID,
                start: 4,
                end: 6,
                text: "后一句",
                speakerID: "speaker-2",
                source: .system,
                sequenceIndex: 1
            ),
            transcript(
                id: earlierID,
                start: 1,
                end: 3,
                text: "前一句",
                speakerID: "speaker-1",
                source: .microphone,
                sequenceIndex: 0
            )
        ]

        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: transcripts,
            corrections: []
        )

        XCTAssertEqual(
            resolved,
            [
                CanonicalTranscriptEntry(
                    id: earlierID,
                    transcriptIDs: [earlierID],
                    startTime: 1,
                    endTime: 3,
                    text: "前一句",
                    speakerID: "speaker-1",
                    source: .microphone,
                    isManuallyEdited: false
                ),
                CanonicalTranscriptEntry(
                    id: laterID,
                    transcriptIDs: [laterID],
                    startTime: 4,
                    endTime: 6,
                    text: "后一句",
                    speakerID: "speaker-2",
                    source: .system,
                    isManuallyEdited: false
                )
            ]
        )
    }

    func testCorrectionWinsOverGeneratedTextForExactTranscriptIDs() {
        let firstID = uuid("00000000-0000-0000-0000-000000000011")
        let secondID = uuid("00000000-0000-0000-0000-000000000012")
        let correctionID = uuid("00000000-0000-0000-0000-000000000013")
        let transcripts = [
            transcript(
                id: firstID,
                start: 10,
                end: 11,
                text: "生成文字一",
                speakerID: "speaker-1",
                source: .microphone,
                sequenceIndex: 0
            ),
            transcript(
                id: secondID,
                start: 11,
                end: 12,
                text: "生成文字二",
                speakerID: "speaker-1",
                source: .microphone,
                sequenceIndex: 1
            )
        ]
        let correction = correction(
            id: correctionID,
            anchorStart: 10,
            anchorEnd: 12,
            source: .microphone,
            originalText: "生成文字一生成文字二",
            replacementText: "手动修正文字",
            transcriptIDs: [secondID, firstID]
        )

        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: transcripts,
            corrections: [correction]
        )

        XCTAssertEqual(resolved.count, 1)
        let entry = resolved[0]
        XCTAssertEqual(entry.id, correctionID)
        XCTAssertEqual(entry.transcriptIDs, [firstID, secondID])
        XCTAssertEqual(entry.startTime, 10)
        XCTAssertEqual(entry.endTime, 12)
        XCTAssertEqual(entry.text, "手动修正文字")
        XCTAssertEqual(entry.speakerID, "speaker-1")
        XCTAssertEqual(entry.source, .microphone)
        XCTAssertTrue(entry.isManuallyEdited)
    }

    func testCorrectionReattachesBySourceAndTimeAfterIDsChange() throws {
        let oldID = uuid("00000000-0000-0000-0000-000000000021")
        let newID = uuid("00000000-0000-0000-0000-000000000022")
        let systemID = uuid("00000000-0000-0000-0000-000000000023")
        let correction = correction(
            id: uuid("00000000-0000-0000-0000-000000000024"),
            anchorStart: 20,
            anchorEnd: 23,
            source: .microphone,
            originalText: "旧生成文字",
            replacementText: "保留的手动文字",
            transcriptIDs: [oldID]
        )
        let transcripts = [
            transcript(
                id: newID,
                start: 20.25,
                end: 22.75,
                text: "新生成文字",
                speakerID: "speaker-new",
                source: .microphone,
                sequenceIndex: 4
            ),
            transcript(
                id: systemID,
                start: 20.25,
                end: 22.75,
                text: "同时间的系统声音",
                speakerID: "speaker-system",
                source: .system,
                sequenceIndex: 5
            )
        ]

        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: transcripts,
            corrections: [correction]
        )

        let edited = try XCTUnwrap(
            resolved.first(where: { $0.isManuallyEdited })
        )
        XCTAssertEqual(edited.transcriptIDs, [newID])
        XCTAssertEqual(edited.startTime, 20.25)
        XCTAssertEqual(edited.endTime, 22.75)
        XCTAssertEqual(edited.text, "保留的手动文字")
        XCTAssertEqual(edited.speakerID, "speaker-new")
        XCTAssertEqual(edited.source, .microphone)
        XCTAssertEqual(
            resolved.filter { $0.id == systemID }.map(\.text),
            ["同时间的系统声音"]
        )
    }

    func testAmbiguousOverlapDoesNotApplyOneCorrectionTwice() {
        let oldID = uuid("00000000-0000-0000-0000-000000000031")
        let firstID = uuid("00000000-0000-0000-0000-000000000032")
        let secondID = uuid("00000000-0000-0000-0000-000000000033")
        let correctionID = uuid("00000000-0000-0000-0000-000000000034")
        let correction = correction(
            id: correctionID,
            anchorStart: 30,
            anchorEnd: 32,
            source: .microphone,
            originalText: "旧文字",
            replacementText: "只能出现一次的修正",
            transcriptIDs: [oldID]
        )
        let transcripts = [
            transcript(
                id: firstID,
                start: 29.5,
                end: 31,
                text: "候选一",
                speakerID: "speaker-1",
                source: .microphone,
                sequenceIndex: 0
            ),
            transcript(
                id: secondID,
                start: 31,
                end: 32.5,
                text: "候选二",
                speakerID: "speaker-2",
                source: .microphone,
                sequenceIndex: 1
            )
        ]

        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: transcripts,
            corrections: [correction]
        )

        XCTAssertEqual(
            resolved.filter { $0.text == "只能出现一次的修正" }.count,
            1
        )
        XCTAssertEqual(
            Set(resolved.filter { !$0.isManuallyEdited }.map(\.id)),
            Set([firstID, secondID])
        )
        let preserved = resolved.first { $0.id == correctionID }
        XCTAssertEqual(preserved?.transcriptIDs, [oldID])
        XCTAssertEqual(preserved?.startTime, 30)
        XCTAssertEqual(preserved?.endTime, 32)
    }

    func testUnmatchedCorrectionRemainsVisibleAtItsAnchor() {
        let oldID = uuid("00000000-0000-0000-0000-000000000041")
        let correctionID = uuid("00000000-0000-0000-0000-000000000042")
        let correction = correction(
            id: correctionID,
            anchorStart: 40,
            anchorEnd: 43,
            source: .room,
            originalText: "不再存在的生成文字",
            replacementText: "未匹配也要保留",
            transcriptIDs: [oldID]
        )

        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: [],
            corrections: [correction]
        )

        XCTAssertEqual(
            resolved,
            [
                CanonicalTranscriptEntry(
                    id: correctionID,
                    transcriptIDs: [oldID],
                    startTime: 40,
                    endTime: 43,
                    text: "未匹配也要保留",
                    speakerID: nil,
                    source: .room,
                    isManuallyEdited: true
                )
            ]
        )
    }

    func testTinyOverlapDoesNotAttachToMuchLargerRegeneratedTranscript() throws {
        let oldID = uuid("00000000-0000-0000-0000-000000000061")
        let regeneratedID = uuid("00000000-0000-0000-0000-000000000062")
        let correctionID = uuid("00000000-0000-0000-0000-000000000063")
        let generatedText = "一段远长于原锚点的重新生成文字"
        let correction = correction(
            id: correctionID,
            anchorStart: 60,
            anchorEnd: 61,
            source: .microphone,
            originalText: "旧文字",
            replacementText: "手动修正",
            transcriptIDs: [oldID]
        )
        let regenerated = transcript(
            id: regeneratedID,
            start: 60.95,
            end: 80,
            text: generatedText,
            speakerID: "speaker-new",
            source: .microphone,
            sequenceIndex: 7
        )

        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: [regenerated],
            corrections: [correction]
        )

        let preservedCorrection = try XCTUnwrap(
            resolved.first(where: { $0.id == correctionID })
        )
        XCTAssertEqual(preservedCorrection.transcriptIDs, [oldID])
        XCTAssertEqual(preservedCorrection.startTime, 60)
        XCTAssertEqual(preservedCorrection.endTime, 61)
        XCTAssertEqual(preservedCorrection.text, "手动修正")
        let visibleGenerated = try XCTUnwrap(
            resolved.first(where: { $0.id == regeneratedID })
        )
        XCTAssertEqual(visibleGenerated.text, generatedText)
        XCTAssertFalse(visibleGenerated.isManuallyEdited)
    }

    func testCompetingFallbackCorrectionsDoNotConsumeSharedTranscript() throws {
        let firstOldID = uuid("00000000-0000-0000-0000-000000000071")
        let secondOldID = uuid("00000000-0000-0000-0000-000000000072")
        let regeneratedID = uuid("00000000-0000-0000-0000-000000000073")
        let firstCorrectionID = uuid(
            "00000000-0000-0000-0000-000000000074"
        )
        let secondCorrectionID = uuid(
            "00000000-0000-0000-0000-000000000075"
        )
        let firstCorrection = correction(
            id: firstCorrectionID,
            anchorStart: 69.8,
            anchorEnd: 71.8,
            source: .microphone,
            originalText: "旧文字一",
            replacementText: "手动修正一",
            transcriptIDs: [firstOldID]
        )
        let secondCorrection = correction(
            id: secondCorrectionID,
            anchorStart: 70.2,
            anchorEnd: 72.2,
            source: .microphone,
            originalText: "旧文字二",
            replacementText: "手动修正二",
            transcriptIDs: [secondOldID]
        )
        let regenerated = transcript(
            id: regeneratedID,
            start: 70,
            end: 72,
            text: "共享候选生成文字",
            speakerID: "speaker-new",
            source: .microphone,
            sequenceIndex: 8
        )

        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: [regenerated],
            corrections: [firstCorrection, secondCorrection]
        )

        let visibleGenerated = try XCTUnwrap(
            resolved.first(where: { $0.id == regeneratedID })
        )
        XCTAssertFalse(visibleGenerated.isManuallyEdited)
        let preservedFirst = try XCTUnwrap(
            resolved.first(where: { $0.id == firstCorrectionID })
        )
        XCTAssertEqual(preservedFirst.transcriptIDs, [firstOldID])
        XCTAssertEqual(preservedFirst.startTime, 69.8)
        let preservedSecond = try XCTUnwrap(
            resolved.first(where: { $0.id == secondCorrectionID })
        )
        XCTAssertEqual(preservedSecond.transcriptIDs, [secondOldID])
        XCTAssertEqual(preservedSecond.startTime, 70.2)
    }

    func testMixedCorrectionPrefersExactMixedSourceCandidate() throws {
        let oldID = uuid("00000000-0000-0000-0000-000000000081")
        let mixedID = uuid("00000000-0000-0000-0000-000000000082")
        let systemID = uuid("00000000-0000-0000-0000-000000000083")
        let correction = correction(
            id: uuid("00000000-0000-0000-0000-000000000084"),
            anchorStart: 80,
            anchorEnd: 82,
            source: .mixed,
            originalText: "旧混合文字",
            replacementText: "优先绑定混合候选",
            transcriptIDs: [oldID]
        )
        let transcripts = [
            transcript(
                id: mixedID,
                start: 80,
                end: 82,
                text: "新混合候选",
                speakerID: nil,
                source: .mixed,
                sequenceIndex: 0
            ),
            transcript(
                id: systemID,
                start: 80,
                end: 82,
                text: "属性化候选",
                speakerID: "remote",
                source: .system,
                sequenceIndex: 1
            )
        ]

        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: transcripts,
            corrections: [correction]
        )

        let edited = try XCTUnwrap(
            resolved.first(where: { $0.isManuallyEdited })
        )
        XCTAssertEqual(edited.transcriptIDs, [mixedID])
        XCTAssertEqual(edited.source, .mixed)
        XCTAssertEqual(
            resolved.filter { !$0.isManuallyEdited }.map(\.id),
            [systemID]
        )
    }

    func testAttributedCorrectionDoesNotFallbackToDifferentAttributedSource()
        throws {
        let oldID = uuid("00000000-0000-0000-0000-000000000091")
        let systemID = uuid("00000000-0000-0000-0000-000000000092")
        let correctionID = uuid(
            "00000000-0000-0000-0000-000000000093"
        )
        let correction = correction(
            id: correctionID,
            anchorStart: 90,
            anchorEnd: 92,
            source: .microphone,
            originalText: "旧麦克风文字",
            replacementText: "不能误绑系统声音",
            transcriptIDs: [oldID]
        )
        let systemTranscript = transcript(
            id: systemID,
            start: 90,
            end: 92,
            text: "同时间系统声音",
            speakerID: "remote",
            source: .system,
            sequenceIndex: 0
        )

        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: [systemTranscript],
            corrections: [correction]
        )

        let preserved = try XCTUnwrap(
            resolved.first(where: { $0.id == correctionID })
        )
        XCTAssertEqual(preserved.transcriptIDs, [oldID])
        XCTAssertEqual(preserved.source, .microphone)
        XCTAssertEqual(
            resolved.first(where: { $0.id == systemID })?.text,
            "同时间系统声音"
        )
    }

    func testAttributedCorrectionDoesNotUseExactIDDifferentAttributedSource()
        throws {
        let systemID = uuid("00000000-0000-0000-0000-000000000094")
        let correctionID = uuid(
            "00000000-0000-0000-0000-000000000095"
        )
        let correction = correction(
            id: correctionID,
            anchorStart: 94,
            anchorEnd: 96,
            source: .microphone,
            originalText: "旧麦克风文字",
            replacementText: "不能用相同 ID 误绑系统声音",
            transcriptIDs: [systemID]
        )
        let systemTranscript = transcript(
            id: systemID,
            start: 94,
            end: 96,
            text: "相同 ID 的系统声音",
            speakerID: "remote",
            source: .system,
            sequenceIndex: 0
        )

        let resolved = TranscriptCorrectionResolver.resolve(
            transcripts: [systemTranscript],
            corrections: [correction]
        )

        XCTAssertEqual(resolved.count, 2)
        XCTAssertEqual(
            resolved.first(where: { $0.id == correctionID })?.source,
            .microphone
        )
        XCTAssertEqual(
            resolved.first(where: { $0.id == systemID })?.text,
            "相同 ID 的系统声音"
        )
    }

    private func transcript(
        id: UUID,
        start: TimeInterval,
        end: TimeInterval,
        text: String,
        speakerID: String?,
        source: TranscriptAudioSource,
        sequenceIndex: Int
    ) -> TranscriptRecord {
        TranscriptRecord(
            id: id,
            startTime: start,
            endTime: end,
            text: text,
            isFinal: true,
            speakerID: speakerID,
            sourceRawValue: source.rawValue,
            sourceRevision: 1,
            sequenceIndex: sequenceIndex
        )
    }

    private func correction(
        id: UUID,
        anchorStart: TimeInterval,
        anchorEnd: TimeInterval,
        source: TranscriptAudioSource,
        originalText: String,
        replacementText: String,
        transcriptIDs: [UUID]
    ) -> TranscriptCorrectionRecord {
        TranscriptCorrectionRecord(
            id: id,
            anchorStartTime: anchorStart,
            anchorEndTime: anchorEnd,
            source: source,
            originalText: originalText,
            replacementText: replacementText,
            transcriptIDs: transcriptIDs,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 1_001)
        )
    }

    private func uuid(_ string: String) -> UUID {
        UUID(uuidString: string)!
    }
}
