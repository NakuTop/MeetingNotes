import Foundation

struct SpeakerTranscriptAssembler: Sendable {
    func assemble(
        _ drafts: [AttributedTranscriptDraft]
    ) -> [AttributedTranscriptDraft] {
        let sanitized: [
            (offset: Int, draft: AttributedTranscriptDraft)
        ] = drafts.enumerated().compactMap { index, draft in
            guard let text = TranscriptTextSanitizer.nonEmpty(
                draft.transcript.text
            ) else {
                return nil
            }

            return (
                offset: index,
                draft: AttributedTranscriptDraft(
                    transcript: TranscriptDraft(
                        startTime: draft.transcript.startTime,
                        endTime: draft.transcript.endTime,
                        text: text
                    ),
                    speakerID: draft.speakerID,
                    source: draft.source
                )
            )
        }

        return sanitized.sorted { lhs, rhs in
            if lhs.draft.transcript.startTime
                != rhs.draft.transcript.startTime {
                return lhs.draft.transcript.startTime
                    < rhs.draft.transcript.startTime
            }
            return lhs.offset < rhs.offset
        }
        .map(\.draft)
    }
}
