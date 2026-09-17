import XCTest

@testable import MeetingNotes

final class SpeakerAttributionAccuracyTests: XCTestCase {
    func testInconsistentMetadataCannotBorrowTheTimestampOfALaterRepeatedWord() {
        let words: [TranscriptWordTiming] = [
            .init(text: "重复", startTime: 0, endTime: 1),
            .init(text: "重复", startTime: 1, endTime: 2),
        ]
        XCTAssertEqual(TranscriptWordAlignment.retainingWords(words, for: "重复", startTime: 0, endTime: 2), [])
        XCTAssertEqual(TranscriptWordAlignment.retainingWords(words, for: "重复", startTime: 0, endTime: 2,
                                                             removingPrefixFrom: "重复重复"), [words[1]])
    }

    func testMergerDropsOnlyProvenDuplicateWordTimings() {
        let result = TranscriptMerger().merge([
            .init(startTime: 0, endTime: 1, text: "开始"),
            .init(startTime: 1, endTime: 3, text: "开始讨论", words: [
                .init(text: "开始", startTime: 1, endTime: 2),
                .init(text: "讨论", startTime: 2, endTime: 3),
            ]),
        ])
        XCTAssertEqual(result.last?.text, "讨论")
        XCTAssertEqual(result.last?.words, [.init(text: "讨论", startTime: 2, endTime: 3)])
    }
    func testChineseScriptLanguageCodesUseUnicodeTimestampGroups() {
        XCTAssertTrue(WhisperWordTimingTokenizer.isChinese("zh"))
        XCTAssertTrue(WhisperWordTimingTokenizer.isChinese("zh-Hans"))
        XCTAssertTrue(WhisperWordTimingTokenizer.isChinese("zh-Hant"))
        XCTAssertFalse(WhisperWordTimingTokenizer.isChinese("en"))
        XCTAssertFalse(WhisperWordTimingTokenizer.isChinese(nil))
        let characters = ["我", "来", "说", "。"]
        let result = WhisperWordTimingTokenizer.unicodeGroups(tokens: [0, 1, 2, 3]) { tokens in
            tokens.map { characters[$0] }.joined()
        }
        XCTAssertEqual(result.words, characters)
        XCTAssertEqual(result.wordTokens.flatMap { $0 }, [0, 1, 2, 3])
    }

    func testTimestampGroupingNeverSplitsUTF8ByteFragmentsOrLosesTokens() {
        let bytes = Array("你好".utf8)
        let result = WhisperWordTimingTokenizer.unicodeGroups(tokens: Array(bytes.indices)) {
            tokens in
            String(decoding: tokens.map { bytes[$0] }, as: UTF8.self)
        }
        XCTAssertEqual(result.words, ["你", "好"])
        XCTAssertEqual(result.wordTokens, [[0, 1, 2], [3, 4, 5]])
    }
    func testShortInterjectionSplitsAtMeasuredWordsWithoutDroppingChineseOrEnglish() {
        let draft = TranscriptDraft(
            startTime: 0, endTime: 3, text: "先讨论 budget。对！继续。",
            words: [
                .init(text: "先讨论", startTime: 0, endTime: 0.7),
                .init(text: " budget。", startTime: 0.7, endTime: 1.5),
                .init(text: "对！", startTime: 1.5, endTime: 1.8),
                .init(text: "继续。", startTime: 1.8, endTime: 3),
            ])
        let result = SpeakerIntervalAssigner().assign(
            [draft],
            intervals: [
                .init(rawSpeakerID: "A", startTime: 0, endTime: 1.5),
                .init(rawSpeakerID: "B", startTime: 1.5, endTime: 1.8),
                .init(rawSpeakerID: "A", startTime: 1.8, endTime: 3),
            ], speakerPrefix: "room", source: .room)
        XCTAssertEqual(result.map(\.speakerID), ["room-1", "room-2", "room-1"])
        XCTAssertEqual(result.map { $0.transcript.text }.joined(), draft.text)
        XCTAssertEqual(result.map { $0.transcript.startTime }, [0, 1.5, 1.8])
        XCTAssertEqual(result.map { $0.transcript.endTime }, [1.5, 1.8, 3])
        XCTAssertEqual(result.map(\.attributionStatus), [.attributed, .attributed, .attributed])
    }

    func testSimultaneousSpeechIsNotPresentedAsOneCertainPerson() {
        let result = SpeakerIntervalAssigner().assign(
            [.init(startTime: 0, endTime: 1, text: "同时说")],
            intervals: [
                .init(rawSpeakerID: "A", startTime: 0, endTime: 1),
                .init(rawSpeakerID: "B", startTime: 0.4, endTime: 0.9),
            ], speakerPrefix: "room", source: .room)
        XCTAssertNil(result.first?.speakerID)
        XCTAssertEqual(result.first?.attributionStatus, .overlapping)
        XCTAssertEqual(
            TranscriptSpeakerLabelPolicy.label(
                speakerID: nil, source: .room,
                attributionStatus: .overlapping), "重叠发言")
    }

    func testBadOrMissingWordTimingNeverInventsACharacterBoundary() {
        for words: [TranscriptWordTiming] in [
            [], [.init(text: "不匹配", startTime: 0, endTime: 1)],
            [.init(text: "原文", startTime: .nan, endTime: 1)],
        ] {
            let original = TranscriptDraft(startTime: 0, endTime: 2, text: "原文不能被改写", words: words)
            let result = SpeakerIntervalAssigner().assign(
                [original],
                intervals: [
                    .init(rawSpeakerID: "A", startTime: 0, endTime: 1),
                    .init(rawSpeakerID: "B", startTime: 1, endTime: 2),
                ], speakerPrefix: "room", source: .room)
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result.first?.transcript.text, original.text)
            XCTAssertEqual(result.first?.attributionStatus, .uncertain)
            XCTAssertNil(result.first?.speakerID)
        }
    }

    func testFourAndFiveSpeakersKeepWholeMeetingIdentityAcrossReturns() {
        for count in [4, 5] {
            let drafts = (0..<(count * 3)).map {
                TranscriptDraft(startTime: Double($0), endTime: Double($0 + 1), text: "发言")
            }
            let intervals = drafts.enumerated().map { index, draft in
                SpeakerInterval(
                    rawSpeakerID: "raw-\(index % count)", startTime: draft.startTime,
                    endTime: draft.endTime)
            }
            let result = SpeakerIntervalAssigner().assign(
                drafts, intervals: intervals, speakerPrefix: "room", source: .room)
            XCTAssertEqual(result.map(\.speakerID), drafts.indices.map { "room-\($0 % count + 1)" })
        }
    }

    func testWordTimingsSurviveBuilderMergerAndAssemblerInMeetingTime() {
        XCTAssertTrue(WhisperDecodingPolicy.options.wordTimestamps)
        let drafts = WhisperTranscriptDraftBuilder.makeDrafts(
            resultLanguage: "zh", resultText: "甲说乙答",
            segments: [
                .init(
                    start: 0, end: 2, text: "甲说乙答",
                    words: [
                        .init(text: "甲说", startTime: 0, endTime: 1),
                        .init(text: "乙答", startTime: 1, endTime: 2),
                    ])
            ], sampleCount: 32_000, startingAt: 10
        )
        let merged = TranscriptMerger().merge(drafts)
        let output = SpeakerTranscriptAssembler().assemble(
            merged.map {
                AttributedTranscriptDraft(transcript: $0, speakerID: "room-1", source: .room)
            })
        XCTAssertEqual(output.first?.transcript.words.map(\.startTime), [10, 11])
        XCTAssertEqual(output.first?.transcript.words.map(\.endTime), [11, 12])
    }

    @MainActor
    func testCorrectionMadeWhileInferenceRunsSurvivesWordSplitWithoutDuplicateText() throws {
        for retry in [false, true] {
            let repository = try MeetingRepository.inMemory()
            let id = try repository.createMeeting(
                mode: .offline, startedAt: .now, speakerDiarizationRequested: true)
            let original = TranscriptDraft(
                startTime: 0, endTime: 2, text: "甲说乙答",
                words: [
                    .init(text: "甲说", startTime: 0, endTime: 1),
                    .init(text: "乙答", startTime: 1, endTime: 2),
                ])
            try repository.appendTranscript(
                meetingID: id, start: 0, end: 2, text: original.text, words: original.words)
            let proposed = SpeakerIntervalAssigner().assign(
                [original],
                intervals: [
                    .init(rawSpeakerID: "A", startTime: 0, endTime: 1),
                    .init(rawSpeakerID: "B", startTime: 1, endTime: 2),
                ], speakerPrefix: "room", source: .room)
            XCTAssertEqual(proposed.count, 2)
            try repository.saveTranscriptCorrection(
                meetingID: id, transcriptIDs: repository.transcripts(meetingID: id).map(\.id),
                anchorStartTime: 0, anchorEndTime: 2, source: .mixed, originalText: original.text,
                replacementText: "我手工修正的内容"
            )
            if retry {
                let meeting = try repository.meeting(id: id)
                meeting.speakerProcessingState = .completed
                try repository.updateMeetingState(id: id, state: .ready)
                try repository.beginSpeakerDiarizationRetry(meetingID: id)
                try repository.completeSpeakerDiarizationRetry(
                    meetingID: id, drafts: proposed, sourceRevision: 1)
            } else {
                try repository.replaceTranscripts(
                    meetingID: id, drafts: proposed, sourceRevision: 1)
            }
            let canonical = try repository.canonicalTranscripts(meetingID: id)
            XCTAssertEqual(canonical.map(\.text), ["我手工修正的内容"])
            XCTAssertTrue(try XCTUnwrap(canonical.first).isManuallyEdited)
            XCTAssertNil(canonical.first?.speakerID)
            XCTAssertEqual(canonical.first?.attributionStatus, .uncertain)
            XCTAssertEqual(try repository.transcripts(meetingID: id).first?.words, original.words)
        }
    }

    func testFourHourThreeThousandSegmentAttributionKeepsEveryTurn() {
        let drafts = (0..<3_000).map { index in
            let start = Double(index) * 4.8
            return TranscriptDraft(
                startTime: start, endTime: start + 4, text: "前半后半",
                words: [
                    .init(text: "前半", startTime: start, endTime: start + 2),
                    .init(text: "后半", startTime: start + 2, endTime: start + 4),
                ])
        }
        let intervals = drafts.enumerated().flatMap { index, draft in
            [
                SpeakerInterval(
                    rawSpeakerID: "s\(index % 5)", startTime: draft.startTime,
                    endTime: draft.startTime + 2),
                SpeakerInterval(
                    rawSpeakerID: "s\((index + 1) % 5)", startTime: draft.startTime + 2,
                    endTime: draft.endTime),
            ]
        }
        let start = ContinuousClock.now
        let result = SpeakerIntervalAssigner().assign(
            drafts, intervals: intervals, speakerPrefix: "room", source: .room)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(result.count, 6_000)
        XCTAssertEqual(result.map { $0.transcript.text }.joined(), drafts.map(\.text).joined())
        XCTAssertLessThan(elapsed, .seconds(5))
    }
    func testSilenceGapDoesNotBorrowNearestSpeaker() {
        let result = SpeakerIntervalAssigner().assignedRawSpeakerIDs(
            [.init(startTime: 10, endTime: 11, text: "不要猜测")],
            intervals: [.init(rawSpeakerID: "A", startTime: 12, endTime: 13)]
        )
        XCTAssertEqual(result, [nil])
    }

    func testEquallyPlausibleSpeakersRemainUncertain() {
        let result = SpeakerIntervalAssigner().assignedRawSpeakerIDs(
            [.init(startTime: 0, endTime: 2, text: "甲乙轮流发言")],
            intervals: [
                .init(rawSpeakerID: "A", startTime: 0, endTime: 1),
                .init(rawSpeakerID: "B", startTime: 1, endTime: 2),
            ]
        )
        XCTAssertEqual(result, [nil])
    }

    func testEvidenceForOneSpeakerIsCombinedAcrossIntervals() {
        let result = SpeakerIntervalAssigner().assignedRawSpeakerIDs(
            [.init(startTime: 0, endTime: 4, text: "同一人的连续证据")],
            intervals: [
                .init(rawSpeakerID: "A", startTime: 0, endTime: 1.4),
                .init(rawSpeakerID: "A", startTime: 1.4, endTime: 2.8),
                .init(rawSpeakerID: "B", startTime: 2.5, endTime: 4),
            ]
        )
        XCTAssertEqual(result, ["A"])
    }

    func testDuplicateIntervalsDoNotManufactureSpeakerEvidence() {
        let result = SpeakerIntervalAssigner().assignedRawSpeakerIDs(
            [.init(startTime: 0, endTime: 4, text: "不重复计算")],
            intervals: Array(
                repeating: .init(rawSpeakerID: "A", startTime: 0, endTime: 1), count: 8)
                + [.init(rawSpeakerID: "B", startTime: 1, endTime: 4)]
        )
        XCTAssertEqual(result, ["B"])
    }
}
