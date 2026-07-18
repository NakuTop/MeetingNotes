import XCTest
@preconcurrency import WhisperKit
@testable import MeetingNotes

final class TranscriptTextSanitizerTests: XCTestCase {
    func testCleansChineseTranscriptAndWhisperControlTokens() {
        XCTAssertEqual(
            TranscriptTextSanitizer.clean(
                "<|startoftranscript|><|zh|><|transcribe|><|7.00|> 我们开始开会。<|15.00|><|endoftext|>"
            ),
            "我们开始开会。"
        )
    }

    func testCleansEnglishTranscriptWithoutTranslatingIt() {
        XCTAssertEqual(
            TranscriptTextSanitizer.clean("<|en|> Let me test it."),
            "Let me test it."
        )
    }

    func testReturnsNilForControlTokenOnlyTranscript() {
        XCTAssertNil(TranscriptTextSanitizer.nonEmpty("<|endoftext|>"))
    }

    func testDropsUnterminatedTrailingWhisperMarkerWithoutLosingBody() {
        XCTAssertEqual(
            TranscriptTextSanitizer.clean("会议结束。 <|endoftext"),
            "会议结束。"
        )
        XCTAssertEqual(
            TranscriptTextSanitizer.clean("Keep the decision. <|"),
            "Keep the decision."
        )
        XCTAssertNil(TranscriptTextSanitizer.nonEmpty("<|unfinished"))
    }

    func testNormalizesWhitespaceAndPreservesOrdinaryAngleBracketTextAndPunctuation() {
        XCTAssertEqual(
            TranscriptTextSanitizer.clean(
                "  中文，  English\t<budget>\n保留！  "
            ),
            "中文， English <budget> 保留！"
        )
    }

    func testSinglePassBilingualDetectionLeavesLanguageUnsetUntilResultGate() {
        let options = WhisperDecodingPolicy.options

        XCTAssertEqual(options.task, .transcribe)
        XCTAssertNil(options.language)
        XCTAssertTrue(options.detectLanguage)
        XCTAssertTrue(options.skipSpecialTokens)
    }

    func testLanguagePolicyAcceptsChineseAndEnglishResultLanguages() {
        XCTAssertTrue(WhisperLanguagePolicy.accepts(language: "zh"))
        XCTAssertTrue(WhisperLanguagePolicy.accepts(language: "en"))
    }

    func testLanguagePolicyRejectsJapaneseAndFrenchResultLanguages() {
        XCTAssertFalse(WhisperLanguagePolicy.accepts(language: "ja"))
        XCTAssertFalse(WhisperLanguagePolicy.accepts(language: "fr"))
    }

    func testDraftBuilderPreservesMixedChineseAndEnglishForSupportedResult() {
        XCTAssertEqual(
            WhisperTranscriptDraftBuilder.makeDrafts(
                resultLanguage: "zh",
                resultText: "<|zh|> 中文 planning starts now.<|endoftext|>",
                segments: [],
                sampleCount: 16_000,
                startingAt: 2
            ),
            [
                TranscriptDraft(
                    startTime: 2,
                    endTime: 3,
                    text: "中文 planning starts now."
                )
            ]
        )
    }

    func testDraftBuilderRejectsUnsupportedResultLanguageBeforeTextProcessing() {
        XCTAssertTrue(
            WhisperTranscriptDraftBuilder.makeDrafts(
                resultLanguage: "ja",
                resultText: "English-looking text must still be rejected.",
                segments: [],
                sampleCount: 16_000,
                startingAt: 0
            ).isEmpty
        )
    }

    func testDraftBuilderCleansFallbackResultText() {
        XCTAssertEqual(
            WhisperTranscriptDraftBuilder.makeDrafts(
                resultLanguage: "zh",
                resultText: "<|zh|> 现在开始。<|endoftext|>",
                segments: [],
                sampleCount: 16_000,
                startingAt: 3
            ),
            [
                TranscriptDraft(
                    startTime: 3,
                    endTime: 4,
                    text: "现在开始。"
                )
            ]
        )
    }

    func testDraftBuilderCleansSegmentsAndOmitsTokenOnlySegments() {
        XCTAssertEqual(
            WhisperTranscriptDraftBuilder.makeDrafts(
                resultLanguage: "en",
                resultText: "unused",
                segments: [
                    .init(start: 0, end: 1, text: "<|en|> Hello."),
                    .init(start: 1, end: 2, text: "<|endoftext|>"),
                    .init(start: 2, end: 3, text: "<|zh|> 你好。")
                ],
                sampleCount: 48_000,
                startingAt: 10
            ),
            [
                TranscriptDraft(startTime: 10, endTime: 11, text: "Hello."),
                TranscriptDraft(startTime: 12, endTime: 13, text: "你好。")
            ]
        )
    }

    func testDraftBuilderOmitsTokenOnlyFallbackResult() {
        XCTAssertTrue(
            WhisperTranscriptDraftBuilder.makeDrafts(
                resultLanguage: "en",
                resultText: "<|endoftext|>",
                segments: [],
                sampleCount: 16_000,
                startingAt: 0
            ).isEmpty
        )
    }

    @MainActor
    func testDisplayPolicyCleansHistoricalRowsAndOmitsTokenOnlyRows() {
        let visible = TranscriptDisplayPolicy.entries(
            from: [
                TranscriptRecord(
                    startTime: 8,
                    endTime: 9,
                    text: "<|endoftext|>",
                    isFinal: true
                ),
                TranscriptRecord(
                    startTime: 4,
                    endTime: 5,
                    text: "<|zh|> 历史记录。<|7.00|>",
                    isFinal: true
                )
            ]
        )

        XCTAssertEqual(visible.map(\.startTime), [4])
        XCTAssertEqual(visible.map(\.text), ["历史记录。"])
    }
}
