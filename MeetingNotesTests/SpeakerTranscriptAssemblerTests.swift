import XCTest
@testable import MeetingNotes

final class SpeakerTranscriptAssemblerTests: XCTestCase {
    func testAssembleSortsOverlappingSourcesChronologically() {
        let drafts = [
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 8,
                    endTime: 10,
                    text: "我稍后补充"
                ),
                speakerID: "me",
                source: .microphone
            ),
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 2,
                    endTime: 9,
                    text: "远端先开始"
                ),
                speakerID: "remote",
                source: .system
            ),
            AttributedTranscriptDraft(
                transcript: TranscriptDraft(
                    startTime: 6,
                    endTime: 7,
                    text: "本地插话"
                ),
                speakerID: "me",
                source: .microphone
            )
        ]

        let assembled = SpeakerTranscriptAssembler().assemble(drafts)

        XCTAssertEqual(
            assembled.map(\.transcript.text),
            ["远端先开始", "本地插话", "我稍后补充"]
        )
        XCTAssertEqual(
            assembled.map(\.source),
            [.system, .microphone, .microphone]
        )
        XCTAssertEqual(
            assembled.map(\.speakerID),
            ["remote", "me", "me"]
        )
    }

    func testAssemblePreservesInputOrderWhenStartTimesTie() {
        let drafts = [
            makeDraft(text: "first", endTime: 5, source: .system),
            makeDraft(text: "second", endTime: 3, source: .microphone),
            makeDraft(text: "third", endTime: 4, source: .room)
        ]

        let assembled = SpeakerTranscriptAssembler().assemble(drafts)

        XCTAssertEqual(
            assembled.map(\.transcript.text),
            ["first", "second", "third"]
        )
    }

    func testAssembleTrimsTextAndFiltersWhitespaceOnlyDrafts() {
        let drafts = [
            makeDraft(text: " \n\t ", source: .mixed),
            makeDraft(text: "  保留内容 \n", source: .room)
        ]

        let assembled = SpeakerTranscriptAssembler().assemble(drafts)

        XCTAssertEqual(assembled.count, 1)
        XCTAssertEqual(assembled[0].transcript.text, "保留内容")
        XCTAssertEqual(assembled[0].source, .room)
    }

    func testAssembleKeepsMatchingSimultaneousTextFromDifferentSources() {
        let drafts = [
            makeDraft(
                text: "发布计划",
                speakerID: "me",
                source: .microphone
            ),
            makeDraft(
                text: "发布计划",
                speakerID: "remote",
                source: .system
            )
        ]

        let assembled = SpeakerTranscriptAssembler().assemble(drafts)

        XCTAssertEqual(assembled.count, 2)
        XCTAssertEqual(assembled.map(\.source), [.microphone, .system])
        XCTAssertEqual(assembled.map(\.speakerID), ["me", "remote"])
    }

    private func makeDraft(
        text: String,
        startTime: TimeInterval = 1,
        endTime: TimeInterval = 2,
        speakerID: String? = nil,
        source: TranscriptAudioSource
    ) -> AttributedTranscriptDraft {
        AttributedTranscriptDraft(
            transcript: TranscriptDraft(
                startTime: startTime,
                endTime: endTime,
                text: text
            ),
            speakerID: speakerID,
            source: source
        )
    }
}
